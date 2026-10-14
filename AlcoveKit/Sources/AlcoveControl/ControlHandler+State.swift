import Foundation
import AlcoveEngine
import AlcoveQMP
import AlcoveAgent
import AlcoveDisplayProtocol

/// Snapshots, runtime port forwards, the network link, leases, the guest resolution and clones.
extension ControlHandler {
    /// `vm.clone` and `vm.delete`, through a registry that conforms to `VMProvisioning`.
    func provision(op: String, params: JSON) async throws -> JSON {
        let name = try string(params, "name")
        guard let provisioning = registry as? VMProvisioning else {
            throw ControlError.failed("this control host cannot clone or delete VMs")
        }
        let owner = try await journalVM(target(params))
        do {
            if op == "vm.clone" {
                let newName = try string(params, "newName").trimmingCharacters(in: .whitespacesAndNewlines)
                guard captureJournal.entry(for: owner) == nil else {
                    throw ControlError.failed("'\(name)' still holds the proxy settings and the CA certificate of an earlier HTTP capture in its "
                                              + "guest; start it, wait until vm.status shows tools so that Alcove removes them, stop it and "
                                              + "call vm.clone again")
                }
                try await provisioning.cloneVM(named: name, as: newName)
                return ["name": .string(newName)]
            }
            try await provisioning.deleteVM(named: name)
            await endCapture(name)
        } catch let error as ControlError {
            throw error
        } catch let error as VMBundle.CloneError {
            throw ControlError.failed(error.description)
        } catch {
            let what = op == "vm.clone" ? "clone" : "delete"
            throw ControlError.failed("\(what) failed: \(ControlHandler.failureReason(error, fallback: "the operation could not finish; check vm.list"))")
        }
        try? captureJournal.forget(vm: owner, now: wallClock())
        forget(vm: name)
        if op == "vm.delete" { recordings.latest[name] = nil }
        return [:]
    }

    func leaseOrResolution(op: String, params: JSON) async throws -> JSON {
        switch op {
        case "vm.lease.acquire":
            let t = try await target(params)
            let owner = params["owner"]?.stringValue ?? "unknown"
            let seconds = max(1, min(3600, params["ttl"]?.intValue ?? 300))
            let lease = try leases.acquire(vm: t.name, owner: owner, ttl: .seconds(seconds), token: params["lease"]?.stringValue, now: clock())
            return ["lease": .string(lease.token), "expiresIn": .int(Int64(seconds))]
        case "vm.lease.release":
            let t = try await target(params)
            guard let token = params["lease"]?.stringValue else { throw ControlError.missing("lease") }
            try leases.release(vm: t.name, token: token, now: clock())
            return [:]
        default:
            return try await setResolution(params)
        }
    }

    private func setResolution(_ params: JSON) async throws -> JSON {
        let width = try int(params, "width"), height = try int(params, "height")
        guard (320...7680).contains(width), (200...4320).contains(height) else {
            throw ControlError.failed("width must be 320...7680 and height 200...4320")
        }
        let t = try await running(params)
        let agent = try await tools(t)
        let first = try await screenshot(t)
        let before = [first.width, first.height]
        await agent.setResolution(width: width, height: height)
        let deadline = clock() + .seconds(8)
        var size = before
        while true {
            try await Task.sleep(for: .milliseconds(500))
            let now = try await screenshot(t)
            size = [now.width, now.height]
            if size != before || size == [width, height] || clock() >= deadline { break }
        }
        return ["width": .int(Int64(size[0])), "height": .int(Int64(size[1]))]
    }

