import Foundation
import AlcoveQMP

/// Receives the frames of a recording and turns them into `video.mp4`.
protocol VideoSink: Sendable {
    func append(frame: Frame, at time: Duration)
    func finish() async
}

/// A sink that discards everything.
struct NoVideoSink: VideoSink {
    func append(frame: Frame, at time: Duration) {}
    func finish() async {}
}

/// One recording of a VM's control ops: a trace file, the frames around input ops and an optional video.
actor Recording {
    struct Summary: Sendable, Equatable {
        let dir: String
        let video: String?
        let trace: String
        let frames: Int
        let seconds: Double
        let ops: Int

        var json: JSON {
            var obj: [String: JSON] = ["dir": .string(dir), "trace": .string(trace), "frames": .int(Int64(frames)),
                                       "seconds": .double(seconds), "ops": .int(Int64(ops))]
            if let video { obj["video"] = .string(video) }
            return .object(obj)
        }
    }

    let vm: String
    let directory: URL
    let fps: Int
    let video: Bool
    let maxSeconds: Int
    private let framesSource: @Sendable () async -> Frame?
    private let sink: VideoSink
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let wallClock: @Sendable () -> Date

    private var writer: TraceWriter?
    private var startedAt = Date()
    private var startedInstant = ContinuousClock.now
    private var deadline = ContinuousClock.now
    private var seq = 0
    private var frameCount = 0
    private var timer: Task<Void, Never>?
    private var finishing: Task<Summary, Never>?

    init(vm: String, directory: URL, fps: Int, video: Bool, maxSeconds: Int, frames: @escaping @Sendable () async -> Frame?,
         sink: VideoSink = NoVideoSink(), clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.vm = vm
        self.directory = directory
        self.fps = fps
        self.video = video
        self.maxSeconds = maxSeconds
        self.framesSource = frames
        self.sink = sink
        self.clock = clock
        self.wallClock = now
    }

    var isActive: Bool { finishing == nil }

    /// Creates the recording directory and starts the `maxSeconds` timer.
    func start() throws {
        writer = try TraceWriter(directory: directory)
        startedAt = wallClock()
        startedInstant = clock()
        deadline = startedInstant + .seconds(maxSeconds)
        let limit = maxSeconds
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            _ = await self?.stop()
        }
    }

    /// The current guest frame; nil when none can be captured.
    func capture() async -> Frame? { await framesSource() }

    /// Ends the recording when its `maxSeconds` have elapsed on the injected clock.
    func endIfDue() async {
        if isActive, clock() >= deadline { _ = await stop() }
    }

    var opCount: Int { seq }
    var elapsedSeconds: Double { Recording.seconds(startedInstant.duration(to: clock())) }

    /// Appends one trace line and its frames; nothing happens after the recording ended.
    func record(op: String, params: JSON, outcome: Result<JSON, Error>, started: Date, duration: Duration,
                before: Frame?, after: Frame?) {
        guard isActive, let writer else { return }
        seq += 1
        let name = String(format: "%06d", seq)
        let beforePath = before.flatMap { try? writer.writeFrame($0, name: "\(name)-before.jpg") }
        let afterPath = after.flatMap { try? writer.writeFrame($0, name: "\(name)-after.jpg") }
        frameCount += (beforePath == nil ? 0 : 1) + (afterPath == nil ? 0 : 1)
        let entry = TraceEntry(seq: seq, time: started, ms: max(0, Int((started.timeIntervalSince(startedAt) * 1000).rounded())),
                               op: op, params: Recording.requestParams(params), outcome: outcome,
                               durationMs: Int((Recording.seconds(duration) * 1000).rounded()), before: beforePath, after: afterPath)
        try? writer.append(entry)
    }

    /// Ends the recording and returns its summary; later calls return the same summary.
    func stop() async -> Summary {
        if let finishing { return await finishing.value }
        let task = Task { await self.finalize() }
        finishing = task
        return await task.value
    }

    private func finalize() async -> Summary {
        timer?.cancel()
        timer = nil
        let seconds = elapsedSeconds
        writer?.close()
        writer = nil
        await sink.finish()
        let videoURL = directory.appendingPathComponent("video.mp4")
        return Summary(dir: directory.path, video: FileManager.default.fileExists(atPath: videoURL.path) ? videoURL.path : nil,
                       trace: directory.appendingPathComponent(TraceWriter.traceName).path, frames: frameCount,
                       seconds: (seconds * 10).rounded() / 10, ops: seq)
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
