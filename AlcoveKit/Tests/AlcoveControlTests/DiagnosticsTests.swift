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
    var applicationEntries: [JSON] = [entry("2026-10-14T01:05:00Z", "Application Error", "Faulting application Other.exe"),
                                      entry("2026-10-14T01:00:00Z", "Application Error", "Faulting application MyApp.exe")]
    var systemEntries: [JSON] = []
    var dumps: [JSON] = []
    var processes: [JSON] = [["pid": 100, "ppid": 1, "name": "explorer.exe", "path": "C:\\Windows\\explorer.exe", "cmd": "explorer.exe", "mem_kb": 10],
                             ["pid": 200, "ppid": 100, "name": "MyApp.exe", "path": "C:\\MyApp.exe", "cmd": "MyApp.exe --token=SECRET123", "mem_kb": 20]]
    var jobs: [JSON] = []
    var jobOutput: [String: (out: String, err: String)] = [:]
    var tails: [String: String] = [:]
    /// The most bytes `fs.tail` answers with, counted from the end of the file in whole lines; nil for no such bound.
    var tailWindow: Int?
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
            var lines = Array(text.split(separator: "\n").map(String.init).suffix(m["lines"]?.intValue ?? 200))
            if let tailWindow {
                while lines.reduce(0, { $0 + $1.utf8.count + 1 }) > tailWindow { lines.removeFirst() }
            }
            let kept = lines.joined(separator: "\n") + "\n"
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

private func dumpRow(_ file: String, bytes: Int, time: String, now: String? = nil) -> JSON {
    var row: [String: JSON] = ["file": .string(file), "exe": "MyApp.exe", "bytes": .int(Int64(bytes)), "time": .string(time)]
    if let now { row["now"] = .string(now) }
    return .object(row)
}

private func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

/// A gray frame of 160 x 120 pixels with a white block that moves right as `step` grows.
private func blockFrame(step: Int) -> Frame {
    let width = 160, height = 120
    var pixels = Data(repeating: 0x40, count: width * height * 4)
    let blockX = (step * 7) % (width - 30)
    pixels.withUnsafeMutableBytes { raw in
        for y in 40..<70 {
            for x in blockX * 4..<(blockX + 30) * 4 { raw[y * width * 4 + x] = 255 }
        }
    }
    return Frame(width: width, height: height, pixels: pixels)
}

/// A video sink that writes no file and whose `finish` waits until `gate` is opened.
private final class GatedSink: VideoSink, @unchecked Sendable {
    let gate = Latch()
    func append(frame: Frame, at time: Duration) {}
    func finish() async { await gate.pass() }
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
        DiagnosticsLimits.frameBytes = 256 * 1024 * 1024
        DiagnosticsLimits.videoBytes = 1024 * 1024 * 1024
        DiagnosticsLimits.traceBytes = 32 * 1024 * 1024
        DiagnosticsTiming.dumps = .seconds(100)
        DiagnosticsTiming.recordingEnd = .seconds(30)
        DiagnosticsTiming.screenshot = .seconds(10)
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

    private func rig(os: VMConfig.GuestOS = .windows, caps: [String] = ["clipboard", "files", "exec", "ui"], now: LockedBox<Date>? = nil,
                     _ configure: (Guest) -> Void = { _ in }) async throws -> Rig {
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
        let handler = ControlHandler(registry: FakeRegistry(targets: ["Win": target]), hostKind: "test", now: { now?.value ?? Date() },
                                     recordingsDirectory: scratch.appendingPathComponent("recordings"),
                                     diagnosticsDirectory: scratch.appendingPathComponent("diagnostics"))
        return Rig(handler: handler, target: target, agent: agent, guest: guest)
    }

