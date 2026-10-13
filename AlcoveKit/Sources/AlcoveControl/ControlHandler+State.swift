import Foundation
import AlcoveEngine
import AlcoveQMP

/// Snapshots, runtime port forwards, the network link, leases and the guest resolution.
extension ControlHandler {
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
            try leases.release(vm: t.name, token: params["lease"]?.stringValue ?? "", now: clock())
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
        let before = PNGInfo.size(of: try await screenshot(t)).map { [$0.width, $0.height] }
        await agent.setResolution(width: width, height: height)
        let deadline = ContinuousClock.now + .seconds(8)
        var size = before ?? [0, 0]
        while true {
            try await Task.sleep(for: .milliseconds(500))
            if let s = PNGInfo.size(of: try await screenshot(t)) { size = [s.width, s.height] }
            if size != before || size == [width, height] || ContinuousClock.now >= deadline { break }
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
            do { try await t.createSnapshot(named: snapshot) } catch { throw ControlError.failed("snapshot create failed: \(error)") }
            return ["snapshot": .string(snapshot)]
        case "vm.snapshot.restore":
            let snapshot = try string(params, "snapshot")
            let wait = params["waitTools"]?.intValue ?? 30
            try await requireSnapshot(snapshot, in: t)
            do { try await t.restoreSnapshot(named: snapshot) } catch { throw ControlError.failed("snapshot restore failed: \(error)") }
            let tools = await t.agent(timeout: .seconds(max(0, wait))) != nil
            return ["snapshot": .string(snapshot), "tools": .bool(tools)]
        case "vm.snapshot.delete":
            let snapshot = try string(params, "snapshot")
            try await requireSnapshot(snapshot, in: t)
            do { try await t.deleteSnapshot(named: snapshot) } catch { throw ControlError.failed("snapshot delete failed: \(error)") }
            return [:]
        case "vm.forward.add":
            guard let guestPort = params["guestPort"]?.intValue, (1...65_535).contains(guestPort) else { throw ControlError.missing("guestPort") }
            var hostPort = 0
            if let value = params["hostPort"], value != .null {
                guard let port = value.intValue, (0...65_535).contains(port) else { throw ControlError.missing("hostPort") }
                hostPort = port
            }
            if hostPort == 0 { hostPort = try freeHostPort() }
            try await forwardLine(t, "hostfwd_add \(VMController.netdevID) tcp:127.0.0.1:\(hostPort)-:\(guestPort)", hostPort: hostPort)
            runtimeForwards[t.name, default: []].append(Forward(hostPort: hostPort, guestPort: guestPort))
            return ["hostPort": .int(Int64(hostPort)), "guestPort": .int(Int64(guestPort))]
        case "vm.forward.remove":
            guard let hostPort = params["hostPort"]?.intValue, (1...65_535).contains(hostPort) else { throw ControlError.missing("hostPort") }
            try await forwardLine(t, "hostfwd_remove \(VMController.netdevID) tcp:127.0.0.1:\(hostPort)", hostPort: hostPort)
            runtimeForwards[t.name]?.removeAll { $0.hostPort == hostPort }
            return [:]
        case "vm.forward.list":
            var rows: [JSON] = []
            for f in await t.staticForwards() {
                rows.append(["hostPort": .int(Int64(f.hostPort)), "guestPort": .int(Int64(f.guestPort)), "kind": "config"])
            }
            for f in runtimeForwards[t.name] ?? [] {
                rows.append(["hostPort": .int(Int64(f.hostPort)), "guestPort": .int(Int64(f.guestPort)), "kind": "runtime"])
            }
            return ["forwards": .array(rows)]
        case "vm.set_network":
            guard let up = params["up"]?.boolValue else { throw ControlError.missing("up") }
            do { try await t.setNetworkLink(up: up) } catch { throw ControlError.failed("set network failed: \(error)") }
            return ["up": .bool(up)]
        default:
            throw ControlError.unknownOp(op)
        }
    }

    private func snapshotList(_ t: VMTarget) async throws -> [VMController.SnapshotInfo] {
        do { return try await t.snapshots() } catch { throw ControlError.failed("snapshot list failed: \(error)") }
    }

    private func requireSnapshot(_ snapshot: String, in t: VMTarget) async throws {
        guard try await snapshotList(t).contains(where: { $0.name == snapshot }) else {
            throw ControlError.failed("no snapshot '\(snapshot)' in '\(t.name)'; call vm.snapshot.list")
        }
    }

    /// Sends a forward line to the monitor; any reply text is an error.
    private func forwardLine(_ t: VMTarget, _ line: String, hostPort: Int) async throws {
        let reply: String
        do { reply = try await t.monitorCommand(line) } catch { throw ControlError.failed("port forward failed: \(error)") }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text.contains("Could not set up host forwarding rule") {
            throw ControlError.failed("host port \(hostPort) is taken; pass hostPort: 0 to let Alcove choose")
        }
        throw ControlError.failed("port forward failed: \(text)")
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
