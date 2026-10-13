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
            case .failed(let m): return m
            }
        }
    }

    public let registry: VMRegistry
    public let hostKind: String
    /// Guest frame size per VM from the latest screenshot (for coordinate scaling).
    var lastSize: [String: (Int, Int)] = [:]
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
        "vm.mouse.move", "vm.mouse.click", "vm.mouse.drag", "vm.mouse.scroll", "vm.mouse.down", "vm.mouse.up",
        "vm.key.press", "vm.key.down", "vm.key.up", "vm.type", "vm.batch",
        "vm.exec", "vm.exec.start", "vm.exec.read", "vm.exec.write", "vm.exec.kill", "vm.exec.list",
        "vm.process.list", "vm.process.kill",
        "vm.clipboard.get", "vm.clipboard.set",
        "vm.push_file", "vm.pull_file", "vm.sync_dir", "vm.fs.list", "vm.fs.read", "vm.fs.write", "vm.fs.delete",
        "vm.snapshot.list", "vm.snapshot.create", "vm.snapshot.restore", "vm.snapshot.delete",
        "vm.forward.add", "vm.forward.remove", "vm.forward.list", "vm.set_network",
        "vm.lease.acquire", "vm.lease.release", "vm.set_resolution",
        "vm.wait_idle", "vm.set_environment", "vm.doctor", "vm.find_text",
    ]

    /// Whether `op` is exempt from the lease guard.
    static func isReadOnly(op: String) -> Bool {
        readOnlyOps.contains(op)
    }

    private static let readOnlyOps: Set<String> = [
        "hello", "vm.list", "vm.status", "vm.screenshot", "vm.wait_idle", "vm.clipboard.get", "vm.exec.read",
        "vm.exec.list", "vm.process.list", "vm.fs.list", "vm.fs.read", "vm.pull_file", "vm.snapshot.list",
        "vm.forward.list", "vm.lease.acquire", "vm.lease.release", "vm.doctor", "vm.find_text",
    ]

    /// Whether `op` runs outside the per-connection request order.
    public static func isConcurrent(op: String) -> Bool {
        op.hasPrefix("vm.exec") || op.hasPrefix("vm.process.") || op.hasPrefix("vm.fs.")
            || op == "vm.push_file" || op == "vm.pull_file" || op == "vm.sync_dir" || op == "vm.find_text"
    }

    /// Whether `op` sends mouse or keyboard input to a guest.
    static func isInput(op: String) -> Bool {
        op.hasPrefix("vm.mouse.") || op.hasPrefix("vm.key.") || op == "vm.type" || op == "vm.batch"
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

    /// Runs one operation without the lease guard and without taking the input gate.
    func perform(op: String, params: JSON) async throws -> JSON {
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

    private func status(of t: VMTarget, quick: Bool) async -> JSON {
        let st = await t.state()
        var obj: [String: JSON] = ["name": .string(t.name), "guestOS": .string(await t.guestOS().rawValue),
                                   "state": .string(describe(st)), "suspended": .bool(await t.isSuspended())]
        if let (w, h) = lastSize[t.name] { obj["width"] = .int(Int64(w)); obj["height"] = .int(Int64(h)) }
        if case .failed(let msg) = st { obj["error"] = .string(msg) }
        if let lease = leases.active(vm: t.name, now: clock()) { obj["leasedBy"] = .string(lease.owner) }
        if !quick, st == .running || st == .paused {
            if lastSize[t.name] == nil, let frame = try? await screenshot(t) {
                obj["width"] = .int(Int64(frame.width)); obj["height"] = .int(Int64(frame.height))
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

    func screenshot(_ t: VMTarget) async throws -> Frame {
        let frame: Frame
        do { frame = try await t.frame() } catch { throw ControlError.failed("screenshot failed: \(error)") }
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
        var languages = ScreenText.defaultLanguages
        if let value = params["languages"] {
            guard let items = value.arrayValue, !items.isEmpty else { throw ControlError.missing("languages") }
            languages = try items.map { item in
                guard let name = item.stringValue else { throw ControlError.missing("languages") }
                return name
            }
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
        let lines = try await Task.detached { try ScreenText.recognize(cropped, languages: chosen) }.value
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

        let frame = try await screenshot(t)
        var area = frame.bounds
        if let region {
            guard let clamped = frame.clamp(region) else {
                throw ControlError.failed("region is outside the \(frame.width)x\(frame.height) frame")
            }
            area = clamped
        }
        let cropped = area == frame.bounds ? frame : frame.crop(area)
        var factor = scale
        if let maxWidth = params["maxWidth"]?.intValue, maxWidth > 0, maxWidth < Int((Double(cropped.width) * scale).rounded()) {
            factor = Double(maxWidth) / Double(cropped.width)
        }
        let image = cropped.scaled(by: factor)
        let key = format == .png ? "png" : "jpeg"
        return [key: .string(image.encoded(format, quality: quality).base64EncodedString()),
                "mime": .string(format == .png ? "image/png" : "image/jpeg"),
                "width": .int(Int64(frame.width)), "height": .int(Int64(frame.height)),
                "sentWidth": .int(Int64(image.width)), "sentHeight": .int(Int64(image.height)),
                "x": .int(Int64(area.x)), "y": .int(Int64(area.y)),
                "scale": .double(Double(image.width) / Double(area.w))]
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
