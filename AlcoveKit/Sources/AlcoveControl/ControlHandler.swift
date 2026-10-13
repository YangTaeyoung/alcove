import Foundation
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveDisplayProtocol

/// Executes control-protocol operations (docs/control-protocol.md) against a registry.
public actor ControlHandler {
    public enum ControlError: Error, CustomStringConvertible, Sendable {
        case unknownOp(String)
        case missing(String)
        case noSuchVM(String)
        case notRunning(String, VMController.State)
        case noDisplay(String)
        case noTools(String)
        case untypable(String)
        case oneOf(String, String)
        case toolsTooOld(vm: String, op: String)
        case failed(String)

        public var description: String {
            switch self {
            case .unknownOp(let op): return "unknown op '\(op)'"
            case .missing(let p): return "missing or invalid parameter '\(p)'"
            case .noSuchVM(let n): return "no VM named '\(n)'; call vm.list"
            case .notRunning(let n, let s): return "VM '\(n)' is \(describe(s)); call vm.start first"
            case .noDisplay(let n): return "VM '\(n)' has no display connection (start it first)"
            case .noTools(let n): return "guest tools are not connected in '\(n)'; install alcove-agent in the guest"
            case .untypable(let s): return "cannot type \(s) with the US keyboard layout; use vm.clipboard.set + ctrl+v or connect guest tools"
            case .oneOf(let a, let b): return "missing parameter; pass '\(a)' or '\(b)'"
            case .toolsTooOld(let vm, let op): return "guest tools in '\(vm)' are too old for \(op); update alcove-agent in the guest"
            case .failed(let m): return m
            }
        }
    }

    public let registry: VMRegistry
    public let hostKind: String
    /// Guest frame size per VM from the latest screenshot (for coordinate scaling).
    private var lastSize: [String: (Int, Int)] = [:]
    private let inputGate = InputGate()
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

    struct Forward: Equatable { let hostPort: Int; let guestPort: Int }

    public init(registry: VMRegistry, hostKind: String, clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                engineDescription: String? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.registry = registry
        self.hostKind = hostKind
        self.clock = clock
        self.engineDescription = engineDescription
        self.wallClock = now
    }

    /// Every op name the dispatcher accepts.
    static let knownOps: [String] = [
        "hello", "vm.list", "vm.status", "vm.start", "vm.stop", "vm.pause", "vm.resume", "vm.screenshot",
        "vm.mouse.move", "vm.mouse.click", "vm.mouse.drag", "vm.mouse.scroll",
        "vm.key.press", "vm.key.down", "vm.key.up", "vm.type",
        "vm.exec", "vm.exec.start", "vm.exec.read", "vm.exec.write", "vm.exec.kill", "vm.exec.list",
        "vm.process.list", "vm.process.kill",
        "vm.clipboard.get", "vm.clipboard.set",
        "vm.push_file", "vm.pull_file", "vm.sync_dir", "vm.fs.list", "vm.fs.read", "vm.fs.write", "vm.fs.delete",
        "vm.snapshot.list", "vm.snapshot.create", "vm.snapshot.restore", "vm.snapshot.delete",
        "vm.forward.add", "vm.forward.remove", "vm.forward.list", "vm.set_network",
        "vm.lease.acquire", "vm.lease.release", "vm.set_resolution",
        "vm.wait_idle", "vm.set_environment", "vm.doctor",
    ]

    /// Whether `op` is exempt from the lease guard.
    static func isReadOnly(op: String) -> Bool {
        readOnlyOps.contains(op)
    }

    private static let readOnlyOps: Set<String> = [
        "hello", "vm.list", "vm.status", "vm.screenshot", "vm.wait_idle", "vm.clipboard.get", "vm.exec.read",
        "vm.exec.list", "vm.process.list", "vm.fs.list", "vm.fs.read", "vm.pull_file", "vm.snapshot.list",
        "vm.forward.list", "vm.lease.acquire", "vm.lease.release", "vm.doctor",
    ]

    /// Whether `op` runs outside the per-connection request order.
    public static func isConcurrent(op: String) -> Bool {
        op.hasPrefix("vm.exec") || op.hasPrefix("vm.process.") || op.hasPrefix("vm.fs.")
            || op == "vm.push_file" || op == "vm.pull_file" || op == "vm.sync_dir"
    }

    /// Whether `op` sends mouse or keyboard input to a guest.
    static func isInput(op: String) -> Bool {
        op.hasPrefix("vm.mouse.") || op.hasPrefix("vm.key.") || op == "vm.type"
    }

    /// Runs one operation. Input operations for the same VM run one at a time in arrival order.
    public func handle(op: String, params: JSON) async throws -> JSON {
        if !ControlHandler.isReadOnly(op: op), let vm = params["name"]?.stringValue,
           let refusal = leases.refusal(vm: vm, token: params["lease"]?.stringValue, now: clock()) {
            throw ControlError.failed(refusal)
        }
        if ControlHandler.isInput(op: op), let vm = params["name"]?.stringValue {
            return try await inputGate.withLock(vm) { try await self.perform(op: op, params: params) }
        }
        return try await perform(op: op, params: params)
    }

    private func perform(op: String, params: JSON) async throws -> JSON {
        switch op {
        case "hello":
            return ["version": 1, "host": .string(hostKind)]
        case "vm.list":
            var list: [JSON] = []
            for name in await registry.names() {
                guard let t = await registry.target(named: name) else { continue }
                list.append(await status(of: t, quick: true))
            }
            return ["vms": .array(list)]
        case "vm.status":
            return await status(of: try await target(params), quick: false)
        case "vm.start":
            let t = try await target(params)
            let st = await t.state()
            if !st.isActive {
                runtimeForwards[t.name] = nil
                do { try await t.start() } catch { throw ControlError.failed("start failed: \(error)") }
            }
            return ["state": .string(describe(await t.state()))]
        case "vm.stop":
            let t = try await target(params)
            if await t.state().isActive {
                do { try await t.stop(force: params["force"]?.boolValue ?? false) } catch { throw ControlError.failed("stop failed: \(error)") }
            }
            lastSize[t.name] = nil
            runtimeForwards[t.name] = nil
            return ["state": .string(describe(await t.state()))]
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
            var png = try await screenshot(t)
            let (w, h) = lastSize[t.name] ?? (0, 0)
            if let maxWidth = params["maxWidth"]?.intValue, maxWidth > 0, maxWidth < w {
                png = PNGInfo.downscale(png, maxWidth: maxWidth)
            }
            return ["png": .string(png.base64EncodedString()), "width": .int(Int64(w)), "height": .int(Int64(h)),
                    "sentWidth": .int(Int64(PNGInfo.size(of: png)?.width ?? w)), "sentHeight": .int(Int64(PNGInfo.size(of: png)?.height ?? h))]
        case "vm.mouse.move":
            let t = try await running(params)
            try await move(t, x: try int(params, "x"), y: try int(params, "y"))
            await t.sendDisplay(.sync)
            return [:]
        case "vm.mouse.click":
            let t = try await running(params)
            let button = try button(params["button"]?.stringValue)
            let count = max(1, min(3, params["count"]?.intValue ?? 1))
            let hold = params["hold"]?.intValue ?? 60
            try await move(t, x: try int(params, "x"), y: try int(params, "y"))
            for i in 0..<count {
                await t.sendDisplay(.btn(con: 0, button: button, down: true)); await t.sendDisplay(.sync)
                try await Task.sleep(for: .milliseconds(hold))
                await t.sendDisplay(.btn(con: 0, button: button, down: false)); await t.sendDisplay(.sync)
                if i < count - 1 { try await Task.sleep(for: .milliseconds(90)) }
            }
            return [:]
        case "vm.mouse.drag":
            let t = try await running(params)
            let button = try button(params["button"]?.stringValue)
            let (fx, fy, tx, ty) = (try int(params, "fromX"), try int(params, "fromY"), try int(params, "toX"), try int(params, "toY"))
            try await move(t, x: fx, y: fy); await t.sendDisplay(.sync)
            await t.sendDisplay(.btn(con: 0, button: button, down: true)); await t.sendDisplay(.sync)
            try await Task.sleep(for: .milliseconds(80))
            for step in 1...10 {
                try await move(t, x: fx + (tx - fx) * step / 10, y: fy + (ty - fy) * step / 10)
                await t.sendDisplay(.sync)
                try await Task.sleep(for: .milliseconds(25))
            }
            await t.sendDisplay(.btn(con: 0, button: button, down: false)); await t.sendDisplay(.sync)
            return [:]
        case "vm.mouse.scroll":
            let t = try await running(params)
            try await move(t, x: try int(params, "x"), y: try int(params, "y")); await t.sendDisplay(.sync)
            let dy = params["dy"]?.intValue ?? 0, dx = params["dx"]?.intValue ?? 0
            for _ in 0..<abs(dy) { await wheel(t, dy > 0 ? .wheelDown : .wheelUp) }
            for _ in 0..<abs(dx) { await wheel(t, dx > 0 ? .wheelRight : .wheelLeft) }
            return [:]
        case "vm.key.press":
            let t = try await running(params)
            guard let spec = params["keys"]?.stringValue, !spec.isEmpty else { throw ControlError.missing("keys") }
            let seq: [(code: Int, down: Bool)]
            do { seq = try KeyNames.pressSequence(spec) } catch { throw ControlError.failed("bad key spec '\(spec)': \(error)") }
            let hold = params["hold"]?.intValue ?? 0
            try await sendKeys(t, seq, gap: 20, holdBeforeRelease: hold)
            return [:]
        case "vm.key.down", "vm.key.up":
            let t = try await running(params)
            guard let name = params["key"]?.stringValue else { throw ControlError.missing("key") }
            let key: KeyNames.Key
            do { key = try KeyNames.key(named: name) } catch { throw ControlError.failed("unknown key '\(name)'") }
            await t.sendDisplay(.key(mac: key.code, q: nil, down: op == "vm.key.down"))
            return [:]
        case "vm.type":
            let t = try await running(params)
            guard let text = params["text"]?.stringValue else { throw ControlError.missing("text") }
            let delay = params["delay"]?.intValue ?? 12
            if let seq = try? KeyNames.typeSequence(text) {
                try await sendKeys(t, seq, gap: delay, holdBeforeRelease: 0)
            } else {
                // non-US characters: go through the guest clipboard and paste
                guard let agent = await t.agent(timeout: .seconds(2)) else { throw ControlError.untypable("this text") }
                do { try await agent.setClipboard(text: text) } catch { throw agentFailure(error, vm: t.name, op: op) }
                try await Task.sleep(for: .milliseconds(150))
                try await sendKeys(t, try KeyNames.pressSequence("ctrl+v"), gap: 20, holdBeforeRelease: 0)
            }
            return [:]
        case "vm.exec", "vm.exec.start", "vm.exec.read", "vm.exec.write", "vm.exec.kill", "vm.exec.list",
             "vm.process.list", "vm.process.kill":
            return try await shell(op: op, params: params)
        case "vm.clipboard.get":
            let t = try await running(params)
            let agent = try await tools(t)
            do { return ["text": .string(try await agent.getClipboard())] } catch { throw ControlError.failed("clipboard: \(error)") }
        case "vm.clipboard.set":
            let t = try await running(params)
            guard let text = params["text"]?.stringValue else { throw ControlError.missing("text") }
            let agent = try await tools(t)
            do { try await agent.setClipboard(text: text) } catch { throw agentFailure(error, vm: t.name, op: op) }
            return [:]
        case "vm.push_file", "vm.pull_file", "vm.sync_dir", "vm.fs.list", "vm.fs.read", "vm.fs.write", "vm.fs.delete":
            return try await files(op: op, params: params)
        case "vm.snapshot.list", "vm.snapshot.create", "vm.snapshot.restore", "vm.snapshot.delete",
             "vm.forward.add", "vm.forward.remove", "vm.forward.list", "vm.set_network":
            return try await state(op: op, params: params)
        case "vm.lease.acquire", "vm.lease.release", "vm.set_resolution":
            return try await leaseOrResolution(op: op, params: params)
        case "vm.set_environment", "vm.doctor":
            return try await guest(op: op, params: params)
        case "vm.wait_idle":
            // "idle" tolerates small changes (clock, cursor blink, widgets): fewer
            // than 0.5% of thumbnail pixels changing between samples
            let t = try await running(params)
            let stable = Duration.seconds(params["seconds"]?.intValue ?? 2)
            let deadline = ContinuousClock.now + .seconds(params["timeout"]?.intValue ?? 30)
            var last = PNGInfo.thumbnail(try await screenshot(t)) ?? []
            var since = ContinuousClock.now
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(500))
                let now = PNGInfo.thumbnail(try await screenshot(t)) ?? []
                if PNGInfo.changedFraction(last, now) < 0.005 {
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

    func target(_ params: JSON) async throws -> VMTarget {
        guard let name = params["name"]?.stringValue else { throw ControlError.missing("name") }
        guard let t = await registry.target(named: name) else { throw ControlError.noSuchVM(name) }
        return t
    }

    func running(_ params: JSON) async throws -> VMTarget {
        let t = try await target(params)
        let st = await t.state()
        guard st == .running || st == .paused else {
            runtimeForwards[t.name] = nil
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
        default: return .failed("\(op) failed: \(error)")
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

    private func button(_ name: String?) throws -> InputButton {
        switch (name ?? "left").lowercased() {
        case "left": return .left
        case "right": return .right
        case "middle": return .middle
        default: throw ControlError.missing("button")
        }
    }

    private func status(of t: VMTarget, quick: Bool) async -> JSON {
        let st = await t.state()
        var obj: [String: JSON] = ["name": .string(t.name), "guestOS": .string(await t.guestOS().rawValue),
                                   "state": .string(describe(st)), "suspended": .bool(await t.isSuspended())]
        if let (w, h) = lastSize[t.name] { obj["width"] = .int(Int64(w)); obj["height"] = .int(Int64(h)) }
        if case .failed(let msg) = st { obj["error"] = .string(msg) }
        if let lease = leases.active(vm: t.name, now: clock()) { obj["leasedBy"] = .string(lease.owner) }
        if !quick, st == .running || st == .paused {
            if lastSize[t.name] == nil, let png = try? await screenshot(t), let (w, h) = PNGInfo.size(of: png) {
                obj["width"] = .int(Int64(w)); obj["height"] = .int(Int64(h))
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

    func screenshot(_ t: VMTarget) async throws -> Data {
        let png: Data
        do { png = try await t.screenshotPNG() } catch { throw ControlError.failed("screenshot failed: \(error)") }
        if let (w, h) = PNGInfo.size(of: png) { lastSize[t.name] = (w, h) }
        return png
    }

    private func move(_ t: VMTarget, x: Int, y: Int) async throws {
        if lastSize[t.name] == nil { _ = try await screenshot(t) }
        guard let (w, h) = lastSize[t.name], w > 1, h > 1 else { throw ControlError.noDisplay(t.name) }
        let ax = Int((Double(max(0, min(x, w - 1))) / Double(w - 1) * Double(ToQEMU.absoluteMax)).rounded())
        let ay = Int((Double(max(0, min(y, h - 1))) / Double(h - 1) * Double(ToQEMU.absoluteMax)).rounded())
        guard await t.sendDisplay(.abs(con: 0, x: ax, y: ay)) else { throw ControlError.noDisplay(t.name) }
    }

    private func wheel(_ t: VMTarget, _ b: InputButton) async {
        await t.sendDisplay(.btn(con: 0, button: b, down: true)); await t.sendDisplay(.sync)
        await t.sendDisplay(.btn(con: 0, button: b, down: false)); await t.sendDisplay(.sync)
    }

    private func sendKeys(_ t: VMTarget, _ seq: [(code: Int, down: Bool)], gap: Int, holdBeforeRelease: Int) async throws {
        for (i, ev) in seq.enumerated() {
            if !ev.down, holdBeforeRelease > 0, i > 0, seq[i - 1].down, seq[i - 1].code == ev.code {
                try await Task.sleep(for: .milliseconds(holdBeforeRelease))
            }
            guard await t.sendDisplay(.key(mac: ev.code, q: nil, down: ev.down)) else { throw ControlError.noDisplay(t.name) }
            if gap > 0 { try await Task.sleep(for: .milliseconds(gap)) }
        }
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
