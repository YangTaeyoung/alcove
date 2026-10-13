import Foundation
import AlcoveAgent
import AlcoveQMP

/// The recordings of the handler's VMs.
struct RecordingTable {
    var active: [String: Recording] = [:]
    /// Recordings that ended by themselves and were not collected with `vm.record.stop`, with their summaries.
    var ended: [String: EndedRecording] = [:]
    /// The directory of the latest recording per VM.
    var lastDirectory: [String: String] = [:]
    /// The recording each VM had when it was found not running.
    var vmGone: [String: Recording] = [:]
    /// Recordings being created, by VM, with their directory.
    var starting: [String: URL] = [:]
    /// Recordings that are ending; `vm.record.stop` waits for them.
    var retiring: [String: Recording] = [:]
    /// What the diagnostics collector needs of the recording of each VM that ended last.
    var latest: [String: LastRecording] = [:]
}

/// A recording that ended and whose summary is waiting for `vm.record.stop`.
struct EndedRecording {
    let delivery: SummaryDelivery
    let summary: Recording.Summary
}

/// The directory, the end time and the video error of a recording that ended; the recording itself is not kept.
struct LastRecording: Sendable {
    let directory: URL
    let ended: Date
    /// Whether the recording was made with a video.
    let video: Bool
    let videoError: String?

    init(_ recording: Recording, summary: Recording.Summary) {
        directory = URL(fileURLWithPath: summary.dir)
        ended = summary.ended
        video = recording.video
        videoError = summary.videoError
    }
}

/// Replaceable parts of a new recording.
struct RecordingSeams: Sendable {
    var openWriter: @Sendable (URL) async throws -> TraceStore = { try TraceWriter(directory: $0) }
    var makeSink: @Sendable (URL, Int) -> VideoSink = { VideoRecorder(url: $0.appendingPathComponent("video.mp4"), fps: $1) }
}

/// `vm.record.*` and the trace of every other op of a recorded VM.
extension ControlHandler {
    static let defaultRecordingSeconds = 900

    /// Whether the trace holds a frame before and after `op`: the input ops, `vm.app.launch` and `vm.deploy`.
    static func capturesFrames(op: String) -> Bool {
        isInput(op: op) || op == "vm.app.launch" || op == "vm.deploy"
    }

    /// What `ui.at` is asked about the element `op` is aimed at, before the op runs: the press point of a
    /// `vm.mouse.click` (`x`, `y`) or a `vm.mouse.drag` (`fromX`, `fromY`), the `ref` of a `vm.ui.click`, `vm.ui.type`
    /// or `vm.ui.action` that names its element by ref alone, and `focused: true` for a `vm.type` with a text.
    /// Nil for any other op and for params that do not hold these values.
    static func targetQuestion(op: String, params: JSON) -> [String: JSON]? {
        func point(_ x: String, _ y: String) -> [String: JSON]? {
            guard let px = params[x]?.intValue, let py = params[y]?.intValue else { return nil }
            return ["x": .int(Int64(px)), "y": .int(Int64(py))]
        }
        switch op {
        case "vm.mouse.click": return point("x", "y")
        case "vm.mouse.drag": return point("fromX", "fromY")
        case "vm.ui.click", "vm.ui.type", "vm.ui.action":
            guard (params["selector"] ?? .null) == .null, let ref = params["ref"]?.stringValue, UISelector.isRef(ref) else { return nil }
            return ["ref": .string(ref)]
        case "vm.type":
            return params["text"]?.stringValue == nil ? nil : ["focused": true]
        case "vm.key.press", "vm.key.down":
            guard let param = keyParam(op: op), let keys = params[param]?.stringValue, isTextKey(keys) else { return nil }
            return ["focused": true]
        default:
            return nil
        }
    }

    /// What a trace line says about the element of a `ui.at` reply, as `target`: `role`, `name`, `automationId` when
    /// the node has one, the window's title as `window` when it has one, the node's rectangle as `rect`,
    /// `password: true` for a node with the `password` flag, and `byAutomationId` and `byName` as `{matches, index}`
    /// when the reply counted them and the index lies within the matches. Nil for a reply without a node that has a role.
    static func targetFacts(_ reply: JSON) -> JSON? {
        guard let node = reply["node"], let role = node["role"]?.stringValue else { return nil }
        var facts: [String: JSON] = ["role": .string(role), "name": .string(node["name"]?.stringValue ?? "")]
        if let id = node["aid"]?.stringValue, !id.isEmpty { facts["automationId"] = .string(id) }
        if let title = reply["window"]?["title"]?.stringValue, !title.isEmpty { facts["window"] = .string(title) }
        if let x = node["x"]?.intValue, let y = node["y"]?.intValue, let w = node["w"]?.intValue, let h = node["h"]?.intValue {
            facts["rect"] = ["x": .int(Int64(x)), "y": .int(Int64(y)), "w": .int(Int64(w)), "h": .int(Int64(h))]
        }
        if isPasswordNode(node) { facts["password"] = true }
        for key in ["byAutomationId", "byName"] {
            guard let matches = reply[key]?["matches"]?.intValue, let index = reply[key]?["index"]?.intValue,
                  matches >= 1, (0..<matches).contains(index) else { continue }
            facts[key] = ["matches": .int(Int64(matches)), "index": .int(Int64(index))]
        }
        return .object(facts)
    }

