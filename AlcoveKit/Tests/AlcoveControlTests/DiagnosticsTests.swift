import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

/// A scripted guest: the data the fake agent answers with, and the ops it fails or leaves unanswered.
private final class Guest: @unchecked Sendable {
    var windows: [JSON] = [
        guestWindow("0x2a", "Alcove Fixture", foreground: true),
        guestWindow("0x3b", "Notepad", responding: false, pid: 777),
    ]
    var tree: [JSON] = [["ref": "e1", "depth": 0, "role": "Window", "name": "Alcove Fixture", "x": 1, "y": 2, "w": 3, "h": 4, "flags": []]]
    var applicationEntries: [JSON] = [entry("2026-10-14T01:00:00Z", "Application Error", "Faulting application MyApp.exe"),
                                      entry("2026-10-14T01:05:00Z", "Application Error", "Faulting application Other.exe")]
    var systemEntries: [JSON] = []
    var dumps: [JSON] = []
    var processes: [JSON] = [["pid": 100, "ppid": 1, "name": "explorer.exe", "path": "C:\\Windows\\explorer.exe", "cmd": "explorer.exe", "mem_kb": 10],
                             ["pid": 200, "ppid": 100, "name": "MyApp.exe", "path": "C:\\MyApp.exe", "cmd": "MyApp.exe --token=SECRET123", "mem_kb": 20]]
    var jobs: [JSON] = []
    var jobOutput: [String: (out: String, err: String)] = [:]
    var tails: [String: String] = [:]
    var failing: [String: String] = [:]
    var silent: Set<String> = []
    let fs = FakeFS()
    private let fileHandler: (JSON, FakeAgent) -> [JSON]

    init() {
        let scratch = FakeAgent()
        fs.install(on: scratch)
        fileHandler = scratch.handler!
        scratch.stop()
    }

    func reply(_ m: JSON, _ agent: FakeAgent) -> [JSON] {
        guard m["t"]?.stringValue == "req", let op = m["op"]?.stringValue else { return [] }
        if silent.contains(op) { return [] }
        if let sentence = failing[op] { return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": .string(sentence)]] }
        func ok(_ fields: [String: JSON]) -> [JSON] { [agentReply(m, fields)] }
        switch op {
        case "win.list": return ok(["windows": .array(windows)])
        case "ui.tree": return ok(["window": windows[0], "nodes": .array(tree), "truncated": false])
        case "proc.list":
            let filter = m["name"]?.stringValue?.lowercased()
            return ok(["procs": .array(processes.filter { filter == nil || ($0["name"]?.stringValue ?? "").lowercased().contains(filter!) })])
        case "exec.list": return ok(["jobs": .array(jobs)])
        case "exec.read":
            let job = m["job"]?.stringValue ?? ""
            guard let output = jobOutput[job] else { return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": "no job '\(job)'; call exec.list"]] }
            func piece(_ text: String, _ offsetKey: String) -> (String, Int) {
                let bytes = Array(text.utf8)
                let from = min(m[offsetKey]?.intValue ?? 0, bytes.count)
                let to = min(from + (m["max"]?.intValue ?? 262_144), bytes.count)
                return (String(decoding: bytes[from..<to], as: UTF8.self), to)
            }
            let (out, outNext) = piece(output.out, "out_offset"), (err, errNext) = piece(output.err, "err_offset")
            return ok(["state": "exited", "out": .string(out), "err": .string(err), "out_next": .int(Int64(outNext)), "err_next": .int(Int64(errNext))])
        case "fs.tail":
            let path = m["path"]?.stringValue ?? ""
            guard let text = tails[path] else { return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": "'\(path)' does not exist"]] }
            let lines = text.split(separator: "\n").map(String.init)
            let wanted = m["lines"]?.intValue ?? 200
            let kept = lines.suffix(wanted).joined(separator: "\n") + "\n"
            return ok(["data": .string(Data(kept.utf8).base64EncodedString()), "size": .int(Int64(text.utf8.count))])
        case "exec.run":
            let cmd = m["cmd"]?.stringValue ?? ""
            func run(_ stdout: String) -> [JSON] { ok(["code": 0, "stdout": .string(stdout), "stderr": "", "timed_out": false, "truncated": false]) }
            if cmd.contains("Get-WinEvent -ListLog") {
                let entries = cmd.contains("$log = 'System'") ? systemEntries : applicationEntries
                return run(JSON.object(["entries": .array(entries), "truncated": false]).text)
            }
            if cmd.contains("journalctl") { return run("") }
            if cmd.contains("-Filter *.dmp") { return run(JSON.array(dumps).text) }
            if cmd.contains("LogonUI") {
                return run("{\"user\":\"u\",\"locked\":false,\"freeBytes\":50000000000,\"utc\":\"\(ISO8601DateFormatter().string(from: Date()))\",\"dns\":true,\"scale\":100}")
            }
            return run("")
        default:
            return fileHandler(m, agent)
        }
    }
}

private extension ControlHandler {
    func eventPositions(of vm: String) -> (baseline: Int?, observed: Int?) { (eventBaseline[vm]?.seq, observedEvents[vm]?.seq) }
}

private extension JSON {
    var text: String { String(decoding: (try? serialized()) ?? Data(), as: UTF8.self) }
}

private func entry(_ time: String, _ provider: String, _ message: String) -> JSON {
    ["time": .string(time), "id": 1000, "level": "error", "provider": .string(provider), "message": .string(message)]
}

private func guestWindow(_ id: String, _ title: String, foreground: Bool = false, responding: Bool = true, pid: Int = 4242) -> JSON {
    ["id": .string(id), "title": .string(title), "pid": .int(Int64(pid)), "process": "app.exe", "class": "C", "x": 0, "y": 0, "w": 100, "h": 100,
     "state": "normal", "foreground": .bool(foreground), "responding": .bool(responding), "modal": false]
}

private func dumpRow(_ file: String, bytes: Int, time: String) -> JSON {
    ["file": .string(file), "exe": "MyApp.exe", "bytes": .int(Int64(bytes)), "time": .string(time)]
}

final class DiagnosticsTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alcove-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        DiagnosticsLimits.dumpBudget = 500 * 1024 * 1024
        DiagnosticsTiming.windowsTurn = .seconds(15)
        DiagnosticsTiming.windows = .seconds(30)
        DiagnosticsTiming.treeTurn = .seconds(40)
        DiagnosticsTiming.tree = .seconds(50)
        DiagnosticsTiming.processes = .seconds(35)
        DiagnosticsTiming.agentWait = .seconds(5)
    }

    private struct Rig {
        let handler: ControlHandler
        let target: FakeTarget
        let agent: FakeAgent
        let guest: Guest
    }

    private func rig(os: VMConfig.GuestOS = .windows, caps: [String] = ["clipboard", "files", "exec", "ui"], _ configure: (Guest) -> Void = { _ in }) async throws -> Rig {
        let guest = Guest()
        configure(guest)
        let agent = FakeAgent()
        agent.caps = caps
        agent.handler = { m, a in guest.reply(m, a) }
        _ = agent.start()
        addTeardownBlock { agent.stop() }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        let target = FakeTarget(name: "Win", state: .running, png: makePNG(width: 800, height: 600))
        await target.setAgent(client)
        await target.setOS(os)
        let handler = ControlHandler(registry: FakeRegistry(targets: ["Win": target]), hostKind: "test",
                                     recordingsDirectory: scratch.appendingPathComponent("recordings"),
                                     diagnosticsDirectory: scratch.appendingPathComponent("diagnostics"))
        return Rig(handler: handler, target: target, agent: agent, guest: guest)
    }

    private func bundleDirectory(_ name: String = "bundle") -> URL { scratch.appendingPathComponent(name) }

    private func collect(_ h: ControlHandler, _ extra: [String: JSON] = [:], dir: URL? = nil) async throws -> JSON {
        var params: [String: JSON] = ["name": "Win"]
        params["dir"] = .string((dir ?? bundleDirectory()).path)
        for (key, value) in extra { params[key] = value }
        return try await h.handle(op: "vm.collect_diagnostics", params: .object(params))
    }

    private func read(_ relative: String, in dir: URL? = nil) throws -> String {
        try String(contentsOf: (dir ?? bundleDirectory()).appendingPathComponent(relative), encoding: .utf8)
    }

    private func exists(_ relative: String, in dir: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (dir ?? bundleDirectory()).appendingPathComponent(relative).path)
    }

