import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

private func solid(_ w: Int, _ h: Int, _ v: UInt8) -> Frame {
    var d = Data(repeating: v, count: w * h * 4)
    for i in stride(from: 3, to: d.count, by: 4) { d[i] = 255 }
    return Frame(width: w, height: h, pixels: d)
}

/// Adds `delta` to the blue channel of every pixel of one 32x32 tile.
private func paint(_ f: Frame, tileX: Int, tileY: Int, delta: UInt8 = 100) -> Frame {
    var d = f.pixels
    for y in tileY * 32..<(tileY + 1) * 32 { for x in tileX * 32..<(tileX + 1) * 32 {
        let o = (y * f.width + x) * 4
        d[o] = d[o] &+ delta
    } }
    return Frame(width: f.width, height: f.height, pixels: d)
}

private func base64(_ text: String) -> JSON { .string(Data(text.utf8).base64EncodedString()) }

final class WaitTests: XCTestCase {
    override func setUp() {
        WaitTiming.tick = .milliseconds(20)
        WaitTiming.screenPeriod = .milliseconds(20)
        WaitTiming.ocrPeriod = .milliseconds(60)
        WaitTiming.agentPeriod = .milliseconds(40)
        WaitTiming.agentCallTimeout = .seconds(3)
    }

    override func tearDown() {
        WaitTiming.tick = .milliseconds(250)
        WaitTiming.screenPeriod = .milliseconds(250)
        WaitTiming.ocrPeriod = .milliseconds(700)
        WaitTiming.agentPeriod = .milliseconds(500)
        WaitTiming.agentCallTimeout = .seconds(5)
    }

