import XCTest
@testable import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class AgentClientTests: XCTestCase {
    func testHandshakeTokenAndCommands() async throws {
        let agent = FakeAgent().start()
        defer { agent.stop() }
        agent.handler = { m, _ in
            switch m["t"]?.stringValue {
            case "exec": return [["t": "exec.result", "code": 0, "out": .string("ran: " + (m["cmd"]?.stringValue ?? ""))]]
            case "file.end": return [["t": "file.done", "id": m["id"] ?? .null, "path": "C:\\Users\\alcove\\Desktop\\x.bin"]]
            case "clipboard.get": return [["t": "clipboard.text", "text": "guest text"]]
            case "ping": return [["t": "pong"]]
            default: return []
            }
        }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: "tok")
        let hello = await client.hello
        XCTAssertEqual(hello?.os, "windows"); XCTAssertEqual(hello?.capabilities, ["clipboard", "files", "exec"])
        let (code, out) = try await client.exec("dir")
        XCTAssertEqual(code, 0); XCTAssertEqual(out, "ran: dir")
        try await client.setClipboard(text: "hi")
        let clip = try await client.getClipboard()
        XCTAssertEqual(clip, "guest text")
        await client.setResolution(width: 1024, height: 768)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("x.bin")
        let payload = Data((0..<600_000).map { UInt8($0 % 251) })
        try payload.write(to: tmp)
        let path = try await client.pushFile(tmp, to: .desktop)
        XCTAssertTrue(path.hasSuffix("x.bin"))

        try await Task.sleep(for: .milliseconds(200))
        let types = agent.received.compactMap { $0["t"]?.stringValue }
        XCTAssertEqual(types.first, "welcome")
        XCTAssertTrue(types.contains("clipboard.set")); XCTAssertTrue(types.contains("resolution.set"))
        XCTAssertEqual(types.filter { $0 == "file.chunk" }.count, 3)   // 600000 / 262144 -> 3 chunks
        let end = agent.received.first { $0["t"]?.stringValue == "file.end" }
        XCTAssertEqual(end?["sha256"]?.stringValue?.count, 64)
        let begin = agent.received.first { $0["t"]?.stringValue == "file.begin" }
        XCTAssertEqual(begin?["size"]?.intValue, 600_000); XCTAssertEqual(begin?["dest"]?.stringValue, "desktop")
    }

    func testTokenMismatchIsRejected() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.token = "other"
        let client = AgentClient()
        do { try await client.connect(port: agent.port, expectedToken: "tok"); XCTFail("expected mismatch") }
        catch AgentClient.AgentError.tokenMismatch {}
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }

    func testEventsAndDisconnect() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        agent.sendLine(["t": "clipboard.changed", "text": "from guest"])
        agent.sendLine(["t": "resolution", "w": 800, "h": 600])
        var it = client.events.makeAsyncIterator()
        let e1 = await it.next(); XCTAssertEqual(e1, .clipboardChanged(text: "from guest"))
        let e2 = await it.next(); XCTAssertEqual(e2, .resolution(width: 800, height: 600))
        let pending = Task { try await client.exec("hang", timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        agent.drop()
        do { _ = try await pending.value; XCTFail("expected disconnect") } catch AgentClient.AgentError.disconnected {}
        let e3 = await it.next(); XCTAssertEqual(e3, .disconnected)
    }

    func testConnectRefusedAndTimeout() async throws {
        let client = AgentClient()
        do { try await client.connect(port: 1, expectedToken: nil); XCTFail("expected connect error") }
        catch AgentClient.AgentError.connect {}
    }

    func testCallRoundTrip() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.handler = { m, _ in m["t"]?.stringValue == "req" ? [["t": "res", "id": m["id"] ?? .null, "ok": true, "pong": true]] : [] }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        let r = try await client.call("ping")
        XCTAssertEqual(r["pong"]?.boolValue, true)
        let req = agent.received.first { $0["t"]?.stringValue == "req" }
        XCTAssertNotNil(req?["id"]?.intValue)
        XCTAssertEqual(req?["op"]?.stringValue, "ping")
        let hello = await client.hello
        XCTAssertEqual(hello?.rpcVersion, 2)
    }

    func testCallsAreMatchedByID() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        let first = LockedBox<JSON?>(nil)
        agent.handler = { m, _ in
            guard m["t"]?.stringValue == "req" else { return [] }
            if let earlier = first.value {
                return [["t": "res", "id": m["id"] ?? .null, "ok": true, "who": m["op"] ?? .null],
                        ["t": "res", "id": earlier["id"] ?? .null, "ok": true, "who": earlier["op"] ?? .null]]
            }
            first.value = m
            return []
        }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        let a = Task { try await client.call("alpha") }
        while agent.receivedCount() < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let b = Task { try await client.call("beta") }
        let (ra, rb) = try await (a.value, b.value)
        XCTAssertEqual(ra["who"]?.stringValue, "alpha")
        XCTAssertEqual(rb["who"]?.stringValue, "beta")
    }

    func testCallRemoteError() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.handler = { m, _ in m["t"]?.stringValue == "req" ? [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": "boom"]] : [] }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        do { _ = try await client.call("ping"); XCTFail("expected remote error") }
        catch AgentClient.AgentError.remote(let text) { XCTAssertEqual(text, "boom") }
    }

    func testCallReturnsAReplyOfThreeMebibytes() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        let big = String(repeating: "x", count: 3 << 20)
        agent.handler = { m, _ in m["t"]?.stringValue == "req" ? [["t": "res", "id": m["id"] ?? .null, "ok": true, "out": .string(big)]] : [] }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        let r = try await client.call("exec.read")
        XCTAssertEqual(r["out"]?.stringValue?.utf8.count, 3 << 20)
    }

    func testSetClipboardRefusesTextTheAgentCannotRead() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.handler = { m, _ in m["t"]?.stringValue == "req" ? [["t": "res", "id": m["id"] ?? .null, "ok": true]] : [] }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        do {
            try await client.setClipboard(text: String(repeating: "x", count: 1 << 20))
            XCTFail("expected a refusal")
        } catch AgentClient.AgentError.remote(let text) {
            XCTAssertEqual(text, "clipboard text is too large for the guest agent (limit about 700 KB of UTF-8)")
        }
        _ = try await client.call("ping")
        XCTAssertFalse(agent.received.contains { $0["t"]?.stringValue == "clipboard.set" })
        try await client.setClipboard(text: String(repeating: "x", count: 700_000))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(agent.received.filter { $0["t"]?.stringValue == "clipboard.set" }.count, 1)
    }

    func testExecRefusesACommandTheAgentCannotRead() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.handler = { m, _ in
            switch m["t"]?.stringValue {
            case "exec": return [["t": "exec.result", "code": 0, "out": "ok"]]
            case "req": return [["t": "res", "id": m["id"] ?? .null, "ok": true]]
            default: return []
            }
        }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        do {
            _ = try await client.exec(String(repeating: "x", count: 1 << 20))
            XCTFail("expected a refusal")
        } catch AgentClient.AgentError.remote(let text) {
            XCTAssertEqual(text, "command is too long for this guest agent; write it to a file in the guest and run that")
        }
        _ = try await client.call("ping")
        XCTAssertFalse(agent.received.contains { $0["t"]?.stringValue == "exec" })
        let (code, out) = try await client.exec("echo hi")
        XCTAssertEqual(code, 0); XCTAssertEqual(out, "ok")
    }

    func testCallRefusesARequestLongerThanTheAgentReads() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.handler = { m, _ in m["t"]?.stringValue == "req" ? [["t": "res", "id": m["id"] ?? .null, "ok": true]] : [] }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        do {
            _ = try await client.call("exec.run", ["stdin": .string(String(repeating: "x", count: 1 << 20))])
            XCTFail("expected a refusal")
        } catch AgentClient.AgentError.remote(let text) {
            XCTAssertEqual(text, "request 'exec.run' is longer than 1 MiB, the most alcove-agent reads in one message; put large input in a guest file and pass its path")
        }
        _ = try await client.call("ping")
        XCTAssertEqual(agent.received.filter { $0["t"]?.stringValue == "req" }.compactMap { $0["op"]?.stringValue }, ["ping"])
        _ = try await client.call("exec.run", ["stdin": .string(String(repeating: "x", count: (1 << 20) - 200))])
        XCTAssertEqual(agent.received.filter { $0["t"]?.stringValue == "req" }.count, 2)
    }

    func testCallUnsupportedOnV1Agent() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.proto = nil
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        let hello = await client.hello
        XCTAssertEqual(hello?.rpcVersion, 1)
        do { _ = try await client.call("ping"); XCTFail("expected unsupported") }
        catch AgentClient.AgentError.unsupported(let op) { XCTAssertEqual(op, "ping") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(agent.received.contains { $0["t"]?.stringValue == "req" })
    }

    func testCallTimeout() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        do { _ = try await client.call("ping", timeout: .milliseconds(150)); XCTFail("expected timeout") }
        catch AgentClient.AgentError.timeout(let op) { XCTAssertEqual(op, "ping") }
        let req = agent.received.first { $0["t"]?.stringValue == "req" }
        agent.sendLine(["t": "res", "id": req?["id"] ?? .null, "ok": true])
        agent.handler = { m, _ in m["t"]?.stringValue == "req" ? [["t": "res", "id": m["id"] ?? .null, "ok": true, "n": 2]] : [] }
        let next = try await client.call("again")
        XCTAssertEqual(next["n"]?.intValue, 2)
    }

    func testDisconnectFailsPendingCalls() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        let pending = Task { try await client.call("ping", timeout: .seconds(10)) }
        while agent.receivedCount() < 2 { try await Task.sleep(for: .milliseconds(10)) }
        agent.drop()
        do { _ = try await pending.value; XCTFail("expected disconnect") } catch AgentClient.AgentError.disconnected {}
    }

    func testAgentEvent() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        agent.sendLine(["t": "ev", "name": "job.exited", "job": "j1", "code": 0])
        var it = client.events.makeAsyncIterator()
        let e = await it.next()
        guard case .agent(let name, let payload)? = e else { return XCTFail("expected agent event, got \(String(describing: e))") }
        XCTAssertEqual(name, "job.exited")
        XCTAssertEqual(payload["job"]?.stringValue, "j1")
        XCTAssertEqual(payload["code"]?.intValue, 0)
    }

    /// Polls `condition` every 10 ms for up to 20 s; returns whether it held.
    private func soon(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    func testEventStreamEndsWhenTheClientIsReleased() async throws {
        var client: AgentClient? = AgentClient()
        let stream = try XCTUnwrap(client).events
        client = nil
        let ended = LockedBox(false)
        Task {
            for await _ in stream {}
            ended.value = true
        }
        let finished = await soon { ended.value }
        XCTAssertTrue(finished)
    }

    func testEventStreamKeepsTheNewestEventsAndTheDisconnect() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.handler = { m, _ in m["op"]?.stringValue == "ping" ? [["t": "res", "id": m["id"] ?? .null, "ok": true, "pong": true]] : [] }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        let count = AgentClient.eventBacklog + 500
        for i in 0..<count { agent.sendLine(["t": "ev", "name": "tick", "i": .int(Int64(i))]) }
        let reply = try await client.call("ping", [:], timeout: .seconds(20))
        XCTAssertEqual(reply["pong"], true)
        agent.drop()
        let ended = await soon { await !client.isConnected }
        XCTAssertTrue(ended)

        var kept: [AgentClient.Event] = []
        var it = client.events.makeAsyncIterator()
        while kept.last != .disconnected, kept.count <= count, let event = await it.next() { kept.append(event) }
        XCTAssertEqual(kept.count, AgentClient.eventBacklog)
        XCTAssertEqual(kept.last, .disconnected)
        guard case .agent(_, let oldest)? = kept.first else { return XCTFail("\(String(describing: kept.first))") }
        XCTAssertEqual(oldest["i"]?.intValue, count - (AgentClient.eventBacklog - 1))
    }

    func testEventsArriveInWireOrder() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        let count = 400
        for i in 0..<count { agent.sendLine(["t": "ev", "name": "tick", "i": .int(Int64(i))]) }
        agent.drop()
        var it = client.events.makeAsyncIterator()
        var order: [Int] = []
        while order.count < count, case .agent(_, let payload)? = await it.next() { order.append(payload["i"]?.intValue ?? -1) }
        XCTAssertEqual(order, Array(0..<count))
    }
}
