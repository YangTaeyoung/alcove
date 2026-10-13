import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class ControlStateTests: XCTestCase {
    private func setup(state: VMController.State = .running) -> (ControlHandler, FakeTarget) {
        let t = FakeTarget(name: "Win", state: state, png: makePNG(width: 800, height: 600))
        return (ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test"), t)
    }

    private func failure(_ h: ControlHandler, _ op: String, _ params: JSON) async -> String {
        do { _ = try await h.handle(op: op, params: params); return "no error" } catch { return "\(error)" }
    }

    private let snapshot = VMController.SnapshotInfo(name: "clean", vmStateSize: 4096, date: Date(timeIntervalSince1970: 1_700_000_000))

    func testSnapshotListMapsFields() async throws {
        let (h, t) = setup()
        await t.setSnapshotList([snapshot])
        let r = try await h.handle(op: "vm.snapshot.list", params: ["name": "Win"])
        XCTAssertEqual(r["snapshots"]?[0]?["name"]?.stringValue, "clean")
        XCTAssertEqual(r["snapshots"]?[0]?["date"]?.stringValue, "2023-11-14T22:13:20Z")
        XCTAssertEqual(r["snapshots"]?[0]?["vmStateBytes"]?.intValue, 4096)
    }

    func testSnapshotCreateRestoreDelete() async throws {
        let (h, t) = setup()
        await t.setSnapshotList([snapshot])
        let created = try await h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "clean"])
        XCTAssertEqual(created["snapshot"]?.stringValue, "clean")
        let restored = try await h.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "clean", "waitTools": 0])
        XCTAssertEqual(restored["snapshot"]?.stringValue, "clean")
        XCTAssertEqual(restored["tools"]?.boolValue, false)
        let deleted = try await h.handle(op: "vm.snapshot.delete", params: ["name": "Win", "snapshot": "clean"])
        XCTAssertEqual(deleted, [:])
        let calls = await t.snapshotCalls
        XCTAssertEqual(calls, ["create:clean", "restore:clean", "delete:clean"])
    }

    func testRestoreUnknownSnapshot() async throws {
        let (h, t) = setup()
        await t.setSnapshotList([snapshot])
        let message = await failure(h, "vm.snapshot.restore", ["name": "Win", "snapshot": "missing"])
        XCTAssertEqual(message, "no snapshot 'missing' in 'Win'; call vm.snapshot.list")
        let deleteMessage = await failure(h, "vm.snapshot.delete", ["name": "Win", "snapshot": "missing"])
        XCTAssertEqual(deleteMessage, "no snapshot 'missing' in 'Win'; call vm.snapshot.list")
        let calls = await t.snapshotCalls
        XCTAssertEqual(calls, [])
    }

    func testRestoreDropsAgentAndReportsTools() async throws {
        let first = FakeAgent()
        let (h, t) = try await handlerWithAgent(first, in: self)
        await t.setSnapshotList([snapshot])
        let second = FakeAgent()
        second.handler = { m, _ in m["t"]?.stringValue == "req" ? [agentReply(m, ["code": 0, "stdout": "ok", "stderr": ""])] : [] }
        _ = second.start()
        addTeardownBlock { second.stop() }
        let client = AgentClient()
        try await client.connect(port: second.port, expectedToken: nil)
        await t.setRestoreHook { target in await target.setAgent(client) }
        let restored = try await h.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "clean", "waitTools": 5])
        XCTAssertEqual(restored["tools"]?.boolValue, true)
        let r = try await h.handle(op: "vm.exec", params: ["name": "Win", "command": "echo ok"])
        XCTAssertEqual(r["code"]?.intValue, 0)
        XCTAssertEqual(agentRequests(second, "exec.run").count, 1)
        XCTAssertEqual(agentRequests(first, "exec.run").count, 0)
    }

    func testForwardAddUsesMonitorLine() async throws {
        let (h, t) = setup()
        let r = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 3389, "hostPort": 13389])
        XCTAssertEqual(r["hostPort"]?.intValue, 13389)
        XCTAssertEqual(r["guestPort"]?.intValue, 3389)
        let lines = await t.monitorLines
        XCTAssertEqual(lines, ["hostfwd_add net0 tcp:127.0.0.1:13389-:3389"])
    }

    func testForwardAddPicksFreePort() async throws {
        let (h, t) = setup()
        let r = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 22, "hostPort": 0])
        let port = try XCTUnwrap(r["hostPort"]?.intValue)
        XCTAssertTrue((1024...65535).contains(port))
        let lines = await t.monitorLines
        XCTAssertEqual(lines, ["hostfwd_add net0 tcp:127.0.0.1:\(port)-:22"])
        let absent = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 80])
        XCTAssertTrue((1024...65535).contains(try XCTUnwrap(absent["hostPort"]?.intValue)))
    }

    func testForwardAddReportsMonitorError() async throws {
        let (h, t) = setup()
        await t.setMonitorReplies(["Could not set up host forwarding rule 'tcp:127.0.0.1:8080-:80'\r\n", "something else\r\n"])
        let taken = await failure(h, "vm.forward.add", ["name": "Win", "guestPort": 80, "hostPort": 8080])
        XCTAssertEqual(taken, "host port 8080 is taken; pass hostPort: 0 to let Alcove choose")
        let other = await failure(h, "vm.forward.add", ["name": "Win", "guestPort": 80, "hostPort": 8081])
        XCTAssertTrue(other.contains("something else"), other)
        let list = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(list["forwards"], [])
    }

    func testForwardListMergesConfigAndRuntime() async throws {
        let (h, t) = setup()
        await t.setForwards([VMConfig.PortForward(proto: .tcp, hostPort: 2222, guestPort: 22)])
        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 3389, "hostPort": 13389])
        let list = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(list["forwards"], [
            ["hostPort": 2222, "guestPort": 22, "kind": "config"],
            ["hostPort": 13389, "guestPort": 3389, "kind": "runtime"],
        ])
    }

    func testForwardRemove() async throws {
        let (h, t) = setup()
        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 3389, "hostPort": 13389])
        let removed = try await h.handle(op: "vm.forward.remove", params: ["name": "Win", "hostPort": 13389])
        XCTAssertEqual(removed, [:])
        let lines = await t.monitorLines
        XCTAssertEqual(lines.last, "hostfwd_remove net0 tcp:127.0.0.1:13389")
        let list = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(list["forwards"], [])
    }

    func testForwardsForgottenWhenStopped() async throws {
        let (h, t) = setup()
        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 3389, "hostPort": 13389])
        _ = try await h.handle(op: "vm.stop", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.start", params: ["name": "Win"])
        var list = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(list["forwards"], [])

        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 22, "hostPort": 12222])
        await t.setState(.stopped)
        _ = await failure(h, "vm.forward.list", ["name": "Win"])
        await t.setState(.running)
        list = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(list["forwards"], [])
    }

    func testSetNetworkCallsTarget() async throws {
        let (h, t) = setup()
        let down = try await h.handle(op: "vm.set_network", params: ["name": "Win", "up": false])
        XCTAssertEqual(down["up"]?.boolValue, false)
        _ = try await h.handle(op: "vm.set_network", params: ["name": "Win", "up": true])
        let calls = await t.linkCalls
        XCTAssertEqual(calls, [false, true])
    }

    func testStateOpsNeedRunningVM() async throws {
        let (h, _) = setup(state: .stopped)
        let ops: [(String, JSON)] = [
            ("vm.snapshot.list", ["name": "Win"]),
            ("vm.snapshot.create", ["name": "Win", "snapshot": "s"]),
            ("vm.snapshot.restore", ["name": "Win", "snapshot": "s"]),
            ("vm.snapshot.delete", ["name": "Win", "snapshot": "s"]),
            ("vm.forward.add", ["name": "Win", "guestPort": 22]),
            ("vm.forward.remove", ["name": "Win", "hostPort": 22]),
            ("vm.forward.list", ["name": "Win"]),
            ("vm.set_network", ["name": "Win", "up": true]),
        ]
        for (op, params) in ops {
            let message = await failure(h, op, params)
            XCTAssertEqual(message, "VM 'Win' is stopped; call vm.start first", op)
        }
    }
}