    /// Every file and folder below `dir`, hidden ones included, as sorted relative paths.
    private func onDisk(_ dir: URL? = nil) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: (dir ?? bundleDirectory()).path).sorted()
    }

    private func summaryLines(_ result: JSON) throws -> [String] {
        try XCTUnwrap(result["summary"]?.stringValue).components(separatedBy: "\n")
    }

    private func startRecording(_ h: ControlHandler, _ extra: [String: JSON] = [:]) async throws -> URL {
        var params: [String: JSON] = ["name": "Win", "video": false]
        for (key, value) in extra { params[key] = value }
        let start = try await h.handle(op: "vm.record.start", params: .object(params))
        return URL(fileURLWithPath: try XCTUnwrap(start["dir"]?.stringValue))
    }

    private func bundleDirectory(_ name: String = "bundle") -> URL { scratch.appendingPathComponent(name) }

    private func collect(_ h: ControlHandler, _ extra: [String: JSON] = [:], dir: URL? = nil) async throws -> JSON {
        var params: [String: JSON] = ["name": "Win"]
        params["dir"] = .string((dir ?? bundleDirectory()).path)
        for (key, value) in extra { params[key] = value }
        return try await h.handle(op: "vm.collect_diagnostics", params: .object(params))
    }

    /// A collection into `dir` that runs in a task of its own.
    private func collecting(_ h: ControlHandler, dir: URL? = nil) -> Task<JSON, Error> {
        let params: JSON = ["name": "Win", "dir": .string((dir ?? bundleDirectory()).path)]
        return Task { try await h.handle(op: "vm.collect_diagnostics", params: params) }
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
            $0.dumps = [dumpRow("MyApp.exe.4242.dmp", bytes: 20, time: stamp(Date()))]
            $0.jobs = [["job": "j1", "pid": 5, "state": "exited", "code": 0, "cmd": "build", "started": "2026-10-14T01:00:00+09:00"]]
            $0.jobOutput["j1"] = ("built\n", "warn\n")
            $0.tails["C:\\logs\\app.log"] = "one\ntwo\n"
            $0.fs["C:\\alcove-dumps\\MyApp.exe.4242.dmp"] = Data(repeating: 7, count: 20)
        }
        let recording = try await startRecording(r.handler)
        _ = try await r.handler.handle(op: "vm.mouse.move", params: ["name": "Win", "x": 10, "y": 10])
        let result = try await collect(r.handler, ["logFiles": ["C:\\logs\\app.log"]])
        XCTAssertEqual(result["dir"]?.stringValue, bundleDirectory().path)
        XCTAssertEqual(files(result), [
            "doctor.json", "dumps/MyApp.exe.4242.dmp", "eventlog-application.json", "eventlog-system.json", "events.json",
            "frames/000001-after.jpg", "frames/000001-before.jpg", "jobs/j1.txt",
            "logs/app.log", "processes.json", "screenshot.png", "summary.txt", "trace.jsonl", "ui-tree.txt", "windows.json",
        ])
        XCTAssertEqual(files(result), ControlHandler.bundleFiles(bundleDirectory()))
        XCTAssertEqual(try onDisk().filter { $0.hasPrefix(".") || $0.hasSuffix(".alcove-part") }, [])
        XCTAssertEqual(try read("summary.txt") + "", (result["summary"]?.stringValue ?? "") + "\n")
        XCTAssertEqual(try read("logs/app.log"), "one\ntwo\n")
        XCTAssertEqual(try Data(contentsOf: bundleDirectory().appendingPathComponent("dumps/MyApp.exe.4242.dmp")), Data(repeating: 7, count: 20))
        XCTAssertTrue(try read("jobs/j1.txt").contains("built"))
        XCTAssertTrue(try read("ui-tree.txt").contains("[e1] Window \"Alcove Fixture\""))
        XCTAssertEqual(Frame(png: try Data(contentsOf: bundleDirectory().appendingPathComponent("screenshot.png")))?.width, 800)
        let lines = try summaryLines(result)
        XCTAssertTrue(lines.contains("recording: \(recording.path) (running)"), "\(lines)")
        XCTAssertTrue(lines.contains("frames: 2 of 2 copied"), "\(lines)")
        XCTAssertEqual(lines.last, "steps that failed: none")
    }

    func testFileListKeepsTheFoldersOfABundleWhoseDirIsGivenWithThePrivatePrefix() async throws {
        let r = try await rig { $0.tails["C:\\logs\\app.log"] = "one\ntwo\n" }
        try XCTSkipUnless(scratch.path.hasPrefix("/var/") || scratch.path.hasPrefix("/tmp/"), "the scratch folder \(scratch.path) has no /private form")
        let dir = URL(fileURLWithPath: "/private" + scratch.path).appendingPathComponent("private-bundle")
        let result = try await collect(r.handler, ["logFiles": ["C:\\logs\\app.log"]], dir: dir)
        XCTAssertEqual(result["dir"]?.stringValue, dir.path)
        XCTAssertTrue(files(result).contains("logs/app.log"), "\(files(result))")
        XCTAssertFalse(files(result).contains("app.log"), "\(files(result))")
        XCTAssertEqual(ControlHandler.bundleFiles(dir), files(result))
    }

    func testProcessesJSONHasTheShapeOfProcessListWithSecretAssignmentsMasked() async throws {
        let r = try await rig()
        _ = try await collect(r.handler)
        let listed = try await r.handler.handle(op: "vm.process.list", params: ["name": "Win"])
        XCTAssertEqual(listed["processes"]?[1]?["command"]?.stringValue, "MyApp.exe --token=SECRET123")
        var expected = try XCTUnwrap(listed["processes"]?.arrayValue)
        var second = try XCTUnwrap(expected[1].objectValue)
        second["command"] = "MyApp.exe --token=<masked>"
        expected[1] = .object(second)
        let written = try JSON.parse(Data(contentsOf: bundleDirectory().appendingPathComponent("processes.json")))
        XCTAssertEqual(written, JSON.object(["processes": .array(expected)]))
        XCTAssertFalse(try read("processes.json").contains("SECRET123"))
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
        let now = stamp(Date())
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
        let lines = try summaryLines(result)
        XCTAssertTrue(lines[0].hasPrefix("VM Win, collected 20"), lines[0])
        XCTAssertTrue(lines[0].hasSuffix(", guest windows"), lines[0])
        XCTAssertTrue(lines.contains("window not responding: 0x3b \"Notepad\" (pid 777, app.exe)"), "\(lines)")
        XCTAssertTrue(lines.contains("foreground window: \"Alcove Fixture\""), "\(lines)")
        XCTAssertTrue(lines.contains("crash dump MyApp.exe.4242.dmp: 20 bytes, \(now), collected as dumps/MyApp.exe.4242.dmp"), "\(lines)")
        XCTAssertTrue(lines.contains("event log Application: 2 entries of level error or worse in the last 30 minutes; newest: Faulting application Other.exe"), "\(lines)")
        XCTAssertTrue(lines.contains("event log System: 1 entry of level error or worse in the last 30 minutes; newest: bad block"), "\(lines)")
        XCTAssertTrue(lines.contains("job j1 exited with code 3"), "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("job j2") || $0.contains("job j3") })
        XCTAssertTrue(lines.contains("recording: none in the last 30 minutes"), "\(lines)")
        let text = try read("summary.txt")
        XCTAssertFalse(text.contains("SECRET123"))
        XCTAssertFalse(text.contains("LEASE-TOKEN"))
        let listing = files(result).joined(separator: "\n")
        XCTAssertFalse(listing.contains("LEASE-TOKEN"))
    }

    func testNewestEventLogMessageIsTheFirstEntryOfTheList() async throws {
        let r = try await rig {
            $0.applicationEntries = [entry("2026-10-14T01:05:00Z", "App", "listed first"), entry("2026-10-14T00:00:00Z", "App", "listed second")]
        }
        let result = try await collect(r.handler)
        XCTAssertTrue(try summaryLines(result).contains("event log Application: 2 entries of level error or worse in the last 30 minutes; newest: listed first"))
    }

    func testSummaryReportsFactsOfFailedStepsAsUnknown() async throws {
        let r = try await rig {
            $0.failing = ["win.list": "the UI helper is shut down; restart alcove-agent", "ui.tree": "the UI helper is shut down; restart alcove-agent",
                          "proc.list": "access denied", "exec.list": "access denied", "exec.run": "the shell did not start"]
        }
        let result = try await collect(r.handler, ["processName": "MyApp"])
        let lines = try summaryLines(result)
        for line in ["windows not responding: unknown (windows failed)", "foreground window: unknown (windows failed)",
                     "crash dumps: unknown (dumps failed)", "event log Application: unknown (eventlog-application failed)",
                     "event log System: unknown (eventlog-system failed)", "jobs exited with a non-zero code: unknown (jobs failed)",
                     "process MyApp: unknown (processes failed)"] {
            XCTAssertTrue(lines.contains(line), "\(line) is missing in \(lines)")
        }
        XCTAssertFalse(lines.contains("windows not responding: none"))
    }

    func testForegroundWindowComesFromTheTreeWhenTheWindowListFailed() async throws {
        let r = try await rig { $0.failing["win.list"] = "the UI helper is shut down; restart alcove-agent" }
        let lines = try summaryLines(try await collect(r.handler))
        XCTAssertTrue(lines.contains("windows not responding: unknown (windows failed)"), "\(lines)")
        XCTAssertTrue(lines.contains("foreground window: \"Alcove Fixture\""), "\(lines)")
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
            XCTAssertTrue(script.contains(" and (Level=1 or Level=2)"), script)
        }
        XCTAssertTrue(scripts.contains { $0.contains("$log = 'Application'") })
        XCTAssertTrue(scripts.contains { $0.contains("$log = 'System'") })
    }

    func testLinuxGuestSkipsTheWindowsOnlyStepsWithOneNote() async throws {
        let r = try await rig(os: .linux, caps: ["clipboard", "files", "exec"])
        let result = try await collect(r.handler)
        XCTAssertEqual(files(result), ["doctor.json", "eventlog-system.json", "events.json", "processes.json", "screenshot.png", "summary.txt"])
        let lines = try summaryLines(result)
        XCTAssertTrue(lines.contains("windows, UI tree and crash dumps are collected on Windows guests only; skipped on this linux guest"), "\(lines)")
        XCTAssertEqual(lines.last, "steps that failed: none")
        XCTAssertFalse(lines.contains { $0.contains("unknown") })
        XCTAssertEqual(agentRequests(r.agent, "win.list").count + agentRequests(r.agent, "ui.tree").count, 0)
    }

    func testPausedVMSkipsTheGuestStepsWithoutAskingTheAgent() async throws {
        let r = try await rig()
        await r.target.setState(.paused)
        let result = try await collect(r.handler)
        XCTAssertEqual(files(result), ["doctor.json", "events.json", "screenshot.png", "summary.txt"])
        let lines = try summaryLines(result)
        XCTAssertTrue(lines.contains { $0.hasPrefix("VM 'Win' is paused; call vm.resume and collect again for the guest files.") }, "\(lines)")
        XCTAssertEqual(lines.last, "steps that failed: none")
        XCTAssertEqual(r.agent.received.filter { $0["t"]?.stringValue == "req" }.count, 0)
        let waits = await r.target.agentTimeouts
        XCTAssertEqual(waits.filter { $0 > .zero }, [])
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

    func testLogFileTailIsCutToTheByteCapAtALineStartAndTheSummarySaysSo() async throws {
        let big = String(repeating: "x", count: 199) + "\n"
        let text = String(repeating: big, count: 10_000)
        let r = try await rig {
            $0.tails["/var/log/big.log"] = text
            $0.tails["/var/log/small.log"] = "one\ntwo\n"
        }
        let result = try await collect(r.handler, ["logFiles": ["/var/log/big.log", "/var/log/small.log"]])
        let written = try read("logs/big.log")
        XCTAssertLessThanOrEqual(written.utf8.count, DiagnosticsLimits.logBytes)
        XCTAssertGreaterThan(written.utf8.count, DiagnosticsLimits.logBytes - 200)
        XCTAssertTrue(written.hasPrefix(String(repeating: "x", count: 199) + "\n"))
        XCTAssertTrue(written.hasSuffix("\n"))
        let lines = try summaryLines(result)
        XCTAssertTrue(lines.contains("logs/big.log: 1310 lines, fewer than 2000, because a log tail holds at most 262144 bytes"), "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("logs/small.log") }, "\(lines)")
    }

    func testLogTailTheAgentCutToItsByteWindowIsNotedInTheSummary() async throws {
        let line = String(repeating: "y", count: 999) + "\n"
        let r = try await rig {
            $0.tails["/var/log/wide.log"] = String(repeating: line, count: 100)
            $0.tailWindow = 50_000
        }
        let result = try await collect(r.handler, ["logFiles": ["/var/log/wide.log"]])
        XCTAssertEqual(try read("logs/wide.log").utf8.count, 50_000)
        XCTAssertTrue(try summaryLines(result).contains("logs/wide.log: 50 lines, fewer than 2000, because a log tail holds at most 262144 bytes"))
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

    func testErrorFileOfOneLogAndALogWithThatNameAreBothKept() async throws {
        let r = try await rig { $0.tails["/l/a.error.txt"] = "a log that is named like an error file\n" }
        let result = try await collect(r.handler, ["logFiles": ["/l/a", "/l/a.error.txt"]])
        XCTAssertEqual(files(result).filter { $0.hasPrefix("logs/") }, ["logs/a.error-2.txt", "logs/a.error.txt"])
        XCTAssertEqual(try read("logs/a.error.txt"), "'/l/a' does not exist\n")
        XCTAssertEqual(try read("logs/a.error-2.txt"), "a log that is named like an error file\n")
    }

    func testNamesKeepClearOfEarlierErrorFileNames() {
        var names = DiagnosticsNames()
        XCTAssertEqual(names.claim("a", fallback: "job", suffix: ".txt"), "a.txt")
        XCTAssertEqual(names.claim("a.txt.error", fallback: "job", suffix: ".txt"), "a.txt-2.error.txt")
        XCTAssertEqual(names.claim("A", fallback: "job", suffix: ".txt"), "A-2.txt")
        var logs = DiagnosticsNames()
        XCTAssertEqual(logs.claim("x.error.txt", fallback: "log"), "x.error.txt")
        XCTAssertEqual(logs.claim("x", fallback: "log"), "x-2")
    }

    func testNamesThatFoldToTheSameTextGetDifferentFiles() {
        var names = DiagnosticsNames()
        let composed = "caf\u{E9}.log", decomposed = "cafe\u{301}.log"
        XCTAssertNotEqual(Array(composed.unicodeScalars), Array(decomposed.unicodeScalars))
        XCTAssertEqual(names.claim(composed, fallback: "log"), composed)
        XCTAssertEqual(Array(names.claim(decomposed, fallback: "log").unicodeScalars), Array("cafe\u{301}-2.log".unicodeScalars))
        XCTAssertEqual(names.claim("CAF\u{C9}.LOG", fallback: "log"), "CAF\u{C9}-3.LOG")
        XCTAssertEqual(names.claim("STRASSE", fallback: "log"), "STRASSE")
        XCTAssertEqual(names.claim("stra\u{DF}e", fallback: "log"), "stra\u{DF}e-2")
        XCTAssertEqual(names.claim("\u{3C3}.txt", fallback: "log"), "\u{3C3}.txt")
        XCTAssertEqual(names.claim("\u{3C2}.txt", fallback: "log"), "\u{3C2}-2.txt")
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

    func testJobFileHoldsTheEndOfALongStreamFromALineStart() async throws {
        let out = (1...6000).map { "line \($0) " + String(repeating: "a", count: 60) }.joined(separator: "\n") + "\nEND-OUT"
        XCTAssertGreaterThan(out.utf8.count, DiagnosticsLimits.jobBytes + 100_000)
        let r = try await rig {
            $0.jobs = [["job": "j1", "pid": 5, "state": "exited", "code": 1, "cmd": "make API_KEY=abc123 all"],
                       ["job": "j2", "pid": 6, "state": "exited", "code": 0, "cmd": "true"]]
            $0.jobOutput["j1"] = (out, "short error\n")
            $0.jobOutput["j2"] = ("ok\n", "")
        }
        let result = try await collect(r.handler)
        let text = try read("jobs/j1.txt")
        let head = "job j1: exited, code 1\ncommand: make API_KEY=<masked> all\n--- stdout (its end, at most \(DiagnosticsLimits.jobBytes) bytes) ---\nline "
        XCTAssertTrue(text.hasPrefix(head), String(text.prefix(200)))
        XCTAssertTrue(text.contains("END-OUT\n--- stderr ---\nshort error\n"), String(text.suffix(200)))
        XCTAssertLessThan(text.utf8.count, DiagnosticsLimits.jobBytes + 1000)
        XCTAssertGreaterThan(text.utf8.count, DiagnosticsLimits.jobBytes - 1000)
        XCTAssertFalse(text.contains("abc123"))
        XCTAssertTrue(agentRequests(r.agent, "exec.read").allSatisfy { $0["out_offset"] != nil })
        XCTAssertEqual(try read("jobs/j2.txt"), "job j2: exited, code 0\ncommand: true\n--- stdout ---\nok\n\n--- stderr ---\n\n")
        XCTAssertTrue(try summaryLines(result).contains("job files that hold only the end of a stream, at most 262144 bytes: j1.txt"))
    }

    func testCutStreamStartsAtALineOrAtACharacter() {
        func cut(_ text: String, dropping bytes: Int) -> String { String(decoding: ControlHandler.fromLineStart(Data(Data(text.utf8).dropFirst(bytes))), as: UTF8.self) }
        XCTAssertEqual(cut("abc\ndef\nghi", dropping: 1), "def\nghi")
        XCTAssertEqual(cut("abc\ndef\nghi", dropping: 3), "def\nghi")
        XCTAssertEqual(cut("abc\n", dropping: 1), "bc\n")
        XCTAssertEqual(cut("한글한글", dropping: 1), "글한글")
        XCTAssertEqual(cut("한글한글", dropping: 2), "글한글")
        XCTAssertEqual(cut("한글한글", dropping: 3), "글한글")
        XCTAssertEqual(cut("", dropping: 0), "")
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

    func testDumpsOlderThanSinceMinutesAreLeftOutAndCounted() async throws {
        let old = stamp(Date().addingTimeInterval(-3 * 3600))
        let recent = stamp(Date().addingTimeInterval(-60))
        let r = try await rig {
            $0.dumps = [dumpRow("recent.exe.1.dmp", bytes: 4, time: recent), dumpRow("old.exe.2.dmp", bytes: 4, time: old)]
            $0.fs["C:\\alcove-dumps\\recent.exe.1.dmp"] = Data(count: 4)
            $0.fs["C:\\alcove-dumps\\old.exe.2.dmp"] = Data(count: 4)
        }
        let result = try await collect(r.handler, ["sinceMinutes": 120])
        XCTAssertEqual(files(result).filter { $0.hasPrefix("dumps/") }, ["dumps/recent.exe.1.dmp"])
        XCTAssertTrue(try summaryLines(result).contains("crash dumps older than 120 minutes: 1 left out, the newest from \(old)"))
    }

    func testDumpAgeIsCountedOnTheClockTheGuestReports() async throws {
        let host = Date()
        let behind = host.addingTimeInterval(-3 * 3600), ahead = host.addingTimeInterval(3 * 3600)
        let slow = try await rig {
            $0.dumps = [dumpRow("fresh.exe.1.dmp", bytes: 4, time: stamp(behind.addingTimeInterval(-60)), now: stamp(behind))]
            $0.fs["C:\\alcove-dumps\\fresh.exe.1.dmp"] = Data(count: 4)
        }
        let kept = try await collect(slow.handler, dir: bundleDirectory("behind"))
        XCTAssertEqual(files(kept).filter { $0.hasPrefix("dumps/") }, ["dumps/fresh.exe.1.dmp"])

        let fast = try await rig {
            $0.dumps = [dumpRow("stale.exe.1.dmp", bytes: 4, time: stamp(host), now: stamp(ahead))]
            $0.fs["C:\\alcove-dumps\\stale.exe.1.dmp"] = Data(count: 4)
        }
        let dropped = try await collect(fast.handler, dir: bundleDirectory("ahead"))
        XCTAssertEqual(files(dropped).filter { $0.hasPrefix("dumps/") }, [])
        let lines = try summaryLines(dropped)
        XCTAssertTrue(lines.contains("crash dumps: none newer than 30 minutes"), "\(lines)")
        XCTAssertTrue(lines.contains("crash dumps older than 30 minutes: 1 left out, the newest from \(stamp(host))"), "\(lines)")
    }

    func testDumpThatHoldsMoreThanTheBudgetLeftIsNotPulled() async throws {
        DiagnosticsLimits.dumpBudget = 1000
        let now = Date()
        let r = try await rig {
            $0.dumps = [dumpRow("grown.exe.1.dmp", bytes: 400, time: stamp(now)), dumpRow("small.exe.2.dmp", bytes: 300, time: stamp(now.addingTimeInterval(-5)))]
            $0.fs["C:\\alcove-dumps\\grown.exe.1.dmp"] = Data(repeating: 1, count: 2000)
            $0.fs["C:\\alcove-dumps\\small.exe.2.dmp"] = Data(repeating: 2, count: 300)
        }
        let result = try await collect(r.handler)
        XCTAssertEqual(files(result).filter { $0.hasPrefix("dumps/") }, ["dumps/small.exe.2.dmp"])
        XCTAssertEqual(agentRequests(r.agent, "fs.read").filter { ($0["path"]?.stringValue ?? "").contains("grown") }.count, 0)
        let lines = try summaryLines(result)
        XCTAssertTrue(lines.contains { $0.hasPrefix("crash dump grown.exe.1.dmp: 400 bytes, \(stamp(now)), not collected: it holds 2000 bytes or more now, and 1000 bytes are left of the ")
            && $0.hasSuffix(" dump budget; pull it with vm.crash_dumps.pull") }, "\(lines)")
        XCTAssertEqual(lines.last, "steps that failed: none")
    }

    func testBudgetLeftForADumpCountsTheBytesAlreadyPulled() async throws {
        DiagnosticsLimits.dumpBudget = 1000
        let now = Date()
        let r = try await rig {
            $0.dumps = [dumpRow("first.exe.1.dmp", bytes: 600, time: stamp(now)), dumpRow("second.exe.2.dmp", bytes: 300, time: stamp(now.addingTimeInterval(-5)))]
            $0.fs["C:\\alcove-dumps\\first.exe.1.dmp"] = Data(repeating: 1, count: 600)
            $0.fs["C:\\alcove-dumps\\second.exe.2.dmp"] = Data(repeating: 2, count: 401)
        }
        let result = try await collect(r.handler)
        XCTAssertEqual(files(result).filter { $0.hasPrefix("dumps/") }, ["dumps/first.exe.1.dmp"])
        XCTAssertTrue(try summaryLines(result).contains { $0.hasPrefix("crash dump second.exe.2.dmp: 300 bytes") && $0.contains("it holds 401 bytes or more now, and 400 bytes are left") })
    }

    func testDumpPullWithoutAnAnswerLeavesOnlyItsErrorFile() async throws {
        DiagnosticsTiming.dumps = .seconds(1)
        let r = try await rig {
            $0.dumps = [dumpRow("stuck.exe.1.dmp", bytes: 4, time: stamp(Date()))]
            $0.fs["C:\\alcove-dumps\\stuck.exe.1.dmp"] = Data(count: 4)
            $0.silent = ["fs.read"]
        }
        let result = try await collect(r.handler)
        XCTAssertEqual(try onDisk().filter { $0.hasPrefix("dumps") }, ["dumps", "dumps/stuck.exe.1.dmp.error.txt"])
        XCTAssertEqual(try onDisk().filter { $0.hasPrefix(".") }, [])
        XCTAssertEqual(try read("dumps/stuck.exe.1.dmp.error.txt"), "guest tools in 'Win' did not answer vm.crash_dumps.pull in time; check vm.status and retry\n")
        XCTAssertEqual(agentRequests(r.agent, "fs.read").count, 1)
        XCTAssertTrue(try summaryLines(result).contains { $0.hasPrefix("crash dump stuck.exe.1.dmp: 4 bytes") && $0.contains("not collected: guest tools in 'Win' did not answer") })
    }

    func testDumpPullFailureWritesItsErrorFileAndTheOthersContinue() async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let r = try await rig {
            $0.dumps = [dumpRow("gone.exe.1.dmp", bytes: 4, time: now), dumpRow("here.exe.2.dmp", bytes: 4, time: now)]
            $0.fs["C:\\alcove-dumps\\here.exe.2.dmp"] = Data(count: 4)
        }
        let result = try await collect(r.handler)
        XCTAssertEqual(try read("dumps/gone.exe.1.dmp.error.txt"), "C:\\alcove-dumps holds no dump named 'gone.exe.1.dmp'; list the dumps with vm.crash_dumps.list\n")
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

    func testHelperHeldByAnotherCallIsNamedAndLeavesTheOtherFiles() async throws {
        let r = try await rig { $0.silent = ["win.list"] }
        let holder = Task { try await r.handler.handle(op: "vm.window.list", params: ["name": "Win"]) }
        let held = await eventually { agentRequests(r.agent, "win.list").count == 1 }
        XCTAssertTrue(held)
        DiagnosticsTiming.windowsTurn = .milliseconds(100)
        DiagnosticsTiming.windows = .milliseconds(200)
        DiagnosticsTiming.treeTurn = .milliseconds(100)
        DiagnosticsTiming.tree = .milliseconds(200)
        let result = try await collect(r.handler)
        let busy = "the UI helper is held by a call outside this collection; retry when that call has answered"
        XCTAssertEqual(try read("windows.error.txt"), busy + "\n")
        XCTAssertEqual(try read("ui-tree.error.txt"), busy + "\n")
        XCTAssertEqual(agentRequests(r.agent, "win.list").count, 1)
        XCTAssertEqual(agentRequests(r.agent, "ui.tree").count, 0)
        for name in ["screenshot.png", "processes.json", "eventlog-application.json", "events.json", "doctor.json", "summary.txt"] {
            XCTAssertTrue(files(result).contains(name), name)
        }
        let summary = try XCTUnwrap(result["summary"]?.stringValue)
        XCTAssertTrue(summary.hasSuffix("steps that failed:\nwindows: \(busy)\nui-tree: \(busy)"), summary)
        holder.cancel()
    }

    func testUnansweredWindowListIsNamedAndTheTreeIsNotAskedFor() async throws {
        let r = try await rig { $0.silent = ["win.list"] }
        DiagnosticsTiming.windows = .seconds(1)
        DiagnosticsTiming.windowsTurn = .milliseconds(100)
        let result = try await collect(r.handler)
        XCTAssertEqual(try read("windows.error.txt"), "the UI helper in 'Win' did not answer vm.window.list within 1 s; run vm.doctor and retry\n")
        XCTAssertEqual(try read("ui-tree.error.txt"), "the window list took the time available; call vm.ui.tree when the app answers\n")
        XCTAssertEqual(agentRequests(r.agent, "win.list").count, 1)
        XCTAssertEqual(agentRequests(r.agent, "ui.tree").count, 0)
        XCTAssertTrue(try summaryLines(result).contains("foreground window: unknown (windows failed)"))
    }

    func testWindowListIsAskedForBeforeTheTree() async throws {
        let r = try await rig()
        _ = try await collect(r.handler)
        let helperOps = r.agent.received.compactMap { $0["op"]?.stringValue }.filter { $0 == "win.list" || $0 == "ui.tree" }
        XCTAssertEqual(helperOps, ["win.list", "ui.tree"])
    }

    func testTreeIsStillReadWhenTheWindowListFailsWithAnAnswer() async throws {
        let r = try await rig { $0.failing["win.list"] = "the UI helper is shut down; restart alcove-agent" }
        let result = try await collect(r.handler)
        XCTAssertTrue(files(result).contains("windows.error.txt"))
        XCTAssertTrue(files(result).contains("ui-tree.txt"))
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

    func testFileWrittenAfterItsStepGaveUpStaysOutOfTheBundle() async throws {
        let r = try await rig()
        let root = bundleDirectory("late")
        let bundle = DiagnosticsBundle(root: root)
        try FileManager.default.createDirectory(at: bundle.partial, withIntermediateDirectories: true)

        let inTime = await r.handler.collectFile("dumps/in-time.dmp", limit: .seconds(30), bundle) { scratch in
            try Data("in time".utf8).write(to: scratch)
        }
        XCTAssertNoThrow(try inTime.get())
        XCTAssertEqual(try onDisk(root), [".partial", "dumps", "dumps/in-time.dmp"])

        let beforeTheEnd = Latch(), afterTheEnd = Latch()
        let wrote = LockedBox<[String: Bool]>([:])
        for (name, gate) in [("before-the-end", beforeTheEnd), ("after-the-end", afterTheEnd)] {
            let late = await r.handler.collectFile("dumps/\(name).dmp", limit: .milliseconds(50), bundle) { scratch in
                await gate.pass()
                let created = FileManager.default.createFile(atPath: scratch.path, contents: Data("late".utf8))
                wrote.value[name] = created
            }
            guard case .failure(let error) = late else { return XCTFail("expected the limit to end the wait") }
            XCTAssertTrue(error is DiagnosticsTimeout, "\(error)")
        }
        await beforeTheEnd.open()
        let first = await eventually { wrote.value["before-the-end"] != nil }
        XCTAssertTrue(first)
        XCTAssertEqual(wrote.value["before-the-end"], true)
        XCTAssertEqual(try onDisk(root).filter { !$0.hasPrefix(".partial") }, ["dumps", "dumps/in-time.dmp"])

        bundle.removePartial()
        XCTAssertEqual(try onDisk(root), ["dumps", "dumps/in-time.dmp"])
        await afterTheEnd.open()
        let second = await eventually { wrote.value["after-the-end"] != nil }
        XCTAssertTrue(second)
        XCTAssertEqual(wrote.value["after-the-end"], false)
        XCTAssertEqual(try onDisk(root), ["dumps", "dumps/in-time.dmp"])
    }

    func testCancelledCallRemovesTheFolderItCreated() async throws {
        let r = try await rig { $0.silent = ["proc.list"] }
        let dir = bundleDirectory("cancelled")
        let call = collecting(r.handler, dir: dir)
        let reached = await eventually { agentRequests(r.agent, "proc.list").count == 1 }
        XCTAssertTrue(reached)
        call.cancel()
        do { _ = try await call.value; XCTFail("expected the call to end without a result") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testCancelledCallLeavesAFolderOfTheCallerWithoutErrorFilesOrSummary() async throws {
        let r = try await rig { $0.silent = ["proc.list", "win.list"] }
        let dir = bundleDirectory("callers")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let call = collecting(r.handler, dir: dir)
        let reached = await eventually { agentRequests(r.agent, "proc.list").count == 1 && agentRequests(r.agent, "win.list").count == 1 }
        XCTAssertTrue(reached)
        call.cancel()
        do { _ = try await call.value; XCTFail("expected the call to end without a result") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let left = try onDisk(dir)
        XCTAssertEqual(left.filter { $0.hasSuffix(".error.txt") || $0 == "summary.txt" || $0.hasPrefix(".") }, [])
        try Data("x".utf8).write(to: dir.appendingPathComponent("keep.txt"))
        let again = await failure(r.handler, ["name": "Win", "dir": .string(dir.path)])
        XCTAssertEqual(again, "'\(dir.path)' is not empty; choose a directory that is missing or empty, or leave dir out for a new folder")
    }

    func testSecondCollectionIntoADirThatIsBeingWrittenIsRefused() async throws {
        let r = try await rig { $0.silent = ["proc.list"] }
        DiagnosticsTiming.processes = .seconds(1)
        let first = collecting(r.handler)
        let reached = await eventually { agentRequests(r.agent, "proc.list").count == 1 }
        XCTAssertTrue(reached)
        let refused = await failure(r.handler, ["name": "Win", "dir": .string(bundleDirectory().path)])
        XCTAssertEqual(refused, "\(bundleDirectory().path) is being written by another collection")
        let link = scratch.appendingPathComponent("link-to-bundle")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundleDirectory())
        let throughLink = await failure(r.handler, ["name": "Win", "dir": .string(link.path)])
        XCTAssertEqual(throughLink, "\(link.path) is being written by another collection")
        let done = try await first.value
        XCTAssertTrue(files(done).contains("summary.txt"))
        XCTAssertTrue(files(done).contains("processes.error.txt"))
        let later = await failure(r.handler, ["name": "Win", "dir": .string(bundleDirectory().path)])
        XCTAssertEqual(later, "'\(bundleDirectory().path)' is not empty; choose a directory that is missing or empty, or leave dir out for a new folder")
    }

    // MARK: - recording

    private func traceBytes(_ dir: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("trace.jsonl"))
    }

    func testRecordingInProgressCopiesWholeLinesAndKeepsRecording() async throws {
        let r = try await rig()
        let recording = try await startRecording(r.handler).path
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
        XCTAssertFalse(files(result).contains { $0.hasPrefix("video") || $0.hasPrefix("frames") })
        XCTAssertFalse(try summaryLines(result).contains { $0.hasPrefix("frames:") || $0.hasPrefix("trace.jsonl:") })

        let status = try await r.handler.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["recording"]?.boolValue, true)
        _ = try await r.handler.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertGreaterThan(try traceBytes(recording).count, whole.count)
        let stopped = try await r.handler.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stopped["dir"]?.stringValue, recording)
    }

    func testTraceLongerThanItsLimitLosesItsFirstLinesAndTheSummarySaysSo() async throws {
        let r = try await rig()
        let recording = try await startRecording(r.handler)
        for _ in 0..<6 { _ = try await r.handler.handle(op: "vm.status", params: ["name": "Win"]) }
        let whole = try traceBytes(recording.path)
        let lines = whole.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 6)
        let kept = lines.suffix(2).reduce(0) { $0 + $1.count + 1 }
        DiagnosticsLimits.traceBytes = kept + 5
        let result = try await collect(r.handler)
        let copied = try Data(contentsOf: bundleDirectory().appendingPathComponent("trace.jsonl"))
        XCTAssertEqual(copied, whole.suffix(kept))
        let megabytes = DiagnosticsLimits.traceBytes / 1_048_576
        XCTAssertTrue(try summaryLines(result).contains("trace.jsonl: the first \(whole.count - kept) bytes of the trace are left out; the bundle holds its newest whole lines within \(megabytes) MiB"))
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

    func testRunningRecordingPutsAPlayableCopyOfItsVideoInTheBundle() async throws {
        let r = try await rig()
        await r.target.setFrames((0..<300).map { blockFrame(step: $0) })
        let recording = try await startRecording(r.handler, ["video": true, "fps": 10])
        let source = recording.appendingPathComponent("video.mp4")
        let growing = await eventually { await VideoRecorder.isPlayable(source) }
        XCTAssertTrue(growing)

        let result = try await collect(r.handler)
        XCTAssertTrue(files(result).contains("video.mp4"))
        XCTAssertFalse(files(result).contains("video.error.txt"))
        let copy = bundleDirectory().appendingPathComponent("video.mp4")
        let plays = await VideoRecorder.isPlayable(copy)
        XCTAssertTrue(plays)
        let lines = try summaryLines(result)
        XCTAssertTrue(lines.contains("recording: \(recording.path) (running)"), "\(lines)")
        XCTAssertTrue(lines.contains("video.mp4: copied while recording, up to the last second may be missing"), "\(lines)")
        XCTAssertEqual(lines.last, "steps that failed: none")

        let status = try await r.handler.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["recording"]?.boolValue, true)
        let stopped = try await r.handler.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stopped["video"]?.stringValue, source.path)
        let whole = await VideoRecorder.isPlayable(source)
        XCTAssertTrue(whole)
    }

    func testRunningRecordingWhoseWriterFailedNamesTheFailureInTheVideoLine() async throws {
        let r = try await rig()
        let recorder = LockedBox<VideoRecorder?>(nil)
        await r.handler.setRecordingSeams(RecordingSeams(makeSink: { dir, fps in
            let made = VideoRecorder(url: dir.appendingPathComponent("video.mp4"), fps: fps)
            recorder.value = made
            return made
        }))
        await r.target.setFrames((0..<300).map { blockFrame(step: $0) })
        let recording = try await startRecording(r.handler, ["video": true, "fps": 10])
        let playable = await eventually { await VideoRecorder.isPlayable(recording.appendingPathComponent("video.mp4")) }
        XCTAssertTrue(playable)
        try XCTUnwrap(recorder.value).failWriterForTesting("the video could not be written: test")

        let result = try await collect(r.handler)
        XCTAssertTrue(files(result).contains("video.mp4"))
        let lines = try summaryLines(result)
        XCTAssertTrue(lines.contains("video.mp4: copied up to the point where the video writer failed (the video could not be written: test)"), "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("up to the last second may be missing") }, "\(lines)")
        _ = try await r.handler.handle(op: "vm.record.stop", params: ["name": "Win"])
    }

    func testRecordingEndedWithAFailedWriterCopiesTheFileItKept() async throws {
        let r = try await rig()
        let recorder = LockedBox<VideoRecorder?>(nil)
        await r.handler.setRecordingSeams(RecordingSeams(makeSink: { dir, fps in
            let made = VideoRecorder(url: dir.appendingPathComponent("video.mp4"), fps: fps)
            recorder.value = made
            return made
        }))
        await r.target.setFrames((0..<300).map { blockFrame(step: $0) })
        let recording = try await startRecording(r.handler, ["video": true, "fps": 10])
        let playable = await eventually { await VideoRecorder.isPlayable(recording.appendingPathComponent("video.mp4")) }
        XCTAssertTrue(playable)
        try XCTUnwrap(recorder.value).failWriterForTesting("the video could not be written: test")
        let stopped = try await r.handler.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertNil(stopped["video"])
        XCTAssertEqual(stopped["lastWriteError"]?.stringValue, "the video could not be written: test")

        let result = try await collect(r.handler)
        XCTAssertTrue(files(result).contains("video.mp4"))
        XCTAssertFalse(files(result).contains("video.error.txt"))
        let copied = await VideoRecorder.isPlayable(bundleDirectory().appendingPathComponent("video.mp4"))
        XCTAssertTrue(copied)
        let lines = try summaryLines(result)
        XCTAssertTrue(lines.contains("video.mp4: copied up to the point where the video writer failed (the video could not be written: test)"), "\(lines)")
    }

    func testRunningRecordingWithoutAPlayableVideoYetWritesVideoErrorFile() async throws {
        let r = try await rig()
        await r.handler.setRecordingSeams(RecordingSeams(makeSink: { _, _ in NoVideoSink() }))
        let recording = try await startRecording(r.handler, ["video": true])
        let result = try await collect(r.handler)
        XCTAssertFalse(files(result).contains("video.mp4"))
        XCTAssertEqual(try read("video.error.txt"), "the recording in \(recording.path) has not written a playable part of its video yet; collect again in a few seconds\n")
        XCTAssertTrue(files(result).contains("trace.jsonl"))
        let status = try await r.handler.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["recording"]?.boolValue, true)
        _ = try await r.handler.handle(op: "vm.record.stop", params: ["name": "Win"])
    }

    func testRecordingEndedByRecordStopIsCopiedWithItsVideo() async throws {
        let r = try await rig()
        await r.target.setFrames((0..<300).map { blockFrame(step: $0) })
        let recording = try await startRecording(r.handler, ["video": true, "fps": 10])
        _ = try await r.handler.handle(op: "vm.mouse.move", params: ["name": "Win", "x": 5, "y": 5])
        let source = recording.appendingPathComponent("video.mp4")
        let written = await eventually { FileManager.default.fileExists(atPath: source.path) }
        XCTAssertTrue(written)
        let stopped = try await r.handler.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stopped["video"]?.stringValue, source.path)

        let result = try await collect(r.handler)
        XCTAssertEqual(files(result).filter { $0.hasPrefix("video") || $0.hasPrefix("trace") || $0.hasPrefix("frames") },
                       ["frames/000001-after.jpg", "frames/000001-before.jpg", "trace.jsonl", "video.mp4"])
        XCTAssertEqual(try Data(contentsOf: bundleDirectory().appendingPathComponent("video.mp4")), try Data(contentsOf: source))
        XCTAssertEqual(try Data(contentsOf: bundleDirectory().appendingPathComponent("trace.jsonl")), try traceBytes(recording.path))
        let lines = try summaryLines(result)
        XCTAssertTrue(lines.contains { $0.hasPrefix("recording: \(recording.path) (ended 20") && $0.hasSuffix("Z)") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("video.mp4:") }, "\(lines)")
        XCTAssertEqual(lines.last, "steps that failed: none")
    }

    func testEndedRecordingWhoseFolderWasRemovedIsNamedWithoutFailedSteps() async throws {
        let r = try await rig()
        await r.target.setFrames((0..<300).map { blockFrame(step: $0) })
        let recording = try await startRecording(r.handler, ["video": true, "fps": 10])
        _ = try await r.handler.handle(op: "vm.mouse.move", params: ["name": "Win", "x": 5, "y": 5])
        let written = await eventually { FileManager.default.fileExists(atPath: recording.appendingPathComponent("video.mp4").path) }
        XCTAssertTrue(written)
        _ = try await r.handler.handle(op: "vm.record.stop", params: ["name": "Win"])
        try FileManager.default.removeItem(at: recording)

        let result = try await collect(r.handler)
        XCTAssertFalse(files(result).contains { $0.hasPrefix("trace") || $0.hasPrefix("video") || $0.hasPrefix("frames") }, "\(files(result))")
        let lines = try summaryLines(result)
        XCTAssertTrue(lines.contains { $0.hasPrefix("recording: \(recording.path) (ended 20") && $0.hasSuffix("Z; its folder no longer exists)") }, "\(lines)")
        XCTAssertEqual(lines.last, "steps that failed: none")
    }

    func testRecordingEndedByTheVMStoppingIsCopied() async throws {
        let r = try await rig()
        let recording = try await startRecording(r.handler)
        _ = try await r.handler.handle(op: "vm.status", params: ["name": "Win"])
        _ = try await r.handler.handle(op: "vm.stop", params: ["name": "Win"])
        let result = try await collect(r.handler)
        XCTAssertEqual(try Data(contentsOf: bundleDirectory().appendingPathComponent("trace.jsonl")), try traceBytes(recording.path))
        XCTAssertTrue(try summaryLines(result).contains { $0.hasPrefix("recording: \(recording.path) (ended 20") })
    }

    func testRecordingThatEndedBeforeSinceMinutesIsNotUsed() async throws {
        let now = LockedBox(Date())
        let r = try await rig(now: now)
        let recording = try await startRecording(r.handler)
        _ = try await r.handler.handle(op: "vm.status", params: ["name": "Win"])
        _ = try await r.handler.handle(op: "vm.record.stop", params: ["name": "Win"])
        now.value = now.value.addingTimeInterval(31 * 60)
        let late = try await collect(r.handler, dir: bundleDirectory("late"))
        XCTAssertFalse(files(late).contains("trace.jsonl"))
        XCTAssertTrue(try summaryLines(late).contains("recording: none in the last 30 minutes"))
        let wider = try await collect(r.handler, ["sinceMinutes": 60], dir: bundleDirectory("wider"))
        XCTAssertTrue(files(wider).contains("trace.jsonl"))
        XCTAssertTrue(try summaryLines(wider).contains { $0.hasPrefix("recording: \(recording.path) (ended ") })
    }

    func testRecordingThatIsEndingIsWaitedForAndCopied() async throws {
        let r = try await rig { $0.silent = ["proc.list"] }
        DiagnosticsTiming.processes = .seconds(1)
        let sink = GatedSink()
        await r.handler.setRecordingSeams(RecordingSeams(makeSink: { _, _ in sink }))
        let recording = try await startRecording(r.handler, ["video": true])
        _ = try await r.handler.handle(op: "vm.status", params: ["name": "Win"])
        let stop = Task { try await r.handler.handle(op: "vm.record.stop", params: ["name": "Win"]) }
        let ending = await eventually { await sink.gate.arrivals == 1 }
        XCTAssertTrue(ending)
        let collection = collecting(r.handler)
        let underWay = await eventually { agentRequests(r.agent, "proc.list").count == 1 }
        XCTAssertTrue(underWay)
        await sink.gate.open()
        let result = try await collection.value
        _ = try await stop.value
        XCTAssertEqual(try Data(contentsOf: bundleDirectory().appendingPathComponent("trace.jsonl")), try traceBytes(recording.path))
        XCTAssertTrue(try summaryLines(result).contains { $0.hasPrefix("recording: \(recording.path) (ended 20") })
        XCTAssertEqual(try read("video.error.txt"), "the recording ended without a playable video; check lastWriteError of vm.record.stop and record again\n")
    }

    func testRecordingStillEndingAtTheLimitGivesItsTraceAndAVideoErrorFile() async throws {
        let r = try await rig()
        DiagnosticsTiming.recordingEnd = .seconds(1)
        let sink = GatedSink()
        await r.handler.setRecordingSeams(RecordingSeams(makeSink: { _, _ in sink }))
        let recording = try await startRecording(r.handler, ["video": true])
        _ = try await r.handler.handle(op: "vm.status", params: ["name": "Win"])
        let stop = Task { try await r.handler.handle(op: "vm.record.stop", params: ["name": "Win"]) }
        let ending = await eventually { await sink.gate.arrivals == 1 }
        XCTAssertTrue(ending)
        let result = try await collect(r.handler)
        XCTAssertEqual(try Data(contentsOf: bundleDirectory().appendingPathComponent("trace.jsonl")), try traceBytes(recording.path))
        XCTAssertTrue(try summaryLines(result).contains("recording: \(recording.path) (ending)"))
        XCTAssertEqual(try read("video.error.txt"), "the recording in \(recording.path) has not ended within 1 s; its video is complete there when vm.record.stop has returned\n")
        await sink.gate.open()
        _ = try await stop.value
    }

    func testVideoLargerThanTheLimitIsLeftOutWithItsSize() async throws {
        let r = try await rig()
        await r.target.setFrames((0..<300).map { blockFrame(step: $0) })
        let recording = try await startRecording(r.handler, ["video": true, "fps": 10])
        let source = recording.appendingPathComponent("video.mp4")
        let written = await eventually { FileManager.default.fileExists(atPath: source.path) }
        XCTAssertTrue(written)
        let stopped = try await r.handler.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stopped["video"]?.stringValue, source.path)
        try Data(count: 2 * 1_048_576 + 1).write(to: source)
        DiagnosticsLimits.videoBytes = 1_048_576
        let result = try await collect(r.handler)
        XCTAssertFalse(files(result).contains("video.mp4"))
        XCTAssertEqual(try read("video.error.txt"), "the video in \(recording.path) is 3 MB, more than the 1 MB a bundle takes; copy it from there\n")

        DiagnosticsLimits.videoBytes = 2 * 1_048_576 + 1
        let fitting = try await collect(r.handler, dir: bundleDirectory("fitting"))
        XCTAssertTrue(files(fitting).contains("video.mp4"))
    }

    // MARK: - frames

    private func size(_ url: URL) throws -> Int { try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) }

    func testFramesTheCopiedTraceLinesReferToAreCopied() async throws {
        let r = try await rig()
        let recording = try await startRecording(r.handler)
        for x in [10, 20] { _ = try await r.handler.handle(op: "vm.mouse.move", params: ["name": "Win", "x": .int(Int64(x)), "y": 10]) }
        let result = try await collect(r.handler)
        let names = ["frames/000001-after.jpg", "frames/000001-before.jpg", "frames/000002-after.jpg", "frames/000002-before.jpg"]
        XCTAssertEqual(files(result).filter { $0.hasPrefix("frames") }, names)
        for name in names {
            XCTAssertEqual(try Data(contentsOf: bundleDirectory().appendingPathComponent(name)), try Data(contentsOf: recording.appendingPathComponent(name)), name)
        }
        XCTAssertTrue(try summaryLines(result).contains("frames: 4 of 4 copied"))
        let copiedTrace = try String(contentsOf: bundleDirectory().appendingPathComponent("trace.jsonl"), encoding: .utf8)
        XCTAssertTrue(copiedTrace.contains("frames/000002-before.jpg"))
    }

    func testFramesAreCopiedNewestFirstUpToTheByteLimit() async throws {
        let r = try await rig()
        let recording = try await startRecording(r.handler)
        for x in [10, 20, 30] { _ = try await r.handler.handle(op: "vm.mouse.move", params: ["name": "Win", "x": .int(Int64(x)), "y": 10]) }
        let newest = try size(recording.appendingPathComponent("frames/000003-after.jpg")) + size(recording.appendingPathComponent("frames/000003-before.jpg"))
        DiagnosticsLimits.frameBytes = try newest + size(recording.appendingPathComponent("frames/000002-after.jpg"))
        let result = try await collect(r.handler)
        XCTAssertEqual(files(result).filter { $0.hasPrefix("frames") }, ["frames/000002-after.jpg", "frames/000003-after.jpg", "frames/000003-before.jpg"])
        XCTAssertTrue(try summaryLines(result).contains("frames: 3 of 6 copied"))
    }

    func testFramePathsThatLeaveTheRecordingAreNotCopied() async throws {
        let r = try await rig()
        let recording = try await startRecording(r.handler)
        _ = try await r.handler.handle(op: "vm.mouse.move", params: ["name": "Win", "x": 10, "y": 10])
        let outside = scratch.appendingPathComponent("recordings/outside.jpg")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: recording.appendingPathComponent("frames/link.jpg"), withDestinationURL: outside)
        try Data("nested".utf8).write(to: recording.appendingPathComponent("nested.jpg"))
        let handle = try FileHandle(forWritingTo: recording.appendingPathComponent("trace.jsonl"))
        try handle.seekToEnd()
        for (before, after) in [("../outside.jpg", "frames/link.jpg"), (outside.path, "frames/../nested.jpg"), ("nested.jpg", "frames/missing.jpg"), ("frames/", "frames/..")] {
            try handle.write(contentsOf: try JSON.object(["seq": 9, "op": "x", "before": .string(before), "after": .string(after)]).serialized() + Data("\n".utf8))
        }
        try handle.close()
        let result = try await collect(r.handler)
        XCTAssertEqual(try onDisk().filter { $0.hasPrefix("frames") }, ["frames", "frames/000001-after.jpg", "frames/000001-before.jpg"])
        XCTAssertTrue(try summaryLines(result).contains("frames: 2 of 10 copied"))
        XCTAssertFalse(try onDisk().contains { $0.hasSuffix("outside.jpg") || $0.hasSuffix("nested.jpg") || $0.hasSuffix("link.jpg") })
    }

    func testFramesFolderThatIsALinkToElsewhereYieldsNoFrames() async throws {
        let r = try await rig()
        let recording = try await startRecording(r.handler)
        _ = try await r.handler.handle(op: "vm.mouse.move", params: ["name": "Win", "x": 10, "y": 10])
        let elsewhere = scratch.appendingPathComponent("elsewhere")
        try FileManager.default.moveItem(at: recording.appendingPathComponent("frames"), to: elsewhere)
        try FileManager.default.createSymbolicLink(at: recording.appendingPathComponent("frames"), withDestinationURL: elsewhere)
        let result = try await collect(r.handler)
        XCTAssertFalse(try onDisk().contains { $0.hasPrefix("frames") })
        XCTAssertTrue(try summaryLines(result).contains("frames: 0 of 2 copied"))
    }

    func testFrameFileThatIsALinkOrBelowALinkedFramesFolderIsNotUsed() throws {
        let recording = scratch.appendingPathComponent("rec")
        let frames = recording.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let outside = scratch.appendingPathComponent("outside.jpg")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: frames.appendingPathComponent("link.jpg"), withDestinationURL: outside)
        XCTAssertNil(ControlHandler.frameFile("frames/link.jpg", in: recording))

        let linked = scratch.appendingPathComponent("linked")
        let target = scratch.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: target.appendingPathComponent("a.jpg"))
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("frames"), withDestinationURL: target)
        XCTAssertNil(ControlHandler.frameFile("frames/a.jpg", in: linked))

        let viaLinkedRecording = scratch.appendingPathComponent("recording-link")
        try FileManager.default.createSymbolicLink(at: viaLinkedRecording, withDestinationURL: recording)
        try Data("y".utf8).write(to: frames.appendingPathComponent("b.jpg"))
        XCTAssertEqual(ControlHandler.frameFile("frames/b.jpg", in: viaLinkedRecording)?.lastPathComponent, "b.jpg")
    }

    func testFramePathIsUsedOnlyInsideTheFramesFolderOfTheRecording() throws {
        let recording = scratch.appendingPathComponent("rec")
        try FileManager.default.createDirectory(at: recording.appendingPathComponent("frames"), withIntermediateDirectories: true)
        XCTAssertEqual(ControlHandler.frameFile("frames/000001-before.jpg", in: recording)?.lastPathComponent, "000001-before.jpg")
        for path in ["", "frames", "frames/", "frames/..", "frames/.", "../x.jpg", "/etc/hosts", "frames/a/b.jpg", "frames/../trace.jsonl", "other/x.jpg", "trace.jsonl", "frames//x.jpg"] {
            XCTAssertNil(ControlHandler.frameFile(path, in: recording), path)
        }
    }

    func testFrameReferencesOfATraceAreListedNewestFirstAndOnce() {
        let trace = Data("""
        {"seq":1,"before":"frames/000001-before.jpg","after":"frames/000001-after.jpg"}
        {"seq":2,"op":"vm.status"}
        not json
        {"seq":3,"before":"frames/000003-before.jpg","after":"frames/000001-after.jpg"}

        """.utf8)
        XCTAssertEqual(ControlHandler.frameReferences(inTrace: trace), ["frames/000001-after.jpg", "frames/000003-before.jpg", "frames/000001-before.jpg"])
    }

    func testWholeLinesOfATraceFile() throws {
        let file = scratch.appendingPathComponent("t.jsonl")
        func lines(_ limit: Int) throws -> String { String(decoding: try ControlHandler.wholeLines(of: file, limit: limit).data, as: UTF8.self) }
        try Data("aaa\nbbb\nccc".utf8).write(to: file)
        XCTAssertEqual(try lines(1000), "aaa\nbbb\n")
        try Data("aaa\nbbb\nccc\n".utf8).write(to: file)
        XCTAssertEqual(try lines(1000), "aaa\nbbb\nccc\n")
        XCTAssertEqual(try ControlHandler.wholeLines(of: file, limit: 1000).leftOut, 0)
        XCTAssertEqual(try lines(6), "ccc\n")
        XCTAssertEqual(try ControlHandler.wholeLines(of: file, limit: 6).leftOut, 8)
        XCTAssertEqual(try lines(2), "")
        XCTAssertEqual(try ControlHandler.wholeLines(of: file, limit: 2).leftOut, 12)
        try Data("partial".utf8).write(to: file)
        XCTAssertEqual(try ControlHandler.wholeLines(of: file, limit: 1000).data, Data())
    }

    func testWithoutARecordingTheSummarySaysThatNoneWasFound() async throws {
        let r = try await rig()
        let result = try await collect(r.handler, ["sinceMinutes": 45])
        XCTAssertFalse(files(result).contains { $0.hasPrefix("trace") || $0.hasPrefix("video") || $0.hasPrefix("frames") })
        XCTAssertTrue(try summaryLines(result).contains("recording: none in the last 45 minutes"))
    }

    // MARK: - the session stays as it is

    func testCollectingMovesNoEventPosition() async throws {
        let r = try await rig()
        _ = try await r.handler.handle(op: "vm.start", params: ["name": "Win"])
        _ = try await r.handler.handle(op: "vm.type", params: ["name": "Win", "text": "a"])
        let positions = await r.handler.eventPositions(of: "Win")
        XCTAssertNotNil(positions.baseline)
        XCTAssertNotNil(positions.observed)
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
