import Foundation
import AlcoveQMP

/// The recordings of the handler's VMs.
struct RecordingTable {
    var active: [String: Recording] = [:]
    /// Summaries of recordings that ended by themselves and were not collected with `vm.record.stop`.
    var ended: [String: Recording.Summary] = [:]
    /// The directory of the latest recording per VM.
    var lastDirectory: [String: String] = [:]
    /// VMs found not running while they had an active recording.
    var vmGone: Set<String> = []
}

/// `vm.record.*` and the trace of every other op of a recorded VM.
extension ControlHandler {
    static let defaultRecordingSeconds = 900

    /// Whether the trace holds a frame before and after `op`.
    static func capturesFrames(op: String) -> Bool {
        isInput(op: op) || op.hasPrefix("vm.ui.")
    }

    /// Runs `run` and adds the op, its outcome and its frames to the VM's recording; without one it only runs `run`.
    func recorded(op: String, params: JSON, run: @Sendable () async throws -> JSON) async throws -> JSON {
        guard !op.hasPrefix("vm.record."), let vm = params["name"]?.stringValue, let recording = await liveRecording(vm) else {
            return try await run()
        }
        let framed = ControlHandler.capturesFrames(op: op)
        let before = framed ? await recording.capture() : nil
        let started = wallClock()
        let t0 = clock()
        let outcome: Result<JSON, Error>
        do { outcome = .success(try await run()) } catch { outcome = .failure(error) }
        let duration = t0.duration(to: clock())
        let after = framed ? await recording.capture() : nil
        await recording.record(op: op, params: params, outcome: outcome, started: started, duration: duration, before: before, after: after)
        var stopped = false
        if op == "vm.stop", case .success = outcome { stopped = true }
        if recordings.vmGone.remove(vm) != nil || stopped { await retireRecording(vm) }
        return try outcome.get()
    }

    /// The VM's recording while it is still active; one that reached its limit is retired first.
    func liveRecording(_ vm: String) async -> Recording? {
        guard let recording = recordings.active[vm] else { return nil }
        await recording.endIfDue()
        if await recording.isActive { return recording }
        await retireRecording(vm)
        return nil
    }

    /// Ends the VM's recording and keeps its summary for `vm.record.stop`.
    func retireRecording(_ vm: String) async {
        guard let recording = recordings.active.removeValue(forKey: vm) else { return }
        let summary = await recording.stop()
        recordings.ended[vm] = summary
        recordings.lastDirectory[vm] = summary.dir
    }

    /// Notes that the VM was found not running; its recording ends once the op that found out is traced.
    func noteVMGone(_ vm: String) {
        if recordings.active[vm] != nil { recordings.vmGone.insert(vm) }
    }

    func record(op: String, params: JSON) async throws -> JSON {
        let t = try await target(params)
        let vm = t.name
        let current = await liveRecording(vm)
        switch op {
        case "vm.record.start":
            if let current { throw ControlError.failed("'\(vm)' is already recording to \(current.directory.path); call vm.record.stop first") }
            return try await startRecording(t, params)
        case "vm.record.stop":
            if let current {
                recordings.active[vm] = nil
                let summary = await current.stop()
                recordings.lastDirectory[vm] = summary.dir
                return summary.json
            }
            guard let summary = recordings.ended.removeValue(forKey: vm) else { throw ControlError.failed("'\(vm)' is not recording") }
            return summary.json
        default:
            if let current {
                return ["recording": true, "dir": .string(current.directory.path),
                        "seconds": .double(await current.elapsedSeconds), "ops": .int(Int64(await current.opCount))]
            }
            guard let dir = recordings.lastDirectory[vm] else { return ["recording": false] }
            return ["recording": false, "dir": .string(dir)]
        }
    }

    private func startRecording(_ t: VMTarget, _ params: JSON) async throws -> JSON {
        let fps = try recordingNumber(params, "fps", default: 5, range: 1...30)
        let maxSeconds = try recordingNumber(params, "maxSeconds", default: ControlHandler.defaultRecordingSeconds, range: 1...86400)
        var video = true
        if let value = params["video"] {
            guard let flag = value.boolValue else { throw ControlError.wrongType("video", .boolean) }
            video = flag
        }
        let directory = try recordingDirectory(params, vm: t.name)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(TraceWriter.traceName).path) {
            throw ControlError.failed("'\(directory.path)' already holds a recording; choose another directory")
        }
        let recording = Recording(vm: t.name, directory: directory, fps: fps, video: video, maxSeconds: maxSeconds,
                                  frames: { try? await t.frame() }, clock: clock, now: wallClock)
        do { try await recording.start() } catch { throw ControlError.failed("cannot create the recording in '\(directory.path)': \(error)") }
        recordings.active[t.name] = recording
        recordings.ended[t.name] = nil
        recordings.vmGone.remove(t.name)
        recordings.lastDirectory[t.name] = directory.path
        return ["dir": .string(directory.path)]
    }

    private func recordingNumber(_ params: JSON, _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = params[key] else { return fallback }
        guard let number = value.intValue, range.contains(number) else {
            throw ControlError.failed("\(key) must be an integer between \(range.lowerBound) and \(range.upperBound)")
        }
        return number
    }

    private func recordingDirectory(_ params: JSON, vm: String) throws -> URL {
        if let value = params["dir"] {
            guard let path = value.stringValue, path.hasPrefix("/") else { throw ControlError.failed("dir must be an absolute path") }
            return URL(fileURLWithPath: path)
        }
        let base = recordingsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Alcove/Recordings")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return base.appendingPathComponent("\(vm.replacingOccurrences(of: "/", with: "-"))-\(formatter.string(from: wallClock()))")
    }
}
