import XCTest
import CryptoKit
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

/// A successful `res` for request `m` carrying `fields`.
func agentReply(_ m: JSON, _ fields: [String: JSON] = [:]) -> JSON {
    var o = fields
    o["t"] = "res"; o["id"] = m["id"] ?? .null; o["ok"] = true
    return .object(o)
}

/// The `req` messages with operation `op` that `agent` received, in arrival order.
func agentRequests(_ agent: FakeAgent, _ op: String) -> [JSON] {
    agent.received.filter { $0["t"]?.stringValue == "req" && $0["op"]?.stringValue == op }
}

/// A handler over a running VM "Win" whose agent is an `AgentClient` connected to `agent`.
/// The teardown of `test` disconnects the client and then stops `agent`.
func handlerWithAgent(_ agent: FakeAgent, in test: XCTestCase) async throws -> (ControlHandler, FakeTarget) {
    _ = agent.start()
    let client = AgentClient()
    test.addTeardownBlock {
        await client.disconnect()
        agent.stop()
    }
    try await client.connect(port: agent.port, expectedToken: nil)
    let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 800, height: 600))
    await t.setAgent(client)
    return (ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test"), t)
}

final class ControlShellFilesTests: XCTestCase {
    private func setup(proto: Int? = 2, _ handler: (@Sendable (JSON, FakeAgent) -> [JSON])? = nil) async throws -> (ControlHandler, FakeAgent) {
        let agent = FakeAgent()
        agent.proto = proto
        agent.handler = handler
        let (h, _) = try await handlerWithAgent(agent, in: self)
        return (h, agent)
    }

    private func setup(fs: FakeFS) async throws -> (ControlHandler, FakeAgent) {
        let agent = FakeAgent()
        fs.install(on: agent)
        let (h, _) = try await handlerWithAgent(agent, in: self)
        return (h, agent)
    }

    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("control-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func failure(_ h: ControlHandler, _ op: String, _ params: JSON, file: StaticString = #filePath, line: UInt = #line) async -> String {
        do { _ = try await h.handle(op: op, params: params); XCTFail("\(op) succeeded", file: file, line: line); return "" }
        catch let e as ControlHandler.ControlError { return e.description }
        catch { XCTFail("\(op) threw \(error)", file: file, line: line); return "" }
    }

    // MARK: - exec

    func testExecMapsParamsAndResult() async throws {
        let (h, agent) = try await setup { m, _ in
            guard m["op"]?.stringValue == "exec.run" else { return [] }
            return [agentReply(m, ["code": 3, "stdout": "out\n", "stderr": "err\n", "timed_out": true, "truncated": true])]
        }
        let r = try await h.handle(op: "vm.exec", params: [
            "name": "Win", "command": "dir", "timeout": 7, "cwd": "C:\\x", "env": ["A": "1"], "stdin": "in", "shell": "cmd",
        ])
        XCTAssertEqual(r, ["code": 3, "output": "out\nerr\n", "stdout": "out\n", "stderr": "err\n", "timedOut": true, "truncated": true])
        let req = agentRequests(agent, "exec.run").first
        XCTAssertEqual(req?["cmd"]?.stringValue, "dir")
        XCTAssertEqual(req?["cwd"]?.stringValue, "C:\\x")
        XCTAssertEqual(req?["env"], ["A": "1"])
        XCTAssertEqual(req?["stdin"]?.stringValue, "in")
        XCTAssertEqual(req?["shell"]?.stringValue, "cmd")
        XCTAssertEqual(req?["timeout_ms"]?.intValue, 7000)
        for key in ["command", "timeout", "name", "argv"] { XCTAssertNil(req?[key], key) }

        _ = try await h.handle(op: "vm.exec", params: ["name": "Win", "argv": ["whoami", "/all"], "shell": "none"])
        let second = agentRequests(agent, "exec.run").last
        XCTAssertEqual(second?["argv"], ["whoami", "/all"])
        XCTAssertNil(second?["cmd"])
        XCTAssertEqual(second?["timeout_ms"]?.intValue, 120_000)

        let text = await failure(h, "vm.exec", ["name": "Win"])
        XCTAssertTrue(text.contains("'command'") && text.contains("'argv'"), text)
        XCTAssertEqual(agentRequests(agent, "exec.run").count, 2)
    }

