import Foundation
import AlcoveAgent
import AlcoveQMP

/// `vm.wait_for`: waits until the first of several conditions holds or the timeout passes.
extension ControlHandler {
    private static let idleChangeFraction = 0.005
    private static let tailLines = 400
    private static let logLineLimit = 500
    private static let jobBufferLimit = 64 * 1024
    private static let jobReadsPerEvaluation = 16

    /// What one evaluation of a condition found.
    private enum Verdict {
        case pending
        case holds(JSON?)
        /// The condition can no longer become true.
        case over(JSON?)
    }

    /// Per-condition progress between evaluations.
    private struct WaitState {
        var nextDue: ContinuousClock.Instant
        var previous: Frame?
        var quietSince: ContinuousClock.Instant
        var reference: Frame?
        var referenceRect: Frame.Rect?
        var script: String?
        var outOffset = 0, errOffset = 0
        var out = "", err = ""
    }

    /// Frames and recognitions shared by the conditions of one tick.
    private struct Tick {
        var frame: Frame?
        var recognitions: [String: (lines: [TextMatch], area: Frame.Rect)] = [:]
    }

    func waitFor(_ params: JSON) async throws -> JSON {
        let options = try observeOptions(params)
        let conditions = try WaitCondition.parseList(params)
        let timeout = try WaitCondition.parseTimeout(params)
        let t = try await running(params)
        let os = await t.guestOS()
        let clock = ContinuousClock()

        var agent: AgentClient?
        if conditions.contains(where: \.needsAgent) { agent = try await tools(t) }

        var states: [WaitState] = []
        for (index, condition) in conditions.enumerated() {
            var state = WaitState(nextDue: clock.now, quietSince: clock.now)
            if case .portListening(let port) = condition {
                guard let script = GuestRecipes.portListening(port, os: os) else {
                    throw ControlError.failed("condition \(index): port_listening is not supported for this guest OS")
                }
                state.script = script
            }
            states.append(state)
        }

        let started = clock.now
        let deadline = started + .milliseconds(Int((timeout * 1000).rounded()))
        let needsFrame = options.level != .none || conditions.contains(where: \.needsFrame)
        let first = needsFrame ? try await screenshot(t) : nil
        for (index, condition) in conditions.enumerated() {
            states[index].quietSince = started
            states[index].previous = first
            if case .regionChanged(let region) = condition, let first {
                guard let area = first.clamp(region) else { throw outside(index, first) }
                states[index].referenceRect = area
                states[index].reference = first.crop(area)
            }
        }

        var matched = -1
        var type: String?
        var detail: JSON?
        wait: while true {
            try Task.checkCancellation()
            let tickStart = clock.now
            var tick = Tick()
            for (index, condition) in conditions.enumerated() where states[index].nextDue <= tickStart {
                states[index].nextDue = tickStart + condition.period
                let verdict: Verdict
                do {
                    verdict = try await evaluate(condition, index: index, state: &states[index], tick: &tick, vm: t,
                                                 now: tickStart,
                                                 agent: agent, clock: clock, deadline: deadline)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ControlError {
                    throw error
                } catch {
                    throw agentFailure(error, vm: t.name, op: "vm.wait_for")
                }
                switch verdict {
                case .pending:
                    continue
                case .holds(let found):
                    (matched, type, detail) = (index, condition.typeName, found)
                    break wait
                case .over(let found):
                    (type, detail) = (condition.typeName, found)
                    break wait
                }
            }
            if clock.now >= deadline { break }
            try await Task.sleep(until: min(tickStart + WaitTiming.tick, deadline), clock: clock)
        }

        let elapsed = clock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        var out: [String: JSON] = ["matched": .int(Int64(matched)), "waited": .double((seconds * 10).rounded() / 10)]
        if let type { out["type"] = .string(type) }
        if let detail { out["detail"] = detail }
        if options.level != .none, let first {
            try await addObservation(to: &out, t, after: "vm.wait_for", before: first, options)
        }
        return .object(out)
    }

    private func outside(_ index: Int, _ frame: Frame) -> ControlError {
        .failed("condition \(index): region is outside the \(frame.width)x\(frame.height) frame")
    }

    private func evaluate(_ condition: WaitCondition, index: Int, state: inout WaitState, tick: inout Tick, vm t: VMTarget,
                          now: ContinuousClock.Instant, agent: AgentClient?, clock: ContinuousClock, deadline: ContinuousClock.Instant) async throws -> Verdict {
        switch condition {
        case .screenIdle(let seconds):
            let frame = try await tickFrame(&tick, t)
            let still = state.previous.map { FrameDiff.between($0, frame).fraction < ControlHandler.idleChangeFraction } ?? false
            state.previous = frame
            if !still { state.quietSince = now; return .pending }
            return now - state.quietSince >= .milliseconds(Int((seconds * 1000).rounded())) ? .holds(nil) : .pending
        case .regionChanged:
            let frame = try await tickFrame(&tick, t)
            guard let reference = state.reference, let rect = state.referenceRect else { return .pending }
            guard let area = frame.clamp(rect), area == rect else { return .holds(nil) }
            return FrameDiff.between(reference, frame.crop(area)).changedTiles > 0 ? .holds(nil) : .pending
        case .textVisible(let text):
            let matches = try await recognize(text, index: index, tick: &tick, vm: t)
            guard let first = matches.first else { return .pending }
            return .holds(["text": .string(first.text), "x": .int(Int64(first.x)), "y": .int(Int64(first.y)),
                           "w": .int(Int64(first.w)), "h": .int(Int64(first.h)),
                           "cx": .int(Int64(first.x + first.w / 2)), "cy": .int(Int64(first.y + first.h / 2))])
        case .textGone(let text):
            return try await recognize(text, index: index, tick: &tick, vm: t).isEmpty ? .holds(nil) : .pending
        default:
            guard let agent else { throw ControlError.noTools(t.name) }
            return try await evaluateAgent(condition, index: index, state: &state, vm: t.name, agent: agent, clock: clock, deadline: deadline)
        }
    }

    private func tickFrame(_ tick: inout Tick, _ t: VMTarget) async throws -> Frame {
        if let frame = tick.frame { return frame }
        let frame = try await screenshot(t)
        tick.frame = frame
        return frame
    }

    /// The lines of this tick's frame that contain `text`, in frame coordinates.
    private func recognize(_ text: WaitText, index: Int, tick: inout Tick, vm t: VMTarget) async throws -> [(text: String, x: Int, y: Int, w: Int, h: Int)] {
        let frame = try await tickFrame(&tick, t)
        let key = text.recognitionKey
        let found: (lines: [TextMatch], area: Frame.Rect)
        if let cached = tick.recognitions[key] {
            found = cached
        } else {
            var area = frame.bounds
            if let region = text.region {
                guard let clamped = frame.clamp(region) else { throw outside(index, frame) }
                area = clamped
            }
            let cropped = area == frame.bounds ? frame : frame.crop(area)
            let languages = text.languages
            let lines = try await Task.detached { try ScreenText.recognize(cropped, languages: languages) }.value
            found = (lines, area)
            tick.recognitions[key] = found
        }
        let matches: [TextMatch]
        do { matches = try ScreenText.filter(found.lines, query: text.query, regex: text.regex) }
        catch { throw ControlError.failed("condition \(index): '\(text.query)' is not a valid regular expression") }
        return matches.map { ($0.text, $0.rect.x + found.area.x, $0.rect.y + found.area.y, $0.rect.w, $0.rect.h) }
    }

    // MARK: - agent conditions

    /// One agent call bounded by the per-call limit and the deadline; nil when the call timed out.
    private func callAgent(_ agent: AgentClient, _ op: String, _ params: [String: JSON], clock: ContinuousClock,
                           deadline: ContinuousClock.Instant) async throws -> JSON? {
        let limit = min(WaitTiming.agentCallTimeout, max(deadline - clock.now, .milliseconds(200)))
        do { return try await agent.call(op, params, timeout: limit) }
        catch AgentClient.AgentError.timeout { return nil }
    }

    private func evaluateAgent(_ condition: WaitCondition, index: Int, state: inout WaitState, vm: String, agent: AgentClient,
                               clock: ContinuousClock, deadline: ContinuousClock.Instant) async throws -> Verdict {
        func call(_ op: String, _ params: [String: JSON]) async throws -> JSON? {
            try await callAgent(agent, op, params, clock: clock, deadline: deadline)
        }
        switch condition {
        case .processStarted(let name):
            guard let r = try await call("proc.list", ["name": .string(name)]) else { return .pending }
            let wanted = ControlHandler.processKey(name)
            guard let found = (r["procs"]?.arrayValue ?? []).first(where: { ControlHandler.processKey($0["name"]?.stringValue ?? "") == wanted }) else { return .pending }
            return .holds(["pid": found["pid"] ?? .null, "name": found["name"] ?? .null])
        case .processExited(let pid, let name):
            var request: [String: JSON] = [:]
            if pid == nil, let name { request["name"] = .string(name) }
            guard let r = try await call("proc.list", request) else { return .pending }
            let procs = r["procs"]?.arrayValue ?? []
            if let pid { return procs.contains { $0["pid"]?.intValue == pid } ? .pending : .holds(nil) }
            let wanted = ControlHandler.processKey(name ?? "")
            return procs.contains { ControlHandler.processKey($0["name"]?.stringValue ?? "") == wanted } ? .pending : .holds(nil)
        case .fileExists(let path):
            guard let r = try await call("fs.stat", ["path": .string(path)]) else { return .pending }
            guard r["exists"]?.boolValue == true else { return .pending }
            return .holds(["path": r["path"] ?? .string(path), "size": r["size"] ?? 0])
        case .portListening:
            guard let script = state.script else { return .pending }
            let milliseconds = Int64(WaitTiming.agentCallTimeout.components.seconds * 1000)
                + Int64(WaitTiming.agentCallTimeout.components.attoseconds / 1_000_000_000_000_000)
            guard let r = try await call("exec.run", ["cmd": .string(script), "timeout_ms": .int(milliseconds)]) else { return .pending }
            if r["timed_out"]?.boolValue == true { return .pending }
            let code = r["code"]?.intValue ?? -1
            let out = (r["stdout"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard code == 0 else {
                let err = (r["stderr"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                throw ControlError.failed("condition \(index): the port check failed: \(err.isEmpty ? "exit code \(code)" : err)")
            }
            return out == "1" ? .holds(nil) : .pending
        case .logMatches(let path, let pattern):
            let r: JSON?
            do { r = try await call("fs.tail", ["path": .string(path), "lines": .int(Int64(ControlHandler.tailLines))]) }
            catch AgentClient.AgentError.remote(let message) {
                guard let stat = try await call("fs.stat", ["path": .string(path)]), stat["exists"]?.boolValue == true else { return .pending }
                throw AgentClient.AgentError.remote(message)
            }
            guard let r else { return .pending }
            let data = Data(base64Encoded: r["data"]?.stringValue ?? "") ?? Data()
            let text = GuestText.decode(data, utf16: r["encoding"]?.stringValue == "utf-16le")
            for line in text.split(whereSeparator: \.isNewline) {
                let value = String(line)
                if pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
                    return .holds(.string(String(value.prefix(ControlHandler.logLineLimit))))
                }
            }
            return .pending
        case .jobOutputMatches(let job, let pattern):
            var exited = false
            for _ in 0..<ControlHandler.jobReadsPerEvaluation {
                guard let r = try await call("exec.read", ["job": .string(job), "out_offset": .int(Int64(state.outOffset)),
                                                           "err_offset": .int(Int64(state.errOffset))]) else { return .pending }
                let out = r["out"]?.stringValue ?? "", err = r["err"]?.stringValue ?? ""
                let outNext = r["out_next"]?.intValue ?? state.outOffset + out.utf8.count
                let errNext = r["err_next"]?.intValue ?? state.errOffset + err.utf8.count
                exited = r["state"]?.stringValue == "exited"
                let progressed = outNext > state.outOffset || errNext > state.errOffset
                if outNext > state.outOffset { state.out = ControlHandler.rolling(state.out + out) }
                if errNext > state.errOffset { state.err = ControlHandler.rolling(state.err + err) }
                state.outOffset = max(state.outOffset, outNext)
                state.errOffset = max(state.errOffset, errNext)
                if !progressed { break }
            }
            for buffer in [state.out, state.err] where pattern.firstMatch(in: buffer, range: NSRange(buffer.startIndex..., in: buffer)) != nil {
                return .holds(nil)
            }
            return exited ? .over(.string("job exited")) : .pending
        default:
            return .pending
        }
    }

    private static func processKey(_ name: String) -> String {
        var key = name.lowercased()
        if key.hasSuffix(".exe") { key.removeLast(4) }
        return key
    }

    /// The last `jobBufferLimit` bytes of `text`, starting on a character boundary.
    private static func rolling(_ text: String) -> String {
        guard text.utf8.count > jobBufferLimit else { return text }
        var bytes = Array(text.utf8.suffix(jobBufferLimit))
        while let first = bytes.first, first & 0xC0 == 0x80 { bytes.removeFirst() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
