import Foundation
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP

/// Executes control-protocol operations (docs/control-protocol.md) against a registry.
public actor ControlHandler {
    /// The JSON type of an optional boolean or integer parameter.
    public enum ParamType: Sendable {
        case boolean, integer

        var article: String { self == .boolean ? "a boolean" : "an integer" }
        func accepts(_ value: JSON) -> Bool { self == .boolean ? value.boolValue != nil : value.intValue != nil }
    }

    public enum ControlError: Error, CustomStringConvertible, Sendable {
        case unknownOp(String)
        case missing(String)
        case wrongType(String, ParamType)
        case noSuchVM(String)
        case notRunning(String, VMController.State)
        case noDisplay(String)
        case noTools(String)
        case untypable(String)
        case oneOf(String, String)
        case toolsTooOld(vm: String, op: String)
        case noUI(String)
        case recognitionFailed(String)
        case failed(String)

        public var description: String {
            switch self {
            case .unknownOp(let op): return "unknown op '\(op)'"
            case .wrongType(let p, let type): return "parameter '\(p)' must be \(type.article)"
            case .missing(let p): return "missing or invalid parameter '\(p)'"
            case .noSuchVM(let n): return "no VM named '\(n)'; call vm.list"
            case .notRunning(let n, let s): return "VM '\(n)' is \(describe(s)); call vm.start first"
            case .noDisplay(let n): return "VM '\(n)' has no display connection (start it first)"
            case .noTools(let n): return "guest tools are not connected in '\(n)'; install alcove-agent in the guest"
            case .untypable(let s): return "cannot type \(s) with the US keyboard layout; use vm.clipboard.set + ctrl+v or connect guest tools"
            case .oneOf(let a, let b): return "missing parameter; pass '\(a)' or '\(b)'"
            case .toolsTooOld(let vm, let op): return "guest tools in '\(vm)' are too old for \(op); update alcove-agent in the guest"
            case .noUI(let vm): return "UI Automation is only available on Windows guests with current guest tools; update alcove-agent in '\(vm)'"
            case .recognitionFailed(let m): return "text recognition failed: \(m)"
            case .failed(let m): return m
            }
        }
    }

    public let registry: VMRegistry
    public let hostKind: String
    /// Guest frame size per VM as last read, for the rows of `vm.list`.
    var lastSize: [String: (Int, Int)] = [:]
    let inputGate = InputGate()
    /// One `vm.deploy` per VM at a time.
    let deployGate = InputGate()
    /// Lets one `ui.*` or `win.*` agent call per VM run at a time, in arrival order.
    let helperGate = InputGate()
    /// Longest `vm.find_text` waits for its turn in the recognition queue.
    var textTurnLimit = Duration.seconds(60)
    /// Port forwards added with `vm.forward.add`, per VM name.
    var runtimeForwards: [String: [Forward]] = [:]
    /// The engine instance each VM's `runtimeForwards` belong to.
    var forwardInstances: [String: Int] = [:]

    var leases = LeaseTable()
    let clock: @Sendable () -> ContinuousClock.Instant
    /// The host's wall-clock time, used for guest clock settings and the doctor's skew check.
    let wallClock: @Sendable () -> Date
    /// The engine binary the host runs VMs with; nil when the app manages the engine.
    let engineDescription: String?
    /// The base directory of new recordings; nil selects `~/Library/Application Support/Alcove/Recordings`.
    let recordingsDirectory: URL?
    /// The base directory of new diagnostics bundles; nil selects `~/Library/Application Support/Alcove/Diagnostics`.
    let diagnosticsDirectory: URL?
    var recordings = RecordingTable()
    /// The directories `vm.collect_diagnostics` calls are writing at this moment, as paths with their links resolved.
    var diagnosticsInProgress: Set<String> = []
    var recordingSeams = RecordingSeams()
    /// A position in the event sequence of one target object, which the mark does not keep alive.
    struct EventMark {
        weak var source: AnyObject?
        var seq: Int
    }

    /// Per VM: the newest event sequence number when the latest op that can cause window or process events began.
    var eventBaseline: [String: EventMark] = [:]
    /// Per VM: the event sequence number up to which its observations have reported events; an op of `sessionOps`
    /// moves it past the events received by then.
    var observedEvents: [String: EventMark] = [:]
    /// An agent connection, which the mark does not keep alive.
    struct AgentMark {
        weak var client: AgentClient?
    }

    /// Per VM: the agent connection that answered that it does not know the op `ui.at`.
    var agentsWithoutTargetOp: [String: AgentMark] = [:]
    /// The target `handle` looked up for the op running in the current task.
    @TaskLocal static var resolvedTarget: (name: String, target: any VMTarget)?
    /// The kind of call a script run is making in the current task; nil outside a script run.
    @TaskLocal static var scriptCall: ScriptCall?
    /// The values of the secret variables of the script run this task belongs to; trace lines of its calls hold `TraceSanitizer.mask` in their place.
    @TaskLocal static var scriptSecrets: [String] = []
    /// Builds the proxy of a new HTTP capture.
    let makeProxy: @Sendable () -> ProxyControlling
    /// The HTTP captures by VM name.
    var captures: [String: HTTPCapture] = [:]
    /// One `vm.http.start`, `vm.http.stop` or cleanup after an earlier capture per VM at a time.
    let captureGate = InputGate()
    /// One proxy is started at a time.
    let proxyStartGate = InputGate()
    let httpTiming: HTTPTiming
    /// The captures whose guest is not restored, and the snapshots created during a capture.
    let captureJournal: CaptureJournal
    /// Per VM: the running cleanup after an earlier capture.
    var staleCleanups: [String: (id: UUID, task: Task<Bool, Never>)] = [:]
    /// Per VM: the latest cleanup after an earlier capture that ended, and whether it removed anything from the guest.
    var endedCleanups: [String: (id: UUID, cleaned: Bool)] = [:]
    /// Per VM: the target object this handler observes the agent connections of.
    var observedTargets: [String: EventMark] = [:]

    struct Forward: Equatable { let hostPort: Int; let guestPort: Int }

    /// `captureDirectory` is the folder of the proxy's CA certificate and of the capture journal; a handler that serves
    /// a user's VMs gets `ProxyProcess.defaultCADirectory`. Without `makeProxy` a capture runs `alcove-proxy` as found
    /// by `ToolLocator`, with `captureDirectory` as its CA directory.
    public init(registry: VMRegistry, hostKind: String, captureDirectory: URL,
                clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                engineDescription: String? = nil, now: @escaping @Sendable () -> Date = { Date() },
                recordingsDirectory: URL? = nil, diagnosticsDirectory: URL? = nil, httpTiming: HTTPTiming = HTTPTiming(),
                makeProxy: (@Sendable () -> ProxyControlling)? = nil) {
        self.makeProxy = makeProxy ?? { ProxyProcess(executable: ToolLocator.proxy(), caDirectory: captureDirectory) }
        self.httpTiming = httpTiming
        self.captureJournal = CaptureJournal(directory: captureDirectory)
        self.registry = registry
        self.hostKind = hostKind
        self.clock = clock
        self.engineDescription = engineDescription
        self.wallClock = now
        self.recordingsDirectory = recordingsDirectory
        self.diagnosticsDirectory = diagnosticsDirectory
    }

    /// Every op name the dispatcher accepts.
    static let knownOps: [String] = [
        "hello", "vm.list", "vm.status", "vm.start", "vm.stop", "vm.pause", "vm.resume", "vm.screenshot",
        "vm.clone", "vm.delete",
        "vm.mouse.move", "vm.mouse.click", "vm.mouse.drag", "vm.mouse.scroll", "vm.mouse.down", "vm.mouse.up",
        "vm.key.press", "vm.key.down", "vm.key.up", "vm.type", "vm.batch",
        "vm.exec", "vm.exec.start", "vm.exec.read", "vm.exec.write", "vm.exec.kill", "vm.exec.list",
        "vm.process.list", "vm.process.kill",
        "vm.clipboard.get", "vm.clipboard.set",
        "vm.push_file", "vm.pull_file", "vm.sync_dir", "vm.fs.list", "vm.fs.read", "vm.fs.write", "vm.fs.delete",
        "vm.snapshot.list", "vm.snapshot.create", "vm.snapshot.restore", "vm.snapshot.delete",
        "vm.forward.add", "vm.forward.remove", "vm.forward.list", "vm.set_network",
        "vm.lease.acquire", "vm.lease.release", "vm.set_resolution",
        "vm.wait_idle", "vm.wait_for", "vm.set_environment", "vm.doctor", "vm.find_text",
        "vm.event_log", "vm.crash_dumps.enable", "vm.crash_dumps.disable", "vm.crash_dumps.list", "vm.crash_dumps.pull",
        "vm.record.start", "vm.record.stop", "vm.record.status",
        "script.run", "script.save",
        "vm.window.list", "vm.window.action", "vm.ui.tree", "vm.ui.find", "vm.ui.text", "vm.ui.click", "vm.ui.type", "vm.ui.action",
        "vm.app.launch", "vm.deploy", "vm.events", "vm.collect_diagnostics",
        "vm.http.start", "vm.http.stop", "vm.http.requests", "vm.http.request", "vm.http.clear",
        "vm.http.rule.add", "vm.http.rule.list", "vm.http.rule.remove", "vm.http.rule.clear",
    ]

    /// Whether `op` is exempt from the lease guard.
    static func isReadOnly(op: String) -> Bool {
        readOnlyOps.contains(op)
    }

    private static let readOnlyOps: Set<String> = [
        "hello", "vm.list", "vm.status", "vm.screenshot", "vm.wait_idle", "vm.clipboard.get", "vm.exec.read",
        "vm.exec.list", "vm.process.list", "vm.fs.list", "vm.fs.read", "vm.pull_file", "vm.snapshot.list",
        "vm.forward.list", "vm.lease.acquire", "vm.lease.release", "vm.doctor", "vm.find_text",
        "vm.wait_for", "vm.record.status", "vm.window.list", "vm.ui.tree", "vm.ui.find", "vm.ui.text", "vm.events",
        "vm.event_log", "vm.crash_dumps.list", "vm.crash_dumps.pull", "vm.collect_diagnostics",
        "vm.http.requests", "vm.http.request", "vm.http.rule.list",
        "script.save",
    ]

    /// Whether `op` runs outside the per-connection request order.
    public static func isConcurrent(op: String) -> Bool {
        op.hasPrefix("vm.exec") || op.hasPrefix("vm.process.") || op.hasPrefix("vm.fs.")
            || op == "vm.push_file" || op == "vm.pull_file" || op == "vm.sync_dir" || op == "vm.find_text"
            || op == "vm.crash_dumps.pull" || op == "vm.collect_diagnostics"
            || op == "script.run"
            || concurrentUIOps.contains(op)
    }

    private static let concurrentUIOps: Set<String> = [
        "vm.window.list", "vm.ui.tree", "vm.ui.find", "vm.ui.text", "vm.app.launch", "vm.deploy",
    ]

    /// Whether `op` sends mouse or keyboard input to a guest or acts on its windows and elements.
    static func isInput(op: String) -> Bool {
        op.hasPrefix("vm.mouse.") || op.hasPrefix("vm.key.") || op == "vm.type" || op == "vm.batch"
            || op == "vm.ui.click" || op == "vm.ui.type" || op == "vm.ui.action" || op == "vm.window.action"
    }

    /// The ops that end the guest's session or replace its state: the events from before them belong to another session.
    static let sessionOps: Set<String> = ["vm.start", "vm.stop", "vm.snapshot.restore"]

    /// Whether `op` moves the VM's event baseline when it begins: an op that can cause window or process events in
    /// the guest (input, launches, deploys, commands and kills) and an op of `sessionOps`.
    static func movesEventBaseline(op: String) -> Bool {
        guard !isReadOnly(op: op) else { return false }
        return isInput(op: op) || op == "vm.app.launch" || op == "vm.deploy" || op.hasPrefix("vm.exec") || op == "vm.process.kill"
            || sessionOps.contains(op)
    }

    /// The `maxWidth` of a request: a whole number of pixels of 1 or more; nil for anything else.
    static func maxWidth(_ params: JSON) -> Int? {
        params["maxWidth"]?.intValue.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Runs one operation. Input operations for the same VM run one at a time in arrival order.
    public func handle(op: String, params: JSON) async throws -> JSON {
        if !ControlHandler.isReadOnly(op: op), let vm = params["name"]?.stringValue,
           let refusal = leases.refusal(vm: vm, token: params["lease"]?.stringValue, now: clock()) {
            throw ControlError.failed(refusal)
        }
        let traced = !op.hasPrefix("script.")
        let run: @Sendable () async throws -> JSON = {
            guard traced else { return try await self.perform(op: op, params: params) }
            return try await self.recorded(op: op, params: params) { try await self.performNotingEvents(op: op, params: params) }
        }
        if ControlHandler.isInput(op: op), let vm = params["name"]?.stringValue {
            return try await inputGate.withLock(vm, run)
        }
        return try await run()
    }

    /// Runs one operation without the lease guard and without taking the input gate.
    func perform(op: String, params: JSON) async throws -> JSON {
        switch op {
        case "hello":
            return ["version": 1, "host": .string(hostKind)]
        case "vm.list":
            var list: [JSON] = []
            for name in await registry.names() {
                guard let t = await lookUp(name) else { continue }
                list.append(await status(of: t, quick: true))
            }
            return ["vms": .array(list)]
        case "vm.status":
            return await status(of: try await target(params), quick: false)
        case "vm.start":
            let t = try await target(params)
            let discard = params["discardChanges"]?.boolValue ?? false
            if await t.state().isActive {
                if discard {
                    throw ControlError.failed("VM '\(t.name)' is already running; stop it first to start a session that discards changes")
                }
            } else {
                runtimeForwards[t.name] = nil
                await endCapture(t.name)
                let resuming = await t.isSuspended()
                do {
                    try await t.start(discardChanges: discard)
                } catch VMController.ControllerError.engineDidNotStart(let reason) {
                    throw ControlError.failed("start failed: \(reason)")
                } catch {
                    throw ControlError.failed("start failed: \(ControlHandler.failureReason(error, fallback: "the VM did not start; check vm.status"))")
                }
                if resuming {
                    let hasClockRecipe = GuestRecipes.setClock(unixSeconds: 0, os: await t.guestOS()) != nil
                    let wait = hasClockRecipe ? max(0, params["waitTools"]?.intValue ?? 30) : 0
                    let agent = await t.agent(timeout: .seconds(wait))
                    var clockSynced = false
                    if let agent { clockSynced = await syncGuestClock(t, agent: agent, op: "vm.start") }
                    return ["state": .string(describe(await t.state())), "ephemeral": .bool(await t.isEphemeral()),
                            "resumed": true, "tools": .bool(agent != nil), "clockSynced": .bool(clockSynced)]
                }
            }
            return ["state": .string(describe(await t.state())), "ephemeral": .bool(await t.isEphemeral())]
        case "vm.clone", "vm.delete":
            return try await provision(op: op, params: params)
        case "vm.stop":
            let t = try await target(params)
            let force = params["force"]?.boolValue ?? false
            let capturing = captures[t.name] != nil
            var unrestored = captures[t.name]?.guestChanged == true ? "the VM was not running" : nil
            if await t.state().isActive {
                if capturing { unrestored = force ? (unrestored == nil ? nil : "the stop was forced") : await restoreCaptureGuest(t) }
                await endCapture(t.name)
                do {
                    try await t.stop(force: force)
                } catch {
                    let reason = ControlHandler.failureReason(error, fallback: "the VM did not stop; check vm.status, or call vm.stop with force")
                    throw ControlError.failed("stop failed: \(reason)" + (capturing ? "; its HTTP capture was ended, call vm.http.start to capture again" : ""))
                }
            }
            await endCapture(t.name)
            lastSize[t.name] = nil
            runtimeForwards[t.name] = nil
            var stopped: [String: JSON] = ["state": .string(describe(await t.state())), "eventSeq": .int(Int64(await passEvents(of: t)))]
            if capturing { stopped["captureEnded"] = true }
            if let unrestored { stopped["warning"] = .string(ControlHandler.unrestoredWarning(unrestored)) }
            return .object(stopped)
        case "vm.pause":
            let t = try await running(params)
            if await t.state() == .running { try await t.pause() }
            return ["state": .string(describe(await t.state()))]
        case "vm.resume":
            let t = try await target(params)
            if await t.state() == .paused { try await t.resume() }
            return ["state": .string(describe(await t.state()))]
        case "vm.screenshot":
            let t = try await running(params)
            return try await screenshotResult(t, params)
        case "vm.find_text":
            let t = try await running(params)
            return try await findText(t, params)
        case "vm.mouse.move", "vm.mouse.click", "vm.mouse.drag", "vm.mouse.scroll", "vm.mouse.down", "vm.mouse.up",
             "vm.key.press", "vm.key.down", "vm.key.up", "vm.type":
            return try await action(op: op, params: params)
        case "vm.batch":
            return try await batch(params)
        case "vm.exec", "vm.exec.start", "vm.exec.read", "vm.exec.write", "vm.exec.kill", "vm.exec.list",
             "vm.process.list", "vm.process.kill":
            return try await shell(op: op, params: params)
        case "vm.clipboard.get":
            let t = try await running(params)
            let agent = try await tools(t)
            do { return ["text": .string(try await agent.getClipboard())] } catch { throw agentFailure(error, vm: t.name, op: op) }
        case "vm.clipboard.set":
            let t = try await running(params)
            guard let text = params["text"]?.stringValue else { throw ControlError.missing("text") }
            let agent = try await tools(t)
            do { try await agent.setClipboard(text: text) } catch { throw agentFailure(error, vm: t.name, op: op) }
            return [:]
        case "vm.push_file", "vm.pull_file", "vm.crash_dumps.pull", "vm.sync_dir", "vm.fs.list", "vm.fs.read", "vm.fs.write", "vm.fs.delete":
            return try await files(op: op, params: params)
        case "vm.snapshot.list", "vm.snapshot.create", "vm.snapshot.restore", "vm.snapshot.delete",
             "vm.forward.add", "vm.forward.remove", "vm.forward.list", "vm.set_network":
            return try await state(op: op, params: params)
        case "vm.lease.acquire", "vm.lease.release", "vm.set_resolution":
            return try await leaseOrResolution(op: op, params: params)
        case "vm.set_environment", "vm.doctor", "vm.event_log",
             "vm.crash_dumps.enable", "vm.crash_dumps.disable", "vm.crash_dumps.list":
            return try await guest(op: op, params: params)
        case "vm.wait_for":
            return try await waitFor(params)
        case "vm.record.start", "vm.record.stop", "vm.record.status":
            return try await record(op: op, params: params)
        case "vm.collect_diagnostics":
            return try await collectDiagnostics(params)
        case "script.run":
            return try await scriptRun(params)
        case "script.save":
            return try await scriptSave(params)
        case "vm.window.list", "vm.window.action", "vm.ui.tree", "vm.ui.find", "vm.ui.text", "vm.ui.click", "vm.ui.type", "vm.ui.action",
             "vm.app.launch", "vm.events":
            return try await ui(op: op, params: params)
        case "vm.deploy":
            return try await deploy(params)
        case _ where ControlHandler.httpOps.contains(op):
            return try await http(op: op, params: params)
        case "vm.wait_idle":
            // "idle" tolerates small changes (clock, cursor blink, widgets): fewer
            // than 0.5% of the frame's tiles changing between samples 250 ms apart
            let t = try await running(params)
            let stable = Duration.seconds(params["seconds"]?.intValue ?? 2)
            let deadline = ContinuousClock.now + .seconds(params["timeout"]?.intValue ?? 30)
            var last = try await screenshot(t)
            var since = ContinuousClock.now
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(250))
                let now = try await screenshot(t)
                if FrameDiff.between(last, now).fraction < 0.005 {
                    if ContinuousClock.now - since >= stable { return ["idle": true] }
                } else {
                    since = ContinuousClock.now
                }
                last = now
            }
            return ["idle": false]
        default:
            throw ControlError.unknownOp(op)
        }
    }

    // MARK: - helpers

    /// The VM `params` names: the target `handle` looked up for the running op, or the registry's.
    func target(_ params: JSON) async throws -> VMTarget {
        guard let name = params["name"]?.stringValue else { throw ControlError.missing("name") }
        if let resolved = ControlHandler.resolvedTarget, resolved.name == name { return resolved.target }
        guard let t = await lookUp(name) else { throw ControlError.noSuchVM(name) }
        return t
    }

    /// The VM `name` of the registry. The handler becomes the observer of the agent connections of a target object
    /// it has not looked up before.
    func lookUp(_ name: String) async -> VMTarget? {
        guard let t = await registry.target(named: name) else { return nil }
        if observedTargets[name]?.source !== (t as AnyObject) {
            observedTargets[name] = EventMark(source: t as AnyObject, seq: 0)
            await t.setAgentObserver { [weak self] target, agent in await self?.toolsConnected(target, agent) }
        }
        return t
    }

    /// Drops the lease, the runtime forwards, the cached frame size, the event positions and the agent mark of `vm`.
    func forget(vm: String) {
        observedTargets[vm] = nil
        leases.forget(vm: vm)
        runtimeForwards[vm] = nil
        forwardInstances[vm] = nil
        lastSize[vm] = nil
        eventBaseline[vm] = nil
        observedEvents[vm] = nil
        agentsWithoutTargetOp[vm] = nil
    }

    /// Runs `op`. For an op outside the read-only set the VM is looked up once: here, or before the op by the code that
    /// set `resolvedTarget` for it. Its newest event sequence number at this moment becomes the VM's event baseline
    /// when `movesEventBaseline` says so, the position of its observations for an op of `sessionOps`, and `eventSeq`
    /// of the result unless the op set one itself.
    private func performNotingEvents(op: String, params: JSON) async throws -> JSON {
        guard !ControlHandler.isReadOnly(op: op), let vm = params["name"]?.stringValue else { return try await perform(op: op, params: params) }
        var found = ControlHandler.resolvedTarget.flatMap { $0.name == vm ? $0.target : nil }
        if found == nil { found = await lookUp(vm) }
        guard let t = found else { return try await perform(op: op, params: params) }
        let seq = await t.events(since: .max).next
        if ControlHandler.movesEventBaseline(op: op) { advanceEventBaseline(of: t, to: seq) }
        if ControlHandler.sessionOps.contains(op) { advanceObservedEvents(of: t, to: seq) }
        let result = try await ControlHandler.$resolvedTarget.withValue((vm, t)) { try await perform(op: op, params: params) }
        guard var fields = result.objectValue else { return result }
        if fields["eventSeq"] == nil { fields["eventSeq"] = .int(Int64(seq)) }
        return .object(fields)
    }

    /// Moves the event baseline of `t` and the position of its observations past every event received so far and
    /// returns that position.
    func passEvents(of t: VMTarget) async -> Int {
        let seq = await t.events(since: .max).next
        advanceEventBaseline(of: t, to: seq)
        advanceObservedEvents(of: t, to: seq)
        return seq
    }

    /// The position `marks` holds for the target object `t`; nil when it holds none for this object.
    func position(in marks: [String: EventMark], of t: VMTarget) -> Int? {
        guard let mark = marks[t.name], mark.source === (t as AnyObject) else { return nil }
        return mark.seq
    }

    /// `seq` and the position `marks` holds for `t`, whichever is higher, as the position of `t`.
    func advanced(_ marks: [String: EventMark], of t: VMTarget, to seq: Int) -> EventMark {
        EventMark(source: t as AnyObject, seq: max(seq, position(in: marks, of: t) ?? 0))
    }

    /// Moves the event baseline of `t` forward to `seq`; it never moves backwards within one target's sequence.
    func advanceEventBaseline(of t: VMTarget, to seq: Int) {
        eventBaseline[t.name] = advanced(eventBaseline, of: t, to: seq)
    }

    /// Moves the position up to which the observations of `t` have reported its events forward to `seq`.
    func advanceObservedEvents(of t: VMTarget, to seq: Int) {
        observedEvents[t.name] = advanced(observedEvents, of: t, to: seq)
    }

    func running(_ params: JSON) async throws -> VMTarget {
        let t = try await target(params)
        let st = await t.state()
        guard st == .running || st == .paused else {
            runtimeForwards[t.name] = nil
            noteVMGone(t.name)
            if !ControlHandler.keepsCapture(st) { await endCapture(t.name) }
            throw ControlError.notRunning(t.name, st)
        }
        return t
    }

    /// The guest agent; waits a while because the guest may still be logging in.
    func tools(_ t: VMTarget) async throws -> AgentClient {
        guard let a = await t.agent(timeout: .seconds(25)) else { throw ControlError.noTools(t.name) }
        return a
    }

    /// The control error for a failure of `op` against the agent of `vm`.
    nonisolated func agentFailure(_ error: Error, vm: String, op: String) -> ControlError {
        switch error {
        case let e as ControlError: return e
        case AgentClient.AgentError.unsupported: return .toolsTooOld(vm: vm, op: op)
        case AgentClient.AgentError.remote(let message): return .failed(message)
        case AgentClient.AgentError.timeout: return .failed("guest tools in '\(vm)' did not answer \(op) in time; check vm.status and retry")
        case AgentClient.AgentError.disconnected, AgentClient.AgentError.notConnected:
            return .failed("guest tools in '\(vm)' disconnected during \(op); retry once the guest is back")
        default: return .failed("\(op) failed: \(ControlHandler.failureReason(error, fallback: "the guest tools failed unexpectedly; check vm.status"))")
        }
    }

    /// The string parameter `key`.
    nonisolated func string(_ params: JSON, _ key: String) throws -> String {
        guard let v = params[key]?.stringValue else { throw ControlError.missing(key) }
        return v
    }

    func int(_ params: JSON, _ key: String) throws -> Int {
        guard let v = params[key]?.intValue else { throw ControlError.missing(key) }
        return v
    }

    private func status(of t: VMTarget, quick: Bool) async -> JSON {
        let st = await t.state()
        var obj: [String: JSON] = ["name": .string(t.name), "guestOS": .string(await t.guestOS().rawValue),
                                   "state": .string(describe(st)), "suspended": .bool(await t.isSuspended())]
        if let (w, h) = lastSize[t.name] { obj["width"] = .int(Int64(w)); obj["height"] = .int(Int64(h)) }
        if case .failed(let msg) = st { obj["error"] = .string(msg) }
        if let lease = leases.active(vm: t.name, now: clock()) { obj["leasedBy"] = .string(lease.owner) }
        if let template = await t.cloneOf() { obj["cloneOf"] = .string(template) }
        if await t.isEphemeral() { obj["ephemeral"] = true }
        if !quick, st == .running || st == .paused {
            if let (width, height) = try? await frameSize(of: t) {
                obj["width"] = .int(Int64(width)); obj["height"] = .int(Int64(height))
            }
            if let agent = await t.agent(timeout: .seconds(2)), let hello = await agent.hello {
                obj["tools"] = true
                obj["agentCaps"] = .array(hello.capabilities.map(JSON.string))
            } else {
                obj["tools"] = false
            }
        }
        return .object(obj)
    }

    /// Width and height of the current guest frame of `t`, which `vm.list` reports for the VM from then on.
    /// Cancellation is thrown as `CancellationError`.
    func frameSize(of t: VMTarget) async throws -> (width: Int, height: Int) {
        let size: (width: Int, height: Int)
        do {
            size = try await t.frameSize()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ControlError.failed("the size of the guest screen could not be read: \(ControlHandler.failureReason(error, fallback: "the display gave no image; check vm.status"))")
        }
        lastSize[t.name] = (size.width, size.height)
        return (size.width, size.height)
    }

    func screenshot(_ t: VMTarget) async throws -> Frame {
        let frame: Frame
        do { frame = try await t.frame() } catch { throw ControlError.failed("screenshot failed: \(ControlHandler.failureReason(error, fallback: "the display gave no image; check vm.status"))") }
        lastSize[t.name] = (frame.width, frame.height)
        return frame
    }

    private func regionParam(_ params: JSON) throws -> Frame.Rect? {
        guard let value = params["region"] else { return nil }
        guard let x = value["x"]?.intValue, let y = value["y"]?.intValue,
              let w = value["w"]?.intValue, let h = value["h"]?.intValue, w > 0, h > 0 else {
            throw ControlError.failed("region needs integer x, y, w, h with w and h above 0")
        }
        return Frame.Rect(x: x, y: y, w: w, h: h)
    }

    private func findText(_ t: VMTarget, _ params: JSON) async throws -> JSON {
        let region = try regionParam(params)
        var languages: [String]?
        if let value = params["languages"] {
            guard let items = value.arrayValue, !items.isEmpty, items.allSatisfy({ $0.stringValue != nil }) else {
                throw ControlError.failed("languages must be an array of language codes such as [\"en-US\",\"ko-KR\"]")
            }
            languages = items.compactMap(\.stringValue)
        }
        let regex = params["regex"]?.boolValue ?? false
        let query = params["query"]?.stringValue ?? ""
        if regex { _ = try ScreenText.filter([], query: query, regex: true) }

        let frame = try await screenshot(t)
        var area = frame.bounds
        if let region {
            guard let clamped = frame.clamp(region) else {
                throw ControlError.failed("region is outside the \(frame.width)x\(frame.height) frame")
            }
            area = clamped
        }
        let cropped = area == frame.bounds ? frame : frame.crop(area)
        let chosen = languages
        try ScreenText.validate(languages: chosen ?? ScreenText.defaultLanguages + ScreenText.latinLanguages)
        let turnLimit = textTurnLimit
        let lines: [TextMatch]
        do {
            lines = try await queuedRecognition(of: cropped, languages: chosen, turnLimit: turnLimit)
        } catch ControlError.recognitionFailed {
            try await Task.sleep(for: .milliseconds(150))
            do {
                lines = try await queuedRecognition(of: cropped, languages: chosen, turnLimit: turnLimit)
            } catch ControlError.recognitionFailed {
                throw ControlError.failed("text recognition failed twice; call vm.find_text again or use vm.screenshot")
            }
        }
        let matches = try ScreenText.filter(lines, query: query, regex: regex)
        let rows: [JSON] = matches.map { m in
            let x = m.rect.x + area.x, y = m.rect.y + area.y
            return ["text": .string(m.text), "x": .int(Int64(x)), "y": .int(Int64(y)),
                    "w": .int(Int64(m.rect.w)), "h": .int(Int64(m.rect.h)),
                    "cx": .int(Int64(x + m.rect.w / 2)), "cy": .int(Int64(y + m.rect.h / 2)),
                    "confidence": .double((m.confidence * 100).rounded() / 100)]
        }
        return ["matches": .array(rows), "lines": .int(Int64(lines.count))]
    }

    /// The lines the recognition queue reads in `frame`. A reading that has not begun `turnLimit` after this call
    /// leaves the queue and throws `recognitionBusy`; a cancelled task leaves the queue and throws `CancellationError`.
    private nonisolated func queuedRecognition(of frame: Frame, languages: [String]?, turnLimit: Duration) async throws -> [TextMatch] {
        let queue = RecognitionQueue.shared
        guard let outcome = await queue.recognize(frame, languages: languages, turnBy: .now + turnLimit) else { throw CancellationError() }
        do {
            return try outcome.get()
        } catch let busy as RecognitionQueue.Busy {
            throw ControlError.failed(ControlHandler.recognitionBusy(running: busy.running))
        }
    }

    func setTextTurnLimit(_ limit: Duration) { textTurnLimit = limit }

    /// The answer of `vm.find_text` when another reading, running for `running` so far, kept it from its turn.
    static func recognitionBusy(running: Duration) -> String {
        let seconds = (Double(running.components.seconds) + Double(running.components.attoseconds) / 1e18).rounded()
        return "the text recognition is busy (another reading has been running for \(Int(seconds)) s); retry in a few seconds"
    }

    private func screenshotResult(_ t: VMTarget, _ params: JSON) async throws -> JSON {
        let region = try regionParam(params)
        var scale = 1.0
        if let value = params["scale"] {
            guard let s = value.doubleValue, (0.1...1).contains(s) else { throw ControlError.failed("scale must be between 0.1 and 1") }
            scale = s
        }
        var quality = 0.8
        if let value = params["quality"] {
            guard let q = value.doubleValue, (0.1...1).contains(q) else { throw ControlError.failed("quality must be between 0.1 and 1") }
            quality = q
        }
        var format = Frame.Format.png
        if let value = params["format"] {
            guard let f = value.stringValue.flatMap(Frame.Format.init(rawValue:)) else { throw ControlError.failed("format must be 'png' or 'jpeg'") }
            format = f
        }

        let view = try await screenshotView(t, params, hasRegion: region != nil)

        let frame = try await screenshot(t)
        var area = frame.bounds
        if let region {
            guard let clamped = frame.clamp(region) else {
                throw ControlError.failed("region is outside the \(frame.width)x\(frame.height) frame")
            }
            area = clamped
        }
        if let window = view.window { area = try windowArea(window, in: frame) }
        var cropped = area == frame.bounds ? frame : frame.crop(area)
        var factor = scale
        if let maxWidth = ControlHandler.maxWidth(params), maxWidth < Int((Double(cropped.width) * scale).rounded()) {
            factor = Double(maxWidth) / Double(cropped.width)
        }
        var legend: [JSON]?
        var marksTruncated = false
        if let nodes = view.nodes {
            let (marks, more) = ControlHandler.marks(for: nodes, in: area)
            cropped = cropped.drawingMarks(marks.map { Frame.Mark(number: $0.number, rect: $0.rect.offset(x: -area.x, y: -area.y)) }, scale: 1 / factor)
            legend = marks.map(\.json)
            marksTruncated = more || view.nodesTruncated
        }
        let image = cropped.scaled(by: factor)
        let key = format == .png ? "png" : "jpeg"
        var out: [String: JSON] = [
            key: .string(image.encoded(format, quality: quality).base64EncodedString()),
            "mime": .string(format == .png ? "image/png" : "image/jpeg"),
            "width": .int(Int64(frame.width)), "height": .int(Int64(frame.height)),
            "sentWidth": .int(Int64(image.width)), "sentHeight": .int(Int64(image.height)),
            "x": .int(Int64(area.x)), "y": .int(Int64(area.y)),
            "areaWidth": .int(Int64(area.w)), "areaHeight": .int(Int64(area.h)),
            "scale": .double(Double(image.width) / Double(area.w)),
        ]
        if let window = view.window { out["window"] = window }
        if let legend { out["marks"] = .array(legend) }
        if marksTruncated { out["marksTruncated"] = true }
        return .object(out)
    }
}

func describe(_ s: VMController.State) -> String {
    switch s {
    case .stopped: return "stopped"
    case .starting: return "starting"
    case .running: return "running"
    case .paused: return "paused"
    case .suspending: return "suspending"
    case .stopping: return "stopping"
    case .failed: return "failed"
    }
}