    func state(op: String, params: JSON) async throws -> JSON {
        let t = try await running(params)
        switch op {
        case "vm.snapshot.list":
            let list = try await snapshotList(t)
            let formatter = ISO8601DateFormatter()
            let rows = list.map { s -> JSON in
                ["name": .string(s.name), "date": .string(formatter.string(from: s.date)), "vmStateBytes": .int(Int64(s.vmStateSize))]
            }
            return ["snapshots": .array(rows)]
        case "vm.snapshot.create":
            let snapshot = try string(params, "snapshot")
            guard VMController.isValidSnapshotName(snapshot) else {
                throw ControlError.failed("snapshot name must be 1 to 128 characters without a line break; choose another name")
            }
            guard try await !snapshotList(t).contains(where: { $0.name == snapshot }) else {
                throw ControlError.failed("a snapshot named '\(snapshot)' already exists in '\(t.name)'; call vm.snapshot.delete first or choose another name")
            }
            do { try await t.createSnapshot(named: snapshot) } catch { throw ControlError.failed("snapshot create failed: \(engineReason(error))") }
            await noteSnapshot(snapshot, of: t)
            return ["snapshot": .string(snapshot)]
        case "vm.snapshot.restore":
            let snapshot = try string(params, "snapshot")
            let wait = params["waitTools"]?.intValue ?? 30
            try await requireSnapshot(snapshot, in: t)
            do {
                try await t.restoreSnapshot(named: snapshot)
            } catch {
                _ = await passEvents(of: t)
                throw ControlError.failed("snapshot restore failed: \(engineReason(error))")
            }
            let restored = await passEvents(of: t)
            let after = Task { await self.afterRestore(t, snapshot: snapshot, waitTools: wait) }
            var out = await after.value
            out["eventSeq"] = .int(Int64(restored))
            return .object(out)
        case "vm.snapshot.delete":
            let snapshot = try string(params, "snapshot")
            try await requireSnapshot(snapshot, in: t)
            do { try await t.deleteSnapshot(named: snapshot) } catch { throw ControlError.failed("snapshot delete failed: \(engineReason(error))") }
            try? captureJournal.forgetSnapshot(snapshot, vm: await journalVM(t), now: wallClock())
            return [:]
        case "vm.forward.add":
            let guestPort = try portParameter(params, "guestPort")
            var hostPort = 0
            if let value = params["hostPort"], value != .null {
                guard let port = value.intValue else { throw ControlError.missing("hostPort") }
                guard (0...65_535).contains(port) else { throw ControlError.failed("hostPort must be between 1 and 65535") }
                hostPort = port
            }
            await discardStaleForwards(t)
            let instance = await t.engineInstance()
            if hostPort == 0 {
                hostPort = try freeHostPort()
            } else if try await isReserved(hostPort, in: t) {
                throw ControlError.failed("host port \(hostPort) is taken; pass hostPort: 0 to let Alcove choose")
            }
            let added = try await forwardLine(t, "hostfwd_add \(VMController.netdevID) tcp:127.0.0.1:\(hostPort)-:\(guestPort)")
            if added.contains("Could not set up host forwarding rule") {
                throw ControlError.failed("host port \(hostPort) is taken; pass hostPort: 0 to let Alcove choose")
            }
            guard added.isEmpty else { throw ControlError.failed("port forward failed: \(added)") }
            guard await t.state() == .running, await t.engineInstance() == instance, forwardInstances[t.name] == instance else {
                throw ControlError.failed("VM '\(t.name)' stopped or restarted while the forward was added; call vm.forward.add again once it runs")
            }
            runtimeForwards[t.name, default: []].append(Forward(hostPort: hostPort, guestPort: guestPort))
            return ["hostPort": .int(Int64(hostPort)), "guestPort": .int(Int64(guestPort))]
        case "vm.forward.remove":
            let hostPort = try portParameter(params, "hostPort")
            await discardStaleForwards(t)
            guard runtimeForwards[t.name]?.contains(where: { $0.hostPort == hostPort }) == true else {
                throw ControlError.failed("no runtime forward on host port \(hostPort) in '\(t.name)'; call vm.forward.list (forwards from the VM configuration cannot be removed while it runs)")
            }
            let removed = try await forwardLine(t, "hostfwd_remove \(VMController.netdevID) tcp:127.0.0.1:\(hostPort)")
            guard removed.hasSuffix(" removed") || removed.hasSuffix(" not found") else {
                throw ControlError.failed("port forward failed: \(removed.isEmpty ? "the engine gave no answer" : removed)")
            }
            runtimeForwards[t.name]?.removeAll { $0.hostPort == hostPort }
            return [:]
        case "vm.forward.list":
            await discardStaleForwards(t)
            var rows: [JSON] = []
            for f in await t.staticForwards() {
                rows.append(["hostPort": .int(Int64(f.hostPort)), "guestPort": .int(Int64(f.guestPort)), "kind": "config"])
            }
            rows.append(["hostPort": .int(Int64(await t.agentHostPort())), "guestPort": .int(Int64(VMConfig.agentGuestPort)), "kind": "agent"])
            for f in runtimeForwards[t.name] ?? [] {
                rows.append(["hostPort": .int(Int64(f.hostPort)), "guestPort": .int(Int64(f.guestPort)), "kind": "runtime"])
            }
            return ["forwards": .array(rows)]
        case "vm.set_network":
            guard let up = params["up"]?.boolValue else { throw ControlError.missing("up") }
            do { try await t.setNetworkLink(up: up) } catch { throw ControlError.failed("set network failed: \(engineReason(error))") }
            return ["up": .bool(up)]
        default:
            throw ControlError.unknownOp(op)
        }
    }