    func testExecWaitsLongerThanTheCommandTimeout() async throws {
        let (h, _) = try await setup { m, a in
            guard m["op"]?.stringValue == "exec.run" else { return [] }
            let reply = agentReply(m, ["code": -1, "stdout": "", "stderr": "", "timed_out": true, "truncated": false])
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { a.sendLine(reply) }
            return []
        }
        let r = try await h.handle(op: "vm.exec", params: ["name": "Win", "command": "sleep 60", "timeout": 1])
        XCTAssertEqual(r["timedOut"]?.boolValue, true)
        XCTAssertEqual(r["code"]?.intValue, -1)
    }

    func testExecFallsBackToV1() async throws {
        let (h, agent) = try await setup(proto: nil) { m, _ in
            m["t"]?.stringValue == "exec" ? [["t": "exec.result", "code": 5, "out": .string("ran: " + (m["cmd"]?.stringValue ?? ""))]] : []
        }
        let r = try await h.handle(op: "vm.exec", params: ["name": "Win", "command": "hostname", "timeout": 5])
        XCTAssertEqual(r, ["code": 5, "output": "ran: hostname"])

        for extra in ["cwd", "stdin", "shell"] {
            let text = await failure(h, "vm.exec", .object(["name": "Win", "command": "hostname", extra: "x"]))
            XCTAssertEqual(text, "guest tools in 'Win' are too old for vm.exec; update alcove-agent in the guest", extra)
        }
        let withEnv = await failure(h, "vm.exec", ["name": "Win", "command": "hostname", "env": ["A": "1"]])
        XCTAssertEqual(withEnv, "guest tools in 'Win' are too old for vm.exec; update alcove-agent in the guest")
        let withArgv = await failure(h, "vm.exec", ["name": "Win", "argv": ["hostname"]])
        XCTAssertEqual(withArgv, "guest tools in 'Win' are too old for vm.exec; update alcove-agent in the guest")

        XCTAssertEqual(agent.received.filter { $0["t"]?.stringValue == "exec" }.count, 1)
        XCTAssertFalse(agent.received.contains { $0["t"]?.stringValue == "req" })
    }

