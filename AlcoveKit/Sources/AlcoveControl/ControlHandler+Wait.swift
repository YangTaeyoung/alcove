import Foundation
import AlcoveAgent
import AlcoveQMP

/// `vm.wait_for`: waits until the first of several conditions holds or the timeout passes.
extension ControlHandler {
    private static let idleChangeFraction = 0.005
    private static let tailLines = 400
    private static let logLineLimit = 500
    private static let jobBufferLimit = 64 * 1024
    /// Characters of a failed port check's output that its sentence quotes.
    private static let portOutputLimit = 200

    /// What one evaluation of a condition found.
    private enum Verdict: Sendable {
        /// The guest was read and the condition does not hold yet.
        case pending
        /// The guest has not answered; nothing is known.
        case unanswered
        case holds(JSON?)
        /// The condition can no longer become true.
        case over(JSON?)
    }

    /// A failure that ends the wait at once.
    private struct HardFailure: Error { let error: ControlError }

    /// The output of its job that a `job_output_matches` condition has read.
    private struct JobOutput: Sendable {
        var outOffset = 0, errOffset = 0
        var out = "", err = ""
    }

    /// What the agent calls of one evaluation of an agent condition brought: the verdict or the error, and the job
    /// output read by then.
    private struct AgentReading: Sendable {
        let verdict: Result<Verdict, Error>
        let job: JobOutput
    }

    /// The agent op one evaluation of an agent condition has sent and has no answer to. It stays set when the call
    /// ran out of time.
    private final class OpenCall: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        var op: String? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// The agent calls of one evaluation of an agent condition, running in a task of their own.
    private struct AgentProbe: Sendable {
        /// When the evaluation began.
        let started: ContinuousClock.Instant
        let openCall: OpenCall
        let answer: CallAnswer<AgentReading>
        let task: Task<Void, Never>
    }

    /// Per-condition progress between evaluations.
    private struct WaitState {
        var nextDue: ContinuousClock.Instant
        var previous: Frame?
        var quietSince: ContinuousClock.Instant
        var reference: Frame?
        var referenceRect: Frame.Rect?
        var script: String?
        var job = JobOutput()
        /// Evaluations in a row that failed, and the sentence of the latest failure.
        var failures = 0
        var lastError: String?
        /// The element text of the previous evaluation and its full length.
        var lastText: String?
        var lastTotal: JSON?
        /// The helper call of a UI condition whose outcome has not been collected.
        var probe: HelperProbe?
        /// The agent calls of an agent condition whose outcome has not been collected.
        var reading: AgentProbe?
        /// Whether the latest helper call waited `WaitTiming.reportedSilence` or longer for its turn at the helper and did not get it.
        var helperWasBusy = false
        /// The agent calls of an agent condition that ran out of time, over the evaluations that have ended.
        var agentSilence = AgentSilence()
        /// The sequence number of the newest guest event this condition has looked at.
        var eventCursor = 0

        /// Whether an evaluation of the condition runs in a task of its own and has not been collected.
        var isInFlight: Bool { probe != nil || reading != nil }

        /// Gives up the evaluation in flight: a helper call still waiting for its turn is not sent and a sent one keeps
        /// the helper until the agent answered; agent calls not yet made are not made.
        func abandon() {
            probe?.abandon()
            reading?.task.cancel()
        }
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
            if case .event(_, _, let since) = condition {
                let newest = await t.events(since: .max).next
                if let since {
                    state.eventCursor = since > newest ? 0 : since
                } else {
                    state.eventCursor = min(position(in: eventBaseline, of: t) ?? newest, newest)
                }
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
        defer { for state in states { state.abandon() } }

        /// Takes in what an evaluation of condition `index` brought: a failure is counted, an answer clears the count.
        /// True when the answer ends the wait. Cancellation, a hard failure and a lost agent are thrown.
        func settle(_ outcome: Result<Verdict, Error>, _ index: Int) throws -> Bool {
            let verdict: Verdict
            do {
                verdict = try outcome.get()
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
                    return false
                }
            }
            if case .unanswered = verdict { return false }
            states[index].failures = 0
            states[index].lastError = nil
            switch verdict {
            case .pending, .unanswered:
                return false
            case .holds(let found):
                (matched, type, detail) = (index, conditions[index].typeName, found)
                return true
            case .over(let found):
                (type, detail) = (conditions[index].typeName, found)
                return true
            }
        }