    /// The work after a restore of `snapshot` of `t`, which a cancelled caller does not stop: ends the VM's capture,
    /// makes the snapshot's note the VM's journal entry, waits up to `waitTools` seconds for the guest tools, sets the
    /// guest clock and waits for the cleanup that entry starts. Returns the fields of the result but `eventSeq`.
    private func afterRestore(_ t: VMTarget, snapshot: String, waitTools wait: Int) async -> [String: JSON] {
        let capturing = captures[t.name] != nil
        await endCapture(t.name)
        let duringCapture = captureJournal.snapshotEntry(snapshot, vm: await journalVM(t))
        if let duringCapture { try? captureJournal.record(duringCapture, now: wallClock()) }
        let mark = cleanupMark(t.name)
        let agent = await t.agent(timeout: .seconds(max(0, wait)))
        let cleaning = duringCapture == nil ? nil : agent.map { cleanup(since: mark, t, $0) }
        var clockSynced = false
        if let agent { clockSynced = await syncGuestClock(t, agent: agent, op: "vm.snapshot.restore") }
        var out: [String: JSON] = ["snapshot": .string(snapshot), "tools": .bool(agent != nil), "clockSynced": .bool(clockSynced)]
        if capturing { out["captureEnded"] = true }
        if duringCapture != nil { out["staleProxyCleared"] = .bool(await cleaning?.value ?? false) }
        return out
    }

    /// Notes in the capture journal that `snapshot` of `t` was created during the live capture of the VM whose guest
    /// steps were begun, or else during the VM's unrestored entry; without either, an earlier note of that snapshot
    /// name of the VM is removed.
    func noteSnapshot(_ snapshot: String, of t: VMTarget) async {
        let owner = await journalVM(t)
        if let capture = captures[t.name], capture.guestChanged {
            try? captureJournal.noteSnapshot(snapshot, during: capture.journalEntry, now: wallClock())
        } else if let unrestored = captureJournal.entry(for: owner) {
            try? captureJournal.noteSnapshot(snapshot, during: unrestored, now: wallClock())
        } else {
            try? captureJournal.forgetSnapshot(snapshot, vm: owner, now: wallClock())
        }
    }

    /// Drops the runtime forwards remembered for an engine process other than the current one.
    private func discardStaleForwards(_ t: VMTarget) async {
        let instance = await t.engineInstance()
        if forwardInstances[t.name] != instance {
            runtimeForwards[t.name] = nil
            forwardInstances[t.name] = instance
        }
    }

    /// Whether `hostPort` is already forwarded by the configuration, the guest agent or a runtime forward.
    private func isReserved(_ hostPort: Int, in t: VMTarget) async throws -> Bool {
        if await t.staticForwards().contains(where: { $0.hostPort == hostPort }) { return true }
        if await t.agentHostPort() == hostPort { return true }
        return runtimeForwards[t.name]?.contains(where: { $0.hostPort == hostPort }) == true
    }

    private nonisolated func portParameter(_ params: JSON, _ key: String) throws -> Int {
        guard let port = params[key]?.intValue else { throw ControlError.missing(key) }
        guard (1...65_535).contains(port) else { throw ControlError.failed("\(key) must be between 1 and 65535") }
        return port
    }

    private func snapshotList(_ t: VMTarget) async throws -> [VMController.SnapshotInfo] {
        do { return try await t.snapshots() } catch { throw ControlError.failed("snapshot list failed: \(engineReason(error))") }
    }

    private func requireSnapshot(_ snapshot: String, in t: VMTarget) async throws {
        guard try await snapshotList(t).contains(where: { $0.name == snapshot }) else {
            throw ControlError.failed("no snapshot '\(snapshot)' in '\(t.name)'; call vm.snapshot.list")
        }
    }