    func testExecStartReadWriteKillList() async throws {
        let jobs: JSON = [["job": "j1", "pid": 42, "state": "exited", "code": 0, "cmd": "ping", "started": "2026-01-01T00:00:00Z"]]
        let (h, agent) = try await setup { m, _ in
            switch m["op"]?.stringValue {
            case "exec.start": return [agentReply(m, ["job": "j1", "pid": 42])]
            case "exec.read": return [agentReply(m, ["state": "exited", "code": 0, "pid": 42, "out": "a", "err": "b", "out_next": 6, "err_next": 7, "dropped": false])]
            case "exec.write": return [agentReply(m)]
            case "exec.kill": return [agentReply(m, ["state": "exited"])]
            case "exec.list": return [agentReply(m, ["jobs": jobs])]
            default: return []
            }
        }
        let started = try await h.handle(op: "vm.exec.start", params: ["name": "Win", "command": "ping -t host", "cwd": "C:\\x", "env": ["A": "1"], "shell": "cmd"])
        XCTAssertEqual(started, ["job": "j1", "pid": 42])
        let start = agentRequests(agent, "exec.start").first
        XCTAssertEqual(start?["cmd"]?.stringValue, "ping -t host")
        XCTAssertEqual(start?["cwd"]?.stringValue, "C:\\x")
        XCTAssertEqual(start?["env"], ["A": "1"])
        XCTAssertEqual(start?["shell"]?.stringValue, "cmd")
        XCTAssertNil(start?["timeout_ms"])

        let read = try await h.handle(op: "vm.exec.read", params: ["name": "Win", "job": "j1", "outOffset": 5, "errOffset": 6, "max": 100])
        XCTAssertEqual(read, ["state": "exited", "code": 0, "pid": 42, "out": "a", "err": "b", "outNext": 6, "errNext": 7, "dropped": false])
        let readReq = agentRequests(agent, "exec.read").first
        XCTAssertEqual(readReq?["job"]?.stringValue, "j1")
        XCTAssertEqual(readReq?["out_offset"]?.intValue, 5)
        XCTAssertEqual(readReq?["err_offset"]?.intValue, 6)
        XCTAssertEqual(readReq?["max"]?.intValue, 100)
        XCTAssertNil(readReq?["outOffset"]); XCTAssertNil(readReq?["errOffset"])

        let written = try await h.handle(op: "vm.exec.write", params: ["name": "Win", "job": "j1", "data": "x\n", "eof": true])
        XCTAssertEqual(written, [:])
        let writeReq = agentRequests(agent, "exec.write").first
        XCTAssertEqual(writeReq?["job"]?.stringValue, "j1")
        XCTAssertEqual(writeReq?["data"]?.stringValue, "x\n")
        XCTAssertEqual(writeReq?["eof"]?.boolValue, true)

        let killed = try await h.handle(op: "vm.exec.kill", params: ["name": "Win", "job": "j1"])
        XCTAssertEqual(killed, ["state": "exited"])
        XCTAssertEqual(agentRequests(agent, "exec.kill").first?["job"]?.stringValue, "j1")

        let list = try await h.handle(op: "vm.exec.list", params: ["name": "Win"])
        XCTAssertEqual(list, ["jobs": jobs])

        for op in ["vm.exec.read", "vm.exec.write", "vm.exec.kill"] {
            let text = await failure(h, op, ["name": "Win", "data": "x"])
            XCTAssertTrue(text.contains("'job'"), "\(op): \(text)")
        }
    }

    // MARK: - processes

    func testProcessListMapsNames() async throws {
        let (h, agent) = try await setup { m, _ in
            guard m["op"]?.stringValue == "proc.list" else { return [] }
            return [agentReply(m, ["procs": [["pid": 10, "ppid": 1, "name": "notepad.exe", "path": "C:\\Windows\\notepad.exe", "cmd": "notepad a.txt", "mem_kb": 2048]]])]
        }
        let r = try await h.handle(op: "vm.process.list", params: ["name": "Win", "filter": "note"])
        XCTAssertEqual(r, ["processes": [["pid": 10, "ppid": 1, "name": "notepad.exe", "path": "C:\\Windows\\notepad.exe", "command": "notepad a.txt", "memoryKB": 2048]]])
        let req = agentRequests(agent, "proc.list").first
        XCTAssertEqual(req?["name"]?.stringValue, "note")
        XCTAssertNil(req?["filter"])

        _ = try await h.handle(op: "vm.process.list", params: ["name": "Win"])
        XCTAssertNil(agentRequests(agent, "proc.list").last?["name"])
    }

    func testProcessKillNeedsPidOrName() async throws {
        let (h, agent) = try await setup { m, _ in
            m["op"]?.stringValue == "proc.kill" ? [agentReply(m, ["killed": 2])] : []
        }
        let text = await failure(h, "vm.process.kill", ["name": "Win", "tree": true])
        XCTAssertTrue(text.contains("'pid'") && text.contains("'processName'"), text)
        XCTAssertTrue(agentRequests(agent, "proc.kill").isEmpty)

        let byName = try await h.handle(op: "vm.process.kill", params: ["name": "Win", "processName": "notepad", "tree": true])
        XCTAssertEqual(byName, ["killed": 2])
        let nameReq = agentRequests(agent, "proc.kill").last
        XCTAssertEqual(nameReq?["name"]?.stringValue, "notepad")
        XCTAssertEqual(nameReq?["tree"]?.boolValue, true)
        XCTAssertNil(nameReq?["pid"]); XCTAssertNil(nameReq?["processName"])

        _ = try await h.handle(op: "vm.process.kill", params: ["name": "Win", "pid": 7])
        let pidReq = agentRequests(agent, "proc.kill").last
        XCTAssertEqual(pidReq?["pid"]?.intValue, 7)
        XCTAssertNil(pidReq?["name"])
    }