        var settled = false
        wait: while true {
            try Task.checkCancellation()
            let tickStart = clock.now
            let tickEnd = min(tickStart + WaitTiming.tick, deadline)
            var tick = Tick()
            for (index, condition) in conditions.enumerated() where states[index].isInFlight || states[index].nextDue <= tickStart {
                let outcome: Result<Verdict, Error>
                do {
                    outcome = .success(try await evaluate(condition, index: index, state: &states[index], tick: &tick, vm: t,
                                                          now: tickStart, agent: agent, clock: clock, tickEnd: tickEnd, deadline: deadline))
                } catch {
                    outcome = .failure(error)
                }
                if try settle(outcome, index) {
                    settled = true
                    break wait
                }
            }
            if clock.now >= deadline { break }
            try await Task.sleep(until: tickEnd, clock: clock)
        }
        if !settled {
            for index in conditions.indices {
                guard let outcome = await collect(conditions[index], state: &states[index], until: clock.now) else { continue }
                if try settle(outcome, index) { break }
            }
        }

        let ending = clock.now
        let elapsed = ending - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        var out: [String: JSON] = ["matched": .int(Int64(matched)), "waited": .double((seconds * 10).rounded() / 10)]
        if let type { out["type"] = .string(type) }
        if let detail { out["detail"] = detail }
        if matched == -1 {
            var problems: [JSON] = []
            for index in conditions.indices {
                var problem: [String: JSON] = ["condition": .int(Int64(index)), "type": .string(conditions[index].typeName)]
                if states[index].failures > 0, let error = states[index].lastError {
                    problem["error"] = .string(error)
                    problem["failures"] = .int(Int64(states[index].failures))
                } else if let silence = await helperSilence(states[index], now: ending) ?? agentSilence(states[index], now: ending) {
                    problem["error"] = .string(silence)
                } else {
                    continue
                }
                problems.append(.object(problem))
            }
            if !problems.isEmpty { out["problems"] = .array(problems) }
        }
        var helperTaken = false
        for state in states {
            if let probe = state.probe, case .sent(let at) = await probe.answer.phase, ending - at >= WaitTiming.reportedSilence {
                helperTaken = true
            }
            state.abandon()
        }
        if options.level != .none, let first {
            try await addObservation(to: &out, t, after: "vm.wait_for", before: first, options, helperTaken: helperTaken)
        }
        return .object(out)
    }

    static let busyHelper = "the UI helper was busy with other requests"

    /// Why a UI condition without a recorded failure got no answer from the helper: its call has waited for
    /// `WaitTiming.reportedSilence` or longer, counted from the moment it began to wait for its turn, and was sent and
    /// not answered, or did not get its turn. Nil for an answered call and for a shorter wait.
    private func helperSilence(_ state: WaitState, now: ContinuousClock.Instant) async -> String? {
        guard let probe = state.probe else { return state.helperWasBusy ? ControlHandler.busyHelper : nil }
        let waited = now - probe.started
        switch await probe.answer.phase {
        case .queued:
            return waited >= WaitTiming.reportedSilence ? ControlHandler.busyHelper : nil
        case .sent:
            guard waited >= WaitTiming.reportedSilence else { return nil }
            let seconds = (Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18).rounded()
            return "the UI helper has not answered \(probe.op) for \(Int(seconds)) s"
        case .done(.failure(let error), let at):
            return error is HelperBusy && at - probe.started >= WaitTiming.reportedSilence ? ControlHandler.busyHelper : nil
        case .done:
            return nil
        }
    }

    /// Why an agent condition without a recorded failure got no answer from the guest agent: `AgentSilence.sentence`
    /// for its evaluation in flight and the ones that ended.
    private func agentSilence(_ state: WaitState, now: ContinuousClock.Instant) -> String? {
        state.agentSilence.sentence(inFlight: state.reading.map { ($0.openCall.op, $0.started) }, now: now)
    }

