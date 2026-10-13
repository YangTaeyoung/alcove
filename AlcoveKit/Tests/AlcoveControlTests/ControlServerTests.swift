import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class ControlServerTests: XCTestCase {
    func testRequestsOverTheSocket() async throws {
        let path = "/tmp/alcove-ctl-\(UUID().uuidString.prefix(8)).sock"
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        let server = ControlServer(handler: ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test"), socketPath: path)
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(ControlServer.isAlive(at: path))

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in _ = path.withCString { strncpy(dst, $0, 103) } } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(rc, 0)
        defer { close(fd) }

        func call(_ line: String) -> JSON {
            _ = line.withCString { write(fd, $0, strlen($0)) }
            var out = [UInt8](); var b: UInt8 = 0
            while read(fd, &b, 1) == 1 { if b == 10 { break }; out.append(b) }
            return try! JSON.parse(Data(out))
        }
        let hello = call("{\"id\":1,\"op\":\"hello\"}\n")
        XCTAssertEqual(hello["ok"]?.boolValue, true); XCTAssertEqual(hello["id"]?.intValue, 1); XCTAssertEqual(hello["version"]?.intValue, 1)
        // two requests in one write are answered in order
        _ = "{\"id\":2,\"op\":\"vm.status\",\"name\":\"Win\"}\n{\"id\":3,\"op\":\"vm.list\"}\n".withCString { write(fd, $0, strlen($0)) }
        func readReply() -> JSON { var out = [UInt8](); var b: UInt8 = 0; while read(fd, &b, 1) == 1 { if b == 10 { break }; out.append(b) }; return try! JSON.parse(Data(out)) }
        let r2 = readReply(), r3 = readReply()
        XCTAssertEqual(r2["id"]?.intValue, 2); XCTAssertEqual(r2["width"]?.intValue, 320)
        XCTAssertEqual(r3["id"]?.intValue, 3); XCTAssertEqual(r3["vms"]?[0]?["name"]?.stringValue, "Win")
        let bad = call("{\"id\":4,\"op\":\"vm.status\",\"name\":\"X\"}\n")
        XCTAssertEqual(bad["ok"]?.boolValue, false); XCTAssertTrue(bad["error"]!.stringValue!.contains("no VM named"))
        let garbage = call("not json\n")
        XCTAssertEqual(garbage["ok"]?.boolValue, false)
        let shot = call("{\"id\":5,\"op\":\"vm.screenshot\",\"name\":\"Win\"}\n")
        XCTAssertEqual(shot["sentWidth"]?.intValue, 320)
        XCTAssertGreaterThan(shot["png"]!.stringValue!.count, 100)
    }

    private func startServer(_ handler: ControlHandler) throws -> (ControlServer, String) {
        let path = "/tmp/alcove-ctl-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(handler: handler, socketPath: path)
        try server.start()
        addTeardownBlock { server.stop() }
        return (server, path)
    }

    /// A connected client socket whose reads give up after ten seconds.
    private func connectClient(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in _ = path.withCString { strncpy(dst, $0, 103) } } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(rc, 0)
        var limit = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func send(_ text: String, on fd: Int32) {
        _ = text.withCString { write(fd, $0, strlen($0)) }
    }

    private func readReply(_ fd: Int32) -> JSON {
        var out = [UInt8](); var b: UInt8 = 0
        while read(fd, &b, 1) == 1 { if b == 10 { break }; out.append(b) }
        return (try? JSON.parse(Data(out))) ?? .null
    }

    func testConcurrentOpDoesNotBlockSerialLane() async throws {
        let agent = FakeAgent()
        agent.handler = { m, a in
            guard m["op"]?.stringValue == "exec.run" else { return [] }
            let reply = agentReply(m, ["code": 0, "stdout": "done", "stderr": ""])
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { a.sendLine(reply) }
            return []
        }
        let (handler, _) = try await handlerWithAgent(agent, in: self)
        let (_, path) = try startServer(handler)
        let fd = connectClient(path)
        defer { close(fd) }

        send("{\"id\":1,\"op\":\"vm.exec\",\"name\":\"Win\",\"command\":\"slow\"}\n{\"id\":2,\"op\":\"vm.status\",\"name\":\"Win\"}\n", on: fd)
        let first = readReply(fd), second = readReply(fd)
        XCTAssertEqual(first["id"]?.intValue, 2)
        XCTAssertEqual(first["state"]?.stringValue, "running")
        XCTAssertEqual(second["id"]?.intValue, 1)
        XCTAssertEqual(second["ok"]?.boolValue, true)
        XCTAssertEqual(second["output"]?.stringValue, "done")
    }

    func testConcurrentOpsAnswerInCompletionOrder() async throws {
        let agent = FakeAgent()
        agent.handler = { m, a in
            guard m["op"]?.stringValue == "exec.run" else { return [] }
            let reply = agentReply(m, ["code": 0, "stdout": m["cmd"] ?? .null, "stderr": ""])
            let delay = m["cmd"]?.stringValue == "slow" ? 0.6 : 0.1
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { a.sendLine(reply) }
            return []
        }
        let (handler, _) = try await handlerWithAgent(agent, in: self)
        let (_, path) = try startServer(handler)
        let fd = connectClient(path)
        defer { close(fd) }

        send("{\"id\":1,\"op\":\"vm.exec\",\"name\":\"Win\",\"command\":\"slow\"}\n{\"id\":2,\"op\":\"vm.exec\",\"name\":\"Win\",\"command\":\"quick\"}\n", on: fd)
        let first = readReply(fd), second = readReply(fd)
        XCTAssertEqual(first["id"]?.intValue, 2); XCTAssertEqual(first["output"]?.stringValue, "quick")
        XCTAssertEqual(second["id"]?.intValue, 1); XCTAssertEqual(second["output"]?.stringValue, "slow")
    }

    func testSerialLaneKeepsOrder() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        let (_, path) = try startServer(ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test"))
        let fd = connectClient(path)
        defer { close(fd) }

        send("{\"id\":1,\"op\":\"vm.mouse.click\",\"name\":\"Win\",\"x\":1,\"y\":1,\"hold\":400}\n{\"id\":2,\"op\":\"vm.status\",\"name\":\"Win\"}\n", on: fd)
        let first = readReply(fd), second = readReply(fd)
        XCTAssertEqual(first["id"]?.intValue, 1); XCTAssertEqual(first["ok"]?.boolValue, true)
        XCTAssertEqual(second["id"]?.intValue, 2); XCTAssertEqual(second["state"]?.stringValue, "running")
        let sent = await t.sent
        XCTAssertEqual(sent.last, .sync)
    }

    func testClosingTheConnectionCancelsConcurrentOps() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        await t.setAgentWait(.seconds(20))
        let (server, path) = try startServer(ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test"))
        let fd = connectClient(path)

        send("{\"id\":1,\"op\":\"vm.exec.list\",\"name\":\"Win\"}\n{\"id\":2,\"op\":\"vm.fs.list\",\"name\":\"Win\",\"path\":\"/\"}\n", on: fd)
        let deadline = ContinuousClock.now + .seconds(5)
        while await t.agentWaits < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(server.concurrentTaskCount(), 2)
        close(fd)
        while await t.cancelledAgentWaits < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let cancelled = await t.cancelledAgentWaits
        XCTAssertEqual(cancelled, 2)
        XCTAssertEqual(server.concurrentTaskCount(), 0)
    }

    func testFinishedConcurrentOpsAreForgotten() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        let (server, path) = try startServer(ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test"))
        let fd = connectClient(path)
        defer { close(fd) }

        send("{\"id\":1,\"op\":\"vm.exec.list\",\"name\":\"Win\"}\n", on: fd)
        let reply = readReply(fd)
        XCTAssertEqual(reply["id"]?.intValue, 1); XCTAssertEqual(reply["ok"]?.boolValue, false)
        let deadline = ContinuousClock.now + .seconds(5)
        while server.concurrentTaskCount() > 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(server.concurrentTaskCount(), 0)
    }
}