    // MARK: - file transfer

    func testPushFileWithGuestPath() async throws {
        let fs = FakeFS()
        let (h, agent) = try await setup(fs: fs)
        let local = try tempDir().appendingPathComponent("blob.bin")
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        try payload.write(to: local)

        let r = try await h.handle(op: "vm.push_file", params: ["name": "Win", "path": .string(local.path), "guestPath": "/data/in/blob.bin"])
        XCTAssertEqual(r, ["guestPath": "/data/in/blob.bin", "bytes": 300_000, "sha256": .string(sha256(payload))])
        XCTAssertEqual(fs["/data/in/blob.bin"], payload)

        let refused = await failure(h, "vm.push_file", ["name": "Win", "path": .string(local.path), "guestPath": "/data/in/blob.bin"])
        XCTAssertEqual(refused, "'/data/in/blob.bin' exists in the guest; pass overwrite")

        let replacement = Data("replacement".utf8)
        try replacement.write(to: local)
        _ = try await h.handle(op: "vm.push_file", params: ["name": "Win", "path": .string(local.path), "guestPath": "/data/in/blob.bin", "overwrite": true])
        XCTAssertEqual(fs["/data/in/blob.bin"], replacement)

        let missing = await failure(h, "vm.push_file", ["name": "Win", "path": .string(local.path + ".absent"), "guestPath": "/data/in/x.bin"])
        XCTAssertTrue(missing.contains(local.path + ".absent") && missing.contains("host"), missing)
        XCTAssertFalse(agent.received.contains { $0["t"]?.stringValue == "file.begin" })
    }