    /// Whether the helper node `node` has the `password` flag.
    static func isPasswordNode(_ node: JSON?) -> Bool {
        (node?["flags"]?.arrayValue ?? []).contains("password")
    }

    /// The param of `op` that holds the text the op writes into its element: `text` of `vm.type` and `vm.ui.type`,
    /// `value` of `vm.ui.action`; nil for any other op.
    static func writtenTextParam(op: String) -> String? {
        switch op {
        case "vm.type", "vm.ui.type": return "text"
        case "vm.ui.action": return "value"
        default: return nil
        }
    }

    /// `params` of `op` with `TraceSanitizer.mask` in place of the string in its `writtenTextParam`.
    static func maskingWrittenText(op: String, params: JSON) -> JSON {
        guard let key = writtenTextParam(op: op), var fields = params.objectValue, fields[key]?.stringValue != nil else { return params }
        fields[key] = .string(TraceSanitizer.mask)
        return .object(fields)
    }

    /// The param of `op` that holds the keys it presses: `keys` of `vm.key.press`, `key` of `vm.key.down` and
    /// `vm.key.up`; nil for any other op.
    static func keyParam(op: String) -> String? {
        switch op {
        case "vm.key.press": return "keys"
        case "vm.key.down", "vm.key.up": return "key"
        default: return nil
        }
    }

    /// Whether `keys` is a text key: one printable character, a space included, alone or after `shift+` only.
    static func isTextKey(_ keys: String) -> Bool {
        var rest = Substring(keys)
        while rest.count > 1, rest.lowercased().hasPrefix("shift+") { rest = rest.dropFirst("shift+".count) }
        guard rest.count == 1, let character = rest.first, !character.isNewline,
              !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        return !character.isWhitespace || character == " "
    }

    /// `params` of `op` with `TraceSanitizer.mask` in place of its `keyParam`.
    static func maskingKey(op: String, params: JSON) -> JSON {
        guard let key = keyParam(op: op), var fields = params.objectValue, fields[key]?.stringValue != nil else { return params }
        fields[key] = .string(TraceSanitizer.mask)
        return .object(fields)
    }

    /// Whether the agent connection `agent` of `vm` has not answered that it does not know the op `ui.at`.
    private func mayKnowTargetOp(_ agent: AgentClient, vm: String) -> Bool {
        agentsWithoutTargetOp[vm]?.client !== agent
    }

    /// Notes that the agent connection `agent` of `vm` answered that it does not know the op `ui.at`.
    private func noteNoTargetOp(_ agent: AgentClient, vm: String) {
        agentsWithoutTargetOp[vm] = AgentMark(client: agent)
    }

    /// The element `question` asks `ui.at` about, as `targetFacts`. The question goes out with the helper's time limit
    /// `UITiming.targetHelperBudgetMs`, only when the UI helper is free at this moment, and its answer is waited for
    /// `UITiming.targetBudget`. Nil, with nothing sent, for a cancelled task, for a guest without a connected agent
    /// that has the `ui` capability, for an agent connection that answered that it does not know `ui.at`, and while
    /// another call has the helper; nil also when the answer did not come in time and when the call failed.
    private nonisolated func aimedElement(_ question: [String: JSON], of t: VMTarget) async -> JSON? {
        guard !Task.isCancelled, case .connected(let agent) = await t.agentLink(), let hello = await agent.hello,
              hello.rpcVersion >= 2, hello.capabilities.contains("ui"), await mayKnowTargetOp(agent, vm: t.name) else { return nil }
        var request = question
        request["budgetMs"] = .int(Int64(UITiming.targetHelperBudgetMs))
        let name = t.name
        let fact = await factAtOnce(agent, "ui.at", request, vm: name, patience: UITiming.targetBudget) { result in
            guard case .failure(let error) = result, case AgentClient.AgentError.remote(let message) = error,
                  HelperSentence(message) == .unknownOp else { return }
            await self.noteNoTargetOp(agent, vm: name)
        }
        guard case .answer(let reply) = fact else { return nil }
        return ControlHandler.targetFacts(reply)
    }