    /// Sends a forward line to the monitor and returns its reply without surrounding whitespace.
    /// `hostfwd_add` answers nothing on success; `hostfwd_remove` answers
    /// `host forwarding rule for <address> removed` or `... not found`.
    private func forwardLine(_ t: VMTarget, _ line: String) async throws -> String {
        do {
            return try await t.monitorCommand(line).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ControlError.failed("port forward failed: \(engineReason(error))")
        }
    }

    /// A sentence for an engine failure: the engine's own message when it gave one, otherwise the next step.
    nonisolated func engineReason(_ error: Error) -> String { ControlHandler.engineSentence(error) }

    nonisolated static func engineSentence(_ error: Error) -> String {
        let restart = "restart the VM with vm.stop and vm.start"
        switch error {
        case let e as QMPClient.QMPError:
            switch e {
            case .job(_, let message): return message
            case .command(_, _, let message): return message
            case .disconnected(let reason): return "the engine closed the connection (\(reason)); check vm.status"
            case .timeout(let what): return "the engine did not answer \(what) in time; check vm.status"
            case .notConnected: return "the connection to the engine is gone; check vm.status and \(restart)"
            case .connect(let reason): return "could not connect to the engine (\(reason)); check vm.status and \(restart)"
            case .protocolViolation(let reason): return "the engine sent a message Alcove cannot read (\(reason)); \(restart)"
            case .unexpectedReturn(let command, _): return "the engine answered \(command) with a value Alcove does not expect; \(restart)"
            }
        case let e as VMController.ControllerError:
            switch e {
            case .notRunning: return "the VM is not running; check vm.status"
            case .alreadyRunning: return "the VM is already running; check vm.status"
            case .engineDidNotStart(let reason): return "the engine did not start (\(reason)); check vm.status and call vm.start again"
            case .qmpUnavailable(let reason): return "the engine's control connection is unavailable (\(reason)); check vm.status and \(restart)"
            case .invalidSnapshotName: return "snapshot name must be 1 to 128 characters without a line break; choose another name"
            case .snapshotListFailed(let text):
                let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return message.isEmpty ? "qemu-img could not read the snapshots of the disk; check the VM's disk file" : message
            }
        case let e as CocoaError:
            return e.localizedDescription
        default:
            return "the engine failed in a way Alcove cannot describe; check vm.status and \(restart)"
        }
    }

    /// A sentence for any failure: engine errors through `engineReason`, errors that carry their own sentence
    /// (`ControlError`, `LocalizedError`, `CustomStringConvertible`) as they are, `fallback` for the rest.
    nonisolated static func failureReason(_ error: Error, fallback: String) -> String {
        switch error {
        case is QMPClient.QMPError, is VMController.ControllerError, is CocoaError:
            return ControlHandler.engineSentence(error)
        case let e as ControlError: return e.description
        case AgentClient.AgentError.connect(let reason): return "the guest tools could not be reached (\(reason)); check vm.status"
        case AgentClient.AgentError.handshake(let reason): return "the guest tools handshake failed (\(reason)); reinstall alcove-agent in the guest"
        case AgentClient.AgentError.tokenMismatch: return "the guest tools refused the connection token; reinstall alcove-agent in the guest"
        case AgentClient.AgentError.disconnected, AgentClient.AgentError.notConnected:
            return "the guest tools are not connected; check vm.status"
        case AgentClient.AgentError.timeout(let what): return "the guest tools did not answer \(what) in time; check vm.status and retry"
        case AgentClient.AgentError.remote(let message): return message
        case AgentClient.AgentError.unsupported(let what): return "the guest tools do not support \(what); update alcove-agent in the guest"
        case KeyNames.KeyError.unknownKey(let key): return "unknown key '\(key)'; use a key name such as ctrl, shift, enter or a letter"
        case KeyNames.KeyError.untypableCharacter(let ch): return "cannot type '\(ch)' with the US keyboard layout"
        case let e as LocalizedError where e.errorDescription != nil: return e.errorDescription ?? fallback
        case let e as POSIXError: return e.localizedDescription
        case let e where type(of: e) is NSError.Type: return e.localizedDescription
        case let e as CustomStringConvertible: return e.description
        default: return fallback
        }
    }

    /// A TCP port on 127.0.0.1 that was free at the time of the call.
    private nonisolated func freeHostPort() throws -> Int {
        let failure = ControlError.failed("no free host port available; pass hostPort explicitly")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0 else { throw failure }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