    func testPushFileWithDestUsesTheFolderTransfer() async throws {
        let (h, agent) = try await setup { m, _ in
            m["t"]?.stringValue == "file.end" ? [["t": "file.done", "id": m["id"] ?? .null, "path": "C:\\Users\\alcove\\Downloads\\note.txt"]] : []
        }
        let local = try tempDir().appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: local)
        let r = try await h.handle(op: "vm.push_file", params: ["name": "Win", "path": .string(local.path), "dest": "downloads"])
        XCTAssertEqual(r, ["guestPath": "C:\\Users\\alcove\\Downloads\\note.txt"])
        let begin = agent.received.first { $0["t"]?.stringValue == "file.begin" }
        XCTAssertEqual(begin?["dest"]?.stringValue, "downloads")
        XCTAssertFalse(agent.received.contains { $0["t"]?.stringValue == "req" })
    }

    func testPullFile() async throws {
        let fs = FakeFS()
        let payload = Data((0..<300_000).map { UInt8($0 % 241) })
        fs["/data/out.bin"] = payload
        let (h, _) = try await setup(fs: fs)
        let dest = try tempDir().appendingPathComponent("out.bin")

        let r = try await h.handle(op: "vm.pull_file", params: ["name": "Win", "guestPath": "/data/out.bin", "path": .string(dest.path)])
        XCTAssertEqual(r, ["path": .string(dest.path), "bytes": 300_000, "sha256": .string(sha256(payload))])
        XCTAssertEqual(try Data(contentsOf: dest), payload)

        let absent = await failure(h, "vm.pull_file", ["name": "Win", "guestPath": "/data/nope.bin", "path": .string(dest.path)])
        XCTAssertEqual(absent, "'/data/nope.bin' is not a file in the guest; check the path")
        let noPath = await failure(h, "vm.pull_file", ["name": "Win", "guestPath": "/data/out.bin"])
        XCTAssertTrue(noPath.contains("'path'"), noPath)
    }

    func testSyncDir() async throws {
        let root = try tempDir()
        let a = Data("same".utf8), b = Data("new contents".utf8)
        try a.write(to: root.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try b.write(to: root.appendingPathComponent("sub/b.bin"))
        let fs = FakeFS()
        fs["/g/in/a.txt"] = a
        fs["/g/in/old.txt"] = Data("x".utf8)
        let (h, _) = try await setup(fs: fs)

        let kept = try await h.handle(op: "vm.sync_dir", params: ["name": "Win", "path": .string(root.path), "guestPath": "/g/in"])
        XCTAssertEqual(kept, ["sent": ["sub/b.bin"], "skipped": 1, "deleted": [], "bytes": .int(Int64(b.count))])
        XCTAssertEqual(fs["/g/in/sub/b.bin"], b)
        XCTAssertNotNil(fs["/g/in/old.txt"])

        let pruned = try await h.handle(op: "vm.sync_dir", params: ["name": "Win", "path": .string(root.path), "guestPath": "/g/in", "delete": true])
        XCTAssertEqual(pruned, ["sent": [], "skipped": 2, "deleted": ["old.txt"], "bytes": 0])
        XCTAssertNil(fs["/g/in/old.txt"])

        let notDir = await failure(h, "vm.sync_dir", ["name": "Win", "path": .string(root.appendingPathComponent("a.txt").path), "guestPath": "/g/in"])
        XCTAssertTrue(notDir.contains("a.txt") && notDir.contains("directory"), notDir)
    }

    // MARK: - guest files

    func testFsListDropsDigests() async throws {
        let fs = FakeFS()
        fs["/g/a.txt"] = Data("abc".utf8)
        fs["/g/sub/b.txt"] = Data("defgh".utf8)
        let (h, agent) = try await setup(fs: fs)
        let r = try await h.handle(op: "vm.fs.list", params: ["name": "Win", "path": "/g", "recursive": true])
        XCTAssertEqual(r, ["entries": [
            ["name": "a.txt", "dir": false, "size": 3, "mtime": "2026-01-01T00:00:00Z"],
            ["name": "sub/b.txt", "dir": false, "size": 5, "mtime": "2026-01-01T00:00:00Z"],
        ], "truncated": false])
        let req = agentRequests(agent, "fs.list").first
        XCTAssertEqual(req?["path"]?.stringValue, "/g")
        XCTAssertEqual(req?["recursive"]?.boolValue, true)
        XCTAssertNil(req?["sha256"])
    }

    func testFsReadTextAndTail() async throws {
        var utf16 = Data([0xFF, 0xFE])
        for unit in "héllo 한글".utf16 { utf16.append(UInt8(unit & 0xFF)); utf16.append(UInt8(unit >> 8)) }
        let encoded = utf16.base64EncodedString()
        let (h, agent) = try await setup { m, _ in
            switch m["op"]?.stringValue {
            case "fs.read": return [agentReply(m, ["data": .string(encoded), "size": 500, "eof": .bool(m["offset"]?.intValue == 0)])]
            case "fs.tail": return [agentReply(m, ["data": .string(Data("last line\n".utf8).base64EncodedString()), "size": 900])]
            default: return []
            }
        }
        let whole = try await h.handle(op: "vm.fs.read", params: ["name": "Win", "path": "C:\\log.txt"])
        XCTAssertEqual(whole, ["text": "héllo 한글", "size": 500, "eof": true])
        let first = agentRequests(agent, "fs.read").first
        XCTAssertEqual(first?["path"]?.stringValue, "C:\\log.txt")
        XCTAssertEqual(first?["offset"]?.intValue, 0)
        XCTAssertEqual(first?["length"]?.intValue, 262_144)

        let part = try await h.handle(op: "vm.fs.read", params: ["name": "Win", "path": "C:\\log.txt", "offset": 10, "length": 999_999])
        XCTAssertEqual(part["eof"]?.boolValue, false)
        let second = agentRequests(agent, "fs.read").last
        XCTAssertEqual(second?["offset"]?.intValue, 10)
        XCTAssertEqual(second?["length"]?.intValue, 262_144)

        _ = try await h.handle(op: "vm.fs.read", params: ["name": "Win", "path": "C:\\log.txt", "length": 64])
        XCTAssertEqual(agentRequests(agent, "fs.read").last?["length"]?.intValue, 64)

        let tail = try await h.handle(op: "vm.fs.read", params: ["name": "Win", "path": "C:\\log.txt", "tail": 5])
        XCTAssertEqual(tail, ["text": "last line\n", "size": 900, "eof": true])
        let tailReq = agentRequests(agent, "fs.tail").first
        XCTAssertEqual(tailReq?["path"]?.stringValue, "C:\\log.txt")
        XCTAssertEqual(tailReq?["lines"]?.intValue, 5)
        XCTAssertEqual(agentRequests(agent, "fs.read").count, 3)
    }

    func testFsWriteAppend() async throws {
        let file = LockedBox(Data())
        let (h, agent) = try await setup { m, _ in
            guard m["op"]?.stringValue == "fs.write" else { return [] }
            let piece = Data(base64Encoded: m["data"]?.stringValue ?? "") ?? Data()
            file.value = m["truncate"]?.boolValue == true ? piece : file.value + piece
            return [agentReply(m, ["size": .int(Int64(file.value.count))])]
        }
        let created = try await h.handle(op: "vm.fs.write", params: ["name": "Win", "path": "~/note.txt", "text": "héllo"])
        XCTAssertEqual(created, ["size": 6])
        let create = agentRequests(agent, "fs.write").last
        XCTAssertEqual(create?["path"]?.stringValue, "~/note.txt")
        XCTAssertEqual(create?["data"]?.stringValue, Data("héllo".utf8).base64EncodedString())
        XCTAssertEqual(create?["truncate"]?.boolValue, true)
        XCTAssertEqual(create?["mkdirs"]?.boolValue, true)
        XCTAssertNil(create?["append"]); XCTAssertNil(create?["text"])

        let appended = try await h.handle(op: "vm.fs.write", params: ["name": "Win", "path": "~/note.txt", "text": " more", "append": true])
        XCTAssertEqual(appended, ["size": 11])
        let append = agentRequests(agent, "fs.write").last
        XCTAssertEqual(append?["append"]?.boolValue, true)
        XCTAssertEqual(append?["mkdirs"]?.boolValue, true)
        XCTAssertNil(append?["truncate"])
        XCTAssertEqual(file.value, Data("héllo more".utf8))

        let long = String(repeating: "0123456789", count: 30_000)
        let replaced = try await h.handle(op: "vm.fs.write", params: ["name": "Win", "path": "~/note.txt", "text": .string(long)])
        XCTAssertEqual(replaced, ["size": 300_000])
        XCTAssertEqual(file.value, Data(long.utf8))
        let pieces = agentRequests(agent, "fs.write").suffix(2)
        XCTAssertEqual(agentRequests(agent, "fs.write").count, 4)
        XCTAssertEqual(pieces.first?["truncate"]?.boolValue, true)
        XCTAssertNil(pieces.first?["append"])
        XCTAssertEqual(Data(base64Encoded: pieces.first?["data"]?.stringValue ?? "")?.count, 262_144)
        XCTAssertEqual(pieces.last?["append"]?.boolValue, true)
        XCTAssertNil(pieces.last?["truncate"])
        XCTAssertEqual(Data(base64Encoded: pieces.last?["data"]?.stringValue ?? "")?.count, 37_856)

        let noText = await failure(h, "vm.fs.write", ["name": "Win", "path": "~/note.txt"])
        XCTAssertTrue(noText.contains("'text'"), noText)
    }

    func testFsDelete() async throws {
        let fs = FakeFS()
        fs["/g/a.txt"] = Data("abc".utf8)
        let (h, agent) = try await setup(fs: fs)
        let r = try await h.handle(op: "vm.fs.delete", params: ["name": "Win", "path": "/g/a.txt", "recursive": true])
        XCTAssertEqual(r, ["deleted": true])
        XCTAssertNil(fs["/g/a.txt"])
        let req = agentRequests(agent, "fs.delete").first
        XCTAssertEqual(req?["path"]?.stringValue, "/g/a.txt")
        XCTAssertEqual(req?["recursive"]?.boolValue, true)
        let again = try await h.handle(op: "vm.fs.delete", params: ["name": "Win", "path": "/g/a.txt"])
        XCTAssertEqual(again, ["deleted": false])
    }

    // MARK: - errors

    func testOldAgentErrorNamesTheUpdate() async throws {
        let (h, agent) = try await setup(proto: nil)
        let local = try tempDir().appendingPathComponent("x.bin")
        try Data("x".utf8).write(to: local)
        let cases: [(String, JSON)] = [
            ("vm.exec.start", ["name": "Win", "command": "dir"]),
            ("vm.exec.read", ["name": "Win", "job": "j1"]),
            ("vm.exec.write", ["name": "Win", "job": "j1", "data": "x"]),
            ("vm.exec.kill", ["name": "Win", "job": "j1"]),
            ("vm.exec.list", ["name": "Win"]),
            ("vm.process.list", ["name": "Win"]),
            ("vm.process.kill", ["name": "Win", "pid": 4]),
            ("vm.push_file", ["name": "Win", "path": .string(local.path), "guestPath": "/x.bin"]),
            ("vm.pull_file", ["name": "Win", "guestPath": "/x.bin", "path": .string(local.path + ".out")]),
            ("vm.sync_dir", ["name": "Win", "path": .string(local.deletingLastPathComponent().path), "guestPath": "/x"]),
            ("vm.fs.list", ["name": "Win", "path": "/"]),
            ("vm.fs.read", ["name": "Win", "path": "/x"]),
            ("vm.fs.write", ["name": "Win", "path": "/x", "text": "x"]),
            ("vm.fs.delete", ["name": "Win", "path": "/x"]),
        ]
        for (op, params) in cases {
            let text = await failure(h, op, params)
            XCTAssertEqual(text, "guest tools in 'Win' are too old for \(op); update alcove-agent in the guest")
        }
        XCTAssertFalse(agent.received.contains { $0["t"]?.stringValue == "req" })
    }

    func testAgentErrorTextIsPassedThrough() async throws {
        let (h, _) = try await setup { m, _ in
            m["t"]?.stringValue == "req" ? [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": "exec disabled; start alcove-agent with --allow-exec"]] : []
        }
        for (op, params) in [("vm.exec", ["name": "Win", "command": "dir"] as JSON), ("vm.process.list", ["name": "Win"]), ("vm.fs.read", ["name": "Win", "path": "/x"])] {
            let text = await failure(h, op, params)
            XCTAssertEqual(text, "exec disabled; start alcove-agent with --allow-exec", op)
        }
    }

    func testShellAndFileOpsNeedARunningVMWithTools() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 8, height: 8))
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test")
        let noTools = await failure(h, "vm.fs.list", ["name": "Win", "path": "/"])
        XCTAssertEqual(noTools, "guest tools are not connected in 'Win'; install alcove-agent in the guest")
        await t.setState(.stopped)
        let stopped = await failure(h, "vm.exec.list", ["name": "Win"])
        XCTAssertEqual(stopped, "VM 'Win' is stopped; call vm.start first")
        let unknown = await failure(h, "vm.fs.bogus", ["name": "Win"])
        XCTAssertEqual(unknown, "unknown op 'vm.fs.bogus'")
    }

    func testConcurrentOps() {
        for op in ["vm.exec", "vm.exec.start", "vm.exec.read", "vm.exec.write", "vm.exec.kill", "vm.exec.list", "vm.process.list", "vm.process.kill",
                   "vm.push_file", "vm.pull_file", "vm.sync_dir", "vm.fs.list", "vm.fs.read", "vm.fs.write", "vm.fs.delete"] {
            XCTAssertTrue(ControlHandler.isConcurrent(op: op), op)
        }
        for op in ["hello", "vm.list", "vm.status", "vm.start", "vm.stop", "vm.screenshot", "vm.mouse.click", "vm.key.press", "vm.type",
                   "vm.clipboard.get", "vm.clipboard.set", "vm.wait_idle"] {
            XCTAssertFalse(ControlHandler.isConcurrent(op: op), op)
        }
    }
}