    private func files(_ result: JSON) -> [String] { result["files"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    private func failure(_ h: ControlHandler, _ params: JSON) async -> String {
        do { _ = try await h.handle(op: "vm.collect_diagnostics", params: params); XCTFail("expected a failure"); return "" } catch { return "\(error)" }
    }

    // MARK: - the bundle

    func testBundleContainsEveryFile() async throws {
        let r = try await rig {
            $0.systemEntries = [entry("2026-10-14T01:06:00Z", "Disk", "bad block")]
            $0.dumps = [dumpRow("MyApp.exe.4242.dmp", bytes: 20, time: ISO8601DateFormatter().string(from: Date()))]
            $0.jobs = [["job": "j1", "pid": 5, "state": "exited", "code": 0, "cmd": "build", "started": "2026-10-14T01:00:00+09:00"]]
            $0.jobOutput["j1"] = ("built\n", "warn\n")
            $0.tails["C:\\logs\\app.log"] = "one\ntwo\n"
            $0.fs["C:\\alcove-dumps\\MyApp.exe.4242.dmp"] = Data(repeating: 7, count: 20)
        }
        let start = try await r.handler.handle(op: "vm.record.start", params: ["name": "Win", "video": false])
        XCTAssertNotNil(start["dir"])
        _ = try await r.handler.handle(op: "vm.status", params: ["name": "Win"])
        let result = try await collect(r.handler, ["logFiles": ["C:\\logs\\app.log"]])
        XCTAssertEqual(result["dir"]?.stringValue, bundleDirectory().path)
        XCTAssertEqual(files(result), [
            "doctor.json", "dumps/MyApp.exe.4242.dmp", "eventlog-application.json", "eventlog-system.json", "events.json", "jobs/j1.txt",
            "logs/app.log", "processes.json", "screenshot.png", "summary.txt", "trace.jsonl", "ui-tree.txt", "windows.json",
        ])
        XCTAssertEqual(files(result), ControlHandler.bundleFiles(bundleDirectory()))
        XCTAssertEqual(try read("summary.txt") + "", (result["summary"]?.stringValue ?? "") + "\n")
        XCTAssertEqual(try read("logs/app.log"), "one\ntwo\n")
        XCTAssertEqual(try Data(contentsOf: bundleDirectory().appendingPathComponent("dumps/MyApp.exe.4242.dmp")), Data(repeating: 7, count: 20))
        XCTAssertTrue(try read("jobs/j1.txt").contains("built"))
        XCTAssertTrue(try read("ui-tree.txt").contains("[e1] Window \"Alcove Fixture\""))
        XCTAssertEqual(Frame(png: try Data(contentsOf: bundleDirectory().appendingPathComponent("screenshot.png")))?.width, 800)
        XCTAssertTrue(try read("summary.txt").hasSuffix("steps that failed: none\n"))
    }

    func testProcessesJSONHasTheShapeOfProcessList() async throws {
        let r = try await rig()
        _ = try await collect(r.handler)
        let expected = try await r.handler.handle(op: "vm.process.list", params: ["name": "Win"])
        let written = try JSON.parse(Data(contentsOf: bundleDirectory().appendingPathComponent("processes.json")))
        XCTAssertEqual(written, JSON.object(["processes": expected["processes"] ?? []]))
        XCTAssertEqual(written["processes"]?[1]?["command"]?.stringValue, "MyApp.exe --token=SECRET123")
    }

    func testProcessNameNarrowsTheListAndMarksTheApp() async throws {
        let r = try await rig()
        _ = try await collect(r.handler, ["processName": "MyApp"])
        XCTAssertEqual(agentRequests(r.agent, "proc.list").last?["name"]?.stringValue, "MyApp")
        let written = try JSON.parse(Data(contentsOf: bundleDirectory().appendingPathComponent("processes.json")))
        XCTAssertEqual(written["processes"]?.arrayValue?.count, 1)
        XCTAssertTrue(try read("summary.txt").contains("process MyApp: running, pid 200"))

        let none = try await rig()
        _ = try await collect(none.handler, ["processName": "Missing"], dir: bundleDirectory("two"))
        XCTAssertTrue(try read("summary.txt", in: bundleDirectory("two")).contains("process Missing: not running"))
    }

    func testStepFailureWritesErrorFile() async throws {
        let r = try await rig { $0.failing["win.list"] = "the UI helper is shut down; restart alcove-agent" }
        let result = try await collect(r.handler)
        XCTAssertEqual(try read("windows.error.txt"), "the UI helper is shut down; restart alcove-agent\n")
        XCTAssertFalse(exists("windows.json"))
        for name in ["screenshot.png", "ui-tree.txt", "processes.json", "eventlog-application.json", "events.json", "doctor.json", "summary.txt"] {
            XCTAssertTrue(files(result).contains(name), name)
        }
        let summary = try XCTUnwrap(result["summary"]?.stringValue)
        XCTAssertTrue(summary.hasSuffix("steps that failed:\nwindows: the UI helper is shut down; restart alcove-agent"), summary)
    }

    func testSummaryNamesHangDumpAndErrors() async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let r = try await rig {
            $0.systemEntries = [entry("2026-10-14T01:06:00Z", "Disk", "bad\nblock")]
            $0.dumps = [dumpRow("MyApp.exe.4242.dmp", bytes: 20, time: now)]
            $0.jobs = [["job": "j1", "pid": 5, "state": "exited", "code": 3, "cmd": "build --token=SECRET123"],
                       ["job": "j2", "pid": 6, "state": "exited", "code": 0, "cmd": "ok"],
                       ["job": "j3", "pid": 7, "state": "running", "cmd": "serve"]]
            $0.jobOutput = ["j1": ("", ""), "j2": ("", ""), "j3": ("", "")]
            $0.fs["C:\\alcove-dumps\\MyApp.exe.4242.dmp"] = Data(repeating: 1, count: 20)
        }
        let result = try await collect(r.handler, ["lease": "LEASE-TOKEN"])
        let lines = try XCTUnwrap(result["summary"]?.stringValue).components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("VM Win, collected 20"), lines[0])
        XCTAssertTrue(lines[0].hasSuffix(", guest windows"), lines[0])
        XCTAssertTrue(lines.contains("window not responding: 0x3b \"Notepad\" (pid 777, app.exe)"), "\(lines)")
        XCTAssertTrue(lines.contains("foreground window: \"Alcove Fixture\""), "\(lines)")
        XCTAssertTrue(lines.contains("crash dump MyApp.exe.4242.dmp: 20 bytes, \(now), collected as dumps/MyApp.exe.4242.dmp"), "\(lines)")
        XCTAssertTrue(lines.contains("event log Application: 2 entries of level error or worse in the last 30 minutes; newest: Faulting application Other.exe"), "\(lines)")
        XCTAssertTrue(lines.contains("event log System: 1 entry of level error or worse in the last 30 minutes; newest: bad block"), "\(lines)")
        XCTAssertTrue(lines.contains("job j1 exited with code 3"), "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("job j2") || $0.contains("job j3") })
        let text = try read("summary.txt")
        XCTAssertFalse(text.contains("SECRET123"))
        XCTAssertFalse(text.contains("LEASE-TOKEN"))
        let listing = files(result).joined(separator: "\n")
        XCTAssertFalse(listing.contains("LEASE-TOKEN"))
    }

    func testSummaryReportsCleanStates() async throws {
        let r = try await rig {
            $0.windows = [guestWindow("0x1", "Main", foreground: true)]
            $0.applicationEntries = []
        }
        let result = try await collect(r.handler)
        let lines = try XCTUnwrap(result["summary"]?.stringValue).components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("windows not responding: none"))
        XCTAssertTrue(lines.contains("crash dumps: none newer than 30 minutes"))
        XCTAssertTrue(lines.contains("event log Application: 0 entries of level error or worse in the last 30 minutes"))
        XCTAssertTrue(lines.contains("jobs exited with a non-zero code: none"))
    }

