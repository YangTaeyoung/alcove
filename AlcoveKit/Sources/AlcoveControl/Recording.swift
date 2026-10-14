import Foundation
import AlcoveQMP

/// Receives the frames of a recording and turns them into `video.mp4`.
protocol VideoSink: Sendable {
    /// Adds `frame` at `time` after the start of the recording.
    func append(frame: Frame, at time: Duration)
    /// Completes the file; no frame is appended afterwards.
    func finish() async
    /// Frames the encoder could not take.
    var droppedFrames: Int { get }
    /// Seconds of video appended.
    var appendedSeconds: Double { get }
    /// A sentence describing why the video could not be written; nil when it can.
    var errorMessage: String? { get }
    /// Adds the last frame of the recording; an encoder that is busy is given a moment, and the frame is not counted as dropped.
    func appendFinal(frame: Frame, at time: Duration) async
    /// Whether the file this sink's writer created is still there after `finish()`.
    var keptFile: Bool { get }
}

extension VideoSink {
    var keptFile: Bool { false }
    var droppedFrames: Int { 0 }
    var appendedSeconds: Double { 0 }
    var errorMessage: String? { nil }
    func appendFinal(frame: Frame, at time: Duration) async { append(frame: frame, at: time) }
}

/// A sink that discards everything.
struct NoVideoSink: VideoSink {
    func append(frame: Frame, at time: Duration) {}
    func finish() async {}
}

/// Hands the summary of one recording to a single caller.
final class SummaryDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    var isTaken: Bool { lock.withLock { taken } }

    /// True for the first call only.
    func take() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}

