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
        let server = ControlServer(handler: ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory), socketPath: path)
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

    func testALineThatCannotBeParsedIsAnsweredWithTheIDItHolds() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        let handler = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory)
        func reply(_ line: String) async throws -> JSON {
            let data = await ControlServer.process(Data(line.utf8), handler: handler)
            XCTAssertEqual(data.last, 10)
            return try JSON.parse(data.dropLast())
        }
        let unreadable: JSON = .string(ControlServer.unreadableRequest)
        let cases: [(String, JSON)] = [
            (#"{"id": 7, "op": "vm.event_log", "name": "Win", "contains": "\ud83d"}"#, 7),
            (#"{"op": "hello", "x": "\udc00 tail", "id": "abc"}"#, "abc"),
            (#"{"nested": {"id": 1, "list": ["}", {"id": 2}]}, "text": "\"id\": 3", "id": 44, "x": }"#, 44),
            (#"{"id": 9, "op": "hello", "x": }"#, 9),
            (#" { "id" : 12.5 , "op": "hello" "#, 12.5),
            (#"{"op": "hello", "x": "\ud83d"}"#, .null),
            (#"{"x": }, "id": 5}"#, .null),
            (#"{"id": [5], "x": "\ud83d"}"#, .null),
            (#"{"id": true, "x": "\ud83d"}"#, .null),
            (#"{"id": "\ud83d"}"#, .null),
            ("not json at all", .null),
            (#"[{"id": 5}"#, .null),
            (#"{"op": "x", "a": nope, "id": 5, "#, .null),
            (#"{"a": tru, "id": 5, "x": }"#, .null),
            (#"{"a": 01, "id": 5, "x": }"#, .null),
            (#"{"a": 1 2, "id": 5, "x": }"#, .null),
            (#"{"a": [1, 2,], "id": 5, "x": }"#, .null),
            (#"{"a": {"b" 1}, "id": 5, "x": }"#, .null),
            (#"{"a": "\q", "id": 5, "x": }"#, .null),
            (#"{"a": "\u12", "id": 5, "x": }"#, .null),
            (#"{"\u0069d": 5, "x": }"#, .null),
            (#"{"a": [true, false, null, -1.5e3, 0, {"b": "\u00e9\n"}, []], "c": {}, "id": 6, "x": }"#, 6),
            (#"{"id": 8 }"#.replacingOccurrences(of: "}", with: "} \u{1}"), 8),
            (#"{"id": 5 6, "x": "\ud83d"}"#, .null),
            (#"{"id": "a" "b", "x": "\ud83d"}"#, .null),
            (#"{"id": 5"#, .null),
            (#"{"id": 5 x"#, .null),
        ]
        for (line, id) in cases {
            let r = try await reply(line)
            XCTAssertEqual(r, ["ok": false, "id": id, "error": unreadable], line)
        }
        let whole = try await reply(#"{"id": 3, "op": "hello"}"#)
        XCTAssertEqual(whole, ["ok": true, "id": 3, "version": 1, "host": "test"])
        let noObject = try await reply("[1, 2, 3]")
        XCTAssertEqual(noObject, ["ok": false, "id": .null, "error": "missing or invalid parameter 'op'"])
    }

    func testASocketPathLongerThanMacOSAllowsIsRefusedWithASentenceThatNamesTheLimit() throws {
        let handler = ControlHandler(registry: FakeRegistry(targets: [:]), hostKind: "test", captureDirectory: scratchCaptureDirectory)
        let base = "/tmp/alcove-ctl-\(UUID().uuidString.prefix(8))-"
        let longest = base + String(repeating: "x", count: 103 - base.utf8.count - 5) + ".sock"
        XCTAssertEqual(longest.utf8.count, 103)
        let accepted = ControlServer(handler: handler, socketPath: longest)
        XCTAssertNoThrow(try accepted.start())
        accepted.stop()
        let tooLong = base + String(repeating: "y", count: 104 - base.utf8.count - 5) + ".sock"
        let refused = ControlServer(handler: handler, socketPath: tooLong)
        XCTAssertThrowsError(try refused.start()) {
            XCTAssertEqual("\($0)", "the socket path \(tooLong) is 104 bytes long, and a unix socket path on macOS holds at most 103 bytes "
                           + "(104 with the closing NUL byte); choose a shorter path")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tooLong))
    }

    private func startServer(_ handler: ControlHandler, loadingRecognizers: Bool = false,
                             writeStallLimit: Duration = .seconds(30), maxOutboxBytes: Int = 64 << 20) throws -> (ControlServer, String) {
        let path = "/tmp/alcove-ctl-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(handler: handler, socketPath: path, writeStallLimit: writeStallLimit, maxOutboxBytes: maxOutboxBytes)
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
        let handler = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory)
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
        let handler = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory)
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
        let handler = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory)
        await recognitionsEnded()
        _ = try startServer(handler, loadingRecognizers: true)
        let find = Task { try await handler.handle(op: "vm.find_text", params: ["name": "Win", "languages": ["en-US"]]) }
        let queued = await eventually { RecognitionQueue.shared.load.waiting == 1 }
        XCTAssertTrue(queued)
        let warming = await eventually { widths.value == [400] }
        XCTAssertTrue(warming, "\(widths.value)")
        gate.open()
        let found = try await find.value
        XCTAssertEqual(found["lines"]?.intValue, 0)
        XCTAssertEqual(widths.value, [400, 400, 320])
    }

    func testTheWarmUpFrameHoldsTextForBothRecognizers() throws {
        let frame = ScreenText.warmUpFrame()
        XCTAssertEqual([frame.width, frame.height], [400, 64])
        let latin = try recognizedLines(frame, languages: ScreenText.latinLanguages)
        XCTAssertTrue(latin.contains { $0.text.contains("Alcove") }, "\(latin)")
        guard try ScreenText.supportedLanguages.get().contains("ko-KR") else { throw XCTSkip("ko-KR is not a supported recognition language on this host") }
        let standard = try recognizedLines(frame, languages: ScreenText.defaultLanguages)
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
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
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

    /// A fake agent that answers no `exec.run` request until the test sends the reply; the held requests by command.
    private func holdingExecAgent() -> (FakeAgent, LockedBox<[String: JSON]>) {
        let held = LockedBox<[String: JSON]>([:])
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "exec.run", let command = m["cmd"]?.stringValue else { return [] }
            held.value[command] = m
            return []
        }
        return (agent, held)
    }

    func testConcurrentOpDoesNotBlockSerialLane() async throws {
        let (agent, held) = holdingExecAgent()
        let (handler, _) = try await handlerWithAgent(agent, in: self)
        let (_, path) = try startServer(handler)
        let fd = connectClient(path)
        defer { close(fd) }

        send("{\"id\":1,\"op\":\"vm.exec\",\"name\":\"Win\",\"command\":\"slow\"}\n{\"id\":2,\"op\":\"vm.status\",\"name\":\"Win\"}\n", on: fd)
        guard await eventually("the guest gets the command", { held.value["slow"] != nil }) else { return }
        let first = readReply(fd)
        XCTAssertEqual(first["id"]?.intValue, 2)
        XCTAssertEqual(first["state"]?.stringValue, "running")
        agent.sendLine(agentReply(try XCTUnwrap(held.value["slow"]), ["code": 0, "stdout": "done", "stderr": ""]))
        let second = readReply(fd)
        XCTAssertEqual(second["id"]?.intValue, 1)
        XCTAssertEqual(second["ok"]?.boolValue, true)
        XCTAssertEqual(second["output"]?.stringValue, "done")
    }

    func testConcurrentOpsAnswerInCompletionOrder() async throws {
        let (agent, held) = holdingExecAgent()
        let (handler, _) = try await handlerWithAgent(agent, in: self)
        let (_, path) = try startServer(handler)
        let fd = connectClient(path)
        defer { close(fd) }

        send("{\"id\":1,\"op\":\"vm.exec\",\"name\":\"Win\",\"command\":\"slow\"}\n{\"id\":2,\"op\":\"vm.exec\",\"name\":\"Win\",\"command\":\"quick\"}\n", on: fd)
        guard await eventually("the guest gets both commands", { held.value.count == 2 }) else { return }
        agent.sendLine(agentReply(try XCTUnwrap(held.value["quick"]), ["code": 0, "stdout": "quick", "stderr": ""]))
        let first = readReply(fd)
        XCTAssertEqual(first["id"]?.intValue, 2); XCTAssertEqual(first["output"]?.stringValue, "quick")
        agent.sendLine(agentReply(try XCTUnwrap(held.value["slow"]), ["code": 0, "stdout": "slow", "stderr": ""]))
        let second = readReply(fd)
        XCTAssertEqual(second["id"]?.intValue, 1); XCTAssertEqual(second["output"]?.stringValue, "slow")
    }

    func testSerialLaneKeepsOrder() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        let (_, path) = try startServer(ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory))
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
        let (server, path) = try startServer(ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory))
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

    func testClosingTheConnectionCancelsEveryQueuedSerialOp() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        await t.setAgentWait(.seconds(20))
        let (server, path) = try startServer(ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory))
        let fd = connectClient(path)

        send("{\"id\":1,\"op\":\"vm.clipboard.get\",\"name\":\"Win\"}\n{\"id\":2,\"op\":\"vm.clipboard.get\",\"name\":\"Win\"}\n{\"id\":3,\"op\":\"vm.status\",\"name\":\"Win\"}\n", on: fd)
        guard await eventually("the first request waits for the agent", { await t.agentWaits == 1 }) else { return }
        XCTAssertEqual(server.serialTaskCount(), 3)
        close(fd)
        guard await eventually("the first request is cancelled", { await t.cancelledAgentWaits == 1 }) else { return }
        guard await eventually("the serial tasks are forgotten", { server.serialTaskCount() == 0 }) else { return }
        let waits = await t.agentWaits
        XCTAssertEqual(waits, 1)
        let statusCalls = await t.agentTimeouts.count
        XCTAssertEqual(statusCalls, 1)
    }

    func testFinishedSerialOpsAreForgotten() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        let (server, path) = try startServer(ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory))
        let fd = connectClient(path)
        defer { close(fd) }
        send("{\"id\":1,\"op\":\"hello\"}\n{\"id\":2,\"op\":\"hello\"}\n", on: fd)
        XCTAssertEqual(readReply(fd)["id"]?.intValue, 1)
        XCTAssertEqual(readReply(fd)["id"]?.intValue, 2)
        _ = await eventually("the serial tasks are forgotten") { server.serialTaskCount() == 0 }
    }

    /// A handler over a running VM "Win" whose screenshots are a 1000x1000 frame of noise, several MB of PNG.
    private func noisyHandler() async -> ControlHandler {
        var pixels = Data(count: 1000 * 1000 * 4)
        pixels.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 8, height: 8))
        await t.setFrames([Frame(width: 1000, height: 1000, pixels: pixels)])
        return ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory)
    }

    func testAClientThatDoesNotReadDoesNotHoldBackOtherClients() async throws {
        let (server, path) = try startServer(await noisyHandler())
        let stalled = connectClient(path)
        defer { close(stalled) }
        send("{\"id\":1,\"op\":\"vm.screenshot\",\"name\":\"Win\"}\n", on: stalled)
        guard await eventually("the screenshot reply waits to be read", { server.outboxByteCount() > 0 }) else { return }

        let other = connectClient(path)
        defer { close(other) }
        send("{\"id\":7,\"op\":\"hello\"}\n", on: other)
        let reply = readReply(other)
        XCTAssertEqual(reply["id"]?.intValue, 7)
        XCTAssertEqual(reply["host"]?.stringValue, "test")
        XCTAssertEqual(server.connectionCount(), 2)

        var total = 0
        var b = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(stalled, &b, b.count)
            if n <= 0 { break }
            total += n
            if b[n - 1] == 10 { break }
        }
        XCTAssertGreaterThan(total, 1_000_000)
        XCTAssertEqual(server.outboxByteCount(), 0)
    }

    func testAClientWithoutWriteProgressIsClosed() async throws {
        let (server, path) = try startServer(await noisyHandler(), writeStallLimit: .milliseconds(300))
        let stalled = connectClient(path)
        defer { close(stalled) }
        send("{\"id\":1,\"op\":\"vm.screenshot\",\"name\":\"Win\"}\n", on: stalled)
        guard await eventually("the screenshot reply waits to be read", { server.outboxByteCount() > 0 }) else { return }
        _ = await eventually("the client is closed") { server.connectionCount() == 0 }
        XCTAssertEqual(server.outboxByteCount(), 0)
    }

    func testAClientWhoseUnreadRepliesPassTheOutboxLimitIsClosed() async throws {
        let (server, path) = try startServer(await noisyHandler(), maxOutboxBytes: 8 << 20)
        let stalled = connectClient(path)
        defer { close(stalled) }
        for id in 1...3 { send("{\"id\":\(id),\"op\":\"vm.screenshot\",\"name\":\"Win\"}\n", on: stalled) }
        _ = await eventually("the client is closed") { server.connectionCount() == 0 }
        XCTAssertEqual(server.outboxByteCount(), 0)
    }

    func testAReplyLargerThanTheOutboxLimitIsAnsweredWithASentence() async throws {
        let (server, path) = try startServer(await noisyHandler(), maxOutboxBytes: 1 << 20)
        let fd = connectClient(path)
        defer { close(fd) }
        send("{\"id\":1,\"op\":\"vm.screenshot\",\"name\":\"Win\"}\n", on: fd)
        let reply = readReply(fd)
        XCTAssertEqual(reply["id"]?.intValue, 1)
        XCTAssertEqual(reply["ok"]?.boolValue, false)
        let error = reply["error"]?.stringValue ?? ""
        XCTAssertTrue(error.hasPrefix("the reply to vm.screenshot holds "), error)
        XCTAssertTrue(error.hasSuffix(" bytes, more than the 1048576 bytes one reply may hold; ask for less, such as a vm.screenshot with maxWidth, scale or region"), error)
        send("{\"id\":2,\"op\":\"hello\"}\n", on: fd)
        XCTAssertEqual(readReply(fd)["id"]?.intValue, 2)
        XCTAssertEqual(server.connectionCount(), 1)
    }

    func testFinishedConcurrentOpsAreForgotten() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        let (server, path) = try startServer(ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory))
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