    func testEventLogsAskForErrorsInTheWindowRequested() async throws {
        let r = try await rig()
        _ = try await collect(r.handler, ["sinceMinutes": 90])
        let scripts = agentRequests(r.agent, "exec.run").compactMap { $0["cmd"]?.stringValue }.filter { $0.contains("Get-WinEvent -ListLog") }
        XCTAssertEqual(scripts.count, 2)
        for script in scripts {
            XCTAssertTrue(script.contains("AddMinutes(-90)"), script)
            XCTAssertTrue(script.contains("$filter.Level = @(1,2)"), script)
        }
        XCTAssertTrue(scripts.contains { $0.contains("$log = 'Application'") })
        XCTAssertTrue(scripts.contains { $0.contains("$log = 'System'") })
    }

    func testLinuxGuestWritesOneEventLog() async throws {
        let r = try await rig(os: .linux, caps: ["clipboard", "files", "exec"])
        let result = try await collect(r.handler)
        XCTAssertTrue(files(result).contains("eventlog-system.json"))
        XCTAssertFalse(files(result).contains("eventlog-application.json"))
        XCTAssertTrue(files(result).contains("ui-tree.error.txt"))
        XCTAssertTrue(files(result).contains("windows.error.txt"))
        XCTAssertTrue(files(result).contains("dumps.error.txt"))
    }