/// One recording of a VM's control ops: a trace file, the frames around input ops and an optional video.
actor Recording {
    struct Summary: Sendable, Equatable {
        let dir: String
        /// The video file: the finished video, or the file a failed writer kept because it plays; nil without one.
        let video: String?
        let trace: String
        let frames: Int
        let seconds: Double
        /// Trace lines written.
        let ops: Int
        let writeErrors: Int
        let lastWriteError: String?
        /// Seconds of video appended; nil without a video file.
        let videoSeconds: Double?
        let droppedFrames: Int?
        /// The wall-clock time at which the recording began to end.
        let ended: Date
        /// The sentence describing why the video could not be written; nil when it could.
        let videoError: String?

        var json: JSON {
            var obj: [String: JSON] = ["dir": .string(dir), "trace": .string(trace), "frames": .int(Int64(frames)),
                                       "seconds": .double(seconds), "ops": .int(Int64(ops)), "writeErrors": .int(Int64(writeErrors))]
            if let lastWriteError { obj["lastWriteError"] = .string(lastWriteError) }
            if let video { obj["video"] = .string(video) }
            if let videoSeconds { obj["videoSeconds"] = .double(videoSeconds) }
            if let droppedFrames { obj["droppedFrames"] = .int(Int64(droppedFrames)) }
            return .object(obj)
        }
    }

    nonisolated let delivery = SummaryDelivery()
    let vm: String
    let directory: URL
    let fps: Int
    let video: Bool
    let maxSeconds: Int
    private let framesSource: @Sendable () async -> Frame?
    private let sink: VideoSink
    private let openWriter: @Sendable (URL) async throws -> TraceStore
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let wallClock: @Sendable () -> Date

    /// Consecutive failed trace lines after which the recording ends itself.
    static let maxConsecutiveLineFailures = 20

    private var writer: TraceStore?
    private var startedAt = Date()
    private var startedInstant = ContinuousClock.now
    private var deadline = ContinuousClock.now
    private var seq = 0
    private var frameCount = 0
    private var lineCount = 0
    private var writeErrors = 0
    private var lastWriteError: String?
    private var consecutiveLineFailures = 0
    private var timer: Task<Void, Never>?
    private var sampler: Task<Void, Never>?
    private var lastVideoFrame: Frame?
    private var lastVideoAt = Duration.zero
    private var finishing: Task<Summary, Never>?

    init(vm: String, directory: URL, fps: Int, video: Bool, maxSeconds: Int, frames: @escaping @Sendable () async -> Frame?,
         sink: VideoSink = NoVideoSink(),
         openWriter: @escaping @Sendable (URL) async throws -> TraceStore = { try TraceWriter(directory: $0) },
         clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.vm = vm
        self.directory = directory
        self.fps = fps
        self.video = video
        self.maxSeconds = maxSeconds
        self.framesSource = frames
        self.sink = sink
        self.openWriter = openWriter
        self.clock = clock
        self.wallClock = now
    }

    var isActive: Bool { finishing == nil }

    /// The summary of a recording that is ending or has ended, once it has ended; nil while the recording is active.
    func ending() async -> Summary? {
        guard let finishing else { return nil }
        return await finishing.value
    }

    /// Longest stretch without an encoded frame while the screen does not change.
    static let videoKeepAlive = Duration.seconds(2)

    /// Creates the recording directory, starts the `maxSeconds` timer and, with video, the frame sampler.
    func start() async throws {
        writer = try await openWriter(directory)
        startedAt = wallClock()
        startedInstant = clock()
        deadline = startedInstant + .seconds(maxSeconds)
        let limit = maxSeconds
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            _ = await self?.stop()
        }
        if video {
            let interval = Duration.seconds(1.0 / Double(fps))
            sampler = Task { [weak self] in
                var tick = ContinuousClock.now
                while !Task.isCancelled {
                    await self?.sample()
                    tick = Recording.nextTick(after: tick, now: .now, interval: interval)
                    try? await Task.sleep(until: tick, clock: .continuous)
                }
            }
        }
    }

    /// The sampling tick after `tick`: one `interval` later, or the first later tick on the same schedule that is still ahead of `now`.
    static func nextTick(after tick: ContinuousClock.Instant, now: ContinuousClock.Instant, interval: Duration) -> ContinuousClock.Instant {
        let next = tick + interval
        guard next <= now else { return next }
        let missed = Int(((now - next) / interval).rounded(.down)) + 1
        return next + interval * missed
    }

    /// Reads one frame and encodes it unless it repeats the previous one.
    private func sample() async {
        guard isActive, let frame = await framesSource() else { return }
        guard isActive, !Task.isCancelled else { return }
        appendVideo(frame)
    }

    private func appendVideo(_ frame: Frame) {
        let elapsed = startedInstant.duration(to: clock())
        if let last = lastVideoFrame, last == frame, elapsed - lastVideoAt < Recording.videoKeepAlive { return }
        sink.append(frame: frame, at: elapsed)
        lastVideoFrame = frame
        lastVideoAt = elapsed
    }

    /// The current guest frame; nil when none can be captured.
    func capture() async -> Frame? { await framesSource() }

    /// Ends the recording when its `maxSeconds` have elapsed on the injected clock.
    func endIfDue() async {
        if isActive, clock() >= deadline { _ = await stop() }
    }

    private var maskedKeysDown: Set<String> = []

    /// Notes that the key `key` went down, and whether the trace masks it.
    func noteKeyDown(_ key: String, masked: Bool) {
        if masked { maskedKeysDown.insert(key) } else { maskedKeysDown.remove(key) }
    }

    /// Whether `key` went down masked and has not been released since; releasing it ends that.
    func releasesMaskedKey(_ key: String) -> Bool { maskedKeysDown.remove(key) != nil }

    var opCount: Int { lineCount }
    var writeErrorCount: Int { writeErrors }
    var latestWriteError: String? { lastWriteError }
    /// The sentence describing why the video could not be written, as soon as the writer failed; nil while it can.
    nonisolated var videoError: String? { sink.errorMessage }
    var elapsedSeconds: Double { Recording.seconds(startedInstant.duration(to: clock())) }

    /// Appends one trace line and its frames; nothing happens after the recording ended. `target` and `script` are
    /// written to the line when given.
    func record(op: String, params: JSON, outcome: Result<JSON, Error>, started: Date, duration: Duration,
                before: Frame?, after: Frame?, target: JSON? = nil, script: String? = nil, secrets: [String] = []) {
        guard isActive, let writer else { return }
        seq += 1
        let name = String(format: "%06d", seq)
        let beforePath = before.flatMap { writeFrame($0, name: "\(name)-before.jpg", with: writer) }
        let afterPath = after.flatMap { writeFrame($0, name: "\(name)-after.jpg", with: writer) }
        frameCount += (beforePath == nil ? 0 : 1) + (afterPath == nil ? 0 : 1)
        let entry = TraceEntry(seq: seq, time: started, ms: max(0, Int((started.timeIntervalSince(startedAt) * 1000).rounded())),
                               op: op, params: Recording.requestParams(params), outcome: outcome,
                               durationMs: Int((Recording.seconds(duration) * 1000).rounded()), before: beforePath, after: afterPath,
                               target: target, script: script, secrets: secrets)
        do {
            try writer.append(entry)
            lineCount += 1
            consecutiveLineFailures = 0
        } catch {
            noteWriteError("trace line \(seq) could not be written: \(ControlHandler.failureReason(error, fallback: "the disk write failed"))")
            consecutiveLineFailures += 1
            if consecutiveLineFailures >= Recording.maxConsecutiveLineFailures { _ = beginFinish() }
        }
    }

    private func writeFrame(_ frame: Frame, name: String, with writer: TraceStore) -> String? {
        do { return try writer.writeFrame(frame, name: name) } catch {
            noteWriteError("frame \(name) could not be written: \(ControlHandler.failureReason(error, fallback: "the disk write failed"))")
            return nil
        }
    }

    private func noteWriteError(_ message: String) {
        writeErrors += 1
        lastWriteError = message
    }

    /// Ends the recording and returns its summary; later calls return the same summary.
    func stop() async -> Summary {
        await beginFinish().value
    }

    private func beginFinish() -> Task<Summary, Never> {
        if let finishing { return finishing }
        let task = Task { await self.finalize() }
        finishing = task
        return task
    }

    private func finalize() async -> Summary {
        timer?.cancel()
        timer = nil
        let ended = wallClock()
        let seconds = elapsedSeconds
        writer?.close()
        writer = nil
        if let sampler {
            sampler.cancel()
            await sampler.value
            self.sampler = nil
        }
        if video, let last = await framesSource() ?? lastVideoFrame {
            await sink.appendFinal(frame: last, at: startedInstant.duration(to: clock()))
        }
        await sink.finish()
        if let message = sink.errorMessage { noteWriteError(message) }
        let videoURL = directory.appendingPathComponent("video.mp4")
        let size = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? nil
        let hasVideo = video && (sink.errorMessage == nil || sink.keptFile) && (size ?? 0) > 0
        return Summary(dir: directory.path, video: hasVideo ? videoURL.path : nil,
                       trace: directory.appendingPathComponent(TraceWriter.traceName).path, frames: frameCount,
                       seconds: (seconds * 10).rounded() / 10, ops: lineCount,
                       writeErrors: writeErrors, lastWriteError: lastWriteError,
                       videoSeconds: hasVideo ? (sink.appendedSeconds * 10).rounded() / 10 : nil,
                       droppedFrames: hasVideo ? sink.droppedFrames : nil, ended: ended, videoError: sink.errorMessage)
    }

    private static func requestParams(_ params: JSON) -> JSON {
        guard var fields = params.objectValue else { return params }
        fields["id"] = nil
        fields["op"] = nil
        return .object(fields)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
