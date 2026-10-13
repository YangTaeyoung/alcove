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

/// Holds the threads that call `pass` until `open` is called; an opened gate stays open.
final class RecognitionGate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func pass() {
        semaphore.wait()
        semaphore.signal()
    }

    func open() { semaphore.signal() }
}

/// Returns once the recognitions asked of the shared queue before this call have ended.
func recognitionsEnded() async {
    _ = await RecognitionQueue.shared.recognize(solid(1, 1, 0), languages: ["drain"], recognizer: { _, _ in [] })
}

/// The value of `task` once it finished; nil when it has not finished within `limit`.
func finishedValue<T: Sendable, Failure: Error>(of task: Task<T, Failure>, within limit: Duration = .seconds(20)) async throws -> T? {
    let box = LockedBox<Result<T, Failure>?>(nil)
    Task { box.value = await task.result }
    guard await eventually(timeout: limit, { box.value != nil }), let result = box.value else { return nil }
    return try result.get()
}

final class WaitTests: XCTestCase {
    override func setUp() async throws {
        await recognitionsEnded()
        WaitTiming.tick = .milliseconds(20)
        WaitTiming.screenPeriod = .milliseconds(20)
        WaitTiming.ocrPeriod = .milliseconds(60)
        WaitTiming.agentPeriod = .milliseconds(40)
        WaitTiming.agentCallTimeout = .seconds(3)
        WaitTiming.recognitionGrace = .milliseconds(300)
    }

