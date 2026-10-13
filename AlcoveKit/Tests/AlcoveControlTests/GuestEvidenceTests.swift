import XCTest
import CryptoKit
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class GuestEvidenceTests: XCTestCase {
    private func setup(os: VMConfig.GuestOS = .windows, fs: FakeFS? = nil, stdout: String = "", code: Int = 0, stderr: String = "",
                       truncated: Bool = false, timedOut: Bool = false, staleDigest: Bool = false, statError: String? = nil)
        async throws -> (ControlHandler, FakeAgent) {
        let agent = FakeAgent()
        fs?.install(on: agent)
        let files = agent.handler
        agent.handler = { m, a in
            if m["t"]?.stringValue == "req", m["op"]?.stringValue == "exec.run" {
                return [agentReply(m, ["code": .int(Int64(code)), "stdout": .string(stdout), "stderr": .string(stderr), "timed_out": .bool(timedOut), "truncated": .bool(truncated)])]
            }
            if let statError, m["op"]?.stringValue == "fs.stat" {
                return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": .string(statError)]]
            }
            let replies = files?(m, a) ?? []
            guard staleDigest, m["op"]?.stringValue == "fs.stat" else { return replies }
            return replies.map { reply in
                guard case .object(var o) = reply else { return reply }
                o["sha256"] = .string(String(repeating: "0", count: 64))
                return .object(o)
            }
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
        XCTAssertTrue(script.contains("Get-WinEvent -LogName $log -FilterXPath $query -ErrorAction SilentlyContinue"), script)
        XCTAssertTrue(script.contains("TimeCreated[@SystemTime>='"), script)
        XCTAssertFalse(script.contains("Level="), script)
        XCTAssertFalse(script.contains("$provider"), script)
        XCTAssertTrue(script.contains("-gt 150000"), script)
        XCTAssertTrue(script.contains("ConvertTo-Json -Compress -Depth 3"), script)
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
        let expected = ["critical": " and (Level=1)", "error": " and (Level=1 or Level=2)", "warning": " and (Level=1 or Level=2 or Level=3)"]
        for (level, clause) in expected {
            let (h, agent) = try await setup(stdout: "[]")
            _ = try await h.handle(op: "vm.event_log", params: ["name": "Win", "level": .string(level)])
            let script = try XCTUnwrap(commands(agent).first)
            XCTAssertTrue(script.contains("']\(clause)\""), "\(level): \(script)")
        }
    }

    func testEventLogLevelInfoReadsEveryLevel() async throws {
        let (h, agent) = try await setup(stdout: "[]")
        _ = try await h.handle(op: "vm.event_log", params: ["name": "Win", "level": "info"])
        XCTAssertFalse(try XCTUnwrap(commands(agent).first).contains("Level="))
    }

    func testEventLogParametersReachTheScript() async throws {
        let (h, agent) = try await setup(stdout: "[]")
        _ = try await h.handle(op: "vm.event_log", params: ["name": "Win", "log": "System", "provider": "Disk", "sinceMinutes": 5,
                                                            "contains": "bad block", "max": 7])
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("'System'"), script)
        XCTAssertTrue(script.contains("$provider = 'Disk'\n"), script)
        XCTAssertTrue(script.contains(" and Provider[@Name='\" + $provider + \"']"), script)
        XCTAssertFalse(script.contains("$_.ProviderName"), script)
        XCTAssertTrue(script.contains("AddMinutes(-5)"), script)
        XCTAssertTrue(script.contains("'bad block'"), script)
        XCTAssertTrue(script.contains("-First 7"), script)
    }

    func testEventLogProviderWithAnApostropheIsMatchedInThePipeline() async throws {
        let (h, agent) = try await setup(stdout: "[]")
        _ = try await h.handle(op: "vm.event_log", params: ["name": "Win", "provider": "Bob's App"])
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("$provider = 'Bob''s App'\n"), script)
        XCTAssertTrue(script.contains("| Where-Object { $_.ProviderName -eq $provider } | Select-Object -First 50"), script)
        XCTAssertFalse(script.contains("Provider[@Name="), script)
    }

    func testEventLogEntriesAreNewestFirst() async throws {
        func row(_ time: String, _ id: Int) -> String {
            "{\"time\":\"\(time)\",\"id\":\(id),\"level\":\"info\",\"provider\":\"p\",\"message\":\"\"}"
        }
        let rows = [row("2026-10-13T22:06:57.3595543Z", 6000), row("2026-10-13T22:06:56.3934525Z", 5615),
                    row("2026-10-13T22:06:56.5844096Z", 6003), row("2026-10-13T22:06:56.5844096Z", 6004),
                    row("2026-10-13T22:06:55.4163154Z", 1531)]
        let (h, _) = try await setup(stdout: "{\"entries\":[\(rows.joined(separator: ","))],\"truncated\":false}")
        let r = try await h.handle(op: "vm.event_log", params: ["name": "Win"])
        XCTAssertEqual(r["entries"]?.arrayValue?.compactMap { $0["id"]?.intValue }, [6000, 6003, 6004, 5615, 1531])
    }

    func testEventLogCutsAMessageBeforeASplitSurrogatePair() async throws {
        let (h, agent) = try await setup(stdout: "[]")
        _ = try await h.handle(op: "vm.event_log", params: ["name": "Win"])
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("if ([char]::IsHighSurrogate($m[$cut - 1])) { $cut = $cut - 1 }"), script)
        XCTAssertTrue(script.contains("$cut = 2000\n"), script)
    }

    func testEventLogReadFailureSentenceComesFromTheScript() async throws {
        let sentence = "could not read the event log 'Security': Attempted to perform an unauthorized operation.; check that alcove-agent runs elevated, or read the log with vm.exec"
        let (h, agent) = try await setup(stdout: "", code: 2, stderr: sentence + "\r\n")
        let text = await failure(h, "vm.event_log", ["name": "Win", "log": "Security"])
        XCTAssertEqual(text, sentence)
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("} catch {\n  [Console]::Error.WriteLine(\"could not read the event log '$log': \" + ($_.Exception.GetBaseException().Message -replace '\\s+', ' ') + '; check that alcove-agent runs elevated, or read the log with vm.exec')\n  exit 2\n}"), script)
    }

    func testEventLogRefusesTextTheGuestShellCannotTake() async throws {
        let (h, agent) = try await setup(stdout: "[]")
        let long = String(repeating: "x", count: 1001)
        let cases: [(JSON, String)] = [
            (["contains": "a\u{0}b"], "contains must not hold a NUL character; remove it"),
            (["provider": "a\u{0}b"], "provider must not hold a NUL character; remove it"),
            (["contains": .string(long)], "contains must be at most 1000 characters; pass a shorter part of the message"),
            (["provider": .string(long)], "provider must be at most 1000 characters; pass the provider name as the entries show it"),
        ]
        for (extra, message) in cases {
            var params: [String: JSON] = ["name": "Win"]
            for (k, v) in extra.objectValue ?? [:] { params[k] = v }
            let text = await failure(h, "vm.event_log", .object(params))
            XCTAssertEqual(text, message)
        }
        XCTAssertEqual(commands(agent), [])
        _ = try await h.handle(op: "vm.event_log", params: ["name": "Win", "contains": .string(String(repeating: "x", count: 1000))])
        XCTAssertEqual(commands(agent).count, 1)
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
        let newer = "{\"__REALTIME_TIMESTAMP\":\"1800000001000000\",\"PRIORITY\":\"6\",\"_COMM\":\"cron\",\"MESSAGE\":[104,105]}"
        let (h, agent) = try await setup(os: .linux, stdout: "{\"__REALTIME_TIMESTAMP\":\"17999\npartial\n" + line + "\n" + newer + "\n")
        let r = try await h.handle(op: "vm.event_log", params: ["name": "Win", "level": "error", "provider": "myapp", "sinceMinutes": 10, "contains": "a.b", "max": 20])
        XCTAssertEqual(r["entries"]?.arrayValue?.count, 2)
        XCTAssertEqual(r["entries"]?[0]?["level"]?.stringValue, "info")
        XCTAssertEqual(r["entries"]?[0]?["provider"]?.stringValue, "cron")
        XCTAssertEqual(r["entries"]?[0]?["message"]?.stringValue, "hi")
        XCTAssertEqual(r["entries"]?[1]?["time"]?.stringValue, "2027-01-15T08:00:00.123Z")
        XCTAssertEqual(r["entries"]?[1]?["level"]?.stringValue, "error")
        XCTAssertEqual(r["entries"]?[1]?["provider"]?.stringValue, "myapp")
        XCTAssertEqual(r["entries"]?[1]?["id"]?.intValue, 412)
        XCTAssertEqual(r["entries"]?[1]?["message"]?.stringValue, "segfault at 0")
        XCTAssertNil(r["truncated"])
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("journalctl -o json"), script)
        XCTAssertFalse(script.contains(" -r "), script)
        XCTAssertTrue(script.contains("-p 3"), script)
        XCTAssertTrue(script.contains("-t 'myapp'"), script)
        XCTAssertTrue(script.contains("--since=-10min"), script)
        XCTAssertTrue(script.contains("--grep='a\\.b'"), script)
        XCTAssertTrue(script.contains("-n 20"), script)
    }

    func testEventLogOnLinuxKeepsTheNewestEntriesWhenOutputIsCut() async throws {
        func row(_ micros: Int, _ text: String) -> String {
            "{\"__REALTIME_TIMESTAMP\":\"\(micros)\",\"PRIORITY\":\"3\",\"MESSAGE\":\"\(text)\"}"
        }
        let (h, _) = try await setup(os: .linux, stdout: "ncated tail\"}\n" + row(1_800_000_001_000_000, "b") + "\n" + row(1_800_000_002_000_000, "c") + "\n", truncated: true)
        let r = try await h.handle(op: "vm.event_log", params: ["name": "Win", "max": 2])
        XCTAssertEqual(r["entries"]?.arrayValue?.compactMap { $0["message"]?.stringValue }, ["c", "b"])
        XCTAssertEqual(r["truncated"]?.boolValue, true)
    }

    func testEventLogCutByTheAgentNamesTheNextStep() async throws {
        let (h, _) = try await setup(stdout: "ries\":[{\"time\":\"t\"}],\"truncated\":false}", truncated: true)
        let text = await failure(h, "vm.event_log", ["name": "Win"])
        XCTAssertEqual(text, "the guest output was cut before the host read it; pass a smaller max or a narrower sinceMinutes")
    }

    func testEventLogTimeoutNamesTheNextStep() async throws {
        let (h, _) = try await setup(stdout: "", code: -1, timedOut: true)
        let text = await failure(h, "vm.event_log", ["name": "Win"])
        XCTAssertEqual(text, "the guest took more than 60 s to read the event log; narrow it with level, provider, contains or a smaller sinceMinutes")
    }

    func testEventLogOnAnOldJournalctlNamesTheNextStep() async throws {
        let (h, _) = try await setup(os: .linux, stdout: "", code: 1, stderr: "journalctl: unrecognized option '--output-fields=PRIORITY'")
        let text = await failure(h, "vm.event_log", ["name": "Win"])
        XCTAssertEqual(text, "journalctl in the guest is too old for these filters; read the logs with vm.exec instead")
    }

    func testUnknownLogSentenceComesFromTheScript() async throws {
        let (h, agent) = try await setup(stdout: "", code: 2, stderr: "the guest has no event log named 'Nope'; list the logs with Get-WinEvent -ListLog *\r\n")
        let text = await failure(h, "vm.event_log", ["name": "Win", "log": "Nope"])
        XCTAssertEqual(text, "the guest has no event log named 'Nope'; list the logs with Get-WinEvent -ListLog *")
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("[Console]::Error.WriteLine(\"the guest has no event log named '$log'; list the logs with Get-WinEvent -ListLog *\"); exit 2"), script)
    }

    func testLogTheGuestToolsMayNotReadSentenceComesFromTheScript() async throws {
        let sentence = "guest tools may not read the event log 'Security'; check that alcove-agent runs elevated"
        let (h, agent) = try await setup(stdout: "", code: 2, stderr: sentence + "\r\n")
        let text = await failure(h, "vm.event_log", ["name": "Win", "log": "Security"])
        XCTAssertEqual(text, sentence)
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("-ErrorVariable listErrors"), script)
        XCTAssertTrue(script.contains("if ($listErrors | Where-Object { $_.FullyQualifiedErrorId -like 'LogInfoUnavailable*' }) { [Console]::Error.WriteLine(\"guest tools may not read the event log '$log'; check that alcove-agent runs elevated\"); exit 2 }"), script)
    }

    func testEventLogOutputThatIsNoJSONIsAnError() async throws {
        let (h, _) = try await setup(stdout: "not json")
        let bad = await failure(h, "vm.event_log", ["name": "Win"])
        XCTAssertEqual(bad, "the guest printed no event log JSON; run vm.doctor to check the guest shell")
    }

    // MARK: - crash dumps

    func testEnableDumpsWritesKeysForExe() async throws {
        let (h, agent) = try await setup(stdout: "{\"folder\":\"C:\\\\alcove-dumps\"}")
        let r = try await h.handle(op: "vm.crash_dumps.enable", params: ["name": "Win", "exe": "My App.exe"])
        XCTAssertEqual(r, ["folder": "C:\\alcove-dumps", "eventSeq": 0])
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("$root = 'SOFTWARE\\Microsoft\\Windows\\Windows Error Reporting\\LocalDumps'\n$sub = $root + '\\' + 'My App.exe'\n"), script)
        XCTAssertTrue(script.contains("C:\\alcove-dumps"), script)
        XCTAssertTrue(script.contains("SetValue('DumpFolder'"), script)
        XCTAssertTrue(script.contains("ExpandString"), script)
        XCTAssertTrue(script.contains("SetValue('DumpCount', 5,"), script)
        XCTAssertTrue(script.contains("SetValue('DumpType', 1,"), script)
        let full = try await setup(stdout: "{\"folder\":\"C:\\\\alcove-dumps\"}")
        _ = try await full.0.handle(op: "vm.crash_dumps.enable", params: ["name": "Win", "exe": "a.exe", "full": true])
        XCTAssertTrue(try XCTUnwrap(commands(full.1).first).contains("SetValue('DumpType', 2,"))
    }

    func testDisableDumpsRemovesThatImageAndAnEmptyLocalDumpsKey() async throws {
        let (h, agent) = try await setup()
        let r = try await h.handle(op: "vm.crash_dumps.disable", params: ["name": "Win", "exe": "MyApp.exe"])
        XCTAssertEqual(r, ["eventSeq": 0])
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("$sub = $root + '\\' + 'MyApp.exe'\n"), script)
        XCTAssertTrue(script.contains("$hklm.DeleteSubKeyTree($sub, $false)\n  if ($hklm.OpenSubKey($sub)) { [Console]::Error.WriteLine('the crash dump setting is still there after its removal; check that alcove-agent runs elevated'); exit 2 }"), script)
        XCTAssertTrue(script.contains("$empty = $parent.SubKeyCount -eq 0 -and $parent.ValueCount -eq 0"), script)
        XCTAssertTrue(script.contains("if ($empty) { $hklm.DeleteSubKey($root, $false) }"), script)
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
        XCTAssertTrue(script.contains("if (Test-Path -LiteralPath $folder -PathType Container) {"), script)
        XCTAssertTrue(script.contains("-Filter *.dmp"), script)
        XCTAssertTrue(script.contains("-match '^(.+\\.exe)(\\([0-9]+\\))?\\.[0-9]+\\.dmp$'"), script)
        XCTAssertTrue(script.contains("Sort-Object @{ Expression = 'LastWriteTimeUtc'; Descending = $true }, @{ Expression = 'Name'; Descending = $false }"), script)
        let single = try await setup(stdout: "{\"file\":\"a.exe.1.dmp\",\"exe\":\"a.exe\",\"bytes\":9,\"time\":\"t\"}")
        let one = try await single.0.handle(op: "vm.crash_dumps.list", params: ["name": "Win"])
        XCTAssertEqual(one["dumps"]?.arrayValue?.count, 1)
    }

    func testDumpListOfADumpNamedAfterAReusedProcessID() async throws {
        let (h, _) = try await setup(stdout: "[{\"file\":\"alcove-fixture.exe(1).5648.dmp\",\"exe\":\"alcove-fixture.exe\",\"bytes\":121632778,\"time\":\"2026-10-13T22:22:07.8251684Z\"},{\"file\":\"alcove-fixture.exe.5648.dmp\",\"exe\":\"alcove-fixture.exe\",\"bytes\":122015050,\"time\":\"2026-10-13T22:20:42.7321952Z\"}]\r\n")
        let r = try await h.handle(op: "vm.crash_dumps.list", params: ["name": "Win"])
        XCTAssertEqual(r["dumps"]?.arrayValue?.compactMap { $0["file"]?.stringValue }, ["alcove-fixture.exe(1).5648.dmp", "alcove-fixture.exe.5648.dmp"])
        XCTAssertEqual(r["dumps"]?[0]?["exe"]?.stringValue, "alcove-fixture.exe")
        XCTAssertEqual(r["dumps"]?[0]?["bytes"]?.intValue, 121_632_778)
    }

    func testDumpListWithoutFolder() async throws {
        let (h, _) = try await setup(stdout: "[]")
        let r = try await h.handle(op: "vm.crash_dumps.list", params: ["name": "Win"])
        XCTAssertEqual(r, ["dumps": []])
    }

    func testDumpListOutputThatIsNoJSONIsAnError() async throws {
        for output in ["", "Warning: profile", "[{\"file\""] {
            let (h, _) = try await setup(stdout: output)
            let text = await failure(h, "vm.crash_dumps.list", ["name": "Win"])
            XCTAssertEqual(text, "the guest printed no crash dump list; run vm.doctor to check the guest shell", output)
        }
    }

    func testDumpListKeepsOnlyDmpExtensions() async throws {
        let (h, agent) = try await setup(stdout: "[]")
        _ = try await h.handle(op: "vm.crash_dumps.list", params: ["name": "Win"])
        XCTAssertTrue(try XCTUnwrap(commands(agent).first).contains("$_.Extension -ieq '.dmp'"))
    }

    func testDumpListFailureSentenceComesFromTheScript() async throws {
        let sentence = "could not list the dumps in C:\\alcove-dumps: Access to the path 'C:\\alcove-dumps' is denied.; check the folder permissions"
        let (h, agent) = try await setup(stdout: "", code: 2, stderr: sentence + "\r\n")
        let text = await failure(h, "vm.crash_dumps.list", ["name": "Win"])
        XCTAssertEqual(text, sentence)
        let script = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(script.contains("[Console]::Error.WriteLine('could not list the dumps in C:\\alcove-dumps: ' + ($_.Exception.GetBaseException().Message -replace '\\s+', ' ') + '; check the folder permissions')\n  exit 2"), script)
    }

    func testEnableAndDisableReportGuestFailuresAsSentences() async throws {
        let (h, agent) = try await setup()
        _ = try await h.handle(op: "vm.crash_dumps.enable", params: ["name": "Win", "exe": "a.exe"])
        let enable = try XCTUnwrap(commands(agent).first)
        XCTAssertTrue(enable.contains("$null = & icacls.exe $folder /grant '*S-1-5-32-545:(OI)(CI)M' 2>&1\n"), enable)
        XCTAssertTrue(enable.contains("$LASTEXITCODE -ne 0"), enable)
        XCTAssertLessThan(try XCTUnwrap(enable.range(of: "try {")).lowerBound, try XCTUnwrap(enable.range(of: "OpenBaseKey")).lowerBound, enable)
        XCTAssertTrue(enable.contains("[Console]::Error.WriteLine('could not make C:\\alcove-dumps writable for the Users group; check that alcove-agent runs elevated and may change the permissions of that folder'); exit 2"), enable)
        XCTAssertTrue(enable.contains("if (-not (Test-Path -LiteralPath $folder -PathType Container)) { [Console]::Error.WriteLine('C:\\alcove-dumps is not a folder; remove or rename that file, then call vm.crash_dumps.enable again'); exit 2 }"), enable)
        XCTAssertTrue(enable.contains("catch {"), enable)
        XCTAssertTrue(enable.contains("check that alcove-agent runs elevated"), enable)
        _ = try await h.handle(op: "vm.crash_dumps.disable", params: ["name": "Win", "exe": "a.exe"])
        let disable = commands(agent)[1]
        XCTAssertTrue(disable.contains("check that alcove-agent runs elevated"), disable)
        XCTAssertLessThan(try XCTUnwrap(disable.range(of: "try {")).lowerBound, try XCTUnwrap(disable.range(of: "OpenBaseKey")).lowerBound, disable)
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
        XCTAssertEqual(absent, "C:\\alcove-dumps holds no dump named 'gone.exe.1.dmp'; list the dumps with vm.crash_dumps.list")
        let noPath = await failure(h, "vm.crash_dumps.pull", ["name": "Win", "file": "MyApp.exe.4242.dmp"])
        XCTAssertEqual(noPath, "missing or invalid parameter 'path'")
    }

    func testDumpPullRefusesOtherFiles() async throws {
        let (h, agent) = try await setup(fs: FakeFS())
        let message = "file must be the name of a .dmp file listed by vm.crash_dumps.list, without a folder"
        for file in ["..\\Windows\\win.ini", "../x.dmp", "C:\\alcove-dumps\\a.dmp", "sub/a.dmp", "..", "a.dmp:stream", "a.txt", ".dmp", "a\\..\\b.dmp", "", "CON.dmp", "nul.dmp", "Com1.dmp", "LPT9.dmp", "aux.x.dmp"] {
            let text = await failure(h, "vm.crash_dumps.pull", ["name": "Win", "file": .string(file), "path": "/tmp/x.dmp"])
            XCTAssertEqual(text, message, file)
        }
        XCTAssertEqual(agentRequests(agent, "fs.stat").count, 0)
    }

    func testDumpPullOfAChangedDumpNamesTheNextStep() async throws {
        let fs = FakeFS()
        fs["C:\\alcove-dumps\\a.exe.1.dmp"] = Data("dump".utf8)
        let (h, _) = try await setup(fs: fs, staleDigest: true)
        let text = await failure(h, "vm.crash_dumps.pull", ["name": "Win", "file": "a.exe.1.dmp", "path": "/tmp/alcove-test-never-written.dmp"])
        XCTAssertEqual(text, "the dump changed while it was pulled; retry in a few seconds")
    }

    func testDumpPullOfADumpBeingWrittenNamesTheNextStep() async throws {
        let (h, _) = try await setup(fs: FakeFS(), statError: "cannot hash 'C:\\alcove-dumps\\alcove-fixture.exe.10128.dmp': open C:\\alcove-dumps\\alcove-fixture.exe.10128.dmp: The process cannot access the file because it is being used by another process.")
        let text = await failure(h, "vm.crash_dumps.pull", ["name": "Win", "file": "alcove-fixture.exe.10128.dmp", "path": "/tmp/alcove-test-never-written.dmp"])
        XCTAssertEqual(text, "the dump 'alcove-fixture.exe.10128.dmp' is still being written; retry in a few seconds")
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
