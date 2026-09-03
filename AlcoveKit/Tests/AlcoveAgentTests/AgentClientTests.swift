import XCTest
@testable import AlcoveAgent
import AlcoveQMP

/// A scripted stand-in for the Go agent: TCP server sending hello and replying per handler.
private final class FakeAgent: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32
    private var clientFD: Int32 = -1
    private let lock = NSLock()
    private(set) var received: [JSON] = []
    var token = "tok"
    var handler: (@Sendable (JSON, FakeAgent) -> [JSON])?

    init() {
        let lfd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(lfd, $0, &len) } }
        listenFD = lfd
        port = Int(UInt16(bigEndian: addr.sin_port))
        Darwin.listen(lfd, 1)
    }

    func start() -> FakeAgent { Thread { [self] in serve() }.start(); return self }

    private func serve() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        lock.lock(); clientFD = fd; lock.unlock()
        sendLine(["t": "hello", "v": 1, "os": "windows", "agent": "0.1.0", "token": .string(token), "caps": ["clipboard", "files", "exec"]])
        var pending = Data(); var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 10) {
                let line = Data(pending[pending.startIndex..<nl]); pending.removeSubrange(pending.startIndex...nl)
                guard let m = try? JSON.parse(line) else { continue }
                lock.lock(); received.append(m); let h = handler; lock.unlock()
                for r in h?(m, self) ?? [] { sendLine(r) }
            }
        }
    }

    func sendLine(_ j: JSON) {
        lock.lock(); defer { lock.unlock() }
        guard clientFD >= 0, var d = try? j.serialized() else { return }
        d.append(10)
        _ = d.withUnsafeBytes { write(clientFD, $0.baseAddress, $0.count) }
    }

    func drop() { lock.lock(); if clientFD >= 0 { Darwin.close(clientFD); clientFD = -1 }; lock.unlock() }
    func stop() { drop(); Darwin.close(listenFD) }
}

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
        await client.setClipboard(text: "hi")
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
}
