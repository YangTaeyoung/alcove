import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveDisplayProtocol

/// A scripted VM: records display messages, serves the queued frames or a fixed PNG, and hands out the agent set with `setAgent`.
actor FakeTarget: VMTarget {
    nonisolated let name: String
    var stateValue: VMController.State
    var sent: [ToQEMU] = []
    var png: Data
    /// Frames served one per `frame()` call; the last one repeats. Empty: `frame()` decodes `png`.
    var frames: [Frame] = []
    var frameCalls = 0
    var agentClient: AgentClient?
    var startCount = 0, stopCount = 0
    var agentWait: Duration = .zero
    var agentWaits = 0, cancelledAgentWaits = 0
    var snapshotList: [VMController.SnapshotInfo] = []
    var snapshotCalls: [String] = []
    var monitorReplies: [String] = []
    var monitorLines: [String] = []
    var linkCalls: [Bool] = []
    var forwards: [VMConfig.PortForward] = []
    var instance = 1
    var agentPort = 40_000
    var restoreHook: (@Sendable (FakeTarget) async -> Void)?

    init(name: String, state: VMController.State, png: Data) { self.name = name; self.stateValue = state; self.png = png }
    var os: VMConfig.GuestOS = .windows
    func guestOS() async -> VMConfig.GuestOS { os }
    func setOS(_ value: VMConfig.GuestOS) { os = value }
    func state() async -> VMController.State { stateValue }
    func isSuspended() async -> Bool { false }
    func start() async throws { startCount += 1; stateValue = .running }
    func stop(force: Bool) async throws { stopCount += 1; stateValue = .stopped }
    func pause() async throws { stateValue = .paused }
    func resume() async throws { stateValue = .running }
    func screenshotPNG() async throws -> Data { png }
    func frame() async throws -> Frame {
        frameCalls += 1
        if frames.count > 1 { return frames.removeFirst() }
        if let last = frames.first { return last }
        guard let f = Frame(png: png) else { throw NSError(domain: "FakeTarget", code: 1) }
        return f
    }
    @discardableResult func sendDisplay(_ message: ToQEMU) async -> Bool { sent.append(message); return true }
    func agent(timeout: Duration) async -> AgentClient? {
        if agentWait > .zero {
            agentWaits += 1
            try? await Task.sleep(for: agentWait)
            if Task.isCancelled { cancelledAgentWaits += 1 }
        }
        return agentClient
    }
    func snapshots() async throws -> [VMController.SnapshotInfo] { snapshotList }
    func createSnapshot(named name: String) async throws { snapshotCalls.append("create:\(name)") }
    func restoreSnapshot(named name: String) async throws {
        snapshotCalls.append("restore:\(name)")
        await restoreHook?(self)
    }
    func deleteSnapshot(named name: String) async throws { snapshotCalls.append("delete:\(name)") }
    func monitorCommand(_ line: String) async throws -> String {
        monitorLines.append(line)
        return monitorReplies.isEmpty ? "" : monitorReplies.removeFirst()
    }
    func setNetworkLink(up: Bool) async throws { linkCalls.append(up) }
    func staticForwards() async -> [VMConfig.PortForward] { forwards }
    func engineInstance() async -> Int { instance }
    func agentHostPort() async -> Int { agentPort }
    func setInstance(_ i: Int) { instance = i }
    func setSnapshotList(_ l: [VMController.SnapshotInfo]) { snapshotList = l }
    func setMonitorReplies(_ r: [String]) { monitorReplies = r }
    func setForwards(_ f: [VMConfig.PortForward]) { forwards = f }
    func setRestoreHook(_ h: (@Sendable (FakeTarget) async -> Void)?) { restoreHook = h }
    func setAgent(_ a: AgentClient?) { agentClient = a }
    func setAgentWait(_ d: Duration) { agentWait = d }
    func setPNG(_ d: Data) { png = d }
    func setFrames(_ f: [Frame]) { frames = f }
    func setState(_ s: VMController.State) { stateValue = s }
}

