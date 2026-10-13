import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveQMP
import AlcoveDisplayProtocol
import AlcoveTestSupport

/// A frame with every colour channel set to `v`.
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

private func elapsedMs(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

final class ObservationTests: XCTestCase {
    /// A running VM named "Win" that serves `frames`, and a handler over it.
    private func setup(frames: [Frame]) async -> (ControlHandler, FakeTarget) {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 8, height: 8))
        await t.setFrames(frames)
        return (ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test"), t)
    }

    private func failure(_ h: ControlHandler, _ op: String, _ params: JSON, file: StaticString = #filePath, line: UInt = #line) async -> String {
        do { _ = try await h.handle(op: op, params: params); XCTFail("expected failure", file: file, line: line); return "" }
        catch { return "\(error)" }
    }

    private static let shift = 56, keyA = 0

    // MARK: - observe

    func testObservationSummary() async throws {
        let base = solid(320, 192, 40)
        let (_, t) = await setup(frames: [base, paint(base, tileX: 2, tileY: 1)])
        let before = try await t.frame()
        let o = try await AlcoveControl.observe(t, before: before, level: .summary, settleMs: 100, settleTimeoutMs: 2000)
        XCTAssertTrue(o.settled)
        XCTAssertEqual(o.changed, Frame.Rect(x: 64, y: 32, w: 32, h: 32))
        XCTAssertEqual(o.changedFraction, 1.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(o.width, 320); XCTAssertEqual(o.height, 192)
        XCTAssertNil(o.image); XCTAssertNil(o.imageRect); XCTAssertNil(o.imageScale)

        let json = o.json()
        XCTAssertEqual(json["settled"]?.boolValue, true)
        XCTAssertEqual(json["changed"], ["x": 64, "y": 32, "w": 32, "h": 32])
        XCTAssertEqual(json["changedFraction"]?.doubleValue ?? -1, 1.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(json["width"]?.intValue, 320); XCTAssertEqual(json["height"]?.intValue, 192)
        XCTAssertNil(json["png"]); XCTAssertNil(json["imageRect"]); XCTAssertNil(json["imageScale"])
    }

    func testObservationWaitsForTheScreenToStopChanging() async throws {
        let base = solid(320, 192, 40)
        let (_, t) = await setup(frames: [paint(base, tileX: 0, tileY: 0), paint(base, tileX: 1, tileY: 0),
                                          paint(base, tileX: 2, tileY: 0), paint(base, tileX: 3, tileY: 3)])
        let start = ContinuousClock.now
        let o = try await AlcoveControl.observe(t, before: base, level: .summary, settleMs: 150, settleTimeoutMs: 3000)
        XCTAssertTrue(o.settled)
        XCTAssertEqual(o.changed, Frame.Rect(x: 96, y: 96, w: 32, h: 32))
        XCTAssertGreaterThanOrEqual(elapsedMs(since: start), 150 + 3 * 50 - 20)
    }

    func testObservationWithoutChange() async throws {
        let base = solid(320, 192, 40)
        let (_, t) = await setup(frames: [base])
        let o = try await AlcoveControl.observe(t, before: base, level: .summary, settleMs: 60, settleTimeoutMs: 2000)
        XCTAssertTrue(o.settled)
        XCTAssertNil(o.changed)
        XCTAssertEqual(o.changedFraction, 0)
        XCTAssertNil(o.json()["changed"])
        XCTAssertEqual(o.json()["changedFraction"]?.doubleValue, 0)
    }

    func testObservationTimesOutUnsettled() async throws {
        let base = solid(64, 64, 40)
        var frames: [Frame] = []
        for i in 0..<200 { frames.append(i % 2 == 0 ? paint(base, tileX: 0, tileY: 0) : paint(base, tileX: 1, tileY: 1)) }
        let (_, t) = await setup(frames: frames)
        let start = ContinuousClock.now
        let o = try await AlcoveControl.observe(t, before: base, level: .summary, settleMs: 100, settleTimeoutMs: 300)
        let ms = elapsedMs(since: start)
        XCTAssertFalse(o.settled)
        XCTAssertNotNil(o.changed)
        XCTAssertGreaterThanOrEqual(ms, 300)
        XCTAssertLessThan(ms, 300 + 500)
        XCTAssertEqual(o.json()["settled"]?.boolValue, false)
    }

    func testObservationDiffImageCropsChange() async throws {
        let base = solid(640, 480, 40)
        let (_, t) = await setup(frames: [paint(base, tileX: 5, tileY: 4)])
        let o = try await AlcoveControl.observe(t, before: base, level: .diff, settleMs: 60, settleTimeoutMs: 2000)
        XCTAssertEqual(o.changed, Frame.Rect(x: 160, y: 128, w: 32, h: 32))
        XCTAssertEqual(o.imageRect, Frame.Rect(x: 144, y: 112, w: 64, h: 64))
        XCTAssertEqual(o.imageScale, 1)
        let image = try XCTUnwrap(Frame(png: try XCTUnwrap(o.image)))
        XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 64)
        XCTAssertEqual(image.pixels[0], 40)
        XCTAssertEqual(image.pixels[(16 * 64 + 16) * 4], 140)
        XCTAssertEqual(image.pixels[(47 * 64 + 47) * 4], 140)
        XCTAssertEqual(image.pixels[(48 * 64 + 48) * 4], 40)

        let json = o.json()
        XCTAssertEqual(json["png"]?.stringValue, o.image?.base64EncodedString())
        XCTAssertEqual(json["imageRect"], ["x": 144, "y": 112, "w": 64, "h": 64])
        XCTAssertEqual(json["imageScale"]?.doubleValue, 1)
        XCTAssertEqual(json["changed"], ["x": 160, "y": 128, "w": 32, "h": 32])

        await t.setFrames([paint(base, tileX: 0, tileY: 0)])
        let corner = try await AlcoveControl.observe(t, before: base, level: .diff, settleMs: 60, settleTimeoutMs: 2000)
        XCTAssertEqual(corner.imageRect, Frame.Rect(x: 0, y: 0, w: 48, h: 48))
        XCTAssertEqual(Frame(png: try XCTUnwrap(corner.image))?.width, 48)

        await t.setFrames([base])
        let same = try await AlcoveControl.observe(t, before: base, level: .diff, settleMs: 60, settleTimeoutMs: 2000)
        XCTAssertNil(same.changed); XCTAssertNil(same.image); XCTAssertNil(same.imageRect); XCTAssertNil(same.imageScale)
        XCTAssertNil(same.json()["png"]); XCTAssertNil(same.json()["imageRect"])
    }

    func testObservationDiffImageIsAtMost1280Wide() async throws {
        let (_, t) = await setup(frames: [solid(2600, 64, 200)])
        let o = try await AlcoveControl.observe(t, before: solid(2600, 64, 40), level: .diff, settleMs: 0, settleTimeoutMs: 2000)
        XCTAssertEqual(o.changed, Frame.Rect(x: 0, y: 0, w: 2600, h: 64))
        XCTAssertEqual(o.changedFraction, 1)
        XCTAssertEqual(o.imageRect, Frame.Rect(x: 0, y: 0, w: 2600, h: 64))
        XCTAssertEqual(o.imageScale ?? 0, 1280.0 / 2600.0, accuracy: 1e-9)
        let image = try XCTUnwrap(Frame(png: try XCTUnwrap(o.image)))
        XCTAssertEqual(image.width, 1280); XCTAssertEqual(image.height, 32)
    }

    func testObservationImageFullFrame() async throws {
        let wide = solid(1600, 100, 40)
        let (_, t) = await setup(frames: [paint(wide, tileX: 3, tileY: 1)])
        let o = try await AlcoveControl.observe(t, before: wide, level: .image, settleMs: 0, settleTimeoutMs: 2000)
        XCTAssertEqual(o.changed, Frame.Rect(x: 96, y: 32, w: 32, h: 32))
        XCTAssertEqual(o.imageRect, Frame.Rect(x: 0, y: 0, w: 1600, h: 100))
        XCTAssertEqual(o.imageScale ?? 0, 0.8, accuracy: 1e-9)
        let image = try XCTUnwrap(Frame(png: try XCTUnwrap(o.image)))
        XCTAssertEqual(image.width, 1280); XCTAssertEqual(image.height, 80)
        XCTAssertEqual(o.width, 1600); XCTAssertEqual(o.height, 100)

        let small = solid(320, 192, 40)
        await t.setFrames([small])
        let unchanged = try await AlcoveControl.observe(t, before: small, level: .image, settleMs: 0, settleTimeoutMs: 2000)
        XCTAssertNil(unchanged.changed)
        XCTAssertEqual(unchanged.imageRect, Frame.Rect(x: 0, y: 0, w: 320, h: 192))
        XCTAssertEqual(unchanged.imageScale, 1)
        XCTAssertEqual(Frame(png: try XCTUnwrap(unchanged.image)), small)
    }

    // MARK: - action ops

    func testObserveNoneAddsNothing() async throws {
        let base = solid(320, 192, 40)
        let (h, t) = await setup(frames: [base, paint(base, tileX: 2, tileY: 1)])
        let click: [ToQEMU] = [.abs(con: 0, x: 0, y: 0), .btn(con: 0, button: .left, down: true), .sync,
                               .btn(con: 0, button: .left, down: false), .sync]
        let absent = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 0, "y": 0, "hold": 1])
        XCTAssertEqual(absent, [:])
        let none = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 0, "y": 0, "hold": 1, "observe": "none"])
        XCTAssertEqual(none, [:])
        let sent = await t.sent
        XCTAssertEqual(sent, click + click)
        let key = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "a", "observe": "none"])
        XCTAssertEqual(key, [:])
        let frameCalls = await t.frameCalls
        XCTAssertEqual(frameCalls, 1)
    }

    func testClickWithObserveReturnsObservation() async throws {
        let base = solid(320, 192, 40)
        let (h, t) = await setup(frames: [base, paint(base, tileX: 2, tileY: 1)])
        let r = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 0, "y": 0, "hold": 1, "observe": "summary",
                                                                  "settleMs": 60, "settleTimeoutMs": 1000])
        XCTAssertEqual(r.objectValue?.keys.sorted(), ["observation"])
        let o = try XCTUnwrap(r["observation"])
        XCTAssertEqual(o["settled"]?.boolValue, true)
        XCTAssertEqual(o["changed"], ["x": 64, "y": 32, "w": 32, "h": 32])
        XCTAssertEqual(o["changedFraction"]?.doubleValue ?? -1, 1.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(o["width"]?.intValue, 320); XCTAssertEqual(o["height"]?.intValue, 192)
        XCTAssertNil(o["png"])
        let sent = await t.sent
        XCTAssertEqual(sent, [.abs(con: 0, x: 0, y: 0), .btn(con: 0, button: .left, down: true), .sync,
                              .btn(con: 0, button: .left, down: false), .sync])

        await t.setFrames([base, paint(base, tileX: 5, tileY: 3)])
        let diff = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 0, "y": 0, "hold": 1, "observe": "diff", "settleMs": 60])
        XCTAssertEqual(diff["observation"]?["imageRect"], ["x": 144, "y": 80, "w": 64, "h": 64])
        let png = try XCTUnwrap(Data(base64Encoded: diff["observation"]?["png"]?.stringValue ?? ""))
        XCTAssertEqual(Frame(png: png)?.width, 64)
    }

    func testEveryActionOpReturnsAnObservation() async throws {
        let base = solid(320, 192, 40)
        let (h, t) = await setup(frames: [base])
        let ops: [(String, JSON)] = [
            ("vm.mouse.move", ["x": 1, "y": 1]), ("vm.mouse.click", ["x": 1, "y": 1, "hold": 1]),
            ("vm.mouse.drag", ["fromX": 0, "fromY": 0, "toX": 10, "toY": 10]), ("vm.mouse.scroll", ["x": 1, "y": 1, "dy": 1]),
            ("vm.mouse.down", [:]), ("vm.mouse.up", [:]),
            ("vm.key.press", ["keys": "a"]), ("vm.key.down", ["key": "shift"]), ("vm.key.up", ["key": "shift"]),
            ("vm.type", ["text": "a", "delay": 0]),
        ]
        for (op, extra) in ops {
            var params = extra.objectValue ?? [:]
            params["name"] = "Win"; params["observe"] = "summary"; params["settleMs"] = 0
            await t.setFrames([base, paint(base, tileX: 1, tileY: 1)])
            let r = try await h.handle(op: op, params: .object(params))
            XCTAssertEqual(r["observation"]?["settled"]?.boolValue, true, op)
            XCTAssertEqual(r["observation"]?["changed"], ["x": 32, "y": 32, "w": 32, "h": 32], op)
        }
    }

    func testObserveParametersAreCheckedBeforeInput() async throws {
        let (h, t) = await setup(frames: [solid(320, 192, 40)])
        let cases: [(JSON, String)] = [
            (["observe": "everything"], "observe must be one of none, summary, diff, image"),
            (["observe": 1], "observe must be one of none, summary, diff, image"),
            (["observe": "summary", "settleMs": -1], "settleMs must be between 0 and 10000"),
            (["settleMs": 10001], "settleMs must be between 0 and 10000"),
            (["observe": "diff", "settleMs": "fast"], "settleMs must be between 0 and 10000"),
            (["observe": "summary", "settleTimeoutMs": 99], "settleTimeoutMs must be between 100 and 30000"),
            (["settleTimeoutMs": 30001], "settleTimeoutMs must be between 100 and 30000"),
        ]
        for (extra, message) in cases {
            var params = extra.objectValue ?? [:]
            params["name"] = "Win"; params["x"] = 0; params["y"] = 0
            let click = await failure(h, "vm.mouse.click", .object(params))
            XCTAssertEqual(click, message)
            params["steps"] = [["op": "vm.key.down", "key": "shift"]]
            let batch = await failure(h, "vm.batch", .object(params))
            XCTAssertEqual(batch, message)
        }
        let sent = await t.sent
        XCTAssertEqual(sent, [])
    }

    func testMouseDownUpSendButtons() async throws {
        let (h, t) = await setup(frames: [solid(320, 192, 40)])
        let down = try await h.handle(op: "vm.mouse.down", params: ["name": "Win", "x": 319, "y": 191, "button": "right"])
        XCTAssertEqual(down, [:])
        var sent = await t.sent
        XCTAssertEqual(sent, [.abs(con: 0, x: 32767, y: 32767), .btn(con: 0, button: .right, down: true), .sync])
        let up = try await h.handle(op: "vm.mouse.up", params: ["name": "Win", "button": "right"])
        XCTAssertEqual(up, [:])
        sent = await t.sent
        XCTAssertEqual(Array(sent.dropFirst(3)), [.btn(con: 0, button: .right, down: false), .sync])

        _ = try await h.handle(op: "vm.mouse.down", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.mouse.up", params: ["name": "Win", "x": 0, "y": 0])
        sent = await t.sent
        XCTAssertEqual(Array(sent.dropFirst(5)), [.btn(con: 0, button: .left, down: true), .sync,
                                                  .abs(con: 0, x: 0, y: 0), .btn(con: 0, button: .left, down: false), .sync])

        let count = sent.count
        let oneCoordinate = await failure(h, "vm.mouse.down", ["name": "Win", "x": 5])
        XCTAssertEqual(oneCoordinate, "vm.mouse.down takes 'x' and 'y' together; pass both or neither")
        let onlyY = await failure(h, "vm.mouse.up", ["name": "Win", "y": 5])
        XCTAssertEqual(onlyY, "vm.mouse.up takes 'x' and 'y' together; pass both or neither")
        let badButton = await failure(h, "vm.mouse.down", ["name": "Win", "button": "fourth"])
        XCTAssertEqual(badButton, "missing or invalid parameter 'button'")
        let after = await t.sent.count
        XCTAssertEqual(after, count)
    }

    func testMouseDownUpAndBatchClassification() {
        for op in ["vm.mouse.down", "vm.mouse.up", "vm.batch"] {
            XCTAssertTrue(ControlHandler.knownOps.contains(op), op)
            XCTAssertFalse(ControlHandler.isReadOnly(op: op), op)
            XCTAssertFalse(ControlHandler.isConcurrent(op: op), op)
            XCTAssertTrue(ControlHandler.isInput(op: op), op)
        }
    }

    // MARK: - batch

    func testBatchRunsStepsInOrder() async throws {
        let base = solid(320, 192, 40)
        let (h, t) = await setup(frames: [base, paint(base, tileX: 2, tileY: 1)])
        let steps: JSON = [
            ["op": "vm.mouse.move", "x": 0, "y": 0, "observe": "image"],
            ["op": "vm.mouse.down"],
            ["op": "sleep", "ms": 20],
            ["op": "vm.mouse.up", "x": 319, "y": 191],
            ["op": "vm.key.press", "keys": "a"],
            ["op": "vm.type", "text": "a", "delay": 0],
            ["op": "vm.wait_idle", "seconds": 0, "timeout": 5],
        ]
        let r = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": steps, "observe": "summary", "settleMs": 60])
        XCTAssertEqual(r.objectValue?.keys.sorted(), ["completed", "observation", "results"])
        XCTAssertEqual(r["completed"]?.intValue, 7)
        XCTAssertEqual(r["results"], [[:], [:], [:], [:], [:], [:], ["idle": true]])
        XCTAssertEqual(r["observation"]?["settled"]?.boolValue, true)
        XCTAssertEqual(r["observation"]?["changed"], ["x": 64, "y": 32, "w": 32, "h": 32])
        let a = ObservationTests.keyA
        let sent = await t.sent
        XCTAssertEqual(sent, [
            .abs(con: 0, x: 0, y: 0), .sync,
            .btn(con: 0, button: .left, down: true), .sync,
            .abs(con: 0, x: 32767, y: 32767), .btn(con: 0, button: .left, down: false), .sync,
            .key(mac: a, q: nil, down: true), .key(mac: a, q: nil, down: false),
            .key(mac: a, q: nil, down: true), .key(mac: a, q: nil, down: false),
        ])

        let plain = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": [["op": "vm.key.down", "key": "shift"]]])
        XCTAssertEqual(plain, ["completed": 1, "results": [[:]]])
    }

    func testBatchStopsAtFirstFailure() async throws {
        let base = solid(320, 192, 40)
        let (h, t) = await setup(frames: [base, paint(base, tileX: 2, tileY: 1)])
        let shift = ObservationTests.shift
        let steps: JSON = [["op": "vm.key.down", "key": "shift"], ["op": "vm.key.press", "keys": "hyper+x"], ["op": "vm.key.up", "key": "shift"]]
        let r = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": steps])
        XCTAssertEqual(r.objectValue?.keys.sorted(), ["completed", "error", "failedStep", "results"])
        XCTAssertEqual(r["completed"]?.intValue, 1)
        XCTAssertEqual(r["results"], [[:]])
        XCTAssertEqual(r["failedStep"]?.intValue, 1)
        XCTAssertTrue(r["error"]?.stringValue?.hasPrefix("bad key spec 'hyper+x'") ?? false, "\(r)")
        var sent = await t.sent
        XCTAssertEqual(sent, [.key(mac: shift, q: nil, down: true)])

        let observed = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": steps, "observe": "summary", "settleMs": 60])
        XCTAssertEqual(observed["failedStep"]?.intValue, 1)
        XCTAssertEqual(observed["observation"]?["changed"], ["x": 64, "y": 32, "w": 32, "h": 32])

        let missing = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": [["op": "vm.mouse.click", "x": 1]]])
        XCTAssertEqual(missing, ["completed": 0, "results": [], "failedStep": 0, "error": "missing or invalid parameter 'y'"])

        sent = await t.sent
        let waitFor = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": [["op": "vm.wait_for", "text": "Ready"], ["op": "vm.key.press", "keys": "a"]]])
        XCTAssertEqual(waitFor, ["completed": 0, "results": [], "failedStep": 0, "error": "unknown op 'vm.wait_for'"])
        let after = await t.sent
        XCTAssertEqual(after, sent)
    }

    func testBatchRejectsDisallowedOpBeforeRunning() async throws {
        let (h, t) = await setup(frames: [solid(320, 192, 40)])
        let click: JSON = ["op": "vm.mouse.click", "x": 0, "y": 0]
        let cases: [(JSON, String)] = [
            ([click, ["op": "vm.exec", "command": "hostname"]], "step 1: 'vm.exec' cannot run in a batch"),
            ([["op": "vm.batch", "steps": [click]]], "step 0: 'vm.batch' cannot run in a batch"),
            ([click, click, ["op": "vm.screenshot"]], "step 2: 'vm.screenshot' cannot run in a batch"),
            ([click, ["op": "vm.stop"]], "step 1: 'vm.stop' cannot run in a batch"),
            ([click, "vm.key.press"], "step 1: a step is an object with a string 'op'"),
            ([click, ["keys": "a"]], "step 1: a step is an object with a string 'op'"),
            ([click, ["op": "sleep"]], "step 1: sleep needs an integer 'ms' between 1 and 10000"),
            ([click, ["op": "sleep", "ms": 0]], "step 1: sleep needs an integer 'ms' between 1 and 10000"),
            ([click, ["op": "sleep", "ms": 10001]], "step 1: sleep needs an integer 'ms' between 1 and 10000"),
            ([], "steps is empty; pass at least one step"),
            ("vm.key.press", "missing or invalid parameter 'steps'"),
        ]
        for (steps, message) in cases {
            let error = await failure(h, "vm.batch", ["name": "Win", "steps": steps])
            XCTAssertEqual(error, message)
        }
        let noSteps = await failure(h, "vm.batch", ["name": "Win"])
        XCTAssertEqual(noSteps, "missing or invalid parameter 'steps'")
        let sent = await t.sent
        XCTAssertEqual(sent, [])
        let frameCalls = await t.frameCalls
        XCTAssertEqual(frameCalls, 0)
    }

    func testBatchStepLimit() async throws {
        let (h, t) = await setup(frames: [solid(320, 192, 40)])
        let step: JSON = ["op": "vm.key.down", "key": "shift"]
        let error = await failure(h, "vm.batch", ["name": "Win", "steps": .array(Array(repeating: step, count: 51))])
        XCTAssertEqual(error, "a batch runs at most 50 steps, not 51; split them over several vm.batch calls")
        var sent = await t.sent
        XCTAssertEqual(sent, [])
        let r = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": .array(Array(repeating: step, count: 50))])
        XCTAssertEqual(r["completed"]?.intValue, 50)
        sent = await t.sent
        XCTAssertEqual(sent.count, 50)
    }

    func testBatchHoldsInputGate() async throws {
        let (h, t) = await setup(frames: [solid(320, 192, 40)])
        let shift = ObservationTests.shift
        let batchDone = LockedBox(false)
        let steps: JSON = [["op": "vm.key.down", "key": "shift"], ["op": "sleep", "ms": 300], ["op": "vm.key.up", "key": "shift"]]
        let batch = Task {
            let r = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": steps])
            batchDone.value = true
            return r
        }
        while await t.sent.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 0, "y": 0, "hold": 50])
        XCTAssertTrue(batchDone.value)
        let r = try await batch.value
        XCTAssertEqual(r["completed"]?.intValue, 3)
        let sent = await t.sent
        XCTAssertEqual(sent, [
            .key(mac: shift, q: nil, down: true), .key(mac: shift, q: nil, down: false),
            .abs(con: 0, x: 0, y: 0), .btn(con: 0, button: .left, down: true), .sync, .btn(con: 0, button: .left, down: false), .sync,
        ])
    }

    func testCancelledBatchReleasesTheInputGate() async throws {
        let (h, t) = await setup(frames: [solid(320, 192, 40)])
        let shift = ObservationTests.shift, a = ObservationTests.keyA
        let steps: JSON = [["op": "vm.key.down", "key": "shift"], ["op": "sleep", "ms": 10000], ["op": "vm.key.up", "key": "shift"]]
        let batch = Task { try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": steps, "observe": "summary"]) }
        while await t.sent.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        batch.cancel()
        do { _ = try await batch.value; XCTFail("expected cancellation") } catch is CancellationError {}
        _ = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "a"])
        let sent = await t.sent
        XCTAssertEqual(sent, [.key(mac: shift, q: nil, down: true), .key(mac: a, q: nil, down: true), .key(mac: a, q: nil, down: false)])
    }

    func testObservationHoldsInputGate() async throws {
        let base = solid(320, 192, 40)
        let (h, t) = await setup(frames: [base])
        let clickDone = LockedBox(false)
        let click = Task {
            let r = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 0, "y": 0, "hold": 1, "observe": "summary", "settleMs": 300])
            clickDone.value = true
            return r
        }
        while await t.sent.count < 5 { try await Task.sleep(for: .milliseconds(5)) }
        _ = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "a"])
        XCTAssertTrue(clickDone.value)
        _ = try await click.value
    }

    func testBatchChecksTheLeaseOnce() async throws {
        let (h, t) = await setup(frames: [solid(320, 192, 40)])
        let lease = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "agent-a", "ttl": 60])
        let token = try XCTUnwrap(lease["lease"]?.stringValue)
        let steps: JSON = [["op": "vm.key.down", "key": "shift"], ["op": "vm.key.up", "key": "shift"]]
        let refused = await failure(h, "vm.batch", ["name": "Win", "steps": steps])
        XCTAssertTrue(refused.contains("is leased by agent-a"), refused)
        for op in ["vm.mouse.down", "vm.mouse.up"] {
            let error = await failure(h, op, ["name": "Win"])
            XCTAssertTrue(error.contains("is leased by agent-a"), error)
        }
        var sent = await t.sent
        XCTAssertEqual(sent, [])
        let r = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": steps, "lease": .string(token)])
        XCTAssertEqual(r["completed"]?.intValue, 2)
        sent = await t.sent
        XCTAssertEqual(sent.count, 2)
    }
}