    // MARK: - log files

    func testLogFilesArePulledAsTails() async throws {
        let long = (1...3000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let r = try await rig { $0.tails["/var/log/app.log"] = long }
        _ = try await collect(r.handler, ["logFiles": ["/var/log/app.log"]])
        XCTAssertEqual(agentRequests(r.agent, "fs.tail").first?["lines"]?.intValue, 2000)
        let lines = try read("logs/app.log").split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "line 1001")
        XCTAssertEqual(lines.count, 2001)
    }

    func testLogFileTailIsCutToTheByteCapAtALineStart() async throws {
        let big = String(repeating: "x", count: 199) + "\n"
        let text = String(repeating: big, count: 10_000)
        let r = try await rig { $0.tails["/var/log/big.log"] = text }
        _ = try await collect(r.handler, ["logFiles": ["/var/log/big.log"]])
        let written = try read("logs/big.log")
        XCTAssertLessThanOrEqual(written.utf8.count, DiagnosticsLimits.logBytes)
        XCTAssertGreaterThan(written.utf8.count, DiagnosticsLimits.logBytes - 200)
        XCTAssertTrue(written.hasPrefix(String(repeating: "x", count: 199) + "\n"))
        XCTAssertTrue(written.hasSuffix("\n"))
    }

    func testMissingLogFileWritesItsErrorAndTheRestContinues() async throws {
        let r = try await rig { $0.tails["/var/log/there.log"] = "ok\n" }
        let result = try await collect(r.handler, ["logFiles": ["/var/log/gone.log", "/var/log/there.log"]])
        XCTAssertEqual(try read("logs/gone.log.error.txt"), "'/var/log/gone.log' does not exist\n")
        XCTAssertEqual(try read("logs/there.log"), "ok\n")
        XCTAssertTrue(try XCTUnwrap(result["summary"]?.stringValue).contains("logs/gone.log: '/var/log/gone.log' does not exist"))
    }

    func testLogFilesWithTheSameBaseNameDoNotOverwriteEachOther() async throws {
        let r = try await rig {
            $0.tails["C:\\a\\app.log"] = "first\n"
            $0.tails["/srv/app.log"] = "second\n"
            $0.tails["/srv/APP.LOG"] = "third\n"
        }
        _ = try await collect(r.handler, ["logFiles": ["C:\\a\\app.log", "/srv/app.log", "/srv/APP.LOG"]])
        XCTAssertEqual(try read("logs/app.log"), "first\n")
        XCTAssertEqual(try read("logs/app-2.log"), "second\n")
        XCTAssertEqual(try read("logs/APP-3.LOG"), "third\n")
    }