    /// Runs `run` and adds the op, its outcome and its frames to the VM's recording; without one it only runs `run`.
    /// Before an op with a `targetQuestion` runs, the element it is aimed at is asked for and written to the line as
    /// `target`; the op then runs against the VM looked up for that question. When that element, or the `node` of the
    /// op's result, is a password element, the line holds the op's params as `maskingWrittenText` gives them. The line
    /// of a call made by a script run holds the kind of call as `script`.
    func recorded(op: String, params: JSON, run: @Sendable () async throws -> JSON) async throws -> JSON {
        guard !op.hasPrefix("vm.record."), let vm = params["name"]?.stringValue, let recording = await liveRecording(vm) else {
            return try await run()
        }
        var aimed: VMTarget?
        var target: JSON?
        if let question = ControlHandler.targetQuestion(op: op, params: params) {
            aimed = await registry.target(named: vm)
            if let aimed { target = await aimedElement(question, of: aimed) }
        }
        let framed = ControlHandler.capturesFrames(op: op)
        let before = framed ? await recording.capture() : nil
        let started = wallClock()
        let t0 = clock()
        let outcome: Result<JSON, Error>
        do {
            if let aimed {
                outcome = .success(try await ControlHandler.$resolvedTarget.withValue((vm, aimed)) { try await run() })
            } else {
                outcome = .success(try await run())
            }
        } catch {
            outcome = .failure(error)
        }
        let duration = t0.duration(to: clock())
        let after = framed ? await recording.capture() : nil
        var written = params
        if target?["password"]?.boolValue == true || ControlHandler.isPasswordNode((try? outcome.get())?["node"]) {
            written = ControlHandler.maskingWrittenText(op: op, params: params)
        }
        if let param = ControlHandler.keyParam(op: op), let key = params[param]?.stringValue {
            let masked = op == "vm.key.up" ? await recording.releasesMaskedKey(key)
                : ControlHandler.isTextKey(key) && target?["password"]?.boolValue == true
            if op == "vm.key.down" { await recording.noteKeyDown(key, masked: masked) }
            if masked { written = ControlHandler.maskingKey(op: op, params: written) }
        }
        await recording.record(op: op, params: written, outcome: outcome, started: started, duration: duration, before: before, after: after,
                               target: target, script: ControlHandler.scriptCall?.rawValue,
                               secrets: ControlHandler.scriptCall == nil ? [] : ControlHandler.scriptSecrets)
        var stopped = false
        if op == "vm.stop", case .success = outcome { stopped = true }
        if recordings.vmGone.removeValue(forKey: vm) === recording || stopped { await retireRecording(vm, recording) }
        return try outcome.get()
    }

    /// The VM's recording while it is still active; one that reached its limit is retired first.
    func liveRecording(_ vm: String) async -> Recording? {
        while let recording = recordings.active[vm] {
            await recording.endIfDue()
            let live = await recording.isActive
            if recordings.active[vm] !== recording { continue }
            if live { return recording }
            await retireRecording(vm, recording)
        }
        return nil
    }

    /// Ends `recording` and keeps its summary for `vm.record.stop`; does nothing when it is no longer the VM's active recording.
    func retireRecording(_ vm: String, _ recording: Recording) async {
        guard recordings.active[vm] === recording else { return }
        recordings.active[vm] = nil
        recordings.retiring[vm] = recording
        let summary = await recording.stop()
        settle(recording, vm: vm, summary: summary)
    }

    /// Ends the retirement of `recording`, the first time it is settled, and keeps its summary for `vm.record.stop`
    /// unless a stop has delivered it already.
    private func settle(_ recording: Recording, vm: String, summary: Recording.Summary) {
        guard recordings.retiring[vm] === recording else { return }
        recordings.retiring[vm] = nil
        recordings.lastDirectory[vm] = summary.dir
        recordings.latest[vm] = LastRecording(recording, summary: summary)
        if !recording.delivery.isTaken { recordings.ended[vm] = EndedRecording(delivery: recording.delivery, summary: summary) }
    }

    /// Waits until no recording of the VM is being retired.
    private func settleRetirements(_ vm: String) async {
        while let retiring = recordings.retiring[vm] {
            let summary = await retiring.stop()
            settle(retiring, vm: vm, summary: summary)
        }
    }

    func setRecordingSeams(_ seams: RecordingSeams) { recordingSeams = seams }