struct FakeRegistry: VMRegistry {
    let targets: [String: FakeTarget]
    func names() async -> [String] { targets.keys.sorted() }
    func target(named name: String) async -> VMTarget? { targets[name] }
}

/// A minimal 1x1 or WxH PNG produced with ImageIO so the header parser has real data.
func makePNG(width: Int, height: Int, gray: UInt8 = 0x80) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: Double(gray) / 255, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let img = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

final class ControlHandlerTests: XCTestCase {
    private func setup(state: VMController.State = .running, size: (Int, Int) = (800, 600)) -> (ControlHandler, FakeTarget) {
        let t = FakeTarget(name: "Win", state: state, png: makePNG(width: size.0, height: size.1))
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test")
        return (h, t)
    }

    func testHelloListStatusStartStop() async throws {
        let (h, t) = setup(state: .stopped)
        let hello = try await h.handle(op: "hello", params: [:])
        XCTAssertEqual(hello["host"]?.stringValue, "test")
        let list = try await h.handle(op: "vm.list", params: [:])
        XCTAssertEqual(list["vms"]?[0]?["name"]?.stringValue, "Win")
        XCTAssertEqual(list["vms"]?[0]?["state"]?.stringValue, "stopped")
        let started = try await h.handle(op: "vm.start", params: ["name": "Win"])
        XCTAssertEqual(started["state"]?.stringValue, "running")
        let status = try await h.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertEqual(status["width"]?.intValue, 800); XCTAssertEqual(status["height"]?.intValue, 600)
        XCTAssertEqual(status["tools"]?.boolValue, false)
        _ = try await h.handle(op: "vm.stop", params: ["name": "Win"])
        let n = await t.stopCount; XCTAssertEqual(n, 1)
        do { _ = try await h.handle(op: "vm.screenshot", params: ["name": "Win"]); XCTFail() }
        catch let e as ControlHandler.ControlError { XCTAssertTrue(e.description.contains("stopped")) }
        do { _ = try await h.handle(op: "vm.status", params: ["name": "Nope"]); XCTFail() }
        catch let e as ControlHandler.ControlError { XCTAssertTrue(e.description.contains("no VM named")) }
        do { _ = try await h.handle(op: "bogus", params: [:]); XCTFail() }
        catch let e as ControlHandler.ControlError { XCTAssertTrue(e.description.contains("unknown op")) }
    }

