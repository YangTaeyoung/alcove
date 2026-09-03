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
        } catch let QMPClient.QMPError.command(_, cls, desc) {
            XCTAssertEqual(cls, "CommandNotFound")
            XCTAssertTrue(desc.contains("no-such-command"))
        }
    }

    func testOutOfOrderRepliesAreCorrelatedById() async throws {
        let server = try FakeQMPServer { req, _ in
            switch req["execute"]?.stringValue {
            case "qmp_capabilities": return [FakeQMPServer.ok(req)]
            case "slow": Thread.sleep(forTimeInterval: 0.3); return [FakeQMPServer.ok(req, "slow-result")]
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
        let (s, f) = try await (slow, fast)
        XCTAssertEqual(s, "slow-result")
        XCTAssertEqual(f, "fast-result")
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
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