    /// Notes that the VM was found not running; its recording ends once the op that found out is traced.
    func noteVMGone(_ vm: String) {
        if let recording = recordings.active[vm] { recordings.vmGone[vm] = recording }
    }

    func record(op: String, params: JSON) async throws -> JSON {
        let t = try await target(params)
        let vm = t.name
        switch op {
        case "vm.record.start":
            repeat {
                await settleRetirements(vm)
                _ = await liveRecording(vm)
            } while recordings.retiring[vm] != nil
            if let active = recordings.active[vm] { throw ControlError.failed("'\(vm)' is already recording to \(active.directory.path); call vm.record.stop first") }
            if let reserved = recordings.starting[vm] { throw ControlError.failed("'\(vm)' is already recording to \(reserved.path); call vm.record.stop first") }
            return try await startRecording(t, params)
        case "vm.record.stop":
            if let current = recordings.active[vm] {
                recordings.active[vm] = nil
                recordings.retiring[vm] = current
                return try await collect(current, vm: vm)
            }
            if let retiring = recordings.retiring[vm] { return try await collect(retiring, vm: vm) }
            if recordings.starting[vm] != nil { throw ControlError.failed("'\(vm)' is still starting its recording; call vm.record.stop again in a moment") }
            guard let ended = recordings.ended.removeValue(forKey: vm), ended.delivery.take() else {
                throw ControlError.failed("'\(vm)' is not recording")
            }
            return ended.summary.json
        default:
            let current = await liveRecording(vm)
            if let reserved = recordings.starting[vm] {
                return ["recording": true, "dir": .string(reserved.path), "seconds": 0, "ops": 0, "writeErrors": 0]
            }
            if let current {
                var status: [String: JSON] = ["recording": true, "dir": .string(current.directory.path),
                                              "seconds": .double(await current.elapsedSeconds), "ops": .int(Int64(await current.opCount)),
                                              "writeErrors": .int(Int64(await current.writeErrorCount))]
                if let last = await current.latestWriteError { status["lastWriteError"] = .string(last) }
                if let videoError = current.videoError { status["videoError"] = .string(videoError) }
                return .object(status)
            }
            guard let dir = recordings.lastDirectory[vm] else { return ["recording": false] }
            return ["recording": false, "dir": .string(dir)]
        }
    }

    /// Waits for `recording` to end and returns its summary as the answer to `vm.record.stop`; of all the stops that wait for
    /// the same recording, one gets the summary and the others fail.
    private func collect(_ recording: Recording, vm: String) async throws -> JSON {
        let summary = await recording.stop()
        if recordings.retiring[vm] === recording {
            recordings.retiring[vm] = nil
            recordings.lastDirectory[vm] = summary.dir
            recordings.latest[vm] = LastRecording(recording, summary: summary)
        }
        if recordings.ended[vm]?.delivery === recording.delivery { recordings.ended[vm] = nil }
        guard recording.delivery.take() else { throw ControlError.failed("'\(vm)' is not recording") }
        return summary.json
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
        let seams = recordingSeams
        let sink: VideoSink = video ? seams.makeSink(directory, fps) : NoVideoSink()
        let recording = Recording(vm: t.name, directory: directory, fps: fps, video: video, maxSeconds: maxSeconds,
                                  frames: { try? await t.frame() }, sink: sink,
                                  openWriter: seams.openWriter, clock: clock, now: wallClock)
        recordings.starting[t.name] = directory
        do { try await recording.start() } catch {
            await sink.finish()
            recordings.starting[t.name] = nil
            if case TraceWriter.WriterError.exists = error { throw ControlError.failed("'\(directory.path)' already holds a recording; choose another directory") }
            throw ControlError.failed("cannot create the recording in '\(directory.path)': \(ControlHandler.failureReason(error, fallback: "the directory could not be written; choose another directory"))")
        }
        recordings.starting[t.name] = nil
        recordings.active[t.name] = recording
        recordings.ended[t.name] = nil
        recordings.vmGone[t.name] = nil
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

    /// The `dir` parameter as an absolute path; without it a folder named after the VM and the time below `base`
    /// (`recordingsDirectory`, or the Recordings folder of the Alcove support directory, when `base` is nil).
    func recordingDirectory(_ params: JSON, vm: String, base: URL? = nil) throws -> URL {
        if let value = params["dir"] { return URL(fileURLWithPath: try absolutePath(value, "dir")) }
        let base = base ?? recordingsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Alcove/Recordings")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return base.appendingPathComponent("\(vm.replacingOccurrences(of: "/", with: "-"))-\(formatter.string(from: wallClock()))")
    }
}