    private func outside(_ index: Int, _ frame: Frame) -> ControlError {
        .failed("condition \(index): region is outside the \(frame.width)x\(frame.height) frame")
    }

    /// One evaluation of a condition in the tick that began at `now`. A screen, text or event condition is read here
    /// and is due again one period after `now`; an agent or UI condition takes one `step`.
    private func evaluate(_ condition: WaitCondition, index: Int, state: inout WaitState, tick: inout Tick, vm t: VMTarget,
                          now: ContinuousClock.Instant, agent: AgentClient?, clock: ContinuousClock,
                          tickEnd: ContinuousClock.Instant, deadline: ContinuousClock.Instant) async throws -> Verdict {
        if condition.kind != .ui, condition.kind != .agent { state.nextDue = now + condition.period }
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
        case .event(let name, let titleContains, _):
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
            return .holds(found.json)
        default:
            guard let agent else { throw ControlError.noTools(t.name) }
            return try await step(condition, state: &state, vm: t.name, agent: agent, now: now, clock: clock,
                                  tickEnd: tickEnd, deadline: deadline)
        }
    }

    /// One step of an agent or UI condition, whose calls run in a task of their own, one evaluation at a time.
    ///
    /// An evaluation in flight is only looked at. Without one, and before the deadline, one is started and waited for
    /// until `tickEnd` at most; an agent condition is due again one period after the tick that started it. The verdict
    /// is `unanswered` while the evaluation has not ended. A cancelled task starts none and throws `CancellationError`.
    private func step(_ condition: WaitCondition, state: inout WaitState, vm: String, agent: AgentClient,
                      now tickStart: ContinuousClock.Instant, clock: ContinuousClock,
                      tickEnd: ContinuousClock.Instant, deadline: ContinuousClock.Instant) async throws -> Verdict {
        var limit = clock.now
        if !state.isInFlight {
            guard limit < deadline else { return .unanswered }
            try Task.checkCancellation()
            if condition.kind == .ui {
                let request = ControlHandler.probeRequest(condition)
                state.probe = startHelperCall(agent, request.op, request.fields, vm: vm, turnBy: deadline)
                state.helperWasBusy = false
            } else {
                state.nextDue = tickStart + condition.period
                state.reading = startReading(condition, job: state.job, script: state.script, agent: agent, clock: clock, deadline: deadline)
            }
            limit = tickEnd
        }
        guard let outcome = await collect(condition, state: &state, until: limit) else { return .unanswered }
        return try outcome.get()
    }

    /// What the evaluation of `condition` in flight brought, once it ended; waits for that until `limit` at most, and
    /// only looks when `limit` has passed. Nil when none is in flight or it has not ended by then. The answer of a
    /// helper call is judged here, and the condition's next call is due one period after the answer arrived.
    private func collect(_ condition: WaitCondition, state: inout WaitState,
                         until limit: ContinuousClock.Instant) async -> Result<Verdict, Error>? {
        if let probe = state.probe {
            guard let outcome = await probe.answer.outcome(until: limit) else { return nil }
            state.probe = nil
            state.nextDue = outcome.at + condition.period
            if case .failure(let error) = outcome.result, error is HelperBusy {
                state.helperWasBusy = outcome.at - probe.started >= WaitTiming.reportedSilence
                return .success(.unanswered)
            }
            return Result { try judge(condition, outcome.result, state: &state, at: outcome.at) }
        }
        if let reading = state.reading {
            guard let outcome = await reading.answer.outcome(until: limit) else { return nil }
            state.reading = nil
            state.job = outcome.result.job
            state.agentSilence.ended(openCall: reading.openCall.op, started: reading.started)
            return outcome.result.verdict
        }
        return nil
    }

    /// Starts the agent calls of one evaluation of an agent condition in a task of their own and returns at once.
    private nonisolated func startReading(_ condition: WaitCondition, job: JobOutput, script: String?, agent: AgentClient,
                                          clock: ContinuousClock, deadline: ContinuousClock.Instant) -> AgentProbe {
        let answer = CallAnswer<AgentReading>()
        let openCall = OpenCall()
        let started = clock.now
        let task = Task {
            var progress = job
            let verdict: Result<Verdict, Error>
            do {
                verdict = .success(try await self.evaluateAgent(condition, job: &progress, script: script, agent: agent,
                                                                clock: clock, deadline: deadline, openCall: openCall))
            } catch {
                verdict = .failure(error)
            }
            await answer.finish(AgentReading(verdict: verdict, job: progress))
        }
        return AgentProbe(started: started, openCall: openCall, answer: answer, task: task)
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

    /// The lines of this tick's frame that contain `text`, in frame coordinates. Throws when the recognition has not
    /// ended at `deadline` and `WaitTiming.recognitionGrace` after the wait asked for it, whichever comes later.
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

    /// The lines the recognition queue reads in `frame`, or nil when it has not answered at `deadline` and
    /// `WaitTiming.recognitionGrace` after this call, whichever comes later; the wait then leaves the queue.
    private func recognition(of frame: Frame, languages: [String], clock: ContinuousClock,
                             deadline: ContinuousClock.Instant) async throws -> [TextMatch]? {
        let limit = max(deadline, clock.now + WaitTiming.recognitionGrace)
        return try await RecognitionQueue.shared.recognize(frame, languages: languages, until: limit)?.get()
    }

    // MARK: - agent conditions

    /// One agent call bounded by the per-call limit and the deadline; nil when the call timed out. A cancelled task
    /// makes no call. `openCall` holds `op` from the moment the call is made until its answer or error arrived.
    private nonisolated func callAgent(_ agent: AgentClient, _ op: String, _ params: [String: JSON], clock: ContinuousClock,
                                       deadline: ContinuousClock.Instant, openCall: OpenCall) async throws -> JSON? {
        try Task.checkCancellation()
        let limit = min(WaitTiming.agentCallTimeout, max(deadline - clock.now, .milliseconds(200)))
        openCall.op = op
        do {
            let reply = try await agent.call(op, params, timeout: limit)
            openCall.op = nil
            return reply
        } catch AgentClient.AgentError.timeout {
            return nil
        } catch {
            openCall.op = nil
            throw error
        }
    }

    /// The helper call that reads what a UI condition asks about.
    private static func probeRequest(_ condition: WaitCondition) -> (op: String, fields: [String: JSON]) {
        switch condition {
        case .uiExists(let element), .uiGone(let element), .uiEnabled(let element):
            if element["ref"] != nil { return ("ui.rect", element) }
            var request = element
            request["limit"] = 1
            return ("ui.find", request)
        case .uiTextStable(let element, _): return ("ui.text", element)
        default: return ("win.list", [:])
        }
    }

    /// What the helper's answer to the call of a UI condition means; `at` is when the answer arrived. A sentence that
    /// says the helper is shut down or cannot start ends the wait.
    private func judge(_ condition: WaitCondition, _ result: Result<JSON, Error>, state: inout WaitState,
                       at now: ContinuousClock.Instant) throws -> Verdict {
        if case .failure(let error) = result, case AgentClient.AgentError.remote(let message) = error, HelperSentence(message).isPermanent {
            throw HardFailure(error: .failed(message))
        }
        switch condition {
        case .uiExists(let element), .uiGone(let element), .uiEnabled(let element):
            var found: JSON?
            do {
                let r = try result.get()
                found = element["ref"] != nil ? r["node"] ?? .null : r["nodes"]?.arrayValue?.first
            } catch AgentClient.AgentError.remote(let message) {
                guard HelperSentence(message).saysAbsent(ref: element["ref"]?.stringValue) else { throw AgentClient.AgentError.remote(message) }
            }
            switch condition {
            case .uiGone: return found == nil ? .holds(nil) : .pending
            case .uiEnabled:
                guard let node = found, !(node["flags"]?.arrayValue ?? []).contains("disabled") else { return .pending }
                return .holds(node)
            default:
                guard let node = found else { return .pending }
                return .holds(node)
            }
        case .windowTitle(let contains, let pattern):
            for window in try result.get()["windows"]?.arrayValue ?? [] {
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
            let r: JSON
            do { r = try result.get() }
            catch AgentClient.AgentError.remote(let message) where HelperSentence(message) == .passwordField {
                throw HardFailure(error: .failed(message))
            } catch AgentClient.AgentError.remote(let message) where element["ref"] != nil || state.lastText != nil {
                guard HelperSentence(message).saysAbsent(ref: element["ref"]?.stringValue, orNoMatch: true) else {
                    throw AgentClient.AgentError.remote(message)
                }
                return .over(.string(message))
            }
            let text = r["text"]?.stringValue ?? ""
            let total = r["total"] ?? .int(Int64(text.utf16.count))
            guard text == state.lastText, total == state.lastTotal else {
                state.lastText = text
                state.lastTotal = total
                state.quietSince = now
                return .pending
            }
            guard now - state.quietSince >= .milliseconds(quietMs) else { return .pending }
            return .holds(total)
        default:
            return .pending
        }
    }

    /// The agent calls of one evaluation of an agent condition and what they mean. `job` holds the job output read so far.
    private nonisolated func evaluateAgent(_ condition: WaitCondition, job state: inout JobOutput, script: String?, agent: AgentClient,
                                           clock: ContinuousClock, deadline: ContinuousClock.Instant,
                                           openCall: OpenCall) async throws -> Verdict {
        func call(_ op: String, _ params: [String: JSON]) async throws -> JSON? {
            try await callAgent(agent, op, params, clock: clock, deadline: deadline, openCall: openCall)
        }
        switch condition {
        case .processStarted(let name):
            guard let r = try await call("proc.list", ["name": .string(ControlHandler.processKey(name))]) else { return .unanswered }
            let wanted = ControlHandler.processKey(name)
            guard let found = (r["procs"]?.arrayValue ?? []).first(where: { ControlHandler.processKey($0["name"]?.stringValue ?? "") == wanted }) else { return .pending }
            return .holds(["pid": found["pid"] ?? .null, "name": found["name"] ?? .null])
        case .processExited(let pid, let name):
            var request: [String: JSON] = [:]
            if pid == nil, let name { request["name"] = .string(ControlHandler.processKey(name)) }
            guard let r = try await call("proc.list", request) else { return .unanswered }
            let procs = r["procs"]?.arrayValue ?? []
            if let pid { return procs.contains { $0["pid"]?.intValue == pid } ? .pending : .holds(nil) }
            let wanted = ControlHandler.processKey(name ?? "")
            return procs.contains { ControlHandler.processKey($0["name"]?.stringValue ?? "") == wanted } ? .pending : .holds(nil)
        case .fileExists(let path):
            guard let r = try await call("fs.stat", ["path": .string(path)]) else { return .unanswered }
            guard r["exists"]?.boolValue == true else { return .pending }
            return .holds(["path": r["path"] ?? .string(path), "size": r["size"] ?? 0])
        case .portListening:
            guard let script else { return .pending }
            let milliseconds = Int64(WaitTiming.agentCallTimeout.components.seconds * 1000)
                + Int64(WaitTiming.agentCallTimeout.components.attoseconds / 1_000_000_000_000_000)
            guard let r = try await call("exec.run", ["cmd": .string(script), "timeout_ms": .int(milliseconds)]) else { return .unanswered }
            if r["timed_out"]?.boolValue == true { return .unanswered }
            let code = r["code"]?.intValue ?? -1
            let out = (r["stdout"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard code == 0, !out.isEmpty else {
                let err = (r["stderr"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let printed = err.isEmpty ? out : err
                let line = printed.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                let what = line.isEmpty ? " and printed nothing" : ": \(line.prefix(ControlHandler.portOutputLimit))"
                throw ControlError.failed("the port check failed: the guest command exited with code \(code)\(what); run vm.doctor to check the guest shell")
            }
            return out == "1" ? .holds(nil) : .pending
        case .logMatches(let path, let pattern):
            let r: JSON?
            do { r = try await call("fs.tail", ["path": .string(path), "lines": .int(Int64(ControlHandler.tailLines))]) }
            catch AgentClient.AgentError.remote(let message) {
                guard let stat = try await call("fs.stat", ["path": .string(path)]) else { return .unanswered }
                guard stat["exists"]?.boolValue == true else { return .pending }
                throw AgentClient.AgentError.remote(message)
            }
            guard let r else { return .unanswered }
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
                guard let r = reply else { return .unanswered }
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