    func testScreenshotAndDownscale() async throws {
        let (h, _) = setup(size: (1600, 1000))
        let r = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "maxWidth": 400])
        XCTAssertEqual(r["width"]?.intValue, 1600); XCTAssertEqual(r["height"]?.intValue, 1000)
        XCTAssertEqual(r["sentWidth"]?.intValue, 400); XCTAssertEqual(r["sentHeight"]?.intValue, 250)
        let png = Data(base64Encoded: r["png"]!.stringValue!)!
        XCTAssertEqual(Frame(png: png)?.width, 400)
        let full = try await h.handle(op: "vm.screenshot", params: ["name": "Win"])
        XCTAssertEqual(full["sentWidth"]?.intValue, 1600)
    }

    func testClickMapsCoordinatesAndSequences() async throws {
        let (h, t) = setup(size: (800, 600))
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 799, "y": 0, "button": "right"])
        let sent = await t.sent
        XCTAssertEqual(sent.first, .abs(con: 0, x: 32767, y: 0))
        XCTAssertEqual(sent.map { m -> String in if case .btn(_, let b, let d) = m { return "\(b):\(d)" }; if case .sync = m { return "sync" }; return "abs" },
                       ["abs", "right:true", "sync", "right:false", "sync"])
        await t.setState(.running)
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 400, "y": 300, "count": 2])
        let after = await t.sent.dropFirst(sent.count)
        XCTAssertEqual(after.first, .abs(con: 0, x: 16404, y: 16411))
        XCTAssertEqual(after.filter { if case .btn(_, .left, true) = $0 { return true }; return false }.count, 2)
        do { _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 1]); XCTFail() }
        catch let e as ControlHandler.ControlError { XCTAssertTrue(e.description.contains("'y'")) }
    }

    func testScrollDragAndMove() async throws {
        let (h, t) = setup()
        _ = try await h.handle(op: "vm.mouse.scroll", params: ["name": "Win", "x": 10, "y": 10, "dy": 2, "dx": -1])
        var sent = await t.sent
        XCTAssertEqual(sent.filter { if case .btn(_, .wheelDown, true) = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(sent.filter { if case .btn(_, .wheelLeft, true) = $0 { return true }; return false }.count, 1)
        _ = try await h.handle(op: "vm.mouse.drag", params: ["name": "Win", "fromX": 0, "fromY": 0, "toX": 100, "toY": 100])
        sent = await t.sent
        XCTAssertTrue(sent.contains(.btn(con: 0, button: .left, down: true)))
        XCTAssertEqual(sent.last, .sync)
        _ = try await h.handle(op: "vm.mouse.move", params: ["name": "Win", "x": 5000, "y": -5])
        sent = await t.sent
        XCTAssertEqual(sent[sent.count - 2], .abs(con: 0, x: 32767, y: 0), "clamped")
    }

    func testKeysAndTyping() async throws {
        let (h, t) = setup()
        _ = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "win+r"])
        var sent = await t.sent
        XCTAssertEqual(sent, [.key(mac: 55, q: nil, down: true), .key(mac: 15, q: nil, down: true), .key(mac: 15, q: nil, down: false), .key(mac: 55, q: nil, down: false)])
        _ = try await h.handle(op: "vm.type", params: ["name": "Win", "text": "Hi", "delay": 0])
        sent = await t.sent
        XCTAssertEqual(Array(sent.suffix(6)), [.key(mac: 56, q: nil, down: true), .key(mac: 4, q: nil, down: true), .key(mac: 4, q: nil, down: false),
                                               .key(mac: 56, q: nil, down: false), .key(mac: 34, q: nil, down: true), .key(mac: 34, q: nil, down: false)])
        _ = try await h.handle(op: "vm.key.down", params: ["name": "Win", "key": "shift"])
        _ = try await h.handle(op: "vm.key.up", params: ["name": "Win", "key": "shift"])
        sent = await t.sent
        XCTAssertEqual(Array(sent.suffix(2)), [.key(mac: 56, q: nil, down: true), .key(mac: 56, q: nil, down: false)])
        do { _ = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "hyper+x"]); XCTFail() }
        catch let e as ControlHandler.ControlError { XCTAssertTrue(e.description.contains("bad key spec")) }
        do { _ = try await h.handle(op: "vm.type", params: ["name": "Win", "text": "한글"]); XCTFail() }
        catch let e as ControlHandler.ControlError { XCTAssertTrue(e.description.contains("cannot type")) }
    }

    func testToolsRequiredOps() async throws {
        let (h, _) = setup()
        for (op, params) in [("vm.exec", ["name": "Win", "command": "hostname"] as JSON), ("vm.clipboard.get", ["name": "Win"]),
                             ("vm.clipboard.set", ["name": "Win", "text": "x"]), ("vm.push_file", ["name": "Win", "path": "/tmp/x"])] {
            do { _ = try await h.handle(op: op, params: params); XCTFail(op) }
            catch let e as ControlHandler.ControlError { XCTAssertTrue(e.description.contains("guest tools"), op) }
        }
    }

    func testScreenshotRegionAndScale() async throws {
        let (h, _) = setup(size: (1600, 1000))
        let r = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "region": ["x": 100, "y": 200, "w": 400, "h": 300], "scale": 0.5])
        XCTAssertEqual(r["width"]?.intValue, 1600); XCTAssertEqual(r["height"]?.intValue, 1000)
        XCTAssertEqual(r["x"]?.intValue, 100); XCTAssertEqual(r["y"]?.intValue, 200)
        XCTAssertEqual(r["sentWidth"]?.intValue, 200); XCTAssertEqual(r["sentHeight"]?.intValue, 150)
        XCTAssertEqual(r["scale"]?.doubleValue, 0.5)
        XCTAssertEqual(r["mime"]?.stringValue, "image/png")
        let png = Data(base64Encoded: r["png"]!.stringValue!)!
        XCTAssertEqual(Frame(png: png)?.width, 200)

        let capped = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "region": ["x": 100, "y": 200, "w": 400, "h": 300], "scale": 0.5, "maxWidth": 100])
        XCTAssertEqual(capped["sentWidth"]?.intValue, 100)
        XCTAssertEqual(capped["scale"]?.doubleValue, 0.25)

        let clamped = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "region": ["x": 1500, "y": 900, "w": 400, "h": 400]])
        XCTAssertEqual(clamped["x"]?.intValue, 1500); XCTAssertEqual(clamped["sentWidth"]?.intValue, 100)
        XCTAssertEqual(clamped["sentHeight"]?.intValue, 100); XCTAssertEqual(clamped["scale"]?.doubleValue, 1)

        let full = try await h.handle(op: "vm.screenshot", params: ["name": "Win"])
        XCTAssertEqual(full["x"]?.intValue, 0); XCTAssertEqual(full["y"]?.intValue, 0)
        XCTAssertEqual(full["scale"]?.doubleValue, 1)
    }

    func testScreenshotRegionOutside() async throws {
        let (h, _) = setup(size: (800, 600))
        do {
            _ = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "region": ["x": 900, "y": 0, "w": 10, "h": 10]])
            XCTFail()
        } catch let e as ControlHandler.ControlError { XCTAssertTrue(e.description.contains("region is outside the 800x600 frame"), e.description) }
        for region: JSON in [["x": 0, "y": 0, "w": 0, "h": 5], ["x": 0, "y": 0, "w": 5], "full"] {
            do {
                _ = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "region": region])
                XCTFail()
            } catch let e as ControlHandler.ControlError { XCTAssertTrue(e.description.contains("region needs integer x, y, w, h with w and h above 0"), e.description) }
        }
    }

    func testScreenshotParameterErrors() async throws {
        let (h, _) = setup()
        let cases: [(JSON, String)] = [
            (["scale": 1.5], "scale must be between 0.1 and 1"), (["scale": 0.05], "scale must be between 0.1 and 1"),
            (["quality": 2], "quality must be between 0.1 and 1"), (["format": "gif"], "format must be 'png' or 'jpeg'"),
        ]
        for (extra, message) in cases {
            var params: JSON = ["name": "Win"]
            if case .object(let o) = extra { for (k, v) in o { if case .object(var p) = params { p[k] = v; params = .object(p) } } }
            do { _ = try await h.handle(op: "vm.screenshot", params: params); XCTFail(message) }
            catch let e as ControlHandler.ControlError { XCTAssertTrue(e.description.contains(message), e.description) }
        }
    }

    func testScreenshotJPEG() async throws {
        let (h, _) = setup(size: (400, 300))
        let r = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "format": "jpeg", "quality": 0.5])
        XCTAssertNil(r["png"])
        XCTAssertEqual(r["mime"]?.stringValue, "image/jpeg")
        let jpeg = Data(base64Encoded: r["jpeg"]!.stringValue!)!
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(r["sentWidth"]?.intValue, 400)
    }

    func testWaitIdle() async throws {
        let (h, t) = setup()
        let r = try await h.handle(op: "vm.wait_idle", params: ["name": "Win", "seconds": 1, "timeout": 5])
        XCTAssertEqual(r["idle"]?.boolValue, true)
        let flipper = Task { for i in 0..<12 { await t.setPNG(makePNG(width: 800, height: 600, gray: UInt8(i % 2 == 0 ? 10 : 200))); try? await Task.sleep(for: .milliseconds(300)) } }
        let r2 = try await h.handle(op: "vm.wait_idle", params: ["name": "Win", "seconds": 2, "timeout": 3])
        flipper.cancel()
        XCTAssertEqual(r2["idle"]?.boolValue, false)
    }
}
