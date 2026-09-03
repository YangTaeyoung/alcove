import XCTest
@testable import AlcoveQMP

final class QMPClientTests: XCTestCase {
    func testConnectNegotiatesCapabilitiesAndExecutes() async throws {
        let server = try FakeQMPServer()
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        let g = await client.greeting
        XCTAssertEqual(g?["version"]?["qemu"]?["major"]?.intValue, 11)
        XCTAssertEqual(server.requests.first?["execute"]?.stringValue, "qmp_capabilities")
        let status = try await client.queryStatus()
        XCTAssertEqual(status, .init(running: true, state: "running"))
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(server.requests[1]["id"]?.intValue, 2)
        await client.disconnect()
    }

    func testErrorReplyIsThrown() async throws {
        let server = try FakeQMPServer()
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        do {
            _ = try await client.execute("no-such-command")
            XCTFail("expected error")
        } catch let QMPClient.QMPError.command(name, cls, desc) {
            XCTAssertEqual(name, "no-such-command", "error must name the command, not the wire id")
            XCTAssertEqual(cls, "CommandNotFound")
            XCTAssertTrue(desc.contains("no-such-command"))
        }
    }

    func testOutOfOrderRepliesAreCorrelatedById() async throws {
        // "slow" is answered from another thread after "fast" has been answered, so the
        // reply for the lower id really arrives second (a FIFO matcher would swap the results).
        let server = try FakeQMPServer { req, server in
            switch req["execute"]?.stringValue {
            case "qmp_capabilities": return [FakeQMPServer.ok(req)]
            case "slow":
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { server.sendLine(FakeQMPServer.ok(req, "slow-result")) }
                return []
            case "fast": return [FakeQMPServer.ok(req, "fast-result")]
            default: return [FakeQMPServer.ok(req)]
            }
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        async let slow = client.execute("slow")
        try await Task.sleep(for: .milliseconds(50))
        async let fast = client.execute("fast")
        let f = try await fast
        XCTAssertEqual(server.requests.map { $0["execute"]?.stringValue }, ["qmp_capabilities", "slow", "fast"])
        XCTAssertEqual(server.requests.first { $0["execute"]?.stringValue == "fast" }?["id"]?.intValue, 3)
        XCTAssertEqual(server.requests.first { $0["execute"]?.stringValue == "slow" }?["id"]?.intValue, 2)
        XCTAssertEqual(f, "fast-result")
        let s = try await slow
        XCTAssertEqual(s, "slow-result")
    }

    func testEventsAreBufferedBeforeSubscription() async throws {
        let server = try FakeQMPServer()
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        server.emitEvent("STOP")
        server.emitEvent("RESUME", data: ["x": 1])
        _ = try await client.queryStatus()   // round trip guarantees the events were read
        var it = client.events.makeAsyncIterator()
        let e1 = await it.next()
        XCTAssertEqual(e1?.name, "STOP")
        let e2 = await it.next()
        XCTAssertEqual(e2?.name, "RESUME")
        XCTAssertEqual(e2?.data["x"]?.intValue, 1)
        XCTAssertEqual(e2?.seconds, 1)
    }

    func testTimeout() async throws {
        let server = try FakeQMPServer { req, _ in
            req["execute"]?.stringValue == "qmp_capabilities" ? [FakeQMPServer.ok(req)] : []
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        do {
            _ = try await client.execute("never-answered", timeout: .milliseconds(200))
            XCTFail("expected timeout")
        } catch QMPClient.QMPError.timeout(let c) {
            XCTAssertEqual(c, "never-answered")
        }
    }

    func testDisconnectFailsPendingAndFinishesEvents() async throws {
        let server = try FakeQMPServer { req, _ in
            req["execute"]?.stringValue == "qmp_capabilities" ? [FakeQMPServer.ok(req)] : []
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        let task = Task { try await client.execute("hang", timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        server.dropClient()
        do {
            _ = try await task.value
            XCTFail("expected disconnect")
        } catch QMPClient.QMPError.disconnected {
        }
        var it = client.events.makeAsyncIterator()
        let end = await it.next()
        XCTAssertNil(end)
        let connected = await client.isConnected
        XCTAssertFalse(connected)
        do {
            _ = try await client.execute("after")
            XCTFail("expected notConnected")
        } catch QMPClient.QMPError.notConnected {}
    }

    func testGreetingTimeout() async throws {
        // a server that never greets: raw listening socket
        let path = "/tmp/alcove-qmp-silent-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in _ = path.withCString { strncpy(dst, $0, 103) } } }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        listen(fd, 1)
        defer { Darwin.close(fd); unlink(path) }
        let client = QMPClient()
        do {
            try await client.connect(path: path, timeout: .milliseconds(300))
            XCTFail("expected timeout")
        } catch QMPClient.QMPError.timeout {}
    }

    func testSnapshotSaveJobFlow() async throws {
        let server = try FakeQMPServer { req, server in
            let id = req["id"] ?? .null
            switch req["execute"]?.stringValue {
            case "qmp_capabilities": return [["return": [:], "id": id]]
            case "snapshot-save":
                let job = req["arguments"]?["job-id"]?.stringValue ?? ""
                XCTAssertEqual(req["arguments"]?["tag"]?.stringValue, "snap1")
                XCTAssertEqual(req["arguments"]?["vmstate"]?.stringValue, "disk0")
                XCTAssertEqual(req["arguments"]?["devices"], ["disk0"])
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    for s in ["created", "running", "waiting", "pending", "concluded"] {
                        server.emitEvent("JOB_STATUS_CHANGE", data: ["id": .string(job), "status": .string(s)])
                    }
                }
                return [["return": [:], "id": id]]
            case "query-jobs":
                let job = server.requests.compactMap { $0["arguments"]?["job-id"]?.stringValue }.last ?? ""
                return [["return": [["id": .string(job), "type": "snapshot-save", "status": "concluded", "current-progress": 1, "total-progress": 1]], "id": id]]
            case "job-dismiss": return [["return": [:], "id": id]]
            default: return [["error": ["class": "GenericError", "desc": "unexpected"], "id": id]]
            }
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        try await client.snapshotSave(tag: "snap1", vmstate: "disk0", devices: ["disk0"], timeout: .seconds(5))
        let names = server.requests.compactMap { $0["execute"]?.stringValue }
        XCTAssertEqual(names, ["qmp_capabilities", "snapshot-save", "query-jobs", "job-dismiss"])
    }

    func testSnapshotJobErrorIsSurfaced() async throws {
        let server = try FakeQMPServer { req, server in
            let id = req["id"] ?? .null
            switch req["execute"]?.stringValue {
            case "qmp_capabilities": return [["return": [:], "id": id]]
            case "snapshot-load":
                let job = req["arguments"]?["job-id"]?.stringValue ?? ""
                // status change may even arrive before the reply is processed
                server.emitEvent("JOB_STATUS_CHANGE", data: ["id": .string(job), "status": "concluded"])
                return [["return": [:], "id": id]]
            case "query-jobs":
                let job = server.requests.compactMap { $0["arguments"]?["job-id"]?.stringValue }.last ?? ""
                return [["return": [["id": .string(job), "type": "snapshot-load", "status": "concluded", "current-progress": 0, "total-progress": 0, "error": "Snapshot 'nope' does not exist"]], "id": id]]
            case "job-dismiss": return [["return": [:], "id": id]]
            default: return [["error": ["class": "GenericError", "desc": "unexpected"], "id": id]]
            }
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        do {
            try await client.snapshotLoad(tag: "nope", vmstate: "disk0", devices: ["disk0"], timeout: .seconds(5))
            XCTFail("expected job error")
        } catch let QMPClient.QMPError.job(_, error) {
            XCTAssertTrue(error.contains("does not exist"))
        }
    }

    func testMigratePollsUntilCompleted() async throws {
        let counter = Counter()
        let server = try FakeQMPServer { req, _ in
            let id = req["id"] ?? .null
            switch req["execute"]?.stringValue {
            case "qmp_capabilities", "migrate": return [["return": [:], "id": id]]
            case "query-migrate":
                let n = counter.next()
                return [["return": ["status": .string(n < 3 ? "active" : "completed")], "id": id]]
            default: return [["error": ["class": "GenericError", "desc": "unexpected"], "id": id]]
            }
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        try await client.migrate(uri: "file:/tmp/x.state", timeout: .seconds(5))
        XCTAssertEqual(server.requests.filter { $0["execute"]?.stringValue == "query-migrate" }.count, 3)
        XCTAssertEqual(server.requests.first { $0["execute"]?.stringValue == "migrate" }?["arguments"]?["uri"]?.stringValue, "file:/tmp/x.state")
    }

    func testTypedHelpersSendDocumentedArguments() async throws {
        let server = try FakeQMPServer { req, _ in [FakeQMPServer.ok(req, req["execute"]?.stringValue == "query-block" ? [] : [:])] }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        try await client.stop(); try await client.cont(); try await client.systemPowerdown(); try await client.systemReset()
        try await client.changeMedium(deviceID: "cd0", filename: "/a.iso")
        try await client.eject(deviceID: "cd0", force: true)
        try await client.attachUSBHost(id: "usb1", vendorID: 0x05ac, productID: 0x12a8, bus: "xhci.0")
        try await client.deviceDel(id: "usb1")
        try await client.screendump(filename: "/tmp/s.png")
        try await client.sendKey(qcode: "ret", down: true)
        _ = try await client.queryBlock()
        let byName = Dictionary(grouping: server.requests, by: { $0["execute"]?.stringValue ?? "" })
        XCTAssertEqual(byName["blockdev-change-medium"]?.first?["arguments"], ["id": "cd0", "filename": "/a.iso", "format": "raw"])
        XCTAssertEqual(byName["eject"]?.first?["arguments"], ["id": "cd0", "force": true])
        XCTAssertEqual(byName["device_add"]?.first?["arguments"], ["driver": "usb-host", "id": "usb1", "bus": "xhci.0", "vendorid": 1452, "productid": 4776])
        XCTAssertEqual(byName["device_del"]?.first?["arguments"], ["id": "usb1"])
        XCTAssertEqual(byName["screendump"]?.first?["arguments"], ["filename": "/tmp/s.png", "format": "png"])
        XCTAssertEqual(byName["input-send-event"]?.first?["arguments"]?["events"]?[0]?["data"]?["key"]?["data"]?.stringValue, "ret")
        XCTAssertNotNil(byName["stop"]); XCTAssertNotNil(byName["cont"]); XCTAssertNotNil(byName["system_powerdown"]); XCTAssertNotNil(byName["system_reset"])
    }

    // MARK: ordering / teardown

    func testEventsArriveInEmissionOrder() async throws {
        let server = try FakeQMPServer()
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        let count = 3000
        for i in 0..<count { server.emitEvent("E", data: ["n": .int(Int64(i))]) }
        _ = try await client.queryStatus()   // round trip: everything above has been read
        var it = client.events.makeAsyncIterator()
        var seen: [Int] = []
        for _ in 0..<count { seen.append(await it.next()?.data["n"]?.intValue ?? -1) }
        XCTAssertEqual(seen, Array(0..<count), "events must be delivered in wire order")
    }

    func testReplyAndEventsBeforePeerCloseAreDelivered() async throws {
        // QEMU's `quit`: reply, SHUTDOWN event and socket close arrive in one read
        // (system/runstate.c). The reply must succeed and the event must not be lost.
        let server = try FakeQMPServer { req, server in
            switch req["execute"]?.stringValue {
            case "qmp_capabilities": return [FakeQMPServer.ok(req)]
            case "quit":
                server.sendLine(FakeQMPServer.ok(req))
                server.emitEvent("SHUTDOWN", data: ["guest": false, "reason": "host-qmp-quit"])
                server.dropClient()
                return []
            default: return [FakeQMPServer.ok(req)]
            }
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        try await client.quit()
        var it = client.events.makeAsyncIterator()
        let e = await it.next()
        XCTAssertEqual(e?.name, "SHUTDOWN")
        let end = await it.next()
        XCTAssertNil(end, "events finishes after the last event")
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }

    func testDisconnectIsSynchronousAndClientIsSingleUse() async throws {
        let server = try FakeQMPServer { req, _ in
            req["execute"]?.stringValue == "qmp_capabilities" ? [FakeQMPServer.ok(req)] : []
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        let hanging = Task { try await client.execute("hang", timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        await client.disconnect()
        let connected = await client.isConnected
        XCTAssertFalse(connected, "isConnected must be false as soon as disconnect() returns")
        do {
            _ = try await hanging.value
            XCTFail("expected disconnect")
        } catch QMPClient.QMPError.disconnected(let reason) {
            XCTAssertEqual(reason, "closed")
        }
        var it = client.events.makeAsyncIterator()
        let end = await it.next()
        XCTAssertNil(end)
        await client.disconnect()   // idempotent
        do {
            try await client.connect(path: server.path)
            XCTFail("a used client must refuse to connect again")
        } catch QMPClient.QMPError.connect {}
    }

    func testConnectRejectsConcurrentConnect() async throws {
        let server = try FakeQMPServer()
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        do {
            try await client.connect(path: server.path)
            XCTFail("expected .connect")
        } catch QMPClient.QMPError.connect {}
        let connected = await client.isConnected
        XCTAssertTrue(connected, "a rejected second connect must not disturb the live connection")
        let status = try await client.queryStatus()
        XCTAssertEqual(status.state, "running")
    }

    func testCapabilitiesFailureTearsDown() async throws {
        let server = try FakeQMPServer { req, _ in
            [["error": ["class": "GenericError", "desc": "nope"], "id": req["id"] ?? .null]]
        }
        defer { server.stop() }
        let client = QMPClient()
        do {
            try await client.connect(path: server.path)
            XCTFail("expected error")
        } catch let QMPClient.QMPError.command(name, _, _) {
            XCTAssertEqual(name, "qmp_capabilities")
        }
        let connected = await client.isConnected
        XCTAssertFalse(connected)
        do {
            _ = try await client.execute("query-status")
            XCTFail("expected notConnected: the half-open connection must be gone")
        } catch QMPClient.QMPError.notConnected {}
        do {
            try await client.connect(path: server.path)
            XCTFail("connect must not silently no-op after a failed negotiation")
        } catch QMPClient.QMPError.connect {}
    }

    func testGreetingTimeoutTearsDownAndRejectsReuse() async throws {
        let path = "/tmp/alcove-qmp-silent-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in _ = path.withCString { strncpy(dst, $0, 103) } } }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        listen(fd, 1)
        defer { Darwin.close(fd); unlink(path) }
        let client = QMPClient()
        do {
            try await client.connect(path: path, timeout: .milliseconds(200))
            XCTFail("expected timeout")
        } catch QMPClient.QMPError.timeout {}
        var it = client.events.makeAsyncIterator()
        let end = await it.next()
        XCTAssertNil(end, "events finishes when a connect attempt fails")
        do {
            try await client.connect(path: path, timeout: .milliseconds(200))
            XCTFail("expected .connect")
        } catch QMPClient.QMPError.connect {}
    }

    // MARK: cancellation / job waits

    func testExecuteHonorsCancellation() async throws {
        let server = try FakeQMPServer { req, _ in
            req["execute"]?.stringValue == "qmp_capabilities" ? [FakeQMPServer.ok(req)] : []
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        let task = Task { try await client.execute("never-answered", timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5), "cancellation must not wait for the command timeout")
        // an already-cancelled task must not even send
        let before = server.requests.count
        let t2 = Task { try await client.execute("not-sent") }
        t2.cancel()
        do { _ = try await t2.value; XCTFail("expected CancellationError") } catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(server.requests.count, before)
        // the connection is still usable afterwards
        let connected = await client.isConnected
        XCTAssertTrue(connected)
    }

    func testJobWaitReportsDisconnectNotTimeout() async throws {
        let server = try FakeQMPServer { req, server in
            switch req["execute"]?.stringValue {
            case "qmp_capabilities": return [FakeQMPServer.ok(req)]
            case "snapshot-save":
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { server.dropClient() }   // QEMU dies mid-snapshot
                return [FakeQMPServer.ok(req)]
            default: return [FakeQMPServer.ok(req)]
            }
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        do {
            try await client.snapshotSave(tag: "s", vmstate: "d", devices: ["d"], timeout: .seconds(30))
            XCTFail("expected disconnected")
        } catch QMPClient.QMPError.disconnected {
        } catch {
            XCTFail("expected .disconnected, got \(error)")
        }
    }

    func testJobWaitReportsCancellation() async throws {
        let server = try FakeQMPServer { req, _ in [FakeQMPServer.ok(req)] }   // job never concludes
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        let task = Task { try await client.snapshotSave(tag: "s", vmstate: "d", devices: ["d"], timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testJobWaitTimesOut() async throws {
        let server = try FakeQMPServer { req, _ in [FakeQMPServer.ok(req)] }   // job never concludes
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        do {
            try await client.snapshotSave(tag: "s", vmstate: "d", devices: ["d"], timeout: .milliseconds(200))
            XCTFail("expected timeout")
        } catch QMPClient.QMPError.timeout(let what) {
            XCTAssertTrue(what.hasPrefix("job alcove-snapshot-save-"), what)
        }
    }

    // MARK: migrate

    func testMigrateTimeoutCancelsMigration() async throws {
        let server = try FakeQMPServer { req, _ in
            switch req["execute"]?.stringValue {
            case "query-migrate": return [FakeQMPServer.ok(req, ["status": "active"])]
            default: return [FakeQMPServer.ok(req)]
            }
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        do {
            try await client.migrate(uri: "file:/tmp/x.state", timeout: .milliseconds(500))
            XCTFail("expected timeout")
        } catch QMPClient.QMPError.timeout(let c) {
            XCTAssertEqual(c, "migrate")
        }
        XCTAssertEqual(server.requests.last?["execute"]?.stringValue, "migrate_cancel")
    }

    func testMigrateCancellationCancelsMigration() async throws {
        let server = try FakeQMPServer { req, _ in
            switch req["execute"]?.stringValue {
            case "query-migrate": return [FakeQMPServer.ok(req, ["status": "active"])]
            default: return [FakeQMPServer.ok(req)]
            }
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        let task = Task { try await client.migrate(uri: "file:/tmp/x.state", timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        XCTAssertEqual(server.requests.last?["execute"]?.stringValue, "migrate_cancel")
    }

    // MARK: removable media

    /// query-block as QEMU 11.1.1 reports Alcove's CD-ROM layout
    /// (`-blockdev node-name=cd0 -device usb-storage,drive=cd0,id=cd0-dev`): the backend
    /// is anonymous and attached to the SCSI child usb-storage creates internally.
    private static let usbStorageBlockInfo: JSON = [[
        "device": "", "qdev": "/machine/peripheral/cd0-dev/cd0-dev.0/legacy[0]", "type": "unknown",
        "removable": true, "locked": false, "tray_open": false,
        "inserted": ["node-name": "cd0", "file": "/a.iso", "ro": true, "drv": "raw"],
    ], [
        "device": "", "qdev": "disk0-dev", "type": "unknown", "removable": false, "locked": false,
        "inserted": ["node-name": "disk0", "file": "/disk.qcow2", "ro": false, "drv": "qcow2"],
    ]]

    func testQueryBlockExposesQdevAndNodeName() async throws {
        let server = try FakeQMPServer { req, _ in
            [FakeQMPServer.ok(req, req["execute"]?.stringValue == "query-block" ? Self.usbStorageBlockInfo : [:])]
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        let devices = try await client.queryBlock()
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].qdev, "/machine/peripheral/cd0-dev/cd0-dev.0/legacy[0]")
        XCTAssertEqual(devices[0].nodeName, "cd0")
        XCTAssertEqual(devices[0].file, "/a.iso")
        XCTAssertEqual(devices[0].removable, true)
        XCTAssertEqual(devices[0].trayOpen, false)
        XCTAssertEqual(devices[1].qdev, "disk0-dev")
        XCTAssertEqual(devices[1].nodeName, "disk0")
        XCTAssertNil(devices[1].trayOpen)
    }

    func testMediumCommandsResolveUSBStorageBackend() async throws {
        let server = try FakeQMPServer { req, _ in
            [FakeQMPServer.ok(req, req["execute"]?.stringValue == "query-block" ? Self.usbStorageBlockInfo : [:])]
        }
        defer { server.stop() }
        let client = QMPClient()
        try await client.connect(path: server.path)
        let legacy: JSON = "/machine/peripheral/cd0-dev/cd0-dev.0/legacy[0]"
        try await client.changeMedium(deviceID: "cd0-dev", filename: "/b.iso")
        try await client.changeMedium(deviceID: "cd0-dev", filename: "/c.iso", force: true)
        try await client.eject(deviceID: "cd0-dev", force: true)
        try await client.eject(deviceID: "/machine/peripheral/cd0-dev")                  // QOM path of the usb-storage device
        try await client.eject(deviceID: "/machine/peripheral/cd0-dev/cd0-dev.0/legacy[0]") // already the backend's qdev
        try await client.eject(deviceID: "disk0-dev")                                     // device holding the backend directly
        try await client.eject(deviceID: "unknown-dev")                                   // not in query-block: passed through
        let media = server.requests.filter { $0["execute"]?.stringValue == "blockdev-change-medium" }.map { $0["arguments"] }
        XCTAssertEqual(media, [
            ["id": legacy, "filename": "/b.iso", "format": "raw"],
            ["id": legacy, "filename": "/c.iso", "format": "raw", "force": true],
        ])
        let ejects = server.requests.filter { $0["execute"]?.stringValue == "eject" }.map { $0["arguments"]?["id"] }
        XCTAssertEqual(ejects, [legacy, legacy, legacy, "disk0-dev", "unknown-dev"])
        XCTAssertEqual(server.requests.filter { $0["execute"]?.stringValue == "eject" }.first?["arguments"]?["force"], true)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