    func testHostileGuestNamesStayInsideTheBundle() async throws {
        let r = try await rig {
            $0.tails["/var/log/.."] = "dots\n"
            $0.tails["/var/log/a\u{1}b\nc.log"] = "control\n"
            $0.tails["/var/log/"] = "slash\n"
        }
        let result = try await collect(r.handler, ["logFiles": ["/var/log/..", "/var/log/a\u{1}b\nc.log", "/var/log/"]])
        let logs = files(result).filter { $0.hasPrefix("logs/") }
        XCTAssertEqual(logs.count, 3, "\(logs)")
        for name in files(result) {
            XCTAssertFalse(name.contains(".."), name)
            XCTAssertFalse(name.unicodeScalars.contains { $0.value < 0x20 }, name)
        }
        let outside = scratch.appendingPathComponent("logs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testNameCleaning() {
        var names = DiagnosticsNames()
        XCTAssertEqual(names.claim("C:\\Users\\me\\app.log", fallback: "log"), "app.log")
        XCTAssertEqual(names.claim("/a/b/app.log", fallback: "log"), "app-2.log")
        XCTAssertEqual(names.claim("/a/b/App.Log", fallback: "log"), "App-3.Log")
        XCTAssertEqual(names.claim("..", fallback: "log"), "log")
        XCTAssertEqual(names.claim("../..", fallback: "log"), "log-2")
        XCTAssertEqual(names.claim("", fallback: "log"), "log-3")
        XCTAssertEqual(names.claim("/tmp/", fallback: "log"), "tmp")
        XCTAssertEqual(names.claim(".hidden", fallback: "log"), "hidden")
        XCTAssertEqual(names.claim("a:b*c?.txt", fallback: "log"), "a_b_c_.txt")
        XCTAssertEqual(names.claim("tab\there\u{7f}\u{85}.txt", fallback: "log"), "tab_here__.txt")
        XCTAssertEqual(names.claim("trailing. . ", fallback: "log"), "trailing")
        let long = DiagnosticsNames.clean(String(repeating: "é", count: 200) + ".log", fallback: "log")
        XCTAssertLessThanOrEqual(long.utf8.count, DiagnosticsNames.maxBytes)
        XCTAssertTrue(long.hasSuffix(".log"))
        let hugeExtension = DiagnosticsNames.clean("a." + String(repeating: "z", count: 300), fallback: "log")
        XCTAssertLessThanOrEqual(hugeExtension.utf8.count, DiagnosticsNames.maxBytes)
    }

    // MARK: - jobs

    func testJobsKeepTheLastBytesOfEachStream() async throws {
        let out = String(repeating: "a", count: 300_000) + "END-OUT"
        let r = try await rig {
            $0.jobs = [["job": "j1", "pid": 5, "state": "exited", "code": 1, "cmd": "make"]]
            $0.jobOutput["j1"] = (out, "short error\n")
        }
        _ = try await collect(r.handler)
        let text = try read("jobs/j1.txt")
        XCTAssertTrue(text.hasPrefix("job j1: exited, code 1\ncommand: make\n"), text)
        XCTAssertTrue(text.contains("--- stdout (last \(DiagnosticsLimits.jobBytes) bytes) ---"), text)
        XCTAssertTrue(text.contains("END-OUT\n--- stderr ---\nshort error\n"), text)
        XCTAssertLessThan(text.utf8.count, DiagnosticsLimits.jobBytes + 1000)
        XCTAssertTrue(agentRequests(r.agent, "exec.read").allSatisfy { $0["out_offset"] != nil })
    }

    func testJobIdsBecomeSafeFileNames() async throws {
        let r = try await rig {
            $0.jobs = [["job": "../../escape", "pid": 5, "state": "exited", "code": 0, "cmd": "x"],
                       ["job": "..\\..\\escape", "pid": 6, "state": "exited", "code": 0, "cmd": "y"]]
            $0.jobOutput = ["../../escape": ("a", ""), "..\\..\\escape": ("b", "")]
        }
        let result = try await collect(r.handler)
        XCTAssertEqual(Set(files(result).filter { $0.hasPrefix("jobs/") }), ["jobs/escape.txt", "jobs/escape-2.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("escape.txt").path))
    }

    // MARK: - dumps

    func testDumpBudget() async throws {
        DiagnosticsLimits.dumpBudget = 1000
        let now = Date()
        func stamp(_ seconds: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-seconds)) }
        let r = try await rig {
            $0.dumps = [dumpRow("new.exe.1.dmp", bytes: 600, time: stamp(10)), dumpRow("big.exe.2.dmp", bytes: 500, time: stamp(20)),
                        dumpRow("fits.exe.3.dmp", bytes: 400, time: stamp(30)), dumpRow("over.exe.4.dmp", bytes: 1, time: stamp(40))]
            for (name, size) in [("new.exe.1.dmp", 600), ("big.exe.2.dmp", 500), ("fits.exe.3.dmp", 400), ("over.exe.4.dmp", 1)] {
                $0.fs["C:\\alcove-dumps\\\(name)"] = Data(repeating: 9, count: size)
            }
        }
        let result = try await collect(r.handler)
        XCTAssertEqual(files(result).filter { $0.hasPrefix("dumps/") }, ["dumps/fits.exe.3.dmp", "dumps/new.exe.1.dmp"])
        let summary = try XCTUnwrap(result["summary"]?.stringValue)
        XCTAssertTrue(summary.contains("crash dump big.exe.2.dmp: 500 bytes"), summary)
        XCTAssertTrue(summary.contains("not collected: it does not fit the"), summary)
        XCTAssertTrue(summary.contains("crash dump over.exe.4.dmp: 1 bytes"), summary)
    }

    func testDumpSelectionBoundary() {
        let mib = 1024 * 1024
        let budget = 500 * mib
        let a = ControlHandler.DumpRow(file: "a", bytes: 300 * mib, time: "")
        let exact = ControlHandler.DumpRow(file: "b", bytes: 200 * mib, time: "")
        let one = ControlHandler.DumpRow(file: "c", bytes: 1, time: "")
        var picked = ControlHandler.selectDumps([a, exact, one], budget: budget)
        XCTAssertEqual(picked.take, [a, exact])
        XCTAssertEqual(picked.skipped, [one])
        let over = ControlHandler.DumpRow(file: "d", bytes: 200 * mib + 1, time: "")
        picked = ControlHandler.selectDumps([a, over, one], budget: budget)
        XCTAssertEqual(picked.take, [a, one])
        XCTAssertEqual(picked.skipped, [over])
        XCTAssertEqual(DiagnosticsLimits.dumpBudget, 500 * mib)
    }

    func testDumpsOlderThanSinceMinutesAreLeftOut() async throws {
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600))
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let r = try await rig {
            $0.dumps = [dumpRow("recent.exe.1.dmp", bytes: 4, time: recent), dumpRow("old.exe.2.dmp", bytes: 4, time: old)]
            $0.fs["C:\\alcove-dumps\\recent.exe.1.dmp"] = Data(count: 4)
            $0.fs["C:\\alcove-dumps\\old.exe.2.dmp"] = Data(count: 4)
        }
        let result = try await collect(r.handler, ["sinceMinutes": 120])
        XCTAssertEqual(files(result).filter { $0.hasPrefix("dumps/") }, ["dumps/recent.exe.1.dmp"])
    }

    func testDumpPullFailureWritesItsErrorFileAndTheOthersContinue() async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let r = try await rig {
            $0.dumps = [dumpRow("gone.exe.1.dmp", bytes: 4, time: now), dumpRow("here.exe.2.dmp", bytes: 4, time: now)]
            $0.fs["C:\\alcove-dumps\\here.exe.2.dmp"] = Data(count: 4)
        }
        let result = try await collect(r.handler)
        XCTAssertEqual(try read("dumps/gone.exe.1.dmp.error.txt"), "'C:\\alcove-dumps\\gone.exe.1.dmp' is not a file in the guest; check the path\n")
        XCTAssertTrue(files(result).contains("dumps/here.exe.2.dmp"))
        XCTAssertFalse(files(result).contains("dumps/gone.exe.1.dmp"))
        XCTAssertTrue(try XCTUnwrap(result["summary"]?.stringValue).contains("crash dump gone.exe.1.dmp: 4 bytes"))
    }

    // MARK: - guest tools

    func testWorksWithoutGuestTools() async throws {
        let target = FakeTarget(name: "Win", state: .running, png: makePNG(width: 800, height: 600))
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": target]), hostKind: "test",
                               diagnosticsDirectory: scratch.appendingPathComponent("diagnostics"))
        DiagnosticsTiming.agentWait = .zero
        let result = try await collect(h)
        XCTAssertEqual(files(result), ["doctor.json", "events.json", "screenshot.png", "summary.txt"])
        let summary = try XCTUnwrap(result["summary"]?.stringValue)
        XCTAssertTrue(summary.contains("guest tools are not connected in 'Win'; install alcove-agent in the guest."), summary)
        XCTAssertTrue(summary.hasSuffix("steps that failed: none"), summary)
        let doctor = try JSON.parse(Data(contentsOf: bundleDirectory().appendingPathComponent("doctor.json")))
        XCTAssertTrue(doctor["checks"]?.arrayValue?.contains { $0["id"]?.stringValue == "tools" && $0["ok"]?.boolValue == false } ?? false)
    }

    func testStoppedVMKeepsWhatNeedsNoGuest() async throws {
        let r = try await rig()
        await r.target.setState(.stopped)
        let result = try await collect(r.handler)
        XCTAssertEqual(files(result), ["doctor.json", "events.json", "screenshot.error.txt", "summary.txt"])
        XCTAssertEqual(try read("screenshot.error.txt"), "VM 'Win' is stopped; call vm.start first\n")
        let summary = try XCTUnwrap(result["summary"]?.stringValue)
        XCTAssertTrue(summary.contains("VM 'Win' is stopped; call vm.start and collect again"), summary)
        XCTAssertTrue(summary.hasSuffix("steps that failed:\nscreenshot: VM 'Win' is stopped; call vm.start first"), summary)
        XCTAssertEqual(agentRequests(r.agent, "win.list").count, 0)
    }

    func testBusyHelperLeavesTheOtherFiles() async throws {
        let r = try await rig { $0.silent = ["win.list"] }
        let holder = Task { try await r.handler.handle(op: "vm.window.list", params: ["name": "Win"]) }
        let held = await eventually { agentRequests(r.agent, "win.list").count == 1 }
        XCTAssertTrue(held)
        DiagnosticsTiming.windowsTurn = .milliseconds(100)
        DiagnosticsTiming.windows = .milliseconds(200)
        DiagnosticsTiming.treeTurn = .milliseconds(100)
        DiagnosticsTiming.tree = .milliseconds(200)
        let result = try await collect(r.handler)
        let busy = "the UI helper is busy with other requests; retry\n"
        XCTAssertEqual(try read("windows.error.txt"), busy)
        XCTAssertEqual(try read("ui-tree.error.txt"), busy)
        XCTAssertEqual(agentRequests(r.agent, "win.list").count, 1)
        XCTAssertEqual(agentRequests(r.agent, "ui.tree").count, 0)
        for name in ["screenshot.png", "processes.json", "eventlog-application.json", "events.json", "doctor.json", "summary.txt"] {
            XCTAssertTrue(files(result).contains(name), name)
        }
        let summary = try XCTUnwrap(result["summary"]?.stringValue)
        XCTAssertTrue(summary.hasSuffix("steps that failed:\nwindows: the UI helper is busy with other requests; retry\nui-tree: the UI helper is busy with other requests; retry"), summary)
        holder.cancel()
    }

    func testUnansweredHelperCallNamesTheNextStep() async throws {
        let r = try await rig { $0.silent = ["win.list"] }
        DiagnosticsTiming.windows = .milliseconds(200)
        DiagnosticsTiming.windowsTurn = .milliseconds(100)
        DiagnosticsTiming.treeTurn = .milliseconds(100)
        DiagnosticsTiming.tree = .milliseconds(200)
        _ = try await collect(r.handler)
        XCTAssertEqual(try read("windows.error.txt"), "the UI helper in 'Win' did not answer vm.window.list within 0 s; run vm.doctor and retry\n")
        XCTAssertEqual(try read("ui-tree.error.txt"), "the UI helper is busy with other requests; retry\n")
    }

    func testStepWithoutAnswerEndsAtItsLimit() async throws {
        let r = try await rig { $0.silent = ["proc.list"] }
        DiagnosticsTiming.processes = .seconds(1)
        let result = try await collect(r.handler)
        XCTAssertEqual(try read("processes.error.txt"), "the processes step did not finish within 1 s; run vm.doctor to check the guest tools, then collect again\n")
        XCTAssertTrue(files(result).contains("windows.json"))
    }

    func testTimedStopsWaitingForWorkThatDoesNotEnd() async throws {
        let r = try await rig()
        let outcome = await r.handler.timed(.milliseconds(50)) { try await Task.sleep(for: .seconds(60)); return 1 }
        guard case .failure(let error) = outcome else { return XCTFail("expected a timeout") }
        XCTAssertTrue(error is DiagnosticsTimeout)
        let quick = await r.handler.timed(.seconds(30)) { 7 }
        XCTAssertEqual(try quick.get(), 7)
    }

    // MARK: - recording

    private func traceBytes(_ dir: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("trace.jsonl"))
    }

    func testRecordingInProgressCopiesWholeLinesAndKeepsRecording() async throws {
        let r = try await rig()
        let start = try await r.handler.handle(op: "vm.record.start", params: ["name": "Win", "video": false])
        let recording = try XCTUnwrap(start["dir"]?.stringValue)
        _ = try await r.handler.handle(op: "vm.status", params: ["name": "Win"])
        _ = try await r.handler.handle(op: "vm.list", params: [:])
        let trace = URL(fileURLWithPath: recording).appendingPathComponent("trace.jsonl")
        let handle = try FileHandle(forWritingTo: trace)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"seq\":99,\"op\":\"torn".utf8))
        try handle.close()
        let whole = try traceBytes(recording)
        XCTAssertFalse(whole.last == 0x0A)

        let result = try await collect(r.handler)
        let copied = try Data(contentsOf: bundleDirectory().appendingPathComponent("trace.jsonl"))
        XCTAssertFalse(copied.isEmpty)
        XCTAssertEqual(copied.last, 0x0A)
        XCTAssertFalse(String(decoding: copied, as: UTF8.self).contains("torn"))
        XCTAssertEqual(whole.prefix(copied.count), copied)
        XCTAssertTrue(files(result).contains("trace.jsonl"))
        XCTAssertFalse(files(result).contains("video.mp4"))

        let status = try await r.handler.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["recording"]?.boolValue, true)
        _ = try await r.handler.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertGreaterThan(try traceBytes(recording).count, whole.count)
        let stopped = try await r.handler.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stopped["dir"]?.stringValue, recording)
    }

    func testCollectingIsTracedAsAPlainOpLine() async throws {
        let r = try await rig()
        let start = try await r.handler.handle(op: "vm.record.start", params: ["name": "Win", "video": false])
        let recording = try XCTUnwrap(start["dir"]?.stringValue)
        _ = try await collect(r.handler)
        let lines = try String(decoding: traceBytes(recording), as: UTF8.self).split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }
        let line = try XCTUnwrap(lines.last { $0["op"]?.stringValue == "vm.collect_diagnostics" })
        XCTAssertNil(line["before"])
        XCTAssertNil(line["after"])
        XCTAssertNil(line["params"]?["lease"])
        XCTAssertEqual(line["ok"]?.boolValue, true)
        let copied = String(decoding: try Data(contentsOf: bundleDirectory().appendingPathComponent("trace.jsonl")), as: UTF8.self)
        XCTAssertFalse(copied.contains("vm.collect_diagnostics"))
    }

    func testRunningRecordingWithVideoWritesVideoErrorFile() async throws {
        let r = try await rig()
        _ = try await r.handler.handle(op: "vm.record.start", params: ["name": "Win"])
        let result = try await collect(r.handler)
        XCTAssertFalse(files(result).contains("video.mp4"))
        XCTAssertEqual(try read("video.error.txt"), "the recording is still running; call vm.record.stop and collect again for the video\n")
        XCTAssertTrue(files(result).contains("trace.jsonl"))
        let summary = try XCTUnwrap(result["summary"]?.stringValue)
        XCTAssertTrue(summary.contains("video: the recording is still running; call vm.record.stop and collect again for the video"), summary)
        let status = try await r.handler.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["recording"]?.boolValue, true)
        _ = try await r.handler.handle(op: "vm.record.stop", params: ["name": "Win"])
    }

    func testWholeLinesOfATraceFile() throws {
        let file = scratch.appendingPathComponent("t.jsonl")
        try Data("aaa\nbbb\nccc".utf8).write(to: file)
        XCTAssertEqual(String(decoding: try ControlHandler.wholeLines(of: file, limit: 1000), as: UTF8.self), "aaa\nbbb\n")
        try Data("aaa\nbbb\nccc\n".utf8).write(to: file)
        XCTAssertEqual(String(decoding: try ControlHandler.wholeLines(of: file, limit: 1000), as: UTF8.self), "aaa\nbbb\nccc\n")
        XCTAssertEqual(String(decoding: try ControlHandler.wholeLines(of: file, limit: 6), as: UTF8.self), "ccc\n")
        XCTAssertEqual(String(decoding: try ControlHandler.wholeLines(of: file, limit: 2), as: UTF8.self), "")
        try Data("partial".utf8).write(to: file)
        XCTAssertEqual(try ControlHandler.wholeLines(of: file, limit: 1000), Data())
    }

    func testNoRecordingNeedsNoTraceFiles() async throws {
        let r = try await rig()
        let result = try await collect(r.handler)
        XCTAssertFalse(files(result).contains("trace.jsonl"))
        XCTAssertTrue(try XCTUnwrap(result["summary"]?.stringValue).contains("no recording is active"))
    }

    // MARK: - the session stays as it is

    func testCollectingMovesNoEventPosition() async throws {
        let r = try await rig()
        _ = try await r.handler.handle(op: "vm.type", params: ["name": "Win", "text": "a"])
        let positions = await r.handler.eventPositions(of: "Win")
        let before = await r.target.events(since: 0)
        let events = try await r.handler.handle(op: "vm.events", params: ["name": "Win"])
        let result = try await collect(r.handler)
        XCTAssertNil(result["eventSeq"])
        let afterPositions = await r.handler.eventPositions(of: "Win")
        XCTAssertEqual(afterPositions.baseline, positions.baseline)
        XCTAssertEqual(afterPositions.observed, positions.observed)
        let after = await r.target.events(since: 0)
        XCTAssertEqual(after.next, before.next)
        let written = try JSON.parse(Data(contentsOf: bundleDirectory().appendingPathComponent("events.json")))
        XCTAssertEqual(written["next"], events["next"])
        XCTAssertEqual(written["first"], events["first"])
    }

    func testClassification() {
        let op = "vm.collect_diagnostics"
        XCTAssertTrue(ControlHandler.knownOps.contains(op))
        XCTAssertTrue(ControlHandler.isReadOnly(op: op))
        XCTAssertTrue(ControlHandler.isConcurrent(op: op))
        XCTAssertFalse(ControlHandler.isInput(op: op))
        XCTAssertFalse(ControlHandler.capturesFrames(op: op))
        XCTAssertFalse(ControlHandler.movesEventBaseline(op: op))
    }

    func testNeedsNoLease() async throws {
        let r = try await rig()
        _ = try await r.handler.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "someone-else", "ttl": 60])
        let result = try await collect(r.handler)
        XCTAssertTrue(files(result).contains("summary.txt"))
    }

    // MARK: - directory and parameters

    func testDirMustBeAbsoluteAndEmpty() async throws {
        let r = try await rig()
        let relative = await failure(r.handler, ["name": "Win", "dir": "relative/path"])
        XCTAssertEqual(relative, "dir must be an absolute path")

        let full = bundleDirectory("full")
        try FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: full.appendingPathComponent("keep.txt"))
        let refused = await failure(r.handler, ["name": "Win", "dir": .string(full.path)])
        XCTAssertEqual(refused, "'\(full.path)' is not empty; choose a directory that is missing or empty, or leave dir out for a new folder")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: full.path), ["keep.txt"])

        let file = scratch.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        let notADirectory = await failure(r.handler, ["name": "Win", "dir": .string(file.path)])
        XCTAssertEqual(notADirectory, "'\(file.path)' is a file; choose a directory that is missing or empty")
        XCTAssertEqual(agentRequests(r.agent, "win.list").count, 0)
    }

    func testDirIsCreatedOrReusedWhenEmpty() async throws {
        let r = try await rig()
        let nested = scratch.appendingPathComponent("a/b/c")
        let created = try await collect(r.handler, dir: nested)
        XCTAssertEqual(created["dir"]?.stringValue, nested.path)
        XCTAssertTrue(exists("summary.txt", in: nested))

        let empty = bundleDirectory("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let reused = try await collect(r.handler, dir: empty)
        XCTAssertEqual(reused["dir"]?.stringValue, empty.path)
        let dotted = try await collect(r.handler, dir: scratch.appendingPathComponent("x/../y"))
        XCTAssertEqual(dotted["dir"]?.stringValue, scratch.appendingPathComponent("y").path)
    }

    func testDefaultDirIsAFreshFolderNamedAfterTheVM() async throws {
        let r = try await rig()
        let first = try await r.handler.handle(op: "vm.collect_diagnostics", params: ["name": "Win"])
        let second = try await r.handler.handle(op: "vm.collect_diagnostics", params: ["name": "Win"])
        let a = try XCTUnwrap(first["dir"]?.stringValue), b = try XCTUnwrap(second["dir"]?.stringValue)
        XCTAssertNotEqual(a, b)
        for dir in [a, b] {
            XCTAssertEqual(URL(fileURLWithPath: dir).deletingLastPathComponent().path, scratch.appendingPathComponent("diagnostics").path)
            XCTAssertTrue(URL(fileURLWithPath: dir).lastPathComponent.hasPrefix("Win-"), dir)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/summary.txt"))
        }
    }

    func testParameterValidation() async throws {
        let r = try await rig()
        let cases: [([String: JSON], String)] = [
            (["sinceMinutes": 0], "sinceMinutes must be between 1 and 5256000"),
            (["sinceMinutes": "soon"], "parameter 'sinceMinutes' must be an integer"),
            (["logFiles": "a.log"], "logFiles must be a list of 1 to 20 guest file paths"),
            (["logFiles": [1]], "logFiles must be a list of 1 to 20 guest file paths"),
            (["logFiles": [""]], "logFiles must be a list of 1 to 20 guest file paths"),
            (["logFiles": .array((0...20).map { JSON.string("/l/\($0).log") })], "logFiles must be a list of 1 to 20 guest file paths"),
            (["processName": ""], "processName must be a program name such as MyApp.exe"),
            (["processName": 3], "processName must be a program name such as MyApp.exe"),
        ]
        for (extra, message) in cases {
            var params: [String: JSON] = ["name": "Win", "dir": .string(bundleDirectory().path)]
            for (key, value) in extra { params[key] = value }
            let text = await failure(r.handler, .object(params))
            XCTAssertEqual(text, message, "\(extra)")
        }
        XCTAssertFalse(exists("summary.txt"))
        let unknown = await failure(r.handler, ["name": "Nope"])
        XCTAssertEqual(unknown, "no VM named 'Nope'; call vm.list")
    }
}