final class GuestTextTests: XCTestCase {
    func testUTF16LittleEndianWithBOM() {
        var data = Data([0xFF, 0xFE])
        for unit in "Windows 한글 😀".utf16 { data.append(UInt8(unit & 0xFF)); data.append(UInt8(unit >> 8)) }
        XCTAssertEqual(GuestText.decode(data), "Windows 한글 😀")
        XCTAssertEqual(GuestText.decode(Data([0xFF, 0xFE])), "")
        XCTAssertEqual(GuestText.decode(Data([0xFF, 0xFE, 0x41, 0x00, 0x42])), "A\u{FFFD}")
        XCTAssertEqual(GuestText.decode(Data([0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00])), "\u{FFFD}A")
    }

    func testUTF8WithBOMIsStripped() {
        XCTAssertEqual(GuestText.decode(Data([0xEF, 0xBB, 0xBF]) + Data("한글 text".utf8)), "한글 text")
        XCTAssertEqual(GuestText.decode(Data([0xEF, 0xBB, 0xBF])), "")
    }

    func testPlainUTF8() {
        XCTAssertEqual(GuestText.decode(Data("plain 한글\n".utf8)), "plain 한글\n")
        XCTAssertEqual(GuestText.decode(Data()), "")
    }

    func testInvalidUTF8IsReplaced() {
        XCTAssertEqual(GuestText.decode(Data([0x61, 0xFF, 0x62])), "a\u{FFFD}b")
        XCTAssertEqual(GuestText.decode(Data([0x61, 0xC3])), "a\u{FFFD}")
    }
}

