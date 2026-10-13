import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class ControlServerTests: XCTestCase {
    override func setUp() async throws {
        await recognitionsEnded()
    }

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

    private func startServer(_ handler: ControlHandler, loadingRecognizers: Bool = false) throws -> (ControlServer, String) {
        let path = "/tmp/alcove-ctl-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(handler: handler, socketPath: path)
        try server.start(loadingRecognizers: loadingRecognizers)
        addTeardownBlock { server.stop() }
        return (server, path)
    }

    // MARK: - loading the recognizers

    /// The size of the frame and the languages of one recognizer call.
    private struct Recognition: Equatable {
        let width: Int, height: Int
        let languages: [String]
    }

    /// Replaces the recognizer by one that records its calls and reads nothing, until the test ends.
    private func recordingRecognizer() -> LockedBox<[Recognition]> {
        let seen = LockedBox<[Recognition]>([])
        WaitTiming.recognizer = { frame, languages in
            seen.value.append(Recognition(width: frame.width, height: frame.height, languages: languages))
            return []
        }
        addTeardownBlock { WaitTiming.recognizer = { try ScreenText.recognize($0, languages: $1) } }
        return seen
    }

    func testAServerStartedWithLoadingRecognizersReadsTheWarmUpFrameWithTheLanguagesOfFindText() async throws {
        let seen = recordingRecognizer()
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        let handler = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test")
        _ = try startServer(handler, loadingRecognizers: true)
        await recognitionsEnded()
        let warmUp = seen.value
        XCTAssertEqual(warmUp, [Recognition(width: 400, height: 64, languages: ["ko-KR", "en-US"]),
                                Recognition(width: 400, height: 64, languages: ["en-US"])])

        seen.value = []
        _ = try await handler.handle(op: "vm.find_text", params: ["name": "Win"])
        XCTAssertEqual(seen.value.map(\.languages), warmUp.map(\.languages))
    }

    func testCreatingAHandlerAndStartingAServerWithoutLoadingRecognizersReadsNothing() async throws {
        let seen = recordingRecognizer()
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        let handler = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test")
        await recognitionsEnded()
        _ = try startServer(handler)
        let load = RecognitionQueue.shared.load
        XCTAssertFalse(load.running)
        XCTAssertEqual(load.waiting, 0)
        await recognitionsEnded()
        XCTAssertEqual(seen.value, [])
    }

    func testAFindTextDuringTheWarmUpWaitsBehindIt() async throws {
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        let widths = LockedBox<[Int]>([])
        WaitTiming.recognizer = { frame, _ in
            widths.value.append(frame.width)
            gate.pass()
            return []
        }
        addTeardownBlock { WaitTiming.recognizer = { try ScreenText.recognize($0, languages: $1) } }
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        let handler = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test")
        await recognitionsEnded()
        _ = try startServer(handler, loadingRecognizers: true)
        let find = Task { try await handler.handle(op: "vm.find_text", params: ["name": "Win", "languages": ["en-US"]]) }
        let queued = await eventually { RecognitionQueue.shared.load.waiting == 1 }
        XCTAssertTrue(queued)
        XCTAssertEqual(widths.value, [400])
        gate.open()
        let found = try await find.value
        XCTAssertEqual(found["lines"]?.intValue, 0)
        XCTAssertEqual(widths.value, [400, 400, 320])
    }

    func testTheWarmUpFrameHoldsTextForBothRecognizers() throws {
        let frame = ScreenText.warmUpFrame()
        XCTAssertEqual([frame.width, frame.height], [400, 64])
        let latin = try ScreenText.recognize(frame, languages: ScreenText.latinLanguages)
        XCTAssertTrue(latin.contains { $0.text.contains("Alcove") }, "\(latin)")
        guard try ScreenText.supportedLanguages.get().contains("ko-KR") else { throw XCTSkip("ko-KR is not a supported recognition language on this host") }
        let standard = try ScreenText.recognize(frame, languages: ScreenText.defaultLanguages)
        XCTAssertTrue(standard.contains { $0.text.contains("한글") }, "\(standard)")
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

    /// The first connection sends `request` and closes while the fake agent holds the message selected by `holding`;
    /// a second connection is then served, the fake agent sends `answer`, and the second connection's next reply is its own.
    private func checkLateReplyIsDiscarded(request: String, holding: @escaping @Sendable (JSON) -> Bool, answer: @escaping @Sendable (JSON) -> JSON,
                                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let held = LockedBox<JSON?>(nil)
        let agent = FakeAgent()
        agent.handler = { m, _ in
            if holding(m) { held.value = m }
            return []
        }
        let (handler, _) = try await handlerWithAgent(agent, in: self)
        let (server, path) = try startServer(handler)
        let deadline = ContinuousClock.now + .seconds(5)

        let first = connectClient(path)
        send(request, on: first)
        while held.value == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        close(first)
        while server.connectionCount() > 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(server.connectionCount(), 0, file: file, line: line)

        let second = connectClient(path)
        defer { close(second) }
        send("{\"id\":100,\"op\":\"hello\"}\n", on: second)
        XCTAssertEqual(readReply(second)["id"]?.intValue, 100, file: file, line: line)

        guard let pending = held.value else { return XCTFail("the agent did not receive the request", file: file, line: line) }
        agent.sendLine(answer(pending))
        while server.discardedReplyCount() < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(server.discardedReplyCount(), 1, file: file, line: line)
        send("{\"id\":101,\"op\":\"hello\"}\n", on: second)
        let reply = readReply(second)
        XCTAssertEqual(reply["id"]?.intValue, 101, file: file, line: line)
        XCTAssertEqual(reply["host"]?.stringValue, "test", file: file, line: line)
    }

    func testLateConcurrentReplyIsNotWrittenToTheNextConnection() async throws {
        try await checkLateReplyIsDiscarded(
            request: "{\"id\":1,\"op\":\"vm.exec\",\"name\":\"Win\",\"command\":\"slow\"}\n",
            holding: { $0["op"]?.stringValue == "exec.run" },
            answer: { agentReply($0, ["code": 0, "stdout": "stale output of the first connection", "stderr": ""]) })
    }

    func testLateSerialReplyIsNotWrittenToTheNextConnection() async throws {
        try await checkLateReplyIsDiscarded(
            request: "{\"id\":1,\"op\":\"vm.clipboard.get\",\"name\":\"Win\"}\n",
            holding: { $0["t"]?.stringValue == "clipboard.get" },
            answer: { _ in ["t": "clipboard.text", "text": "stale clipboard of the first connection"] })
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