    /// A running VM "Win" serving `frames`, with no guest tools.
    private func screenRig(frames: [Frame]) async -> (ControlHandler, FakeTarget) {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 8, height: 8))
        await t.setFrames(frames)
        return (ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test"), t)
    }

    /// A running VM "Win" with guest tools served by `agent`.
    private func agentRig(_ agent: FakeAgent, frames: [Frame] = []) async throws -> (ControlHandler, FakeTarget) {
        let (h, t) = try await handlerWithAgent(agent, in: self)
        if !frames.isEmpty { await t.setFrames(frames) }
        return (h, t)
    }

    private func waitFor(_ h: ControlHandler, _ conditions: [JSON], timeout: Int = 2, _ extra: [String: JSON] = [:]) async throws -> JSON {
        var params: [String: JSON] = ["name": "Win", "conditions": .array(conditions), "timeout": .int(Int64(timeout))]
        for (k, v) in extra { params[k] = v }
        return try await h.handle(op: "vm.wait_for", params: .object(params))
    }

    private func failure(_ h: ControlHandler, _ params: JSON, file: StaticString = #filePath, line: UInt = #line) async -> String {
        do { _ = try await h.handle(op: "vm.wait_for", params: params); XCTFail("expected failure", file: file, line: line); return "" }
        catch { return "\(error)" }
    }

    // MARK: - ordering and timeout

    func testFirstTrueConditionWins() async throws {
        let fs = FakeFS()
        fs["C:\\b.txt"] = Data("12345".utf8)
        let agent = FakeAgent()
        fs.install(on: agent)
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "file_exists", "path": "C:\\a.txt"], ["type": "file_exists", "path": "C:\\b.txt"]])
        XCTAssertEqual(r["matched"]?.intValue, 1)
        XCTAssertEqual(r["type"]?.stringValue, "file_exists")
        XCTAssertEqual(r["detail"], ["path": "C:\\b.txt", "size": 5])
        XCTAssertNotNil(r["waited"]?.doubleValue)
        XCTAssertNil(r["observation"])
    }

    func testListOrderDecidesWhenSeveralConditionsHold() async throws {
        let fs = FakeFS()
        fs["C:\\a.txt"] = Data("a".utf8)
        fs["C:\\b.txt"] = Data("b".utf8)
        let agent = FakeAgent()
        fs.install(on: agent)
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "file_exists", "path": "C:\\b.txt"], ["type": "file_exists", "path": "C:\\a.txt"]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
    }

    func testTimeoutReturnsMinusOne() async throws {
        let fs = FakeFS()
        let agent = FakeAgent()
        fs.install(on: agent)
        let (h, _) = try await agentRig(agent)
        let start = ContinuousClock.now
        let r = try await waitFor(h, [["type": "file_exists", "path": "C:\\never"]], timeout: 1)
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(r["matched"]?.intValue, -1)
        XCTAssertNil(r["type"]); XCTAssertNil(r["detail"])
        XCTAssertGreaterThanOrEqual(r["waited"]?.doubleValue ?? 0, 1.0)
        XCTAssertLessThan(r["waited"]?.doubleValue ?? 9, 1.5)
        XCTAssertLessThan(elapsed, .milliseconds(1500))
    }

    func testWaitedIsRoundedToOneDecimal() async throws {
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let r = try await waitFor(h, [["type": "screen_idle", "seconds": 0.2]])
        let waited = try XCTUnwrap(r["waited"]?.doubleValue)
        XCTAssertEqual(waited, (waited * 10).rounded() / 10, accuracy: 1e-9)
    }

    // MARK: - screen conditions

    func testScreenIdle() async throws {
        let a = solid(320, 192, 40)
        let (h, t) = await screenRig(frames: [a, paint(a, tileX: 0, tileY: 0), paint(a, tileX: 1, tileY: 0), paint(a, tileX: 2, tileY: 0), paint(a, tileX: 3, tileY: 0)])
        let r = try await waitFor(h, [["type": "screen_idle", "seconds": 0.3]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertEqual(r["type"]?.stringValue, "screen_idle")
        XCTAssertGreaterThanOrEqual(r["waited"]?.doubleValue ?? 0, 0.3)
        let calls = await t.frameCalls
        XCTAssertGreaterThan(calls, 5)
    }

    func testScreenIdleDefaultsToTwoSeconds() async throws {
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let r = try await waitFor(h, [["type": "screen_idle"]], timeout: 1)
        XCTAssertEqual(r["matched"]?.intValue, -1)
    }

    func testRegionChanged() async throws {
        let a = solid(320, 192, 40)
        let outside = paint(a, tileX: 8, tileY: 4)
        let inside = paint(outside, tileX: 0, tileY: 0)
        let (h, _) = await screenRig(frames: [a, a, outside, outside, inside])
        let r = try await waitFor(h, [["type": "region_changed", "region": ["x": 0, "y": 0, "w": 64, "h": 64]]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertEqual(r["type"]?.stringValue, "region_changed")
    }

    func testRegionChangedIgnoresChangesOutsideTheRegion() async throws {
        let a = solid(320, 192, 40)
        let (h, _) = await screenRig(frames: [a, paint(a, tileX: 8, tileY: 4)])
        let r = try await waitFor(h, [["type": "region_changed", "region": ["x": 0, "y": 0, "w": 64, "h": 64]]], timeout: 1)
        XCTAssertEqual(r["matched"]?.intValue, -1)
    }

    func testScreenConditionsShareOneFramePerTick() async throws {
        let (h, t) = await screenRig(frames: [solid(64, 64, 10)])
        let r = try await waitFor(h, [["type": "region_changed", "region": ["x": 0, "y": 0, "w": 32, "h": 32]],
                                      ["type": "screen_idle", "seconds": 100]], timeout: 1)
        XCTAssertEqual(r["matched"]?.intValue, -1)
        let calls = await t.frameCalls
        XCTAssertGreaterThan(calls, 20)
        XCTAssertLessThanOrEqual(calls, 56)
    }

    // MARK: - text conditions

    func testTextVisibleReportsTheMatchRectangle() async throws {
        let blank = drawText([]).frame
        let drawn = drawText([("Install complete", 100, 120)])
        let (h, _) = await screenRig(frames: [blank, blank, drawn.frame])
        let r = try await waitFor(h, [["type": "text_visible", "text": "install complete"]], timeout: 10)
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertEqual(r["type"]?.stringValue, "text_visible")
        let detail = try XCTUnwrap(r["detail"])
        XCTAssertTrue(detail["text"]?.stringValue?.lowercased().contains("install complete") ?? false, "\(detail)")
        let expected = drawn.rects[0]
        for (key, value) in [("x", expected.x), ("y", expected.y), ("w", expected.w), ("h", expected.h)] {
            XCTAssertLessThanOrEqual(abs((detail[key]?.intValue ?? -999) - value), 12, "\(key) \(detail)")
        }
        let cx = try XCTUnwrap(detail["cx"]?.intValue), cy = try XCTUnwrap(detail["cy"]?.intValue)
        XCTAssertEqual(cx, (detail["x"]?.intValue ?? 0) + (detail["w"]?.intValue ?? 0) / 2)
        XCTAssertEqual(cy, (detail["y"]?.intValue ?? 0) + (detail["h"]?.intValue ?? 0) / 2)
    }

    func testTextVisibleInARegionReportsFrameCoordinates() async throws {
        let drawn = drawText([("Install complete", 100, 120), ("Install complete", 100, 500)])
        let (h, _) = await screenRig(frames: [drawn.frame])
        let r = try await waitFor(h, [["type": "text_visible", "text": "install", "region": ["x": 0, "y": 400, "w": 800, "h": 200]]], timeout: 10)
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertLessThanOrEqual(abs((r["detail"]?["y"]?.intValue ?? -999) - drawn.rects[1].y), 12, "\(String(describing: r["detail"]))")
    }

    func testTextVisibleWithRegex() async throws {
        let drawn = drawText([("Build 42 done", 100, 120)])
        let (h, _) = await screenRig(frames: [drawn.frame])
        let hit = try await waitFor(h, [["type": "text_visible", "text": "build \\d+ done", "regex": true]], timeout: 10)
        XCTAssertEqual(hit["matched"]?.intValue, 0)
        let miss = try await waitFor(h, [["type": "text_visible", "text": "build \\d+ failed", "regex": true]], timeout: 1)
        XCTAssertEqual(miss["matched"]?.intValue, -1)
    }

    func testTextGone() async throws {
        let blank = drawText([])
        let drawn = drawText([("Please wait", 100, 120)])
        let (h, _) = await screenRig(frames: [drawn.frame, drawn.frame, drawn.frame, blank.frame])
        let start = ContinuousClock.now
        let r = try await waitFor(h, [["type": "text_gone", "text": "please wait"]], timeout: 10)
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertEqual(r["type"]?.stringValue, "text_gone")
        XCTAssertNil(r["detail"])
        XCTAssertGreaterThan(ContinuousClock.now - start, .milliseconds(60))
    }

    func testTextConditionsOnTheSameRegionShareOneRecognition() async throws {
        let drawn = drawText([("Hello there", 100, 120)])
        let (h, t) = await screenRig(frames: [drawn.frame])
        let r = try await waitFor(h, [["type": "text_gone", "text": "hello"], ["type": "text_visible", "text": "hello"]], timeout: 10)
        XCTAssertEqual(r["matched"]?.intValue, 1)
        let calls = await t.frameCalls
        XCTAssertLessThanOrEqual(calls, 3)
    }

    // MARK: - process conditions

    func testProcessStartedAndExited() async throws {
        let listCalls = LockedBox(0)
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "proc.list" else { return [] }
            listCalls.value += 1
            if listCalls.value < 3 { return [agentReply(m, ["procs": []])] }
            return [agentReply(m, ["procs": [
                ["pid": 7, "ppid": 1, "name": "setup-helper.exe"],
                ["pid": 42, "ppid": 1, "name": "Setup.exe", "path": "C:\\Setup.exe"],
            ]])]
        }
        let (h, _) = try await agentRig(agent)
        let started = try await waitFor(h, [["type": "process_started", "processName": "setup"]])
        XCTAssertEqual(started["matched"]?.intValue, 0)
        XCTAssertEqual(started["type"]?.stringValue, "process_started")
        XCTAssertEqual(started["detail"], ["pid": 42, "name": "Setup.exe"])
        XCTAssertEqual(agentRequests(agent, "proc.list").first?["name"]?.stringValue, "setup")

        let exitedAgent = FakeAgent()
        let exitedCalls = LockedBox(0)
        exitedAgent.handler = { m, _ in
            guard m["op"]?.stringValue == "proc.list" else { return [] }
            exitedCalls.value += 1
            if exitedCalls.value < 3 { return [agentReply(m, ["procs": [["pid": 42, "ppid": 1, "name": "Setup.exe"]]])] }
            return [agentReply(m, ["procs": [["pid": 43, "ppid": 1, "name": "Setup.exe"]]])]
        }
        let (h2, _) = try await agentRig(exitedAgent)
        let byPid = try await waitFor(h2, [["type": "process_exited", "pid": 42]])
        XCTAssertEqual(byPid["matched"]?.intValue, 0)
        XCTAssertEqual(byPid["type"]?.stringValue, "process_exited")
        XCTAssertTrue(exitedCalls.value >= 3)
    }

    func testProcessExitedByName() async throws {
        let calls = LockedBox(0)
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "proc.list" else { return [] }
            calls.value += 1
            return [agentReply(m, ["procs": calls.value < 3 ? [["pid": 5, "ppid": 1, "name": "NOTEPAD.EXE"]] : []])]
        }
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "process_exited", "processName": "notepad.exe"]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertGreaterThanOrEqual(calls.value, 3)
    }

    // MARK: - file, port, log, job

    func testFileExists() async throws {
        let fs = FakeFS()
        let agent = FakeAgent()
        fs.install(on: agent)
        let (h, _) = try await agentRig(agent)
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            fs["C:\\out\\done.txt"] = Data("ok".utf8)
        }
        let r = try await waitFor(h, [["type": "file_exists", "path": "C:\\out\\done.txt"]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertEqual(r["detail"], ["path": "C:\\out\\done.txt", "size": 2])
        XCTAssertGreaterThanOrEqual(r["waited"]?.doubleValue ?? 0, 0.1)
    }

    func testPortListeningRunsRecipe() async throws {
        let calls = LockedBox(0)
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "exec.run" else { return [] }
            calls.value += 1
            return [agentReply(m, ["code": 0, "stdout": calls.value < 3 ? "0\r\n" : "1\r\n", "stderr": ""])]
        }
        let (h, t) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "port_listening", "port": 8080]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertEqual(r["type"]?.stringValue, "port_listening")
        let request = try XCTUnwrap(agentRequests(agent, "exec.run").first)
        XCTAssertEqual(request["cmd"]?.stringValue, GuestRecipes.portListening(8080, os: .windows))
        XCTAssertTrue(request["cmd"]?.stringValue?.contains("-LocalPort 8080") ?? false)
        XCTAssertNotNil(request["timeout_ms"]?.intValue)

        await t.setOS(.linux)
        calls.value = 10
        _ = try await waitFor(h, [["type": "port_listening", "port": 22]])
        XCTAssertEqual(agentRequests(agent, "exec.run").last?["cmd"]?.stringValue, GuestRecipes.portListening(22, os: .linux))
    }

    func testPortRecipes() {
        XCTAssertEqual(GuestRecipes.portListening(8080, os: .windows),
                       "if (Get-NetTCPConnection -State Listen -LocalPort 8080 -ErrorAction SilentlyContinue) { '1' } else { '0' }")
        XCTAssertEqual(GuestRecipes.portListening(8080, os: .linux),
                       "ss -ltn \"sport = :8080\" | tail -n +2 | grep -q . && echo 1 || echo 0")
        XCTAssertNil(GuestRecipes.portListening(8080, os: .other))
    }

    func testPortListeningOnAnUnsupportedGuest() async throws {
        let agent = FakeAgent()
        let (h, t) = try await agentRig(agent)
        await t.setOS(.other)
        let message = await failure(h, ["name": "Win", "conditions": [["type": "port_listening", "port": 80]]])
        XCTAssertEqual(message, "condition 0: port_listening is not supported for this guest OS")
    }

    func testLogMatches() async throws {
        let calls = LockedBox(0)
        let agent = FakeAgent()
        agent.handler = { m, _ in
            switch m["op"]?.stringValue {
            case "fs.tail":
                calls.value += 1
                switch calls.value {
                case 1: return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": "'/var/log/app.log' does not exist"]]
                case 2: return [agentReply(m, ["data": base64("starting\nlistening on 80\n"), "size": 25])]
                default: return [agentReply(m, ["data": base64("starting\nserver READY on 80\nmore\n"), "size": 31])]
                }
            case "fs.stat":
                return [agentReply(m, ["exists": .bool(calls.value >= 2), "path": "/var/log/app.log"])]
            default:
                return []
            }
        }
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "log_matches", "path": "/var/log/app.log", "pattern": "READY"]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertEqual(r["type"]?.stringValue, "log_matches")
        XCTAssertEqual(r["detail"]?.stringValue, "server READY on 80")
        let request = try XCTUnwrap(agentRequests(agent, "fs.tail").first)
        XCTAssertEqual(request["lines"]?.intValue, 400)
        XCTAssertEqual(request["path"]?.stringValue, "/var/log/app.log")
        XCTAssertGreaterThanOrEqual(calls.value, 3)
    }

    func testLogMatchesDecodesUTF16AndCutsTheLine() async throws {
        let long = "ready " + String(repeating: "x", count: 600)
        let units = Data((long + "\r\n").utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "fs.tail" else { return [] }
            return [agentReply(m, ["data": .string(units.base64EncodedString()), "size": .int(Int64(units.count)), "encoding": "utf-16le"])]
        }
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "log_matches", "path": "C:\\app.log", "pattern": "^ready"]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        let line = try XCTUnwrap(r["detail"]?.stringValue)
        XCTAssertEqual(line.count, 500)
        XCTAssertTrue(line.hasPrefix("ready xxx"))
    }

    func testLogMatchesFailsForAnExistingFileTheAgentCannotRead() async throws {
        let agent = FakeAgent()
        agent.handler = { m, _ in
            switch m["op"]?.stringValue {
            case "fs.tail": return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": "access denied"]]
            case "fs.stat": return [agentReply(m, ["exists": true, "dir": false, "size": 1])]
            default: return []
            }
        }
        let (h, _) = try await agentRig(agent)
        let message = await failure(h, ["name": "Win", "conditions": [["type": "log_matches", "path": "C:\\x.log", "pattern": "a"]]])
        XCTAssertEqual(message, "access denied")
    }

    func testJobOutputMatchesAcrossReads() async throws {
        let calls = LockedBox(0)
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "exec.read" else { return [] }
            calls.value += 1
            switch calls.value {
            case 1: return [agentReply(m, ["state": "running", "out": "booting ab", "err": "", "out_next": 10, "err_next": 0])]
            case 2: return [agentReply(m, ["state": "running", "out": "", "err": "warn\n", "out_next": 10, "err_next": 5])]
            case 3: return [agentReply(m, ["state": "running", "out": "cd done\n", "err": "", "out_next": 18, "err_next": 5])]
            default: return [agentReply(m, ["state": "running", "out": "", "err": "", "out_next": 18, "err_next": 5])]
            }
        }
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "job_output_matches", "job": "j1", "pattern": "abcd done"]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertEqual(r["type"]?.stringValue, "job_output_matches")
        let requests = agentRequests(agent, "exec.read")
        XCTAssertEqual(requests.first?["job"]?.stringValue, "j1")
        XCTAssertEqual(requests.first?["out_offset"]?.intValue, 0)
        let offsets = requests.map { [$0["out_offset"]?.intValue ?? -1, $0["err_offset"]?.intValue ?? -1] }
        XCTAssertTrue(offsets.contains([10, 5]), "\(offsets)")
    }

    func testJobExitWithoutAMatchEndsTheWait() async throws {
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "exec.read" else { return [] }
            return [agentReply(m, ["state": "exited", "code": 1, "out": "all done\n", "err": "", "out_next": 9, "err_next": 0])]
        }
        let (h, _) = try await agentRig(agent)
        let start = ContinuousClock.now
        let r = try await waitFor(h, [["type": "job_output_matches", "job": "j1", "pattern": "never appears"]], timeout: 30)
        XCTAssertEqual(r["matched"]?.intValue, -1)
        XCTAssertEqual(r["type"]?.stringValue, "job_output_matches")
        XCTAssertEqual(r["detail"]?.stringValue, "job exited")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testJobOutputMatchInTheLastReadOfAnExitedJob() async throws {
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "exec.read" else { return [] }
            return [agentReply(m, ["state": "exited", "code": 0, "out": "build ok\n", "err": "", "out_next": 9, "err_next": 0])]
        }
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "job_output_matches", "job": "j1", "pattern": "build ok"]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertNil(r["detail"]?.stringValue)
    }

    func testUnknownJobFailsWithTheAgentError() async throws {
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "exec.read" else { return [] }
            return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": "unknown job 'j9'"]]
        }
        let (h, _) = try await agentRig(agent)
        let message = await failure(h, ["name": "Win", "conditions": [["type": "job_output_matches", "job": "j9", "pattern": "x"]]])
        XCTAssertEqual(message, "unknown job 'j9'")
    }

    // MARK: - agent availability

    func testAgentConditionWithoutTools() async throws {
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let start = ContinuousClock.now
        let message = await failure(h, ["name": "Win", "timeout": 30,
                                        "conditions": [["type": "screen_idle", "seconds": 100], ["type": "file_exists", "path": "/x"]]])
        XCTAssertEqual(message, ControlHandler.ControlError.noTools("Win").description)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testScreenConditionsNeedNoTools() async throws {
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let r = try await waitFor(h, [["type": "screen_idle", "seconds": 0.1]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
    }

    func testAgentDisconnectDuringTheWaitFails() async throws {
        let agent = FakeAgent()
        agent.handler = { m, a in
            guard m["op"]?.stringValue == "fs.stat" else { return [] }
            if a.receivedCount() >= 3 { a.drop(); return [] }
            return [agentReply(m, ["exists": false])]
        }
        let (h, _) = try await agentRig(agent)
        let start = ContinuousClock.now
        let message = await failure(h, ["name": "Win", "timeout": 30, "conditions": [["type": "file_exists", "path": "/x"]]])
        XCTAssertTrue(message.contains("disconnected"), message)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    func testAnAgentCallThatNeverAnswersDoesNotHoldThePastTheDeadline() async throws {
        WaitTiming.agentCallTimeout = .milliseconds(300)
        let agent = FakeAgent()
        agent.handler = { _, _ in [] }
        let (h, _) = try await agentRig(agent)
        let start = ContinuousClock.now
        let r = try await waitFor(h, [["type": "file_exists", "path": "/x"]], timeout: 1)
        XCTAssertEqual(r["matched"]?.intValue, -1)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(1800))
    }

    // MARK: - validation

    func testUnknownTypeListsValid() async throws {
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let message = await failure(h, ["name": "Win", "conditions": [["type": "screen_idle"], ["type": "bogus"]]])
        XCTAssertTrue(message.hasPrefix("condition 1: unknown type 'bogus'"), message)
        for type in ["screen_idle", "region_changed", "text_visible", "text_gone", "process_started", "process_exited",
                     "file_exists", "port_listening", "log_matches", "job_output_matches"] {
            XCTAssertTrue(message.contains(type), "\(type) in \(message)")
        }
        let missing = await failure(h, ["name": "Win", "conditions": [["seconds": 1]]])
        XCTAssertTrue(missing.hasPrefix("condition 0: "), missing)
    }

    func testConditionLimit() async throws {
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let none = await failure(h, ["name": "Win", "conditions": []])
        XCTAssertEqual(none, "conditions must hold 1 to 8 conditions, not 0")
        let missing = await failure(h, ["name": "Win"])
        XCTAssertEqual(missing, "missing or invalid parameter 'conditions'")
        let nine = await failure(h, ["name": "Win", "conditions": .array(Array(repeating: ["type": "screen_idle"], count: 9))])
        XCTAssertEqual(nine, "conditions must hold 1 to 8 conditions, not 9")
        let notObjects = await failure(h, ["name": "Win", "conditions": ["screen_idle"]])
        XCTAssertEqual(notObjects, "condition 0: a condition is an object with a string 'type'")
        let eight = try await waitFor(h, Array(repeating: ["type": "screen_idle", "seconds": 0.05], count: 8))
        XCTAssertEqual(eight["matched"]?.intValue, 0)
    }

    func testTimeoutRange() async throws {
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        for bad: JSON in [0, 601, "5"] {
            let message = await failure(h, ["name": "Win", "conditions": [["type": "screen_idle"]], "timeout": bad])
            XCTAssertEqual(message, "timeout must be between 1 and 600 seconds")
        }
    }

    func testFieldValidation() async throws {
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let cases: [(JSON, String)] = [
            (["type": "text_visible"], "condition 0: text_visible needs a non-empty string 'text'"),
            (["type": "text_gone", "text": ""], "condition 0: text_gone needs a non-empty string 'text'"),
            (["type": "text_visible", "text": "a", "regex": "yes"], "condition 0: 'regex' must be a boolean"),
            (["type": "text_visible", "text": "a", "region": ["x": 0, "y": 0, "w": 0, "h": 5]], "condition 0: region needs integer x, y, w, h with w and h above 0"),
            (["type": "region_changed"], "condition 0: region_changed needs a 'region'"),
            (["type": "screen_idle", "seconds": -1], "condition 0: 'seconds' must be a number between 0 and 600"),
            (["type": "screen_idle", "seconds": "2"], "condition 0: 'seconds' must be a number between 0 and 600"),
            (["type": "process_started"], "condition 0: process_started needs a non-empty string 'processName'"),
            (["type": "process_exited"], "condition 0: process_exited needs 'pid' or 'processName'"),
            (["type": "process_exited", "pid": "x"], "condition 0: 'pid' must be an integer"),
            (["type": "file_exists"], "condition 0: file_exists needs a non-empty string 'path'"),
            (["type": "port_listening"], "condition 0: port_listening needs an integer 'port' between 1 and 65535"),
            (["type": "port_listening", "port": 0], "condition 0: port_listening needs an integer 'port' between 1 and 65535"),
            (["type": "port_listening", "port": 65536], "condition 0: port_listening needs an integer 'port' between 1 and 65535"),
            (["type": "log_matches", "pattern": "a"], "condition 0: log_matches needs a non-empty string 'path'"),
            (["type": "log_matches", "path": "/x"], "condition 0: log_matches needs a string 'pattern'"),
            (["type": "job_output_matches", "pattern": "a"], "condition 0: job_output_matches needs a non-empty string 'job'"),
            (["type": "job_output_matches", "job": "j1"], "condition 0: job_output_matches needs a string 'pattern'"),
        ]
        for (condition, expected) in cases {
            let message = await failure(h, ["name": "Win", "conditions": [condition]])
            XCTAssertEqual(message, expected)
        }
    }

    func testInvalidRegularExpressions() async throws {
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let text = await failure(h, ["name": "Win", "conditions": [["type": "screen_idle"], ["type": "text_visible", "text": "(", "regex": true]]])
        XCTAssertEqual(text, "condition 1: '(' is not a valid regular expression")
        let log = await failure(h, ["name": "Win", "conditions": [["type": "log_matches", "path": "/x", "pattern": "[a"]]])
        XCTAssertEqual(log, "condition 0: '[a' is not a valid regular expression")
        let job = await failure(h, ["name": "Win", "conditions": [["type": "job_output_matches", "job": "j", "pattern": "*"]]])
        XCTAssertEqual(job, "condition 0: '*' is not a valid regular expression")
    }

    func testObserveOptionsAreValidated() async throws {
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let level = await failure(h, ["name": "Win", "conditions": [["type": "screen_idle"]], "observe": "loud"])
        XCTAssertEqual(level, "observe must be one of none, summary, diff, image")
        let settle = await failure(h, ["name": "Win", "conditions": [["type": "screen_idle"]], "observe": "summary", "settleMs": -5])
        XCTAssertEqual(settle, "settleMs must be between 0 and 10000")
    }

    // MARK: - observation

    func testObservationComparesTheStartWithTheSettledScreen() async throws {
        let a = solid(320, 192, 40)
        let changed = paint(a, tileX: 2, tileY: 1)
        let (h, _) = await screenRig(frames: [a, a, changed])
        let r = try await waitFor(h, [["type": "region_changed", "region": ["x": 64, "y": 32, "w": 32, "h": 32]]],
                                  timeout: 2, ["observe": "summary", "settleMs": 60])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        let observation = try XCTUnwrap(r["observation"])
        XCTAssertEqual(observation["settled"]?.boolValue, true)
        XCTAssertEqual(observation["changed"], ["x": 64, "y": 32, "w": 32, "h": 32])
    }

    func testUnreadableScreenAfterTheWaitReportsObservationError() async throws {
        let a = solid(320, 192, 40)
        let (h, t) = await screenRig(frames: [a, paint(a, tileX: 2, tileY: 1)])
        await t.setFailingFrameCalls(Set(2...40))
        let r = try await waitFor(h, [["type": "region_changed", "region": ["x": 64, "y": 32, "w": 32, "h": 32]]],
                                  timeout: 2, ["observe": "summary", "settleMs": 60])
        XCTAssertNil(r["observation"])
        XCTAssertTrue(r["observationError"]?.stringValue?.hasPrefix("the screen could not be read after vm.wait_for") ?? false, "\(r)")
    }

    func testObservationAlsoAccompaniesATimeout() async throws {
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let r = try await waitFor(h, [["type": "screen_idle", "seconds": 100]], timeout: 1, ["observe": "summary", "settleMs": 60])
        XCTAssertEqual(r["matched"]?.intValue, -1)
        XCTAssertEqual(r["observation"]?["width"]?.intValue, 64)
    }

    // MARK: - classification and batches

    func testClassification() {
        XCTAssertTrue(ControlHandler.knownOps.contains("vm.wait_for"))
        XCTAssertTrue(ControlHandler.isReadOnly(op: "vm.wait_for"))
        XCTAssertFalse(ControlHandler.isConcurrent(op: "vm.wait_for"))
        XCTAssertFalse(ControlHandler.isInput(op: "vm.wait_for"))
    }

    func testRunsAsABatchStep() async throws {
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let r = try await h.handle(op: "vm.batch", params: [
            "name": "Win",
            "steps": [["op": "vm.wait_for", "conditions": [["type": "screen_idle", "seconds": 0.1]], "timeout": 2]],
        ])
        XCTAssertEqual(r["completed"]?.intValue, 1)
        XCTAssertEqual(r["results"]?.arrayValue?.first?["matched"]?.intValue, 0)
    }

    func testRefusedOnAStoppedVM() async throws {
        let t = FakeTarget(name: "Win", state: .stopped, png: makePNG(width: 8, height: 8))
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test")
        let message = await failure(h, ["name": "Win", "conditions": [["type": "screen_idle"]]])
        XCTAssertTrue(message.contains("stopped"), message)
    }
}