private actor EventLog {
    private(set) var items: [String] = []
    func add(_ item: String) { items.append(item) }
}

final class InputGateTests: XCTestCase {
    func testInputGateIsFIFO() async throws {
        let gate = InputGate()
        let log = EventLog()
        let open = LockedBox(false)

        let first = Task {
            await gate.withLock("Win") {
                await log.add("1 begin")
                while !open.value { try? await Task.sleep(for: .milliseconds(5)) }
                await log.add("1 end")
            }
        }
        while await log.items.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        var later: [Task<Void, Never>] = []
        for n in 2...3 {
            later.append(Task {
                await gate.withLock("Win") {
                    await log.add("\(n) begin")
                    try? await Task.sleep(for: .milliseconds(30))
                    await log.add("\(n) end")
                }
            })
            while await gate.waiterCount(for: "Win") < n - 1 { try await Task.sleep(for: .milliseconds(5)) }
        }

        let other = await gate.withLock("Other") { "ran" }
        XCTAssertEqual(other, "ran")
        let whileHeld = await log.items
        XCTAssertEqual(whileHeld, ["1 begin"])

        open.value = true
        await first.value
        for task in later { await task.value }
        let items = await log.items
        XCTAssertEqual(items, ["1 begin", "1 end", "2 begin", "2 end", "3 begin", "3 end"])
        let waiting = await gate.waiterCount(for: "Win")
        XCTAssertEqual(waiting, 0)
        let after = await gate.withLock("Win") { "free" }
        XCTAssertEqual(after, "free")
    }

    func testInputGateReleasesWhenTheBodyThrows() async throws {
        struct Boom: Error {}
        let gate = InputGate()
        do { try await gate.withLock("Win") { throw Boom() }; XCTFail("expected Boom") } catch is Boom {}
        let after = await gate.withLock("Win") { "free" }
        XCTAssertEqual(after, "free")
    }

    func testInputOpsOnOneVMDoNotInterleave() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 800, height: 600))
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test")
        let click = Task { try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 0, "y": 0, "hold": 300]) }
        while await t.sent.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        _ = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "a"])
        _ = try await click.value
        let sent = await t.sent
        XCTAssertEqual(sent, [
            .abs(con: 0, x: 0, y: 0), .btn(con: 0, button: .left, down: true), .sync, .btn(con: 0, button: .left, down: false), .sync,
            .key(mac: 0, q: nil, down: true), .key(mac: 0, q: nil, down: false),
        ])
    }
}
