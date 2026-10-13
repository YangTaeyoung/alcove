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
        let created = try await h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "fresh"])
        XCTAssertEqual(created["snapshot"]?.stringValue, "fresh")
        let restored = try await h.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "clean", "waitTools": 0])
        XCTAssertEqual(restored["snapshot"]?.stringValue, "clean")
        XCTAssertEqual(restored["tools"]?.boolValue, false)
        let deleted = try await h.handle(op: "vm.snapshot.delete", params: ["name": "Win", "snapshot": "clean"])
        XCTAssertEqual(deleted, [:])
        let calls = await t.snapshotCalls
        XCTAssertEqual(calls, ["create:fresh", "restore:clean", "delete:clean"])
    }

    func testSnapshotCreateRefusesAnInvalidName() async throws {
        let (h, t) = setup()
        for name in ["", "a\nb", String(repeating: "x", count: 129)] {
            let message = await failure(h, "vm.snapshot.create", ["name": "Win", "snapshot": .string(name)])
            XCTAssertEqual(message, "snapshot name must be 1 to 128 characters without a line break; choose another name")
        }
        _ = try await h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": .string(String(repeating: "x", count: 128))])
        let calls = await t.snapshotCalls
        XCTAssertEqual(calls, ["create:" + String(repeating: "x", count: 128)])
    }

    func testSnapshotCreateRefusesAnExistingName() async throws {
        let (h, t) = setup()
        await t.setSnapshotList([snapshot])
        let message = await failure(h, "vm.snapshot.create", ["name": "Win", "snapshot": "clean"])
        XCTAssertEqual(message, "a snapshot named 'clean' already exists in 'Win'; call vm.snapshot.delete first or choose another name")
        let calls = await t.snapshotCalls
        XCTAssertEqual(calls, [])
    }

    func testSnapshotFailuresCarryTheEngineMessage() async throws {
        let (h, t) = setup()
        await t.setSnapshotList([snapshot])
        await t.setSnapshotError(QMPClient.QMPError.job(id: "alcove-snapshot-save-1", error: "Error while writing VM state: No space left on device"))
        let create = await failure(h, "vm.snapshot.create", ["name": "Win", "snapshot": "fresh"])
        XCTAssertEqual(create, "snapshot create failed: Error while writing VM state: No space left on device")
        await t.setSnapshotError(QMPClient.QMPError.command(name: "snapshot-delete", class: "GenericError", desc: "Device 'disk0' is not writable"))
        let delete = await failure(h, "vm.snapshot.delete", ["name": "Win", "snapshot": "clean"])
        XCTAssertEqual(delete, "snapshot delete failed: Device 'disk0' is not writable")
        await t.setSnapshotError(QMPClient.QMPError.disconnected("peer closed"))
        let restore = await failure(h, "vm.snapshot.restore", ["name": "Win", "snapshot": "clean", "waitTools": 0])
        XCTAssertEqual(restore, "snapshot restore failed: the engine closed the connection (peer closed); check vm.status")
    }

    func testSnapshotListFailureCarriesTheEngineText() async throws {
        let (h, t) = setup()
        await t.setSnapshotListError(VMController.ControllerError.snapshotListFailed("qemu-img: Could not open 'disk0.qcow2': Permission denied\n"))
        let list = await failure(h, "vm.snapshot.list", ["name": "Win"])
        XCTAssertEqual(list, "snapshot list failed: qemu-img: Could not open 'disk0.qcow2': Permission denied")
        let create = await failure(h, "vm.snapshot.create", ["name": "Win", "snapshot": "fresh"])
        XCTAssertEqual(create, "snapshot list failed: qemu-img: Could not open 'disk0.qcow2': Permission denied")
    }

    func testSetNetworkFailureIsASentence() async throws {
        let (h, t) = setup()
        await t.setLinkError(QMPClient.QMPError.command(name: "set_link", class: "DeviceNotFound", desc: "Device 'net0' not found"))
        let command = await failure(h, "vm.set_network", ["name": "Win", "up": false])
        XCTAssertEqual(command, "set network failed: Device 'net0' not found")
        await t.setLinkError(QMPClient.QMPError.notConnected)
        let gone = await failure(h, "vm.set_network", ["name": "Win", "up": true])
        XCTAssertEqual(gone, "set network failed: the connection to the engine is gone; check vm.status and restart the VM with vm.stop and vm.start")
    }

    func testEngineReasonNamesEveryQMPError() async throws {
        let (h, _) = setup()
        let restart = "restart the VM with vm.stop and vm.start"
        let cases: [(QMPClient.QMPError, String)] = [
            (.notConnected, "the connection to the engine is gone; check vm.status and \(restart)"),
            (.connect("No such file or directory"), "could not connect to the engine (No such file or directory); check vm.status and \(restart)"),
            (.disconnected("peer closed"), "the engine closed the connection (peer closed); check vm.status"),
            (.command(name: "stop", class: "GenericError", desc: "VM is stopped"), "VM is stopped"),
            (.protocolViolation("bad greeting"), "the engine sent a message Alcove cannot read (bad greeting); \(restart)"),
            (.timeout("query-status"), "the engine did not answer query-status in time; check vm.status"),
            (.job(id: "j1", error: "No space left on device"), "No space left on device"),
            (.unexpectedReturn(command: "query-block", value: .null), "the engine answered query-block with a value Alcove does not expect; \(restart)"),
        ]
        for (error, sentence) in cases {
            XCTAssertEqual(h.engineReason(error), sentence)
        }
    }

    func testEngineReasonNamesEveryControllerError() async throws {
        let (h, _) = setup()
        let restart = "restart the VM with vm.stop and vm.start"
        let cases: [(VMController.ControllerError, String)] = [
            (.notRunning, "the VM is not running; check vm.status"),
            (.alreadyRunning, "the VM is already running; check vm.status"),
            (.engineDidNotStart("exit 1"), "the engine did not start (exit 1); check vm.status and call vm.start again"),
            (.qmpUnavailable("no socket"), "the engine's control connection is unavailable (no socket); check vm.status and \(restart)"),
            (.invalidSnapshotName("a\nb"), "snapshot name must be 1 to 128 characters without a line break; choose another name"),
            (.snapshotListFailed("qemu-img: failed\n"), "qemu-img: failed"),
            (.snapshotListFailed(" \n"), "qemu-img could not read the snapshots of the disk; check the VM's disk file"),
        ]
        for (error, sentence) in cases {
            XCTAssertEqual(h.engineReason(error), sentence)
        }
    }

    func testEngineReasonDoesNotDumpOtherErrors() async throws {
        struct Unknown: Error {}
        let (h, _) = setup()
        XCTAssertEqual(h.engineReason(Unknown()), "the engine failed in a way Alcove cannot describe; check vm.status and restart the VM with vm.stop and vm.start")
        XCTAssertEqual(h.engineReason(CocoaError(.fileNoSuchFile)), CocoaError(.fileNoSuchFile).localizedDescription)
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
        XCTAssertEqual(agentRequests(second, "exec.run").count, 2)
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
        XCTAssertEqual(list["forwards"], [["hostPort": 40000, "guestPort": 7645, "kind": "agent"]])
    }

    func testForwardListMergesConfigAndRuntime() async throws {
        let (h, t) = setup()
        await t.setForwards([VMConfig.PortForward(proto: .tcp, hostPort: 2222, guestPort: 22)])
        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 3389, "hostPort": 13389])
        let list = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(list["forwards"], [
            ["hostPort": 2222, "guestPort": 22, "kind": "config"],
            ["hostPort": 40000, "guestPort": 7645, "kind": "agent"],
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
        XCTAssertEqual(list["forwards"], [["hostPort": 40000, "guestPort": 7645, "kind": "agent"]])
    }

    func testForwardRemoveAcceptsTheEngineConfirmation() async throws {
        let (h, t) = setup()
        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 3389, "hostPort": 13389])
        await t.setMonitorReplies(["host forwarding rule for tcp:127.0.0.1:13389 removed\r\n"])
        let removed = try await h.handle(op: "vm.forward.remove", params: ["name": "Win", "hostPort": 13389])
        XCTAssertEqual(removed, [:])
        let list = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(list["forwards"], [["hostPort": 40000, "guestPort": 7645, "kind": "agent"]])
    }

    func testForwardRemoveDropsAForwardTheEngineDoesNotHave() async throws {
        let (h, t) = setup()
        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 3389, "hostPort": 13389])
        await t.setMonitorReplies(["host forwarding rule for tcp:127.0.0.1:13389 not found\r\n"])
        let removed = try await h.handle(op: "vm.forward.remove", params: ["name": "Win", "hostPort": 13389])
        XCTAssertEqual(removed, [:])
        let list = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(list["forwards"], [["hostPort": 40000, "guestPort": 7645, "kind": "agent"]])
    }

    func testForwardRemoveReportsAnEmptyReply() async throws {
        let (h, t) = setup()
        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 3389, "hostPort": 13389])
        await t.setMonitorReplies([""])
        let message = await failure(h, "vm.forward.remove", ["name": "Win", "hostPort": 13389])
        XCTAssertEqual(message, "port forward failed: the engine gave no answer")
        let list = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(list["forwards"]?.arrayValue?.count, 2)
    }

    func testForwardRemoveReportsAnotherEngineReply() async throws {
        let (h, t) = setup()
        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 3389, "hostPort": 13389])
        await t.setMonitorReplies(["invalid format\r\n"])
        let message = await failure(h, "vm.forward.remove", ["name": "Win", "hostPort": 13389])
        XCTAssertEqual(message, "port forward failed: invalid format")
        let list = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(list["forwards"], [
            ["hostPort": 40000, "guestPort": 7645, "kind": "agent"],
            ["hostPort": 13389, "guestPort": 3389, "kind": "runtime"],
        ])
    }

    func testForwardsForgottenWhenStopped() async throws {
        let (h, t) = setup()
        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 3389, "hostPort": 13389])
        _ = try await h.handle(op: "vm.stop", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.start", params: ["name": "Win"])
        var list = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(list["forwards"], [["hostPort": 40000, "guestPort": 7645, "kind": "agent"]])

        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 22, "hostPort": 12222])
        await t.setState(.stopped)
        _ = await failure(h, "vm.forward.list", ["name": "Win"])
        await t.setState(.running)
        list = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(list["forwards"], [["hostPort": 40000, "guestPort": 7645, "kind": "agent"]])
    }

    func testForwardsForgottenAfterEngineRestart() async throws {
        let (h, t) = setup()
        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 3389, "hostPort": 13389])
        await t.setInstance(2)
        let list = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(list["forwards"], [["hostPort": 40000, "guestPort": 7645, "kind": "agent"]])
    }

    func testForwardRemoveRejectsNonRuntimePorts() async throws {
        let (h, t) = setup()
        await t.setForwards([VMConfig.PortForward(proto: .tcp, hostPort: 2222, guestPort: 22)])
        for port in [2222, 40000, 5555] {
            let message = await failure(h, "vm.forward.remove", ["name": "Win", "hostPort": .int(Int64(port))])
            XCTAssertEqual(message, "no runtime forward on host port \(port) in 'Win'; call vm.forward.list (forwards from the VM configuration cannot be removed while it runs)")
        }
        let lines = await t.monitorLines
        XCTAssertEqual(lines, [])
    }

    func testForwardAddRefusesReservedPorts() async throws {
        let (h, t) = setup()
        await t.setForwards([VMConfig.PortForward(proto: .tcp, hostPort: 2222, guestPort: 22)])
        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 3389, "hostPort": 13389])
        for port in [2222, 40000, 13389] {
            let message = await failure(h, "vm.forward.add", ["name": "Win", "guestPort": 80, "hostPort": .int(Int64(port))])
            XCTAssertEqual(message, "host port \(port) is taken; pass hostPort: 0 to let Alcove choose")
        }
        let lines = await t.monitorLines
        XCTAssertEqual(lines.count, 1)
    }

    func testForwardPortsOutOfRange() async throws {
        let (h, t) = setup()
        let guest = await failure(h, "vm.forward.add", ["name": "Win", "guestPort": 70000])
        XCTAssertEqual(guest, "guestPort must be between 1 and 65535")
        let host = await failure(h, "vm.forward.add", ["name": "Win", "guestPort": 80, "hostPort": 70000])
        XCTAssertEqual(host, "hostPort must be between 1 and 65535")
        let remove = await failure(h, "vm.forward.remove", ["name": "Win", "hostPort": 0])
        XCTAssertEqual(remove, "hostPort must be between 1 and 65535")
        let lines = await t.monitorLines
        XCTAssertEqual(lines, [])
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

    // MARK: - clones and sessions that discard changes

    func testCloneAndDeleteGoThroughProvisioning() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 800, height: 600))
        let registry = FakeProvisioningRegistry(targets: ["Win": t])
        let h = ControlHandler(registry: registry, hostKind: "test")

        let cloned = try await h.handle(op: "vm.clone", params: ["name": "Win", "newName": "  Copy "])
        XCTAssertEqual(cloned, ["name": "Copy"])
        let missingName = await failure(h, "vm.clone", ["name": "Win"])
        XCTAssertEqual(missingName, "missing or invalid parameter 'newName'")
        let unknown = await failure(h, "vm.clone", ["name": "Nope", "newName": "Copy"])
        XCTAssertEqual(unknown, "no VM named 'Nope'; call vm.list")
        let unknownDelete = await failure(h, "vm.delete", ["name": "Nope"])
        XCTAssertEqual(unknownDelete, "no VM named 'Nope'; call vm.list")

        let lease = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "agent-a"])
        let token = try XCTUnwrap(lease["lease"]?.stringValue)
        _ = try await h.handle(op: "vm.screenshot", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.forward.add", params: ["name": "Win", "guestPort": 3389, "hostPort": 13389, "lease": .string(token)])
        let leased = await failure(h, "vm.delete", ["name": "Win"])
        XCTAssertTrue(leased.hasPrefix("VM 'Win' is leased by agent-a"), leased)
        let leasedClone = await failure(h, "vm.clone", ["name": "Win", "newName": "Other"])
        XCTAssertTrue(leasedClone.hasPrefix("VM 'Win' is leased by agent-a"), leasedClone)

        let deleted = try await h.handle(op: "vm.delete", params: ["name": "Win", "lease": .string(token)])
        XCTAssertEqual(deleted, [:])
        let calls = await registry.calls
        XCTAssertEqual(calls, ["clone:Win->Copy", "delete:Win"])

        let row = try await h.handle(op: "vm.list", params: [:])
        XCTAssertNil(row["vms"]?[0]?["leasedBy"])
        XCTAssertNil(row["vms"]?[0]?["width"])
        let forwards = try await h.handle(op: "vm.forward.list", params: ["name": "Win"])
        XCTAssertEqual(forwards["forwards"], [["hostPort": 40000, "guestPort": 7645, "kind": "agent"]])
    }

    func testProvisioningErrorsAreReported() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 800, height: 600))
        let registry = FakeProvisioningRegistry(targets: ["Win": t])
        let h = ControlHandler(registry: registry, hostKind: "test")
        _ = try await h.handle(op: "vm.screenshot", params: ["name": "Win"])
        await registry.setFailure(VMBundle.CloneError.sourceRunning("Win"))
        let clone = await failure(h, "vm.clone", ["name": "Win", "newName": "Copy"])
        XCTAssertEqual(clone, "'Win' is running; stop it before cloning it")
        await registry.setFailure(VMBundle.CloneError.cloneRunning("Win"))
        let delete = await failure(h, "vm.delete", ["name": "Win"])
        XCTAssertEqual(delete, "'Win' is running; stop it before deleting it")
        await registry.setFailure(VMBundle.CloneError.overlayFailed("qemu-img: No space left on device"))
        let overlay = await failure(h, "vm.clone", ["name": "Win", "newName": "Copy"])
        XCTAssertEqual(overlay, "qemu-img could not create the clone's disk (qemu-img: No space left on device); "
                       + "check the template's disk images and the free space, then clone again")
        let row = try await h.handle(op: "vm.list", params: [:])
        XCTAssertEqual(row["vms"]?[0]?["width"]?.intValue, 800)
    }

    func testCloneUnsupportedRegistry() async throws {
        let (h, _) = setup()
        let clone = await failure(h, "vm.clone", ["name": "Win", "newName": "Copy"])
        XCTAssertEqual(clone, "this control host cannot clone or delete VMs")
        let delete = await failure(h, "vm.delete", ["name": "Win"])
        XCTAssertEqual(delete, "this control host cannot clone or delete VMs")
    }

    /// A bundle directory with a config, a disk file and UEFI variables, made without an engine.
    private func writeBundle(_ config: VMConfig, in directory: URL) throws -> VMBundle {
        let bundle = VMBundle(url: directory.appendingPathComponent(config.name).appendingPathExtension(VMBundle.pathExtension))
        try FileManager.default.createDirectory(at: bundle.runURL, withIntermediateDirectories: true)
        try bundle.save(config)
        for disk in config.disks { try Data("QFI".utf8).write(to: bundle.diskURL(disk)) }
        try Data(count: 32).write(to: bundle.efiVarsURL)
        return bundle
    }

    /// A temp VM directory and a stand-in engine: `qemu-system-aarch64` only answers `-display help`,
    /// `qemu-img` writes a stub file at its last argument.
    private func headless() throws -> (ControlHandler, URL) {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alcove-ctl-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let vms = tmp.appendingPathComponent("vms"), root = tmp.appendingPathComponent("engine")
        try fm.createDirectory(at: vms, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("pc-bios"), withIntermediateDirectories: true)
        let scripts = ["qemu-system-aarch64": "#!/bin/sh\necho 'Available display backend types:'\necho alcove\n",
                       "qemu-img": "#!/bin/sh\nfor out; do :; done\nprintf 'QFI' > \"$out\"\n"]
        for (name, source) in scripts {
            fm.createFile(atPath: root.appendingPathComponent(name).path, contents: Data(source.utf8), attributes: [.posixPermissions: 0o755])
        }
        fm.createFile(atPath: root.appendingPathComponent("pc-bios/edk2-aarch64-code.fd").path, contents: Data(count: 16))
        let engine = try EngineLocator(roots: [root.path]).locate()
        return (ControlHandler(registry: HeadlessRegistry(directory: vms, engine: engine), hostKind: "headless"), vms)
    }

    func testDeleteRefusesNonClone() async throws {
        let (h, vms) = try headless()
        let plain = try writeBundle(VMConfig.defaults(name: "Plain", guestOS: .linux), in: vms)
        let message = await failure(h, "vm.delete", ["name": "Plain"])
        XCTAssertEqual(message, "'Plain' is not a clone; delete it in the Alcove app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plain.configURL.path))
        let list = try await h.handle(op: "vm.list", params: [:])
        XCTAssertEqual(list["vms"]?[0]?["name"]?.stringValue, "Plain")
        XCTAssertNil(list["vms"]?[0]?["cloneOf"])
        XCTAssertNil(list["vms"]?[0]?["ephemeral"])
    }

    func testHeadlessCloneAndDelete() async throws {
        let (h, vms) = try headless()
        let template = try writeBundle(VMConfig.defaults(name: "Base", guestOS: .linux), in: vms)
        let cloned = try await h.handle(op: "vm.clone", params: ["name": "Base", "newName": "Copy"])
        XCTAssertEqual(cloned, ["name": "Copy"])
        let copy = VMBundle(url: vms.appendingPathComponent("Copy.alcovevm"))
        XCTAssertEqual(try copy.loadConfig().cloneOf, "Base")
        XCTAssertEqual(template.liveClones().map(\.lastPathComponent), ["Copy.alcovevm"])

        let list = try await h.handle(op: "vm.list", params: [:])
        XCTAssertEqual(list["vms"]?[0]?["name"]?.stringValue, "Base")
        XCTAssertNil(list["vms"]?[0]?["cloneOf"])
        XCTAssertEqual(list["vms"]?[1]?["name"]?.stringValue, "Copy")
        XCTAssertEqual(list["vms"]?[1]?["cloneOf"]?.stringValue, "Base")

        let again = await failure(h, "vm.clone", ["name": "Base", "newName": "Copy"])
        XCTAssertEqual(again, "a VM named 'Copy' already exists; choose another name")
        let ofClone = await failure(h, "vm.clone", ["name": "Copy", "newName": "Third"])
        XCTAssertEqual(ofClone, "'Copy' is a clone of 'Base'; clone 'Base' instead")
        let start = await failure(h, "vm.start", ["name": "Base"])
        XCTAssertEqual(start, "start failed: 'Base' is a template with clones (Copy); delete the clones first or start a clone")

        let deleted = try await h.handle(op: "vm.delete", params: ["name": "Copy"])
        XCTAssertEqual(deleted, [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: template.clonesURL.path))
        let gone = await failure(h, "vm.status", ["name": "Copy"])
        XCTAssertEqual(gone, "no VM named 'Copy'; call vm.list")
    }

    func testStartDiscardChangesReportsEphemeral() async throws {
        let (h, t) = setup(state: .stopped)
        let started = try await h.handle(op: "vm.start", params: ["name": "Win", "discardChanges": true])
        XCTAssertEqual(started, ["state": "running", "ephemeral": true])
        var discards = await t.startDiscard
        XCTAssertEqual(discards, [true])
        let status = try await h.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertEqual(status["ephemeral"]?.boolValue, true)
        XCTAssertNil(status["cloneOf"])
        let list = try await h.handle(op: "vm.list", params: [:])
        XCTAssertEqual(list["vms"]?[0]?["ephemeral"]?.boolValue, true)

        let again = await failure(h, "vm.start", ["name": "Win", "discardChanges": true])
        XCTAssertEqual(again, "VM 'Win' is already running; stop it first to start a session that discards changes")
        let plain = try await h.handle(op: "vm.start", params: ["name": "Win"])
        XCTAssertEqual(plain, ["state": "running", "ephemeral": true])
        discards = await t.startDiscard
        XCTAssertEqual(discards, [true])

        _ = try await h.handle(op: "vm.stop", params: ["name": "Win"])
        await t.setCloneOf("Base")
        let kept = try await h.handle(op: "vm.start", params: ["name": "Win", "discardChanges": false])
        XCTAssertEqual(kept, ["state": "running", "ephemeral": false])
        discards = await t.startDiscard
        XCTAssertEqual(discards, [true, false])
        let after = try await h.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertNil(after["ephemeral"])
        XCTAssertEqual(after["cloneOf"]?.stringValue, "Base")
    }
}

/// A registry over fake targets that records clone and delete requests, or fails them with `failure`.
actor FakeProvisioningRegistry: VMRegistry, VMProvisioning {
    let targets: [String: FakeTarget]
    var calls: [String] = []
    var failure: Error?

    init(targets: [String: FakeTarget]) { self.targets = targets }
    func names() async -> [String] { targets.keys.sorted() }
    func target(named name: String) async -> VMTarget? { targets[name] }
    func setFailure(_ error: Error?) { failure = error }
    func cloneVM(named name: String, as newName: String) async throws {
        if let failure { throw failure }
        calls.append("clone:\(name)->\(newName)")
    }
    func deleteVM(named name: String) async throws {
        if let failure { throw failure }
        calls.append("delete:\(name)")
    }
}