    override func tearDown() async throws {
        await recognitionsEnded()
        WaitTiming.tick = .milliseconds(250)
        WaitTiming.screenPeriod = .milliseconds(250)
        WaitTiming.ocrPeriod = .milliseconds(700)
        WaitTiming.agentPeriod = .milliseconds(500)
        WaitTiming.agentCallTimeout = .seconds(5)
        WaitTiming.recognitionGrace = .seconds(1)
        WaitTiming.reportedSilence = .milliseconds(500)
        WaitTiming.jobByteBudget = 4 * 1024 * 1024
        WaitTiming.recognizer = { try ScreenText.recognize($0, languages: $1) }
        WaitTiming.supportedLanguages = { try ScreenText.supportedLanguages.get() }
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
        XCTAssertNil(r["problems"])
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

    func testTextVisibleAddsTheRegionOriginToTheMatchRectangle() async throws {
        WaitTiming.recognizer = { frame, _ in
            [TextMatch(text: "Edge", rect: Frame.Rect(x: frame.width - 1, y: frame.height - 1, w: 1, h: 1), confidence: 1)]
        }
        let (h, _) = await screenRig(frames: [solid(1280, 800, 10)])
        let r = try await waitFor(h, [["type": "text_visible", "text": "edge", "languages": ["en-US"],
                                       "region": ["x": 500, "y": 350, "w": 400, "h": 200]]], timeout: 10)
        XCTAssertEqual(r["detail"], ["text": "Edge", "x": 899, "y": 549, "w": 1, "h": 1, "cx": 899, "cy": 549])
    }

    func testTextConditionsWithoutLanguagesUseTheMergedReading() async throws {
        let seen = LockedBox<[[String]]>([])
        WaitTiming.recognizer = { _, languages in
            seen.value.append(languages)
            let text = languages == ["en-US"] ? "Alcove OCR check" : "Alcove OR check"
            return [TextMatch(text: text, rect: Frame.Rect(x: 45, y: 117, w: 130, h: 15), confidence: 1)]
        }
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let merged = try await waitFor(h, [["type": "text_gone", "text": "nothing"], ["type": "text_visible", "text": "OCR check"]], timeout: 10)
        XCTAssertEqual(merged["matched"]?.intValue, 0)
        XCTAssertEqual(seen.value, [["ko-KR", "en-US"], ["en-US"]])
        let found = try await waitFor(h, [["type": "text_visible", "text": "OCR check"]], timeout: 10)
        XCTAssertEqual(found["detail"]?["text"]?.stringValue, "Alcove OCR check")

        seen.value = []
        let single = try await waitFor(h, [["type": "text_visible", "text": "OCR check", "languages": ["ko-KR", "en-US"]]], timeout: 1)
        XCTAssertEqual(single["matched"]?.intValue, -1)
        XCTAssertFalse(seen.value.isEmpty)
        XCTAssertTrue(seen.value.allSatisfy { $0 == ["ko-KR", "en-US"] }, "\(seen.value)")
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
                       "command -v ss >/dev/null 2>&1 || { echo \"ss is not installed in the guest; install the iproute2 package\" >&2; exit 127; }\n"
                       + "ss -ltn \"sport = :8080\" | tail -n +2 | grep -q . && echo 1 || echo 0")
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

    func testLogReadErrorsOnAnExistingFileAreRetried() async throws {
        let calls = LockedBox(0)
        let agent = FakeAgent()
        agent.handler = { m, _ in
            switch m["op"]?.stringValue {
            case "fs.tail":
                calls.value += 1
                if calls.value <= 2 { return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": "sharing violation"]] }
                return [agentReply(m, ["data": base64("server ready\n"), "size": 13])]
            case "fs.stat": return [agentReply(m, ["exists": true, "dir": false, "size": 1])]
            default: return []
            }
        }
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "log_matches", "path": "C:\\x.log", "pattern": "ready"]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertNil(r["problems"])
    }

    func testAWaitThatEndsUnmatchedNamesTheConditionThatKeptFailing() async throws {
        let agent = FakeAgent()
        agent.handler = { m, _ in
            switch m["op"]?.stringValue {
            case "fs.tail": return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": "access denied"]]
            case "fs.stat": return [agentReply(m, ["exists": .bool(m["path"]?.stringValue == "C:\\x.log"), "dir": false, "size": 1])]
            default: return []
            }
        }
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "file_exists", "path": "C:\\never"], ["type": "log_matches", "path": "C:\\x.log", "pattern": "a"]], timeout: 1)
        XCTAssertEqual(r["matched"]?.intValue, -1)
        let problems = try XCTUnwrap(r["problems"]?.arrayValue, "\(r)")
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems[0]["condition"]?.intValue, 1)
        XCTAssertEqual(problems[0]["type"]?.stringValue, "log_matches")
        XCTAssertEqual(problems[0]["error"]?.stringValue, "access denied")
        XCTAssertGreaterThan(problems[0]["failures"]?.intValue ?? 0, 2)
    }

    func testAMatchCarriesNoProblems() async throws {
        let fs = FakeFS()
        fs["C:\\a"] = Data("a".utf8)
        let agent = FakeAgent()
        fs.install(on: agent)
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "file_exists", "path": "C:\\a"]])
        XCTAssertNil(r["problems"])
    }

    func testPortCheckWithANonZeroExitIsPending() async throws {
        let calls = LockedBox(0)
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "exec.run" else { return [] }
            calls.value += 1
            if calls.value <= 2 { return [agentReply(m, ["code": 127, "stdout": "", "stderr": "ss is not installed in the guest; install the iproute2 package\n"])] }
            return [agentReply(m, ["code": 0, "stdout": "1\n", "stderr": ""])]
        }
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "port_listening", "port": 22]])
        XCTAssertEqual(r["matched"]?.intValue, 0)

        let failing = FakeAgent()
        failing.handler = { m, _ in
            guard m["op"]?.stringValue == "exec.run" else { return [] }
            return [agentReply(m, ["code": 127, "stdout": "", "stderr": "ss is not installed in the guest; install the iproute2 package\n"])]
        }
        let (h2, _) = try await agentRig(failing)
        let timedOut = try await waitFor(h2, [["type": "port_listening", "port": 22]], timeout: 1)
        XCTAssertEqual(timedOut["matched"]?.intValue, -1)
        XCTAssertEqual(timedOut["problems"]?[0]?["error"]?.stringValue,
                       "the port check failed: the guest command exited with code 127: ss is not installed in the guest; install the iproute2 package")
    }

    func testAPortCheckThatFailsQuotesTheFirstLineOfItsOutput() async throws {
        let long = String(repeating: "x", count: 250)
        let replies: [(code: Int, stdout: String, stderr: String, sentence: String)] = [
            (3, "netstat: unknown option\r\nusage: netstat\r\n", "", "the guest command exited with code 3: netstat: unknown option"),
            (1, "\r\n  \r\nlate line\r\n", "", "the guest command exited with code 1: late line"),
            (0, "", "warning: profile not loaded\nsecond line\n", "the guest command exited with code 0: warning: profile not loaded"),
            (2, "on stdout\n", "on stderr\n", "the guest command exited with code 2: on stderr"),
            (5, long + "\n", "", "the guest command exited with code 5: " + String(repeating: "x", count: 200)),
        ]
        for reply in replies {
            let agent = FakeAgent()
            agent.handler = { m, _ in
                guard m["op"]?.stringValue == "exec.run" else { return [] }
                return [agentReply(m, ["code": .int(Int64(reply.code)), "stdout": .string(reply.stdout), "stderr": .string(reply.stderr)])]
            }
            let (h, _) = try await agentRig(agent)
            let r = try await waitFor(h, [["type": "port_listening", "port": 22]], timeout: 1)
            XCTAssertEqual(r["matched"]?.intValue, -1)
            XCTAssertEqual(r["problems"]?[0]?["error"]?.stringValue, "the port check failed: \(reply.sentence)")
        }
    }

    func testAPortCheckThatPrintsNothingNamesTheNextStep() async throws {
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "exec.run" else { return [] }
            return [agentReply(m, ["code": 0, "stdout": "\r\n", "stderr": ""])]
        }
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "port_listening", "port": 22]], timeout: 1)
        XCTAssertEqual(r["matched"]?.intValue, -1)
        XCTAssertEqual(r["problems"]?[0]?["error"]?.stringValue,
                       "the port check failed: the guest command exited with code 0 and printed nothing; run vm.doctor to check the guest shell")
    }

    func testRecognitionFailuresAreRetried() async throws {
        let calls = LockedBox(0)
        WaitTiming.recognizer = { frame, languages in
            calls.value += 1
            if calls.value <= 3 { throw ControlHandler.ControlError.recognitionFailed("transient") }
            return try ScreenText.recognize(frame, languages: languages)
        }
        let drawn = drawText([("Install complete", 100, 120)])
        let (h, _) = await screenRig(frames: [drawn.frame])
        let r = try await waitFor(h, [["type": "text_visible", "text": "install complete"]], timeout: 10)
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertGreaterThan(calls.value, 3)
    }

    private static let unfinished = "the text recognition did not finish within the timeout; call vm.wait_for again"
    private static let unstarted = "the text recognition was waiting behind other recognitions and did not start; call vm.wait_for again"
    private static let ready = TextMatch(text: "ready", rect: Frame.Rect(x: 1, y: 2, w: 30, h: 10), confidence: 1)

    func testARecognitionThatOutlastsTheTimeoutDoesNotHoldTheWait() async throws {
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        WaitTiming.recognizer = { _, _ in
            gate.pass()
            return []
        }
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let r = try await waitFor(h, [["type": "text_visible", "text": "ready"]], timeout: 1)
        XCTAssertTrue(RecognitionQueue.shared.load.running)
        XCTAssertEqual(r["matched"]?.intValue, -1)
        let problems = try XCTUnwrap(r["problems"]?.arrayValue, "\(r)")
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems[0]["type"]?.stringValue, "text_visible")
        XCTAssertEqual(problems[0]["error"]?.stringValue, WaitTests.unfinished)
        XCTAssertNil(problems[0]["failures"])
        gate.open()
        await recognitionsEnded()
    }

    func testARecognitionThatStraddlesTheTimeoutStillCounts() async throws {
        let began = LockedBox<ContinuousClock.Instant?>(nil)
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        WaitTiming.recognitionGrace = .seconds(30)
        WaitTiming.recognizer = { _, _ in
            if began.value == nil { began.value = .now }
            gate.pass()
            return [WaitTests.ready]
        }
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let wait = Task {
            try await h.handle(op: "vm.wait_for", params: ["name": "Win", "timeout": 1, "conditions": [["type": "text_visible", "text": "ready"]]])
        }
        let asked = await eventually { began.value != nil }
        XCTAssertTrue(asked)
        let timeoutPassed = try XCTUnwrap(began.value) + .seconds(1)
        try await Task.sleep(until: timeoutPassed, clock: .continuous)
        gate.open()
        let r = try await wait.value
        XCTAssertEqual(r["matched"]?.intValue, 0, "\(r)")
        XCTAssertGreaterThanOrEqual(r["waited"]?.doubleValue ?? 0, 1.0)
        XCTAssertNil(r["problems"])
        await recognitionsEnded()
    }

    // MARK: - the recognition queue

    func testTimedOutWaitsOnTheSameFrameLeaveOneRecognitionRunning() async throws {
        let calls = LockedBox(0)
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        WaitTiming.recognizer = { _, _ in
            calls.value += 1
            gate.pass()
            return []
        }
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        for _ in 0..<2 {
            let r = try await waitFor(h, [["type": "text_visible", "text": "ready", "languages": ["en-US"]]], timeout: 1)
            XCTAssertEqual(r["matched"]?.intValue, -1)
            XCTAssertEqual(r["problems"]?[0]?["error"]?.stringValue, WaitTests.unfinished)
        }
        XCTAssertEqual(calls.value, 1)
        let load = RecognitionQueue.shared.load
        XCTAssertTrue(load.running)
        XCTAssertEqual(load.callers, 0)
        XCTAssertEqual(load.waiting, 0)
        gate.open()
        await recognitionsEnded()
        XCTAssertEqual(calls.value, 1)
    }

    func testARecognitionWhoseWaitEndedBeforeItsTurnIsNeverStarted() async throws {
        let seen = LockedBox<[[String]]>([])
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        WaitTiming.recognizer = { _, languages in
            seen.value.append(languages)
            gate.pass()
            return []
        }
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let first = try await waitFor(h, [["type": "text_visible", "text": "ready", "languages": ["ko-KR"]]], timeout: 1)
        XCTAssertEqual(first["problems"]?[0]?["error"]?.stringValue, WaitTests.unfinished)
        let second = try await waitFor(h, [["type": "text_visible", "text": "ready", "languages": ["en-US"]]], timeout: 1)
        XCTAssertEqual(second["matched"]?.intValue, -1)
        XCTAssertEqual(second["problems"]?[0]?["error"]?.stringValue, WaitTests.unstarted)
        let load = RecognitionQueue.shared.load
        XCTAssertTrue(load.running)
        XCTAssertEqual(load.waiting, 0)
        gate.open()
        await recognitionsEnded()
        XCTAssertEqual(seen.value, [["ko-KR"]])
    }

    func testWaitsOnTheSameFrameShareOneRecognition() async throws {
        let calls = LockedBox(0)
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        WaitTiming.recognizer = { _, _ in
            calls.value += 1
            gate.pass()
            return [WaitTests.ready]
        }
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let params: JSON = ["name": "Win", "timeout": 60, "conditions": [["type": "text_visible", "text": "ready", "languages": ["en-US"]]]]
        let first = Task { try await h.handle(op: "vm.wait_for", params: params) }
        let second = Task { try await h.handle(op: "vm.wait_for", params: params) }
        let joined = await eventually { RecognitionQueue.shared.load.callers == 2 }
        XCTAssertTrue(joined)
        XCTAssertEqual(RecognitionQueue.shared.load.waiting, 0)
        gate.open()
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a["matched"]?.intValue, 0)
        XCTAssertEqual(b["matched"]?.intValue, 0)
        XCTAssertEqual(calls.value, 1)
        await recognitionsEnded()
    }

    func testFindTextBehindARunningRecognitionAnswersAfterIt() async throws {
        let seen = LockedBox<[[String]]>([])
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        WaitTiming.recognizer = { _, languages in
            seen.value.append(languages)
            if languages == ["ko-KR"] { gate.pass() }
            return [WaitTests.ready]
        }
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let wait = Task {
            try await h.handle(op: "vm.wait_for", params: ["name": "Win", "timeout": 60, "conditions": [
                ["type": "text_visible", "text": "ready", "languages": ["ko-KR"]],
            ]])
        }
        let running = await eventually { RecognitionQueue.shared.load.running }
        XCTAssertTrue(running)
        let answered = LockedBox(false)
        let find = Task {
            let r = try await h.handle(op: "vm.find_text", params: ["name": "Win", "query": "ready", "languages": ["en-US"]])
            answered.value = true
            return r
        }
        let queued = await eventually { RecognitionQueue.shared.load.waiting == 1 }
        XCTAssertTrue(queued)
        XCTAssertFalse(answered.value)
        XCTAssertEqual(seen.value, [["ko-KR"]])
        gate.open()
        let found = try await find.value
        XCTAssertEqual(found["matches"]?.arrayValue?.count, 1)
        XCTAssertEqual(seen.value, [["ko-KR"], ["en-US"]])
        let waited = try await wait.value
        XCTAssertEqual(waited["matched"]?.intValue, 0)
        await recognitionsEnded()
    }

    func testACancelledCallerLeavesTheQueue() async throws {
        let queue = RecognitionQueue()
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        let started = LockedBox<[Int]>([])
        let recognizer: RecognitionQueue.Recognizer = { frame, _ in
            started.value.append(frame.width)
            gate.pass()
            return []
        }
        let running = Task { await queue.recognize(solid(1, 1, 0), languages: ["en-US"], recognizer: recognizer) != nil }
        let began = await eventually { started.value == [1] }
        XCTAssertTrue(began)
        let behind = Task { await queue.recognize(solid(2, 1, 0), languages: ["en-US"], recognizer: recognizer) != nil }
        let queued = await eventually { queue.load.waiting == 1 }
        XCTAssertTrue(queued)
        behind.cancel()
        let behindAnswered = await behind.value
        XCTAssertFalse(behindAnswered)
        XCTAssertEqual(queue.load.waiting, 0)
        running.cancel()
        let runningAnswered = await running.value
        XCTAssertFalse(runningAnswered)
        XCTAssertTrue(queue.load.running)
        XCTAssertEqual(queue.load.callers, 0)
        gate.open()
        let last = await queue.recognize(solid(3, 1, 0), languages: ["en-US"], recognizer: recognizer)
        XCTAssertEqual(try last?.get(), [])
        XCTAssertEqual(started.value, [1, 3])
        XCTAssertFalse(queue.load.running)
    }

    func testACallerWhoseReadingHasNotBegunAtItsTurnLimitIsAnsweredBusyAndNeverStarted() async throws {
        let queue = RecognitionQueue()
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        let started = LockedBox<[Int]>([])
        let recognizer: RecognitionQueue.Recognizer = { frame, _ in
            started.value.append(frame.width)
            gate.pass()
            return []
        }
        let running = Task { await queue.recognize(solid(1, 1, 0), languages: ["en-US"], recognizer: recognizer, turnBy: .now) }
        let began = await eventually { started.value == [1] }
        XCTAssertTrue(began)
        for limit in [ContinuousClock.now + .milliseconds(50), ContinuousClock.now - .seconds(1)] {
            let behind = Task { await queue.recognize(solid(2, 1, 0), languages: ["en-US"], recognizer: recognizer, turnBy: limit) }
            let late = try await finishedValue(of: behind)
            guard case .failure(let error)?? = late, let busy = error as? RecognitionQueue.Busy else {
                XCTFail("\(String(describing: late))")
                continue
            }
            XCTAssertGreaterThanOrEqual(busy.running, .milliseconds(50))
            XCTAssertEqual(queue.load.waiting, 0)
        }
        gate.open()
        let answered = await running.value
        XCTAssertEqual(try answered?.get(), [])
        XCTAssertEqual(started.value, [1])
    }

    func testAReadingWhoseOnlyCallerLeftWhenItBecameTheRunningOneIsNotStarted() async throws {
        let queue = RecognitionQueue()
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        let started = LockedBox<[Int]>([])
        let recognizer: RecognitionQueue.Recognizer = { frame, _ in
            started.value.append(frame.width)
            gate.pass()
            return []
        }
        let first = Task { await queue.recognize(solid(1, 1, 0), languages: ["en-US"], recognizer: recognizer) != nil }
        let began = await eventually { started.value == [1] }
        XCTAssertTrue(began)
        let second = LockedBox<Task<Bool, Never>?>(nil)
        second.value = Task {
            await queue.recognize(solid(2, 1, 0), languages: ["en-US"], recognizer: recognizer, began: { second.value?.cancel() }) != nil
        }
        let secondQueued = await eventually { queue.load.waiting == 1 }
        XCTAssertTrue(secondQueued)
        let third = Task { await queue.recognize(solid(3, 1, 0), languages: ["en-US"], recognizer: recognizer) != nil }
        let thirdQueued = await eventually { queue.load.waiting == 2 }
        XCTAssertTrue(thirdQueued)
        gate.open()
        let firstAnswered = await first.value, secondAnswered = await second.value?.value, thirdAnswered = await third.value
        XCTAssertTrue(firstAnswered)
        XCTAssertEqual(secondAnswered, false)
        XCTAssertTrue(thirdAnswered)
        XCTAssertEqual(started.value, [1, 3])
        XCTAssertFalse(queue.load.running)
    }

    func testACallerIsToldOnceWhenItsReadingBegins() async throws {
        let queue = RecognitionQueue()
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        let entered = LockedBox(0)
        let recognizer: RecognitionQueue.Recognizer = { _, _ in
            entered.value += 1
            gate.pass()
            return []
        }
        let told = LockedBox<[String]>([])
        let first = Task { await queue.recognize(solid(1, 1, 0), languages: ["en-US"], recognizer: recognizer, began: { told.value.append("first") }) }
        let running = await eventually { entered.value == 1 }
        XCTAssertTrue(running)
        XCTAssertEqual(told.value, ["first"])
        let joiner = Task { await queue.recognize(solid(1, 1, 0), languages: ["en-US"], recognizer: recognizer, began: { told.value.append("joiner") }) }
        let joined = await eventually { told.value == ["first", "joiner"] }
        XCTAssertTrue(joined, "\(told.value)")
        XCTAssertEqual(queue.load.callers, 2)
        let behind = Task { await queue.recognize(solid(2, 1, 0), languages: ["en-US"], recognizer: recognizer, began: { told.value.append("behind") }) }
        let queued = await eventually { queue.load.waiting == 1 }
        XCTAssertTrue(queued)
        XCTAssertEqual(told.value, ["first", "joiner"])
        gate.open()
        _ = await (first.value, joiner.value, behind.value)
        XCTAssertEqual(told.value, ["first", "joiner", "behind"])
        XCTAssertEqual(entered.value, 2)
    }

    func testTheWarmUpCallsTheSecondRecognizerAlsoWhenTheFirstRecognitionThrows() async throws {
        let seen = LockedBox<[[String]]>([])
        WaitTiming.recognizer = { frame, languages in
            seen.value.append(languages)
            XCTAssertEqual([frame.width, frame.height], [400, 64])
            throw ControlHandler.ControlError.recognitionFailed("transient")
        }
        let queue = RecognitionQueue()
        queue.warmUp()
        _ = await queue.recognize(solid(1, 1, 0), languages: ["drain"], recognizer: { _, _ in [] })
        XCTAssertEqual(seen.value, [["ko-KR", "en-US"], ["en-US"]])
    }

    func testTheWarmUpRunsAtUtilityAndTheReadingOfACallerAtUserInitiated() async throws {
        let classes = LockedBox<[qos_class_t]>([])
        let recognizer: RecognitionQueue.Recognizer = { _, _ in
            classes.value.append(qos_class_self())
            return []
        }
        WaitTiming.recognizer = recognizer
        let queue = RecognitionQueue()
        queue.warmUp()
        _ = await queue.recognize(solid(1, 1, 0), languages: ["en-US"], recognizer: recognizer)
        XCTAssertEqual(classes.value, [QOS_CLASS_UTILITY, QOS_CLASS_UTILITY, QOS_CLASS_USER_INITIATED])
    }

    func testACallerThatAsksForTheWarmUpFrameGetsAReadingOfItsOwn() async throws {
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        let calls = LockedBox(0)
        let recognizer: RecognitionQueue.Recognizer = { _, _ in
            calls.value += 1
            gate.pass()
            throw ControlHandler.ControlError.recognitionFailed("transient")
        }
        WaitTiming.recognizer = recognizer
        let queue = RecognitionQueue()
        queue.warmUp()
        let warming = await eventually { calls.value == 1 }
        XCTAssertTrue(warming)
        let caller = Task { await queue.recognize(ScreenText.warmUpFrame(), languages: nil, recognizer: recognizer) }
        let queued = await eventually { queue.load.waiting == 1 }
        XCTAssertTrue(queued)
        XCTAssertEqual(queue.load.callers, 1)
        gate.open()
        let outcome = await caller.value
        XCTAssertThrowsError(try outcome?.get())
        XCTAssertEqual(calls.value, 3)
    }

    func testFindTextWhoseTurnDoesNotComeWithinItsLimitAnswersBusyAndLeavesTheQueue() async throws {
        let seen = LockedBox<[[String]]>([])
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        WaitTiming.recognizer = { _, languages in
            seen.value.append(languages)
            gate.pass()
            return [WaitTests.ready]
        }
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        await h.setTextTurnLimit(.milliseconds(50))
        let first = Task { try await h.handle(op: "vm.find_text", params: ["name": "Win", "query": "ready", "languages": ["ko-KR"]]) }
        let running = await eventually { seen.value == [["ko-KR"]] }
        XCTAssertTrue(running)
        let behind = Task { () -> String in
            do {
                _ = try await h.handle(op: "vm.find_text", params: ["name": "Win", "query": "ready", "languages": ["en-US"]])
                return "answered"
            } catch {
                return "\(error)"
            }
        }
        let answer = try await finishedValue(of: behind)
        let message = try XCTUnwrap(answer, "vm.find_text went on waiting for its turn")
        XCTAssertNotNil(message.wholeMatch(of: /the text recognition is busy \(another reading has been running for \d+ s\); retry in a few seconds/), message)
        XCTAssertEqual(RecognitionQueue.shared.load.waiting, 0)
        gate.open()
        let found = try await first.value
        XCTAssertEqual(found["matches"]?.arrayValue?.count, 1)
        await recognitionsEnded()
        XCTAssertEqual(seen.value, [["ko-KR"]])
    }

    func testTheBusySentenceOfFindTextCountsWholeSeconds() {
        XCTAssertEqual(ControlHandler.recognitionBusy(running: .milliseconds(33_400)),
                       "the text recognition is busy (another reading has been running for 33 s); retry in a few seconds")
        XCTAssertEqual(ControlHandler.recognitionBusy(running: .milliseconds(200)),
                       "the text recognition is busy (another reading has been running for 0 s); retry in a few seconds")
    }

    // MARK: - text readings in tasks of their own

    func testEightTextReadingsBehindAHeldRecognitionAreGivenUpTogetherAndEachConditionIsListed() async throws {
        WaitTiming.recognitionGrace = .seconds(1)
        let widths = LockedBox<[Int]>([])
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        WaitTiming.recognizer = { frame, _ in
            widths.value.append(frame.width)
            gate.pass()
            return []
        }
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let conditions: [JSON] = (1...8).map {
            ["type": "text_visible", "text": "ready", "languages": ["en-US"], "region": ["x": 0, "y": 0, "w": .int(Int64($0 * 4)), "h": 8]]
        }
        let wait = Task { try await h.handle(op: "vm.wait_for", params: ["name": "Win", "timeout": 1, "conditions": .array(conditions)]) }
        let together = await eventually { RecognitionQueue.shared.load.waiting == 7 }
        XCTAssertTrue(together, "the eight readings were not in the recognition queue at the same time")
        let r = try await wait.value
        XCTAssertEqual(r["matched"]?.intValue, -1)
        XCTAssertLessThan(r["waited"]?.doubleValue ?? 99, 3.0, "the wait took the grace more than once")
        let problems = try XCTUnwrap(r["problems"]?.arrayValue, "\(r)")
        XCTAssertEqual(problems.map { $0["condition"]?.intValue }, Array(0..<8))
        XCTAssertEqual(widths.value.count, 1)
        let begun = (widths.value.first ?? 0) / 4 - 1
        for (index, problem) in problems.enumerated() {
            XCTAssertEqual(problem["type"]?.stringValue, "text_visible")
            XCTAssertEqual(problem["error"]?.stringValue, index == begun ? WaitTests.unfinished : WaitTests.unstarted, "condition \(index)")
            XCTAssertNil(problem["failures"])
        }
        let load = RecognitionQueue.shared.load
        XCTAssertTrue(load.running)
        XCTAssertEqual(load.callers, 0)
        XCTAssertEqual(load.waiting, 0)
        gate.open()
        await recognitionsEnded()
        XCTAssertEqual(widths.value.count, 1)
    }

    func testAConditionThatHoldsWhileATextReadingIsHeldEndsTheWaitAtOnce() async throws {
        let entered = LockedBox(0)
        let gate = RecognitionGate()
        addTeardownBlock { gate.open() }
        WaitTiming.recognizer = { _, _ in
            entered.value += 1
            gate.pass()
            return []
        }
        let alive = LockedBox(true)
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "proc.list" else { return [] }
            return [agentReply(m, ["procs": alive.value ? [["pid": 42, "ppid": 1, "name": "Setup.exe"]] : []])]
        }
        let (h, _) = try await agentRig(agent, frames: [solid(64, 64, 10)])
        let wait = Task {
            try await h.handle(op: "vm.wait_for", params: ["name": "Win", "timeout": 300, "conditions": [
                ["type": "text_visible", "text": "ready", "languages": ["en-US"]], ["type": "process_exited", "pid": 42],
            ]])
        }
        addTeardownBlock { wait.cancel() }
        let judged = await eventually { entered.value == 1 && agentRequests(agent, "proc.list").count >= 2 }
        XCTAssertTrue(judged, "the process list was not read again while the reading was held")
        alive.value = false
        let ended = try await finishedValue(of: wait)
        let r = try XCTUnwrap(ended, "the wait did not end while the reading was held")
        XCTAssertEqual(r["matched"]?.intValue, 1)
        XCTAssertEqual(r["type"]?.stringValue, "process_exited")
        XCTAssertEqual(entered.value, 1)
        XCTAssertTrue(RecognitionQueue.shared.load.running)
        gate.open()
        await recognitionsEnded()
    }

    func testTextConditionsOnTheSameAreaAndLanguagesCauseOneRecognizerCallPerFrame() async throws {
        let shades = LockedBox<[UInt8]>([])
        WaitTiming.recognizer = { frame, _ in
            let shade = frame.pixels.first ?? 0
            shades.value.append(shade)
            return shade == 4 ? [WaitTests.ready] : []
        }
        let (h, t) = await screenRig(frames: (0...4).map { solid(64, 64, UInt8($0)) })
        let r = try await waitFor(h, [["type": "text_visible", "text": "steady", "languages": ["en-US"]],
                                      ["type": "text_visible", "text": "ready", "languages": ["en-US"]]], timeout: 60)
        XCTAssertEqual(r["matched"]?.intValue, 1)
        XCTAssertEqual(shades.value, [1, 2, 3, 4])
        let frames = await t.frameCalls
        XCTAssertEqual(frames, 5)
    }

    func testAnUnchangedFrameIsReadOncePerAreaAndLanguagesAndAChangedFrameAgain() async throws {
        struct Call: Equatable {
            let width: Int
            let shade: UInt8
        }
        let calls = LockedBox<[Call]>([])
        WaitTiming.recognizer = { frame, _ in
            let call = Call(width: frame.width, shade: frame.pixels.first ?? 0)
            calls.value.append(call)
            return call == Call(width: 32, shade: 20) ? [WaitTests.ready] : []
        }
        let (h, t) = await screenRig(frames: Array(repeating: solid(64, 64, 10), count: 21) + [solid(64, 64, 20)])
        let r = try await waitFor(h, [
            ["type": "text_visible", "text": "ready", "languages": ["en-US"]],
            ["type": "text_visible", "text": "ready", "languages": ["en-US"], "region": ["x": 0, "y": 0, "w": 32, "h": 32]],
        ], timeout: 60)
        XCTAssertEqual(r["matched"]?.intValue, 1)
        let frames = await t.frameCalls
        XCTAssertGreaterThanOrEqual(frames, 22)
        let unchanged = calls.value.filter { $0.shade == 10 }
        XCTAssertEqual(unchanged.map(\.width).sorted(), [32, 64])
        XCTAssertEqual(calls.value.filter { $0 == Call(width: 32, shade: 20) }.count, 1)
        XCTAssertLessThanOrEqual(calls.value.filter { $0 == Call(width: 64, shade: 20) }.count, 1)
    }

    func testAFailureOfTheSecondRecognitionOfAReadingWithoutLanguagesFailsTheReadingAndTheNextPeriodReadsAgain() async throws {
        let seen = LockedBox<[[String]]>([])
        WaitTiming.recognizer = { _, languages in
            seen.value.append(languages)
            if seen.value.count == 2 { throw ControlHandler.ControlError.recognitionFailed("transient") }
            return [WaitTests.ready]
        }
        let (h, _) = await screenRig(frames: [solid(64, 64, 10)])
        let r = try await waitFor(h, [["type": "text_visible", "text": "ready"]], timeout: 60)
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertEqual(seen.value, [["ko-KR", "en-US"], ["en-US"], ["ko-KR", "en-US"], ["en-US"]])

        WaitTiming.recognizer = { _, languages in
            if languages == ["en-US"] { throw ControlHandler.ControlError.recognitionFailed("the second pass failed") }
            return [WaitTests.ready]
        }
        let failing = try await waitFor(h, [["type": "text_visible", "text": "ready"]], timeout: 1)
        XCTAssertEqual(failing["matched"]?.intValue, -1)
        XCTAssertEqual(failing["problems"]?[0]?["error"]?.stringValue, "text recognition failed: the second pass failed")
        XCTAssertGreaterThan(failing["problems"]?[0]?["failures"]?.intValue ?? 0, 1)
    }

    func testFrameReadFailuresAreRetried() async throws {
        let a = solid(320, 192, 40)
        let (h, t) = await screenRig(frames: [a, paint(a, tileX: 2, tileY: 1)])
        await t.setFailingFrameCalls([1, 2, 3])
        let r = try await waitFor(h, [["type": "region_changed", "region": ["x": 64, "y": 32, "w": 32, "h": 32]]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
    }

    func testARegionThatNoLongerFitsTheFrameCountsAsChanged() async throws {
        let (h, _) = await screenRig(frames: [solid(320, 192, 40), solid(64, 64, 40)])
        let r = try await waitFor(h, [["type": "region_changed", "region": ["x": 200, "y": 100, "w": 32, "h": 32]]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
    }

    func testJobOutputBeyondTheTickBudgetIsReadBeforeTheJobCountsAsExited() async throws {
        WaitTiming.jobByteBudget = 16
        let output = String(repeating: "abcd", count: 25) + "THE-END"
        let bytes = Array(output.utf8)
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "exec.read" else { return [] }
            let offset = m["out_offset"]?.intValue ?? 0
            let end = min(offset + 4, bytes.count)
            let piece = String(decoding: bytes[offset..<end], as: UTF8.self)
            return [agentReply(m, ["state": "exited", "code": 0, "out": .string(piece), "err": "", "out_next": .int(Int64(end)), "err_next": 0])]
        }
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "job_output_matches", "job": "j1", "pattern": "THE-END$"]], timeout: 10)
        XCTAssertEqual(r["matched"]?.intValue, 0, "\(r)")

        let miss = try await waitFor(h, [["type": "job_output_matches", "job": "j2", "pattern": "NOT-THERE"]], timeout: 10)
        XCTAssertEqual(miss["matched"]?.intValue, -1)
        XCTAssertEqual(miss["detail"]?.stringValue, "job exited")
    }

    func testProcessNameFilterDropsTheExecutableSuffix() async throws {
        let agent = FakeAgent()
        agent.handler = { m, _ in
            guard m["op"]?.stringValue == "proc.list" else { return [] }
            return [agentReply(m, ["procs": [["pid": 9, "ppid": 1, "name": "foo"]]])]
        }
        let (h, _) = try await agentRig(agent)
        let r = try await waitFor(h, [["type": "process_started", "processName": "Foo.EXE"]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertEqual(agentRequests(agent, "proc.list").first?["name"]?.stringValue, "foo")
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

    func testAnAgentCallThatNeverAnswersDoesNotHoldTheWaitPastTheDeadline() async throws {
        WaitTiming.agentCallTimeout = .milliseconds(300)
        let agent = FakeAgent()
        agent.handler = { _, _ in [] }
        let (h, _) = try await agentRig(agent)
        let start = ContinuousClock.now
        let r = try await waitFor(h, [["type": "file_exists", "path": "/x"]], timeout: 1)
        XCTAssertEqual(r["matched"]?.intValue, -1)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(1800))
    }

    func testAgentSilenceCountsFromTheFirstOfTheEvaluationsInARowThatGotNoAnswer() {
        WaitTiming.reportedSilence = .milliseconds(500)
        let start = ContinuousClock.now
        func at(_ milliseconds: Int) -> ContinuousClock.Instant { start + .milliseconds(milliseconds) }
        var silence = AgentSilence()
        XCTAssertNil(silence.sentence(inFlight: nil, now: at(9000)))
        XCTAssertNil(silence.sentence(inFlight: (nil, at(0)), now: at(9000)))
        XCTAssertNil(silence.sentence(inFlight: ("fs.stat", at(0)), now: at(499)))
        XCTAssertEqual(silence.sentence(inFlight: ("fs.stat", at(0)), now: at(500)), "the guest agent has not answered fs.stat for 1 s")
        XCTAssertEqual(silence.sentence(inFlight: ("proc.list", at(1000)), now: at(8400)), "the guest agent has not answered proc.list for 7 s")

        silence.ended(openCall: "fs.tail", started: at(1000))
        XCTAssertNil(silence.sentence(inFlight: nil, now: at(1400)))
        XCTAssertEqual(silence.sentence(inFlight: nil, now: at(3000)), "the guest agent has not answered fs.tail for 2 s")
        silence.ended(openCall: "fs.stat", started: at(6000))
        XCTAssertEqual(silence.sentence(inFlight: nil, now: at(11_000)), "the guest agent has not answered fs.stat for 10 s")
        XCTAssertEqual(silence.sentence(inFlight: ("exec.read", at(10_900)), now: at(11_000)), "the guest agent has not answered exec.read for 10 s")
        XCTAssertEqual(silence.sentence(inFlight: (nil, at(10_900)), now: at(11_000)), "the guest agent has not answered fs.stat for 10 s")

        silence.ended(openCall: nil, started: at(11_000))
        XCTAssertNil(silence.sentence(inFlight: nil, now: at(60_000)))
        XCTAssertNil(silence.sentence(inFlight: ("fs.stat", at(59_900)), now: at(60_000)))
        silence.ended(openCall: "fs.stat", started: at(59_900))
        XCTAssertEqual(silence.sentence(inFlight: ("fs.stat", at(64_950)), now: at(65_000)), "the guest agent has not answered fs.stat for 5 s")

        WaitTiming.reportedSilence = .zero
        XCTAssertEqual(AgentSilence().sentence(inFlight: ("fs.stat", at(0)), now: at(0)), "the guest agent has not answered fs.stat for 0 s")
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

    func testAnUnsupportedTextLanguageIsRefusedBeforeWaiting() async throws {
        let calls = LockedBox(0)
        WaitTiming.recognizer = { _, _ in
            calls.value += 1
            return []
        }
        let (h, t) = await screenRig(frames: [solid(64, 64, 10)])
        for type in ["text_visible", "text_gone"] {
            let message = await failure(h, ["name": "Win", "timeout": 2, "conditions": [
                ["type": "screen_idle", "seconds": 100], ["type": .string(type), "text": "a", "languages": ["en-US", "xx-XX"]],
            ]])
            XCTAssertTrue(message.hasPrefix("condition 1: language 'xx-XX' is not supported; supported: "), message)
            XCTAssertTrue(message.contains("en-US"), message)
        }
        XCTAssertEqual(calls.value, 0)
        let frames = await t.frameCalls
        XCTAssertEqual(frames, 0)
    }

    func testALanguageListThatCannotBeReadIsReportedWithTheConditionIndex() async throws {
        WaitTiming.supportedLanguages = {
            throw NSError(domain: "Vision", code: 9, userInfo: [NSLocalizedDescriptionKey: "the language list is unavailable"])
        }
        let (h, t) = await screenRig(frames: [solid(64, 64, 10)])
        let message = await failure(h, ["name": "Win", "timeout": 2, "conditions": [
            ["type": "screen_idle", "seconds": 100], ["type": "text_gone", "text": "a", "languages": ["en-US"]],
        ]])
        XCTAssertEqual(message, "condition 1: the language list is unavailable")
        let frames = await t.frameCalls
        XCTAssertEqual(frames, 0)
    }

    func testTheSupportedLanguagesAreReadUntilOneReadSucceeds() throws {
        struct Unavailable: Error {}
        let reads = LockedBox(0)
        let list = ScreenText.LanguageList {
            reads.value += 1
            if reads.value == 1 { throw Unavailable() }
            return ["en-US", "ko-KR"]
        }
        XCTAssertThrowsError(try list.get())
        XCTAssertEqual(try list.get(), ["en-US", "ko-KR"])
        XCTAssertEqual(try list.get(), ["en-US", "ko-KR"])
        XCTAssertEqual(reads.value, 2)
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
        XCTAssertEqual(level, "observe must be one of none, summary, diff, image, ui")
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
