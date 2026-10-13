import Foundation
import AlcoveAgent
import AlcoveQMP

/// `vm.wait_for`: waits until the first of several conditions holds or the timeout passes.
extension ControlHandler {
    private static let idleChangeFraction = 0.005
    private static let tailLines = 400
    private static let logLineLimit = 500
    private static let jobBufferLimit = 64 * 1024

    /// What one evaluation of a condition found.
    private enum Verdict {
        case pending
        case holds(JSON?)
        /// The condition can no longer become true.
        case over(JSON?)
    }

    /// A failure that ends the wait at once.
    private struct HardFailure: Error { let error: ControlError }

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
        /// Evaluations in a row that failed, and the sentence of the latest failure.
        var failures = 0
        var lastError: String?
        /// The element text of the previous evaluation.
        var lastText: String?
        /// The sequence number of the newest guest event this condition has looked at.
        var eventCursor = 0
    }

    /// Frames and recognitions shared by the conditions of one tick.
    private struct Tick {
        var frame: Frame?
        var frameError: Error?
        var recognitionErrors: [String: Error] = [:]
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
        if conditions.contains(where: \.needsUI) {
            agent = try await uiAgent(t, op: "vm.wait_for")
        } else if conditions.contains(where: \.needsAgent) {
            agent = try await tools(t)
        }

        var states: [WaitState] = []
        for (index, condition) in conditions.enumerated() {
            var state = WaitState(nextDue: clock.now, quietSince: clock.now)
            if case .portListening(let port) = condition {
                guard let script = GuestRecipes.portListening(port, os: os) else {
                    throw ControlError.failed("condition \(index): port_listening is not supported for this guest OS")
                }
                state.script = script
            }
            if case .event = condition {
                let newest = await t.events(since: .max).next
                state.eventCursor = min(eventBaseline[t.name] ?? newest, newest)
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
                    states[index].failures = 0
                    states[index].lastError = nil
                } catch is CancellationError {
                    throw CancellationError()
                } catch let hard as HardFailure {
                    throw hard.error
                } catch {
                    switch error {
                    case AgentClient.AgentError.disconnected, AgentClient.AgentError.notConnected, AgentClient.AgentError.unsupported:
                        throw agentFailure(error, vm: t.name, op: "vm.wait_for")
                    default:
                        states[index].failures += 1
                        states[index].lastError = agentFailure(error, vm: t.name, op: "vm.wait_for").description
                        continue
                    }
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
        if matched == -1 {
            let problems: [JSON] = conditions.indices.compactMap { index in
                guard states[index].failures > 0, let error = states[index].lastError else { return nil }
                return ["condition": .int(Int64(index)), "type": .string(conditions[index].typeName),
                        "error": .string(error), "failures": .int(Int64(states[index].failures))]
            }
            if !problems.isEmpty { out["problems"] = .array(problems) }
        }
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
            let matches = try await recognize(text, index: index, tick: &tick, vm: t, clock: clock, deadline: deadline)
            guard let first = matches.first else { return .pending }
            return .holds(["text": .string(first.text), "x": .int(Int64(first.x)), "y": .int(Int64(first.y)),
                           "w": .int(Int64(first.w)), "h": .int(Int64(first.h)),
                           "cx": .int(Int64(first.x + first.w / 2)), "cy": .int(Int64(first.y + first.h / 2))])
        case .textGone(let text):
            return try await recognize(text, index: index, tick: &tick, vm: t, clock: clock, deadline: deadline).isEmpty ? .holds(nil) : .pending
        case .event(let name, let titleContains):
            guard let agent else { throw ControlError.noTools(t.name) }
            let batch = await t.events(since: state.eventCursor)
            state.eventCursor = max(state.eventCursor, batch.next)
            let found = batch.events.first { event in
                guard event.name == name else { return false }
                guard let titleContains else { return true }
                return event.windowTitle?.range(of: titleContains, options: .caseInsensitive) != nil
            }
            guard let found else {
                guard await agent.isConnected else { throw AgentClient.AgentError.disconnected }
                return .pending
            }
            eventBaseline[t.name] = max(eventBaseline[t.name] ?? 0, found.seq)
            return .holds(found.json)
        default:
            guard let agent else { throw ControlError.noTools(t.name) }
            return try await evaluateAgent(condition, index: index, state: &state, vm: t.name, agent: agent, clock: clock, deadline: deadline)
        }
    }

    private func tickFrame(_ tick: inout Tick, _ t: VMTarget) async throws -> Frame {
        if let frame = tick.frame { return frame }
        if let error = tick.frameError { throw error }
        do {
            let frame = try await screenshot(t)
            tick.frame = frame
            return frame
        } catch {
            tick.frameError = error
            throw error
        }
    }

    /// The lines of this tick's frame that contain `text`, in frame coordinates. Throws when the recognition outlasts `deadline`.
    private func recognize(_ text: WaitText, index: Int, tick: inout Tick, vm t: VMTarget, clock: ContinuousClock,
                           deadline: ContinuousClock.Instant) async throws -> [(text: String, x: Int, y: Int, w: Int, h: Int)] {
        let frame = try await tickFrame(&tick, t)
        let key = text.recognitionKey
        let found: (lines: [TextMatch], area: Frame.Rect)
        if let error = tick.recognitionErrors[key] {
            throw error
        } else if let cached = tick.recognitions[key] {
            found = cached
        } else {
            var area = frame.bounds
            if let region = text.region {
                guard let clamped = frame.clamp(region) else { throw outside(index, frame) }
                area = clamped
            }
            let cropped = area == frame.bounds ? frame : frame.crop(area)
            let lines: [TextMatch]
            do {
                guard let done = try await recognition(of: cropped, languages: text.languages, clock: clock, deadline: deadline) else {
                    throw ControlError.failed("text recognition did not finish within the timeout; call vm.wait_for again with a longer timeout")
                }
                lines = done
            } catch {
                tick.recognitionErrors[key] = error
                throw error
            }
            found = (lines, area)
            tick.recognitions[key] = found
        }
        let matches = found.lines.filter { line in
            if let expression = text.expression { return expression.firstMatch(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)) != nil }
            return line.text.range(of: text.query, options: .caseInsensitive) != nil
        }
        return matches.map { ($0.text, $0.rect.x + found.area.x, $0.rect.y + found.area.y, $0.rect.w, $0.rect.h) }
    }

    /// The recognized lines of `frame`, or nil when the recognition is still running at `deadline` and
    /// `WaitTiming.recognitionGrace` after its start; the recognition then ends unobserved.
    private func recognition(of frame: Frame, languages: [String], clock: ContinuousClock,
                             deadline: ContinuousClock.Instant) async throws -> [TextMatch]? {
        let recognizer = WaitTiming.recognizer
        let limit = max(deadline, clock.now + WaitTiming.recognitionGrace)
        let (outcomes, outcome) = AsyncStream<Result<[TextMatch], Error>?>.makeStream()
        Task.detached {
            outcome.yield(Result { try recognizer(frame, languages) })
            outcome.finish()
        }
        let timer = Task {
            try? await Task.sleep(until: limit, clock: clock)
            outcome.yield(nil)
            outcome.finish()
        }
        defer { timer.cancel() }
        for await first in outcomes { return try first?.get() }
        return nil
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
            guard let r = try await call("proc.list", ["name": .string(ControlHandler.processKey(name))]) else { return .pending }
            let wanted = ControlHandler.processKey(name)
            guard let found = (r["procs"]?.arrayValue ?? []).first(where: { ControlHandler.processKey($0["name"]?.stringValue ?? "") == wanted }) else { return .pending }
            return .holds(["pid": found["pid"] ?? .null, "name": found["name"] ?? .null])
        case .processExited(let pid, let name):
            var request: [String: JSON] = [:]
            if pid == nil, let name { request["name"] = .string(ControlHandler.processKey(name)) }
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
            guard code == 0, !out.isEmpty else {
                let err = (r["stderr"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = err.isEmpty ? "the guest command exited with code \(code) and printed nothing; run vm.doctor to check the guest shell" : err
                throw ControlError.failed("the port check failed: \(reason)")
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
            var exited = false, drained = false, bytes = 0
            while bytes < WaitTiming.jobByteBudget {
                let reply: JSON?
                do {
                    reply = try await call("exec.read", ["job": .string(job), "out_offset": .int(Int64(state.outOffset)),
                                                         "err_offset": .int(Int64(state.errOffset))])
                } catch AgentClient.AgentError.remote(let message) {
                    throw HardFailure(error: .failed(message))
                }
                guard let r = reply else { return .pending }
                let out = r["out"]?.stringValue ?? "", err = r["err"]?.stringValue ?? ""
                let outNext = r["out_next"]?.intValue ?? state.outOffset + out.utf8.count
                let errNext = r["err_next"]?.intValue ?? state.errOffset + err.utf8.count
                exited = r["state"]?.stringValue == "exited"
                let gained = max(0, outNext - state.outOffset) + max(0, errNext - state.errOffset)
                if outNext > state.outOffset { state.out = ControlHandler.rolling(state.out + out) }
                if errNext > state.errOffset { state.err = ControlHandler.rolling(state.err + err) }
                state.outOffset = max(state.outOffset, outNext)
                state.errOffset = max(state.errOffset, errNext)
                bytes += gained
                if gained == 0 { drained = true; break }
            }
            for buffer in [state.out, state.err] where pattern.firstMatch(in: buffer, range: NSRange(buffer.startIndex..., in: buffer)) != nil {
                return .holds(nil)
            }
            return exited && drained ? .over(.string("job exited")) : .pending
        case .uiExists(let element), .uiGone(let element), .uiEnabled(let element):
            let reply: JSON?
            do { reply = try await call("ui.rect", element) }
            catch AgentClient.AgentError.remote(let message) where UISelector.isMissingElement(message) {
                if case .uiGone = condition { return .holds(nil) }
                return .pending
            }
            guard let node = reply?["node"] else { return .pending }
            switch condition {
            case .uiGone: return .pending
            case .uiEnabled: return (node["flags"]?.arrayValue ?? []).contains("disabled") ? .pending : .holds(node)
            default: return .holds(node)
            }
        case .windowTitle(let contains, let pattern):
            guard let r = try await call("win.list", [:]) else { return .pending }
            for window in r["windows"]?.arrayValue ?? [] {
                guard let title = window["title"]?.stringValue else { continue }
                let matches: Bool
                if let contains {
                    matches = title.range(of: contains, options: .caseInsensitive) != nil
                } else {
                    matches = pattern?.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
                }
                if matches { return .holds(["id": window["id"] ?? .null, "title": .string(title), "foreground": window["foreground"] ?? false]) }
            }
            return .pending
        case .uiTextStable(let element, let quietMs):
            let reply: JSON?
            do { reply = try await call("ui.text", element) }
            catch AgentClient.AgentError.remote(let message) where UISelector.isMissingElement(message) {
                return .over(.string(message))
            }
            guard let r = reply else { return .pending }
            let text = r["text"]?.stringValue ?? ""
            let now = clock.now
            guard text == state.lastText else {
                state.lastText = text
                state.quietSince = now
                return .pending
            }
            guard now - state.quietSince >= .milliseconds(quietMs) else { return .pending }
            return .holds(r["total"] ?? .int(Int64(text.utf16.count)))
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
