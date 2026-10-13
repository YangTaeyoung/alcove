import XCTest
import CryptoKit
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class GuestEvidenceTests: XCTestCase {
    private func setup(os: VMConfig.GuestOS = .windows, fs: FakeFS? = nil, stdout: String = "", code: Int = 0, stderr: String = "")
        async throws -> (ControlHandler, FakeAgent) {
        let agent = FakeAgent()
        fs?.install(on: agent)
        let files = agent.handler
        agent.handler = { m, a in
            if m["t"]?.stringValue == "req", m["op"]?.stringValue == "exec.run" {
                return [agentReply(m, ["code": .int(Int64(code)), "stdout": .string(stdout), "stderr": .string(stderr), "timed_out": false])]
            }
            return files?(m, a) ?? []
        }
        let (h, t) = try await handlerWithAgent(agent, in: self)
        await t.setOS(os)
        return (h, agent)
    }

    private func commands(_ agent: FakeAgent) -> [String] {
        agentRequests(agent, "exec.run").compactMap { $0["cmd"]?.stringValue }
    }

    private func failure(_ h: ControlHandler, _ op: String, _ params: JSON) async -> String {
        do { _ = try await h.handle(op: op, params: params); return "no error" } catch { return "\(error)" }
    }

    private let entry = "{\"time\":\"2026-10-13T09:30:00.1234567Z\",\"id\":1000,\"level\":\"error\",\"provider\":\"Application Error\",\"message\":\"Faulting application MyApp.exe\"}"

    // MARK: - vm.event_log

    func testEventLogMapsEntries() async throws {
        let second = "{\"time\":\"2026-10-13T09:29:00.0000000Z\",\"id\":1001,\"level\":\"warning\",\"provider\":\"Windows Error Reporting\",\"message\":\"Fault bucket\"}"
        let (h, agent) = try await setup(stdout: "{\"entries\":[\(entry),\(second)],\"truncated\":false}\r\n")
        let r = try await h.handle(op: "vm.event_log", params: ["name": "Win"])
        XCTAssertEqual(r["entries"]?.arrayValue?.count, 2)
        XCTAssertEqual(r["entries"]?[0]?["id"]?.intValue, 1000)
        XCTAssertEqual(r["entries"]?[0]?["level"]?.stringValue, "error")
        XCTAssertEqual(r["entries"]?[0]?["provider"]?.stringValue, "Application Error")
        XCTAssertEqual(r["entries"]?[1]?["message"]?.stringValue, "Fault bucket")
        XCTAssertNil(r["truncated"])
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("'Application'"), script)
        XCTAssertTrue(script.contains("AddMinutes(-60)"), script)
        XCTAssertTrue(script.contains("-First 50"), script)
        XCTAssertFalse(script.contains("$filter.Level"), script)
    }

    func testEventLogAcceptsAPlainArray() async throws {
        let (h, _) = try await setup(stdout: "[\(entry)]")
        let r = try await h.handle(op: "vm.event_log", params: ["name": "Win"])
        XCTAssertEqual(r["entries"]?.arrayValue?.count, 1)
    }

    func testEventLogSingleObjectResult() async throws {
        let (h, _) = try await setup(stdout: entry)
        let r = try await h.handle(op: "vm.event_log", params: ["name": "Win"])
        XCTAssertEqual(r["entries"]?.arrayValue?.count, 1)
        XCTAssertEqual(r["entries"]?[0]?["id"]?.intValue, 1000)
    }

    func testEventLogEmpty() async throws {
        for output in ["", "[]", "{\"entries\":[],\"truncated\":false}"] {
            let (h, _) = try await setup(stdout: output)
            let r = try await h.handle(op: "vm.event_log", params: ["name": "Win"])
            XCTAssertEqual(r, ["entries": []], output)
        }
    }

    func testEventLogCutsMessagesAndReportsTruncation() async throws {
        let long = String(repeating: "x", count: 2500)
        let (h, _) = try await setup(stdout: "{\"entries\":[{\"time\":\"t\",\"id\":1,\"level\":\"info\",\"provider\":\"p\",\"message\":\"\(long)\"}],\"truncated\":true}")
        let r = try await h.handle(op: "vm.event_log", params: ["name": "Win"])
        XCTAssertEqual(r["entries"]?[0]?["message"]?.stringValue?.count, 2000)
        XCTAssertEqual(r["truncated"]?.boolValue, true)
    }

    func testEventLogLevelMapping() async throws {
        let expected = ["critical": "1", "error": "1,2", "warning": "1,2,3", "info": "1,2,3,4"]
        for (level, levels) in expected {
            let (h, agent) = try await setup(stdout: "[]")
            _ = try await h.handle(op: "vm.event_log", params: ["name": "Win", "level": .string(level)])
            let script = try XCTUnwrap(commands(agent).first)
            XCTAssertTrue(script.contains("$filter.Level = @(\(levels))"), "\(level): \(script)")
        }
    }

    func testEventLogParametersReachTheScript() async throws {
        let (h, agent) = try await setup(stdout: "[]")
        _ = try await h.handle(op: "vm.event_log", params: ["name": "Win", "log": "System", "provider": "Disk", "sinceMinutes": 5,
                                                            "contains": "bad block", "max": 7])
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("'System'"), script)
        XCTAssertTrue(script.contains("$filter.ProviderName = 'Disk'"), script)
        XCTAssertTrue(script.contains("AddMinutes(-5)"), script)
        XCTAssertTrue(script.contains("'bad block'"), script)
        XCTAssertTrue(script.contains("-First 7"), script)
    }

    func testEventLogQuotesCallerText() async throws {
        let (h, agent) = try await setup(stdout: "[]")
        let hostile = "it's $(evil) `x`\n\u{2019}; Remove-Item *"
        _ = try await h.handle(op: "vm.event_log", params: ["name": "Win", "provider": .string(hostile), "contains": .string(hostile)])
        let script = try XCTUnwrap(commands(agent).first)
        let quoted = GuestRecipes.quote(hostile, os: .windows)
        XCTAssertEqual(script.components(separatedBy: quoted).count - 1, 2, script)
        XCTAssertTrue(quoted.hasPrefix("'it''s"), quoted)
    }

    func testEventLogValidation() async throws {
        let (h, agent) = try await setup(stdout: "[]")
        let logMessage = "log must be a plain log name such as Application, System or Microsoft-Windows-PowerShell/Operational"
        let maxMessage = "max must be between 1 and 500; pass a smaller number or narrow with level, provider or contains"
        let cases: [(JSON, String)] = [
            (["log": "Sys;tem"], logMessage),
            (["log": ""], logMessage),
            (["level": "fatal"], "level must be one of critical, error, warning, info"),
            (["max": 0], maxMessage),
            (["max": 501], maxMessage),
            (["sinceMinutes": 0], "sinceMinutes must be between 1 and 5256000"),
            (["max": "many"], "parameter 'max' must be an integer"),
            (["contains": ""], "contains must not be empty; leave it out to read all entries"),
        ]
        for (extra, message) in cases {
            var params: [String: JSON] = ["name": "Win"]
            for (k, v) in extra.objectValue ?? [:] { params[k] = v }
            let text = await failure(h, "vm.event_log", .object(params))
            XCTAssertEqual(text, message, "\(extra)")
        }
        XCTAssertEqual(commands(agent), [])
    }

    func testEventLogOnLinuxReadsTheJournal() async throws {
        let line = "{\"__REALTIME_TIMESTAMP\":\"1800000000123456\",\"PRIORITY\":\"3\",\"SYSLOG_IDENTIFIER\":\"myapp\",\"_PID\":\"412\",\"MESSAGE\":\"segfault at 0\"}"
        let noise = "{\"__REALTIME_TIMESTAMP\":\"1800000001000000\",\"PRIORITY\":\"6\",\"_COMM\":\"cron\",\"MESSAGE\":[104,105]}"
        let (h, agent) = try await setup(os: .linux, stdout: line + "\n" + noise + "\npartial{")
        let r = try await h.handle(op: "vm.event_log", params: ["name": "Win", "level": "error", "provider": "myapp", "sinceMinutes": 10, "contains": "a.b", "max": 20])
        XCTAssertEqual(r["entries"]?.arrayValue?.count, 2)
        XCTAssertEqual(r["entries"]?[0]?["time"]?.stringValue, "2027-01-15T08:00:00.123Z")
        XCTAssertEqual(r["entries"]?[0]?["level"]?.stringValue, "error")
        XCTAssertEqual(r["entries"]?[0]?["provider"]?.stringValue, "myapp")
        XCTAssertEqual(r["entries"]?[0]?["id"]?.intValue, 412)
        XCTAssertEqual(r["entries"]?[0]?["message"]?.stringValue, "segfault at 0")
        XCTAssertEqual(r["entries"]?[1]?["level"]?.stringValue, "info")
        XCTAssertEqual(r["entries"]?[1]?["provider"]?.stringValue, "cron")
        XCTAssertEqual(r["entries"]?[1]?["message"]?.stringValue, "hi")
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("journalctl -o json"), script)
        XCTAssertTrue(script.contains("-p 3"), script)
        XCTAssertTrue(script.contains("-t 'myapp'"), script)
        XCTAssertTrue(script.contains("--since=-10min"), script)
        XCTAssertTrue(script.contains("--grep='a\\.b'"), script)
        XCTAssertTrue(script.contains("-n 20"), script)
    }

    func testEventLogFailureNamesTheNextStep() async throws {
        let (h, _) = try await setup(stdout: "", code: 1, stderr: "the guest has no event log named 'Nope'; list logs with Get-WinEvent -ListLog *")
        let text = await failure(h, "vm.event_log", ["name": "Win", "log": "Nope"])
        XCTAssertEqual(text, "the guest has no event log named 'Nope'; list logs with Get-WinEvent -ListLog *")
        let (h2, _) = try await setup(stdout: "not json")
        let bad = await failure(h2, "vm.event_log", ["name": "Win"])
        XCTAssertEqual(bad, "the guest printed no event log JSON; run vm.doctor to check the guest shell")
    }

    // MARK: - crash dumps

    func testEnableDumpsWritesKeysForExe() async throws {
        let (h, agent) = try await setup(stdout: "{\"folder\":\"C:\\\\alcove-dumps\"}")
        let r = try await h.handle(op: "vm.crash_dumps.enable", params: ["name": "Win", "exe": "My App.exe"])
        XCTAssertEqual(r, ["folder": "C:\\alcove-dumps"])
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("Windows Error Reporting\\LocalDumps\\' + 'My App.exe'"), script)
        XCTAssertTrue(script.contains("C:\\alcove-dumps"), script)
        XCTAssertTrue(script.contains("SetValue('DumpFolder'"), script)
        XCTAssertTrue(script.contains("ExpandString"), script)
        XCTAssertTrue(script.contains("SetValue('DumpCount', 5,"), script)
        XCTAssertTrue(script.contains("SetValue('DumpType', 1,"), script)
        let full = try await setup(stdout: "{\"folder\":\"C:\\\\alcove-dumps\"}")
        _ = try await full.0.handle(op: "vm.crash_dumps.enable", params: ["name": "Win", "exe": "a.exe", "full": true])
        XCTAssertTrue(try XCTUnwrap(commands(full.1).first).contains("SetValue('DumpType', 2,"))
    }

    func testDisableDumpsRemovesOnlyThatImage() async throws {
        let (h, agent) = try await setup()
        let r = try await h.handle(op: "vm.crash_dumps.disable", params: ["name": "Win", "exe": "MyApp.exe"])
        XCTAssertEqual(r, [:])
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("LocalDumps\\' + 'MyApp.exe'"), script)
        XCTAssertTrue(script.contains("DeleteSubKeyTree"), script)
    }

    func testExeValidation() async throws {
        let (h, agent) = try await setup()
        let message = "exe must be an image name such as MyApp.exe: no folder, ends with .exe, no characters that a Windows file name cannot hold"
        for exe in ["C:\\apps\\MyApp.exe", "dir/MyApp.exe", "MyApp", "MyApp.exe ", ".exe", "a*.exe", "a:b.exe", "a\"b.exe", "a\nb.exe", "x.exe.txt", ""] {
            for op in ["vm.crash_dumps.enable", "vm.crash_dumps.disable"] {
                let text = await failure(h, op, ["name": "Win", "exe": .string(exe)])
                XCTAssertEqual(text, message, "\(op) \(exe)")
            }
        }
        let missing = await failure(h, "vm.crash_dumps.enable", ["name": "Win"])
        XCTAssertEqual(missing, "missing or invalid parameter 'exe'")
        XCTAssertEqual(commands(agent), [])
    }

    func testDumpList() async throws {
        let (h, agent) = try await setup(stdout: "[{\"file\":\"MyApp.exe.4242.dmp\",\"exe\":\"MyApp.exe\",\"bytes\":1048576,\"time\":\"2026-10-13T09:30:00.0000000Z\"}]")
        let r = try await h.handle(op: "vm.crash_dumps.list", params: ["name": "Win"])
        XCTAssertEqual(r["dumps"]?[0]?["file"]?.stringValue, "MyApp.exe.4242.dmp")
        XCTAssertEqual(r["dumps"]?[0]?["exe"]?.stringValue, "MyApp.exe")
        XCTAssertEqual(r["dumps"]?[0]?["bytes"]?.intValue, 1_048_576)
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("Test-Path -LiteralPath $folder"), script)
        XCTAssertTrue(script.contains("-Filter *.dmp"), script)
        let single = try await setup(stdout: "{\"file\":\"a.exe.1.dmp\",\"exe\":\"a.exe\",\"bytes\":9,\"time\":\"t\"}")
        let one = try await single.0.handle(op: "vm.crash_dumps.list", params: ["name": "Win"])
        XCTAssertEqual(one["dumps"]?.arrayValue?.count, 1)
    }

    func testDumpListWithoutFolder() async throws {
        for output in ["", "[]"] {
            let (h, _) = try await setup(stdout: output)
            let r = try await h.handle(op: "vm.crash_dumps.list", params: ["name": "Win"])
            XCTAssertEqual(r, ["dumps": []], output)
        }
    }

    func testDumpPullUsesFileOps() async throws {
        let fs = FakeFS()
        let payload = Data((0..<300_000).map { UInt8($0 % 241) })
        fs["C:\\alcove-dumps\\MyApp.exe.4242.dmp"] = payload
        let (h, agent) = try await setup(fs: fs)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dumps-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("out.dmp")
        let r = try await h.handle(op: "vm.crash_dumps.pull", params: ["name": "Win", "file": "MyApp.exe.4242.dmp", "path": .string(dest.path)])
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(r, ["path": .string(dest.path), "bytes": 300_000, "sha256": .string(digest)])
        XCTAssertEqual(try Data(contentsOf: dest), payload)
        XCTAssertEqual(commands(agent), [])
        XCTAssertEqual(agentRequests(agent, "fs.stat").first?["path"]?.stringValue, "C:\\alcove-dumps\\MyApp.exe.4242.dmp")

        let absent = await failure(h, "vm.crash_dumps.pull", ["name": "Win", "file": "gone.exe.1.dmp", "path": .string(dest.path)])
        XCTAssertEqual(absent, "'C:\\alcove-dumps\\gone.exe.1.dmp' is not a file in the guest; check the path")
        let noPath = await failure(h, "vm.crash_dumps.pull", ["name": "Win", "file": "MyApp.exe.4242.dmp"])
        XCTAssertEqual(noPath, "missing or invalid parameter 'path'")
    }

    func testDumpPullRefusesOtherFiles() async throws {
        let (h, agent) = try await setup(fs: FakeFS())
        let message = "file must be the name of a .dmp file listed by vm.crash_dumps.list, without a folder"
        for file in ["..\\Windows\\win.ini", "../x.dmp", "C:\\alcove-dumps\\a.dmp", "sub/a.dmp", "..", "a.dmp:stream", "a.txt", ".dmp", "a\\..\\b.dmp", ""] {
            let text = await failure(h, "vm.crash_dumps.pull", ["name": "Win", "file": .string(file), "path": "/tmp/x.dmp"])
            XCTAssertEqual(text, message, file)
        }
        XCTAssertEqual(agentRequests(agent, "fs.stat").count, 0)
    }

    func testDumpsOnLinux() async throws {
        let (h, agent) = try await setup(os: .linux)
        let message = "crash dumps are only collected on Windows guests"
        let calls: [(String, JSON)] = [
            ("vm.crash_dumps.enable", ["name": "Win", "exe": "a.exe"]),
            ("vm.crash_dumps.disable", ["name": "Win", "exe": "a.exe"]),
            ("vm.crash_dumps.list", ["name": "Win"]),
            ("vm.crash_dumps.pull", ["name": "Win", "file": "a.exe.1.dmp", "path": "/tmp/a.dmp"]),
        ]
        for (op, params) in calls {
            let text = await failure(h, op, params)
            XCTAssertEqual(text, message, op)
        }
        XCTAssertEqual(commands(agent), [])
        XCTAssertEqual(agentRequests(agent, "fs.stat").count, 0)
    }

    func testRecipesForDumpsExistOnlyForWindows() {
        XCTAssertNil(GuestRecipes.enableDumps(exe: "a.exe", full: false, os: .linux))
        XCTAssertNil(GuestRecipes.disableDumps(exe: "a.exe", os: .other))
        XCTAssertNil(GuestRecipes.listDumps(os: .linux))
        XCTAssertNotNil(GuestRecipes.eventLog(log: "Application", level: nil, provider: nil, sinceMinutes: 60, contains: nil, max: 50, os: .linux))
        XCTAssertNil(GuestRecipes.eventLog(log: "Application", level: nil, provider: nil, sinceMinutes: 60, contains: nil, max: 50, os: .other))
    }

    func testEvidenceOpsNeedExecAndAreClassified() async throws {
        let agent = FakeAgent()
        agent.caps = ["fs"]
        let (h, _) = try await handlerWithAgent(agent, in: self)
        for (op, params) in [("vm.event_log", ["name": "Win"] as JSON), ("vm.crash_dumps.list", ["name": "Win"]),
                             ("vm.crash_dumps.enable", ["name": "Win", "exe": "a.exe"])] {
            let text = await failure(h, op, params)
            XCTAssertEqual(text, "guest tools in 'Win' do not allow running commands; start alcove-agent with --allow-exec", op)
        }
        let ops = ["vm.event_log", "vm.crash_dumps.enable", "vm.crash_dumps.disable", "vm.crash_dumps.list", "vm.crash_dumps.pull"]
        for op in ops { XCTAssertTrue(ControlHandler.knownOps.contains(op), op) }
        XCTAssertTrue(ControlHandler.isReadOnly(op: "vm.event_log"))
        XCTAssertTrue(ControlHandler.isReadOnly(op: "vm.crash_dumps.list"))
        XCTAssertFalse(ControlHandler.isReadOnly(op: "vm.crash_dumps.enable"))
        XCTAssertFalse(ControlHandler.isReadOnly(op: "vm.crash_dumps.disable"))
        XCTAssertTrue(ControlHandler.isReadOnly(op: "vm.crash_dumps.pull"))
        XCTAssertTrue(ControlHandler.isConcurrent(op: "vm.crash_dumps.pull"))
        XCTAssertFalse(ControlHandler.isConcurrent(op: "vm.event_log"))
    }
}
