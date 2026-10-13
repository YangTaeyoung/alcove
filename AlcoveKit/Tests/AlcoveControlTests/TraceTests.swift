import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveQMP

final class TraceTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alcove-trace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    private func setup(state: VMController.State = .running) -> (ControlHandler, FakeTarget, TestClock) {
        let t = FakeTarget(name: "Win", state: state, png: makePNG(width: 800, height: 600))
        let clock = TestClock()
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", clock: { clock.now },
                               recordingsDirectory: base)
        return (h, t, clock)
    }

    private func start(_ h: ControlHandler, _ extra: [String: JSON] = [:]) async throws -> URL {
        var params: [String: JSON] = ["name": "Win", "video": false]
        for (k, v) in extra { params[k] = v }
        let r = try await h.handle(op: "vm.record.start", params: .object(params))
        return URL(fileURLWithPath: try XCTUnwrap(r["dir"]?.stringValue))
    }

    private func lines(_ dir: URL) throws -> [JSON] {
        let text = try String(contentsOf: dir.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }
    }

    private func failure(_ h: ControlHandler, _ op: String, _ params: JSON) async -> String {
        do { _ = try await h.handle(op: op, params: params); XCTFail("expected failure"); return "" }
        catch { return "\(error)" }
    }

    // MARK: sanitizer

    func testSanitizerRemovesLeaseAndImages() {
        let input: JSON = ["lease": "tok", "png": "AAAA", "jpeg": "BBBB", "keep": 1,
                           "nested": ["lease": "x", "list": [["png": "C", "a": 2]]]]
        let out = TraceSanitizer.sanitize(input)
        XCTAssertNil(out["lease"])
        XCTAssertEqual(out["png"]?.stringValue, "<image omitted>")
        XCTAssertEqual(out["jpeg"]?.stringValue, "<image omitted>")
        XCTAssertEqual(out["keep"]?.intValue, 1)
        XCTAssertNil(out["nested"]?["lease"])
        XCTAssertEqual(out["nested"]?["list"]?[0]?["png"]?.stringValue, "<image omitted>")
        XCTAssertEqual(out["nested"]?["list"]?[0]?["a"]?.intValue, 2)
    }

    func testSanitizerCutsLongStrings() {
        let long = String(repeating: "a", count: 2001)
        let exact = String(repeating: "b", count: 2000)
        let out = TraceSanitizer.sanitize(["text": .string(long), "exact": .string(exact), "list": [.string(long)]])
        XCTAssertEqual(out["text"]?.stringValue, String(repeating: "a", count: 2000) + "…")
        XCTAssertEqual(out["textTruncated"]?.boolValue, true)
        XCTAssertEqual(out["exact"]?.stringValue, exact)
        XCTAssertNil(out["exactTruncated"])
        XCTAssertEqual(out["list"]?[0]?.stringValue, String(repeating: "a", count: 2000) + "…")
    }

    func testSanitizerMasksEnvSecrets() {
        let out = TraceSanitizer.sanitize(["env": ["API_KEY": "k", "github_token": "t", "MySecret": "s", "DB_PASSWORD": "p", "PATH": "/bin"],
                                           "other": ["API_KEY": "visible"]])
        for key in ["API_KEY", "github_token", "MySecret", "DB_PASSWORD"] {
            XCTAssertEqual(out["env"]?[key]?.stringValue, "<masked>", key)
        }
        XCTAssertEqual(out["env"]?["PATH"]?.stringValue, "/bin")
        XCTAssertEqual(out["other"]?["API_KEY"]?.stringValue, "visible")
    }

    // MARK: trace content

    func testTraceMasksSecrets() async throws {
        let (h, _, _) = setup()
        let dir = try await start(h)
        _ = await failure(h, "vm.exec", ["name": "Win", "command": "env", "env": ["API_TOKEN": "hunter2", "HOME": "/root"], "lease": "nope"])
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        let line = try XCTUnwrap(try lines(dir).first)
        XCTAssertEqual(line["params"]?["env"]?["API_TOKEN"]?.stringValue, "<masked>")
        XCTAssertEqual(line["params"]?["env"]?["HOME"]?.stringValue, "/root")
        XCTAssertNil(line["params"]?["lease"])
        let raw = try String(contentsOf: dir.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        XCTAssertFalse(raw.contains("hunter2"))
    }

    func testTraceLineShape() async throws {
        let (h, _, _) = setup()
        let dir = try await start(h)
        _ = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "id": 7, "maxWidth": 100])
        _ = try await h.handle(op: "vm.status", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5])
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        let rows = try lines(dir)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map { $0["seq"]?.intValue }, [1, 2, 3])
        XCTAssertEqual(rows.map { $0["op"]?.stringValue }, ["vm.screenshot", "vm.status", "vm.mouse.click"])
        let ms = rows.compactMap { $0["ms"]?.intValue }
        XCTAssertEqual(ms.count, 3)
        XCTAssertEqual(ms, ms.sorted())
        let first = rows[0]
        XCTAssertEqual(first["ok"]?.boolValue, true)
        XCTAssertNotNil(first["durationMs"]?.intValue)
        XCTAssertNil(first["error"])
        XCTAssertEqual(first["params"]?["maxWidth"]?.intValue, 100)
        XCTAssertNil(first["params"]?["op"])
        XCTAssertNil(first["params"]?["id"])
        XCTAssertEqual(first["result"]?["png"]?.stringValue, "<image omitted>")
        XCTAssertEqual(first["result"]?["sentWidth"]?.intValue, 100)
        let time = try XCTUnwrap(first["time"]?.stringValue)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(formatter.date(from: time), time)
    }

    func testActionOpsGetFrames() async throws {
        let (h, _, _) = setup()
        let dir = try await start(h)
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5])
        _ = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": [["op": "vm.key.press", "key": "a"]]])
        let stop = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        let rows = try lines(dir)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["before"]?.stringValue, "frames/000001-before.jpg")
        XCTAssertEqual(rows[0]["after"]?.stringValue, "frames/000001-after.jpg")
        XCTAssertEqual(rows[1]["before"]?.stringValue, "frames/000002-before.jpg")
        XCTAssertEqual(stop["frames"]?.intValue, 4)
        for name in ["000001-before", "000001-after", "000002-before", "000002-after"] {
            let data = try Data(contentsOf: dir.appendingPathComponent("frames/\(name).jpg"))
            XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF], name)
            let decoded = try XCTUnwrap(Frame(png: data), name)
            XCTAssertEqual(decoded.width, 400)
            XCTAssertEqual(decoded.height, 300)
        }
    }

    func testNonActionOpsHaveNoFrames() async throws {
        let (h, t, _) = setup()
        let dir = try await start(h)
        _ = try await h.handle(op: "vm.screenshot", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.status", params: ["name": "Win"])
        _ = await failure(h, "vm.clipboard.get", ["name": "Win"])
        let calls = await t.frameCalls
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        let rows = try lines(dir)
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            XCTAssertNil(row["before"])
            XCTAssertNil(row["after"])
        }
        XCTAssertEqual(calls, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("frames").path)
        XCTAssertEqual(files, [])
    }

    func testFailedOpIsTraced() async throws {
        let (h, t, _) = setup()
        let dir = try await start(h)
        await t.setFailingFrameCalls([0])
        let message = await failure(h, "vm.mouse.click", ["name": "Win", "x": 5, "y": 5, "button": "bogus"])
        let unknown = await failure(h, "vm.mouse.click", ["name": "Win", "y": 5])
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        let rows = try lines(dir)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["ok"]?.boolValue, false)
        XCTAssertEqual(rows[0]["error"]?.stringValue, message)
        XCTAssertNil(rows[0]["result"])
        XCTAssertNil(rows[0]["before"])
        XCTAssertEqual(rows[0]["after"]?.stringValue, "frames/000001-after.jpg")
        XCTAssertEqual(rows[1]["error"]?.stringValue, unknown)
        XCTAssertEqual(rows[1]["before"]?.stringValue, "frames/000002-before.jpg")
    }

    func testRecordingDoesNotChangeOutcomes() async throws {
        let (plain, _, _) = setup()
        let (recorded, _, _) = setup()
        _ = try await start(recorded)
        let ops: [(String, JSON)] = [("vm.status", ["name": "Win"]), ("vm.mouse.click", ["name": "Win", "x": 5, "y": 5]),
                                     ("vm.screenshot", ["name": "Win", "maxWidth": 50])]
        for (op, params) in ops {
            let a = try await plain.handle(op: op, params: params)
            let b = try await recorded.handle(op: op, params: params)
            XCTAssertEqual(a, b, op)
        }
        let a = await failure(plain, "vm.mouse.click", ["name": "Win", "y": 5])
        let b = await failure(recorded, "vm.mouse.click", ["name": "Win", "y": 5])
        XCTAssertEqual(a, b)
    }

    func testRefusedOpIsNotTraced() async throws {
        let (h, _, _) = setup()
        let dir = try await start(h)
        let lease = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "a"])
        let token = try XCTUnwrap(lease["lease"]?.stringValue)
        _ = await failure(h, "vm.mouse.click", ["name": "Win", "x": 5, "y": 5])
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "lease": .string(token)])
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win", "lease": .string(token)])
        let rows = try lines(dir)
        XCTAssertEqual(rows.map { $0["op"]?.stringValue }, ["vm.lease.acquire", "vm.mouse.click"])
        XCTAssertNil(rows[1]["params"]?["lease"])
    }

    func testTraceLinesAreWholeAfterAbruptStop() throws {
        let dir = base.appendingPathComponent("abrupt")
        var writer: TraceWriter? = try TraceWriter(directory: dir)
        for seq in 1...20 {
            let entry = TraceEntry(seq: seq, time: Date(), ms: seq, op: "vm.type", params: ["text": .string(String(repeating: "é", count: 3000))],
                                   outcome: .success(["n": .int(Int64(seq))]), durationMs: 1, before: nil, after: nil)
            try writer?.append(entry)
        }
        writer = nil
        let rows = try lines(dir)
        XCTAssertEqual(rows.count, 20)
        XCTAssertEqual(rows.last?["seq"]?.intValue, 20)
    }

    // MARK: ops

    func testRecordStartStopOps() async throws {
        let (h, _, _) = setup()
        let status0 = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status0["recording"]?.boolValue, false)
        XCTAssertNil(status0["dir"])
        let dir = try await start(h)
        XCTAssertEqual(dir.deletingLastPathComponent().standardizedFileURL.path, base.standardizedFileURL.path)
        XCTAssertTrue(dir.lastPathComponent.hasPrefix("Win-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("trace.jsonl").path))
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5])
        let status1 = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status1["recording"]?.boolValue, true)
        XCTAssertEqual(status1["dir"]?.stringValue, dir.path)
        XCTAssertEqual(status1["ops"]?.intValue, 1)
        XCTAssertNotNil(status1["seconds"])
        let stop = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stop["dir"]?.stringValue, dir.path)
        XCTAssertEqual(stop["trace"]?.stringValue, dir.appendingPathComponent("trace.jsonl").path)
        XCTAssertEqual(stop["ops"]?.intValue, 1)
        XCTAssertEqual(stop["frames"]?.intValue, 2)
        XCTAssertNotNil(stop["seconds"])
        XCTAssertNil(stop["video"])
        let status2 = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status2["recording"]?.boolValue, false)
        XCTAssertEqual(status2["dir"]?.stringValue, dir.path)
        let again = await failure(h, "vm.record.stop", ["name": "Win"])
        XCTAssertEqual(again, "'Win' is not recording")
    }

    func testStopSummaryCarriesVideoFields() async throws {
        let (h, _, clock) = setup()
        let dir = try await start(h, ["video": true])
        try await Task.sleep(for: .milliseconds(300))
        clock.advance(.milliseconds(500))
        let stop = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stop["video"]?.stringValue, dir.appendingPathComponent("video.mp4").path)
        XCTAssertEqual(try XCTUnwrap(stop["videoSeconds"]?.doubleValue), 0.5, accuracy: 0.1)
        XCTAssertNotNil(stop["droppedFrames"]?.intValue)
        XCTAssertEqual(stop["writeErrors"]?.intValue, 0)
    }

    func testStartParameters() async throws {
        let (h, _, _) = setup()
        let relative = await failure(h, "vm.record.start", ["name": "Win", "dir": "relative/path"])
        XCTAssertTrue(relative.contains("absolute"), relative)
        for (key, value) in [("fps", 0), ("fps", 31), ("maxSeconds", 0), ("maxSeconds", 86401)] as [(String, Int)] {
            let message = await failure(h, "vm.record.start", ["name": "Win", key: .int(Int64(value))])
            XCTAssertTrue(message.contains(key), message)
        }
        let custom = base.appendingPathComponent("custom/deeper")
        let dir = try await start(h, ["dir": .string(custom.path), "fps": 30, "maxSeconds": 86400, "video": false])
        XCTAssertEqual(dir.path, custom.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: custom.appendingPathComponent("trace.jsonl").path))
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        let again = await failure(h, "vm.record.start", ["name": "Win", "dir": .string(custom.path)])
        XCTAssertEqual(again, "'\(custom.path)' already holds a recording; choose another directory")
        let unknown = await failure(h, "vm.record.start", ["name": "Nope"])
        XCTAssertTrue(unknown.contains("no VM named"), unknown)
    }

    func testDoubleStartRefused() async throws {
        let (h, _, _) = setup()
        let dir = try await start(h)
        let message = await failure(h, "vm.record.start", ["name": "Win"])
        XCTAssertEqual(message, "'Win' is already recording to \(dir.path); call vm.record.stop first")
    }

    func testRecordOpsClassification() {
        for op in ["vm.record.start", "vm.record.stop", "vm.record.status"] {
            XCTAssertTrue(ControlHandler.knownOps.contains(op), op)
            XCTAssertFalse(ControlHandler.isConcurrent(op: op), op)
        }
        XCTAssertFalse(ControlHandler.isReadOnly(op: "vm.record.start"))
        XCTAssertFalse(ControlHandler.isReadOnly(op: "vm.record.stop"))
        XCTAssertTrue(ControlHandler.isReadOnly(op: "vm.record.status"))
    }

    func testRecordStartIsLeaseGuarded() async throws {
        let (h, _, _) = setup()
        _ = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "a"])
        let message = await failure(h, "vm.record.start", ["name": "Win"])
        XCTAssertTrue(message.contains("is leased by a"), message)
        let status = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["recording"]?.boolValue, false)
    }

    // MARK: concurrency and write failures

    func testConcurrentStartsLeaveOneRecording() async throws {
        let (h, _, _) = setup()
        let gate = AsyncGate()
        let first = FirstCallGate()
        await h.setRecordingSeams(RecordingSeams(openWriter: { dir in
            if await first.shouldHold() { await gate.wait() }
            return try TraceWriter(directory: dir)
        }, makeSink: { _, _ in NoVideoSink() }))
        let dirA = base.appendingPathComponent("a"), dirB = base.appendingPathComponent("b")
        let a = Task { try await h.handle(op: "vm.record.start", params: ["name": "Win", "dir": .string(dirA.path)]) }
        await gate.waitUntilWaiting()
        let message = await failure(h, "vm.record.start", ["name": "Win", "dir": .string(dirB.path)])
        XCTAssertEqual(message, "'Win' is already recording to \(dirA.path); call vm.record.stop first")
        await gate.open()
        let result = try await a.value
        XCTAssertEqual(result["dir"]?.stringValue, dirA.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirB.appendingPathComponent("trace.jsonl").path))
        let stop = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stop["dir"]?.stringValue, dirA.path)
    }

    func testFailedStartReleasesReservation() async throws {
        let (h, _, _) = setup()
        await h.setRecordingSeams(RecordingSeams(openWriter: { _ in throw CocoaError(.fileWriteNoPermission) },
                                                 makeSink: { _, _ in NoVideoSink() }))
        let message = await failure(h, "vm.record.start", ["name": "Win"])
        XCTAssertTrue(message.contains("cannot create the recording"), message)
        await h.setRecordingSeams(RecordingSeams(openWriter: { try TraceWriter(directory: $0) }, makeSink: { _, _ in NoVideoSink() }))
        _ = try await start(h)
    }

    func testTraceFileIsCreatedExclusively() throws {
        let dir = base.appendingPathComponent("exclusive")
        _ = try TraceWriter(directory: dir)
        XCTAssertThrowsError(try TraceWriter(directory: dir)) { error in
            XCTAssertEqual(error as? TraceWriter.WriterError, .exists)
        }
    }

    func testWriteFailuresAreCountedAndReported() async throws {
        let (h, _, _) = setup()
        let (plain, _, _) = setup()
        await h.setRecordingSeams(RecordingSeams(openWriter: { FailingStore(inner: try TraceWriter(directory: $0), failLines: true, failFrames: false) },
                                                 makeSink: { _, _ in NoVideoSink() }))
        _ = try await start(h)
        for _ in 0..<3 {
            let a = try await plain.handle(op: "vm.status", params: ["name": "Win"])
            let b = try await h.handle(op: "vm.status", params: ["name": "Win"])
            XCTAssertEqual(a, b)
        }
        let status = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["recording"]?.boolValue, true)
        XCTAssertEqual(status["ops"]?.intValue, 0)
        XCTAssertEqual(status["writeErrors"]?.intValue, 3)
        XCTAssertNotNil(status["lastWriteError"]?.stringValue)
        let stop = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stop["ops"]?.intValue, 0)
        XCTAssertEqual(stop["writeErrors"]?.intValue, 3)
        XCTAssertNotNil(stop["lastWriteError"]?.stringValue)
    }

    func testCleanRecordingReportsZeroWriteErrors() async throws {
        let (h, _, _) = setup()
        _ = try await start(h, ["video": false])
        let status = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["writeErrors"]?.intValue, 0)
        XCTAssertNil(status["lastWriteError"])
        let stop = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stop["writeErrors"]?.intValue, 0)
        XCTAssertNil(stop["lastWriteError"])
    }

    func testFrameWriteFailuresAreCounted() async throws {
        let (h, _, _) = setup()
        await h.setRecordingSeams(RecordingSeams(openWriter: { FailingStore(inner: try TraceWriter(directory: $0), failLines: false, failFrames: true) },
                                                 makeSink: { _, _ in NoVideoSink() }))
        let dir = try await start(h)
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5])
        let stop = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stop["frames"]?.intValue, 0)
        XCTAssertEqual(stop["ops"]?.intValue, 1)
        XCTAssertEqual(stop["writeErrors"]?.intValue, 2)
        XCTAssertEqual(try lines(dir).count, 1)
    }

    func testRecordingEndsAfterTwentyConsecutiveLineFailures() async throws {
        let (h, _, _) = setup()
        await h.setRecordingSeams(RecordingSeams(openWriter: { FailingStore(inner: try TraceWriter(directory: $0), failLines: true, failFrames: false) },
                                                 makeSink: { _, _ in NoVideoSink() }))
        let dir = try await start(h)
        for _ in 0..<19 { _ = try await h.handle(op: "vm.status", params: ["name": "Win"]) }
        let before = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(before["recording"]?.boolValue, true)
        let result = try await h.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertEqual(result["name"]?.stringValue, "Win")
        let after = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(after["recording"]?.boolValue, false)
        XCTAssertEqual(after["dir"]?.stringValue, dir.path)
        let stop = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stop["writeErrors"]?.intValue, 20)
        XCTAssertNotNil(stop["lastWriteError"]?.stringValue)
        let ok = try await h.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertEqual(ok["name"]?.stringValue, "Win")
    }

    func testStopDuringRetirementReturnsSummary() async throws {
        let (h, _, _) = setup()
        let slow = SlowFinishSink()
        await h.setRecordingSeams(RecordingSeams(openWriter: { try TraceWriter(directory: $0) }, makeSink: { _, _ in slow }))
        _ = try await start(h, ["video": true])
        let retire = Task { try await h.handle(op: "vm.stop", params: ["name": "Win"]) }
        await slow.gate.waitUntilWaiting()
        let stopTask = Task { try await h.handle(op: "vm.record.stop", params: ["name": "Win"]) }
        try await Task.sleep(for: .milliseconds(100))
        await slow.gate.open()
        _ = try await retire.value
        let stop = try await stopTask.value
        XCTAssertEqual(stop["ops"]?.intValue, 1)
        let again = await failure(h, "vm.record.stop", ["name": "Win"])
        XCTAssertEqual(again, "'Win' is not recording")
    }

    func testSummaryIsDeliveredOnce() async throws {
        let (h, _, _) = setup()
        let slow = SlowFinishSink()
        await h.setRecordingSeams(RecordingSeams(openWriter: { try TraceWriter(directory: $0) }, makeSink: { _, _ in slow }))
        _ = try await start(h, ["video": true])
        let retire = Task { try await h.handle(op: "vm.stop", params: ["name": "Win"]) }
        await slow.gate.waitUntilWaiting()
        let stops = (0..<2).map { _ in Task { () -> Bool in
            do { _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"]); return true } catch { return false }
        } }
        try await Task.sleep(for: .milliseconds(100))
        await slow.gate.open()
        _ = try await retire.value
        var delivered = 0
        for stop in stops where await stop.value { delivered += 1 }
        do { _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"]); delivered += 1 } catch {}
        XCTAssertEqual(delivered, 1)
    }

    func testStaleRecordingCannotRetireANewerOne() async throws {
        let (h, _, _) = setup()
        let dir = try await start(h, ["video": false])
        let stale = Recording(vm: "Win", directory: base.appendingPathComponent("stale"), fps: 5, video: false, maxSeconds: 60, frames: { nil })
        await h.retireRecording("Win", stale)
        let status = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["recording"]?.boolValue, true)
        XCTAssertEqual(status["dir"]?.stringValue, dir.path)
        let stop = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stop["dir"]?.stringValue, dir.path)
    }

    func testStartWaitsForTheRetiringRecording() async throws {
        let (h, _, _) = setup()
        let slow = SlowFinishSink()
        let sinks = SinkQueue([slow, NoVideoSink()])
        await h.setRecordingSeams(RecordingSeams(openWriter: { try TraceWriter(directory: $0) }, makeSink: { _, _ in sinks.next() }))
        let dirA = try await start(h, ["video": true, "dir": .string(base.appendingPathComponent("a").path)])
        let retire = Task { try await h.handle(op: "vm.stop", params: ["name": "Win"]) }
        await slow.gate.waitUntilWaiting()
        let dirB = base.appendingPathComponent("b")
        let second = Task { try await h.handle(op: "vm.record.start", params: ["name": "Win", "dir": .string(dirB.path), "video": true]) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirB.appendingPathComponent("trace.jsonl").path))
        await slow.gate.open()
        _ = try await retire.value
        let started = try await second.value
        XCTAssertEqual(started["dir"]?.stringValue, dirB.path)
        let status = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["recording"]?.boolValue, true)
        XCTAssertEqual(status["dir"]?.stringValue, dirB.path)
        let stop = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stop["dir"]?.stringValue, dirB.path)
        XCTAssertNotEqual(dirA.path, dirB.path)
        let again = await failure(h, "vm.record.stop", ["name": "Win"])
        XCTAssertEqual(again, "'Win' is not recording")
    }

    func testRecordingThatEndedByItselfDoesNotRetireTheNextOne() async throws {
        let (h, _, clock) = setup()
        let slow = SlowFinishSink()
        let sinks = SinkQueue([slow, NoVideoSink()])
        await h.setRecordingSeams(RecordingSeams(openWriter: { try TraceWriter(directory: $0) }, makeSink: { _, _ in sinks.next() }))
        _ = try await start(h, ["video": true, "maxSeconds": 10, "dir": .string(base.appendingPathComponent("a").path)])
        clock.advance(.seconds(11))
        let probe = Task { try await h.handle(op: "vm.status", params: ["name": "Win"]) }
        await slow.gate.waitUntilWaiting()
        let dirB = base.appendingPathComponent("b")
        let second = Task { try await h.handle(op: "vm.record.start", params: ["name": "Win", "dir": .string(dirB.path), "video": true]) }
        try await Task.sleep(for: .milliseconds(100))
        await slow.gate.open()
        _ = try await probe.value
        _ = try await second.value
        let status = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["recording"]?.boolValue, true)
        XCTAssertEqual(status["dir"]?.stringValue, dirB.path)
        let stop = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stop["dir"]?.stringValue, dirB.path)
    }

    func testFailedStartFinishesTheSink() async throws {
        let (h, _, _) = setup()
        let sink = FinishCountingSink()
        await h.setRecordingSeams(RecordingSeams(openWriter: { _ in throw CocoaError(.fileWriteNoPermission) }, makeSink: { _, _ in sink }))
        let message = await failure(h, "vm.record.start", ["name": "Win", "video": true])
        XCTAssertTrue(message.contains("cannot create the recording"), message)
        XCTAssertEqual(sink.finished, 1)
    }

    // MARK: automatic end

    func testRecordingStopsWhenVMStops() async throws {
        let (h, _, _) = setup()
        let dir = try await start(h)
        _ = try await h.handle(op: "vm.stop", params: ["name": "Win"])
        let status = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["recording"]?.boolValue, false)
        XCTAssertEqual(status["dir"]?.stringValue, dir.path)
        _ = await failure(h, "vm.screenshot", ["name": "Win"])
        let stop = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stop["ops"]?.intValue, 1)
        XCTAssertEqual(try lines(dir).map { $0["op"]?.stringValue }, ["vm.stop"])
        let again = await failure(h, "vm.record.stop", ["name": "Win"])
        XCTAssertEqual(again, "'Win' is not recording")
    }

    func testRecordingStopsWhenVMIsFoundNotRunning() async throws {
        let (h, t, _) = setup()
        let dir = try await start(h)
        await t.setState(.stopped)
        let message = await failure(h, "vm.screenshot", ["name": "Win"])
        XCTAssertTrue(message.contains("stopped"), message)
        let status = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["recording"]?.boolValue, false)
        let rows = try lines(dir)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["ok"]?.boolValue, false)
    }

    func testMaxSecondsStops() async throws {
        let (h, _, clock) = setup()
        let dir = try await start(h, ["maxSeconds": 10])
        _ = try await h.handle(op: "vm.status", params: ["name": "Win"])
        clock.advance(.seconds(11))
        _ = try await h.handle(op: "vm.status", params: ["name": "Win"])
        let status = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["recording"]?.boolValue, false)
        XCTAssertEqual(status["dir"]?.stringValue, dir.path)
        XCTAssertEqual(try lines(dir).count, 1)
        let stop = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(stop["ops"]?.intValue, 1)
        let again = await failure(h, "vm.record.stop", ["name": "Win"])
        XCTAssertEqual(again, "'Win' is not recording")
        _ = try await start(h, ["dir": .string(base.appendingPathComponent("second").path)])
    }

    func testMaxSecondsTimerStops() async throws {
        let (h, _, _) = setup()
        _ = try await start(h, ["maxSeconds": 1])
        let deadline = ContinuousClock.now + .seconds(5)
        var recording = true
        while recording, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            let status = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
            recording = status["recording"]?.boolValue ?? true
        }
        XCTAssertFalse(recording)
    }

    func testVideoSinkIsFinishedOnStop() async throws {
        let dir = base.appendingPathComponent("sink")
        let sink = CountingSink()
        let recording = Recording(vm: "Win", directory: dir, fps: 5, video: true, maxSeconds: 60, frames: { nil }, sink: sink)
        try await recording.start()
        let summary = await recording.stop()
        let finished = sink.finished
        XCTAssertEqual(finished, 1)
        XCTAssertNil(summary.video)
        let again = await recording.stop()
        XCTAssertEqual(again.dir, summary.dir)
        XCTAssertEqual(sink.finished, 1)
        let active = await recording.isActive
        XCTAssertFalse(active)
    }
}

