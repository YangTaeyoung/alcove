import XCTest
@testable import AlcoveAgent
import AlcoveQMP

/// A scripted stand-in for the Go agent: TCP server sending hello and replying per handler.
final class FakeAgent: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32
    private var clientFD: Int32 = -1
    private let lock = NSLock()
    private(set) var received: [JSON] = []
    var token = "tok"
    var proto: Int? = 2
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
        var hello: JSON = ["t": "hello", "v": 1, "os": "windows", "agent": "0.1.0", "token": .string(token), "caps": ["clipboard", "files", "exec"]]
        if let proto, case .object(var o) = hello { o["proto"] = .int(Int64(proto)); hello = .object(o) }
        sendLine(hello)
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

    func receivedCount() -> Int { lock.lock(); defer { lock.unlock() }; return received.count }
    func drop() { lock.lock(); if clientFD >= 0 { Darwin.close(clientFD); clientFD = -1 }; lock.unlock() }
    func stop() { drop(); Darwin.close(listenFD) }
}

/// A value guarded by a lock, shared between test code and the fake agent thread.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// In-memory guest file system answering the `fs.*` requests of the agent contract.
final class FakeFS: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]
    private var writtenPaths: [String] = []
    var corruptWrites = false

    subscript(path: String) -> Data? {
        get { lock.lock(); defer { lock.unlock() }; return store[path] }
        set { lock.lock(); defer { lock.unlock() }; store[path] = newValue }
    }

    func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return store.keys.sorted() }
    func written() -> [String] { lock.lock(); defer { lock.unlock() }; return writtenPaths }

    func install(on agent: FakeAgent) {
        agent.handler = { [self] m, _ in
            guard m["t"]?.stringValue == "req" else { return [] }
            return [handle(m)]
        }
    }

    private static func separator(for path: String) -> String { path.contains("\\") ? "\\" : "/" }

    private func reply(_ m: JSON, _ fields: [String: JSON]) -> JSON {
        var o = fields; o["t"] = "res"; o["id"] = m["id"] ?? .null; o["ok"] = true
        return .object(o)
    }

    private func fail(_ m: JSON, _ text: String) -> JSON { ["t": "res", "id": m["id"] ?? .null, "ok": false, "error": .string(text)] }

    private func handle(_ m: JSON) -> JSON {
        lock.lock(); defer { lock.unlock() }
        let path = m["path"]?.stringValue ?? ""
        switch m["op"]?.stringValue {
        case "fs.stat":
            let sep = Self.separator(for: path)
            if let data = store[path] {
                var f: [String: JSON] = ["exists": true, "dir": false, "size": .int(Int64(data.count)), "path": .string(path)]
                if m["sha256"]?.boolValue == true { f["sha256"] = .string(SHA256Digest.hex(of: data)) }
                return reply(m, f)
            }
            if store.keys.contains(where: { $0.hasPrefix(path + sep) }) { return reply(m, ["exists": true, "dir": true, "size": 0, "path": .string(path)]) }
            return reply(m, ["exists": false])
        case "fs.list":
            let sep = Self.separator(for: path)
            let prefix = path + sep
            let found = store.filter { $0.key.hasPrefix(prefix) }
            if found.isEmpty { return fail(m, "'\(path)' does not exist") }
            let entries: [JSON] = found.keys.sorted().map { key in
                let name = String(key.dropFirst(prefix.count)).replacingOccurrences(of: sep, with: "/")
                let data = found[key]!
                return ["name": .string(name), "dir": false, "size": .int(Int64(data.count)), "mtime": "2026-01-01T00:00:00Z", "sha256": .string(SHA256Digest.hex(of: data))]
            }
            return reply(m, ["entries": .array(entries), "truncated": false])
        case "fs.read":
            guard let data = store[path] else { return fail(m, "'\(path)' does not exist") }
            let offset = min(m["offset"]?.intValue ?? 0, data.count)
            let end = min(offset + (m["length"]?.intValue ?? 262144), data.count)
            return reply(m, ["data": .string(data[offset..<end].base64EncodedString()), "size": .int(Int64(data.count)), "eof": .bool(end >= data.count)])
        case "fs.write":
            var piece = Data(base64Encoded: m["data"]?.stringValue ?? "") ?? Data()
            if corruptWrites, !piece.isEmpty { piece[piece.startIndex] ^= 0xFF }
            var data = m["truncate"]?.boolValue == true ? Data() : (store[path] ?? Data())
            let offset = m["offset"]?.intValue ?? 0
            if data.count < offset { data.append(Data(count: offset - data.count)) }
            data.replaceSubrange(offset..<min(offset + piece.count, data.count), with: piece)
            store[path] = data
            writtenPaths.append(path)
            return reply(m, ["size": .int(Int64(data.count))])
        case "fs.rename":
            let from = m["from"]?.stringValue ?? "", to = m["to"]?.stringValue ?? ""
            guard let data = store[from] else { return fail(m, "'\(from)' does not exist") }
            if store[to] != nil, m["overwrite"]?.boolValue != true { return fail(m, "'\(to)' exists; pass overwrite") }
            store[to] = data; store[from] = nil
            return reply(m, ["path": .string(to)])
        case "fs.delete":
            let existed = store.removeValue(forKey: path) != nil
            return reply(m, ["deleted": .bool(existed)])
        default:
            return fail(m, "unknown op '\(m["op"]?.stringValue ?? "")'; update alcove-agent")
        }
    }
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
}