private final class CountingSink: VideoSink, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var finished: Int { lock.lock(); defer { lock.unlock() }; return count }
    func append(frame: Frame, at time: Duration) {}
    func finish() async { bump() }
    private func bump() { lock.lock(); count += 1; lock.unlock() }
}

private actor AsyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilWaiting() async {
        let limit = ContinuousClock.now + .seconds(5)
        while waiters.isEmpty {
            if ContinuousClock.now >= limit { XCTFail("nothing started waiting within 5 seconds"); return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private actor FirstCallGate {
    private var calls = 0
        func shouldHold() -> Bool { calls += 1; return calls == 1 }
}

private final class FailingStore: TraceStore, @unchecked Sendable {
    private let inner: TraceWriter
    private let failLines: Bool
    private let failFrames: Bool
    init(inner: TraceWriter, failLines: Bool, failFrames: Bool) {
        self.inner = inner; self.failLines = failLines; self.failFrames = failFrames
    }
    func append(_ entry: TraceEntry) throws {
        if failLines { throw CocoaError(.fileWriteOutOfSpace) }
        try inner.append(entry)
    }
    func writeFrame(_ frame: Frame, name: String) throws -> String {
        if failFrames { throw CocoaError(.fileWriteOutOfSpace) }
        return try inner.writeFrame(frame, name: name)
    }
    func close() { inner.close() }
}

private final class SlowFinishSink: VideoSink, @unchecked Sendable {
    let gate = AsyncGate()
    func append(frame: Frame, at time: Duration) {}
    func finish() async { await gate.wait() }
}

private final class SinkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [VideoSink]
    init(_ sinks: [VideoSink]) { self.sinks = sinks }
    func next() -> VideoSink { lock.withLock { sinks.isEmpty ? NoVideoSink() : sinks.removeFirst() } }
}

private final class FinishCountingSink: VideoSink, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var finished: Int { lock.withLock { count } }
    func append(frame: Frame, at time: Duration) {}
    func finish() async { lock.withLock { count += 1 } }
}
