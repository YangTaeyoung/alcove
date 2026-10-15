import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveDisplayProtocol

/// A scripted VM: records display messages, serves the queued frames or a fixed PNG, hands out the agent set with `setAgent`
/// and keeps the events of that agent.
actor FakeTarget: VMTarget {
    nonisolated let name: String
    var stateValue: VMController.State
    var sent: [ToQEMU] = []
    var png: Data
    /// Frames served one per `frame()` call; the last one repeats. Empty: `frame()` decodes `png`.
    var frames: [Frame] = []
    var frameCalls = 0
    /// The `frame()` calls, counted from 0, that throw `FrameUnavailable`.
    var failingFrameCalls: Set<Int> = []
    var agentClient: AgentClient?
    let guestEvents = EventBuffer()
    var eventFeed: Task<Void, Never>?
    var startCount = 0, stopCount = 0
    var agentWait: Duration = .zero
    var agentWaits = 0, cancelledAgentWaits = 0
    var agentTimeouts: [Duration] = []
    /// One entry per `agent(timeout:)` call: its timeout and how many display messages had been sent before it.
    var agentCalls: [(timeout: Duration, sent: Int)] = []
    var snapshotList: [VMController.SnapshotInfo] = []
    var snapshotCalls: [String] = []
    var monitorReplies: [String] = []
    var monitorLines: [String] = []
    var linkCalls: [Bool] = []
    var forwards: [VMConfig.PortForward] = []
    var instance = 1
    var agentPort = 40_000
    var restoreHook: (@Sendable (FakeTarget) async -> Void)?
    var ephemeral = false
    var cloneOfValue: String?
    var startDiscard: [Bool] = []

    init(name: String, state: VMController.State, png: Data) { self.name = name; self.stateValue = state; self.png = png }
    var os: VMConfig.GuestOS = .windows
    func guestOS() async -> VMConfig.GuestOS { os }
    func setOS(_ value: VMConfig.GuestOS) { os = value }
    /// How many times `state()` was called.
    var stateCalls = 0
    func state() async -> VMController.State { stateCalls += 1; return stateValue }
    var suspended = false
    func isSuspended() async -> Bool { suspended }
    func setSuspended(_ value: Bool) { suspended = value }
    func start() async throws { try await start(discardChanges: false) }
    /// What `start` and `stop` throw when set.
    var startError: Error?
    var stopError: Error?
    func setStartError(_ e: Error?) { startError = e }
    func setStopError(_ e: Error?) { stopError = e }
    /// Holds each `start` until it opens, also when the caller is cancelled.
    var startLatch: Latch?
    func setStartLatch(_ latch: Latch?) { startLatch = latch }
    /// The `start` calls that began, finished or not.
    var startsBegun = 0
    func start(discardChanges: Bool) async throws {
        startsBegun += 1
        if let startLatch { await startLatch.pass() }
        if let startError { throw startError }
        startCount += 1; startDiscard.append(discardChanges)
        ephemeral = discardChanges; stateValue = .running; suspended = false
    }
    func stop(force: Bool) async throws { if let stopError { throw stopError }; stopCount += 1; stateValue = .stopped; ephemeral = false }
    func isEphemeral() async -> Bool { ephemeral }
    func cloneOf() async -> String? { cloneOfValue }
    func setCloneOf(_ template: String?) { cloneOfValue = template }
    func pause() async throws { stateValue = .paused }
    func resume() async throws { stateValue = .running }
    func screenshotPNG() async throws -> Data { png }
    /// Runs at the start of every `frame()` call when set.
    var frameHook: (@Sendable () async -> Void)?
    func setFrameHook(_ hook: (@Sendable () async -> Void)?) { frameHook = hook }
    func frame() async throws -> Frame {
        await frameHook?()
        frameCalls += 1
        if failingFrameCalls.contains(frameCalls - 1) { throw FrameUnavailable() }
        if frames.count > 1 { return frames.removeFirst() }
        if let last = frames.first { return last }
        guard let f = Frame(png: png) else { throw NSError(domain: "FakeTarget", code: 1) }
        return f
    }
    /// The `frameSize()` calls.
    var frameSizeCalls = 0
    /// What `frameSize()` throws when set.
    var frameSizeError: Error?
    func setFrameSizeError(_ e: Error?) { frameSizeError = e }
    /// The size of the frame the next `frame()` call serves; the call is not counted in `frameCalls`.
    func frameSize() async throws -> (width: Int, height: Int) {
        frameSizeCalls += 1
        if let frameSizeError { throw frameSizeError }
        if let next = frames.first { return (next.width, next.height) }
        guard let f = Frame(png: png) else { throw NSError(domain: "FakeTarget", code: 1) }
        return (f.width, f.height)
    }
    @discardableResult func sendDisplay(_ message: ToQEMU) async -> Bool { sent.append(message); return true }
    func agent(timeout: Duration) async -> AgentClient? {
        agentTimeouts.append(timeout)
        agentCalls.append((timeout, sent.count))
        if let hook = agentHook {
            agentHook = nil
            await hook(self)
        }
        if agentWait > .zero {
            agentWaits += 1
            try? await Task.sleep(for: agentWait)
            if Task.isCancelled { cancelledAgentWaits += 1 }
        }
        return agentClient
    }
    func snapshots() async throws -> [VMController.SnapshotInfo] {
        if let snapshotListError { throw snapshotListError }
        return snapshotList
    }
    /// What `snapshots()` throws when set.
    var snapshotListError: Error?
    func setSnapshotListError(_ e: Error?) { snapshotListError = e }
    func createSnapshot(named name: String) async throws {
        snapshotCalls.append("create:\(name)")
        if let snapshotError { throw snapshotError }
    }
    func restoreSnapshot(named name: String) async throws {
        snapshotCalls.append("restore:\(name)")
        if let snapshotError { throw snapshotError }
        await restoreHook?(self)
    }
    func deleteSnapshot(named name: String) async throws {
        snapshotCalls.append("delete:\(name)")
        if let snapshotError { throw snapshotError }
    }
    /// What `createSnapshot`, `restoreSnapshot` and `deleteSnapshot` throw when set.
    var snapshotError: Error?
    func setSnapshotError(_ e: Error?) { snapshotError = e }
    /// Runs once, on the next `monitorCommand`, before it answers.
    var monitorHook: (@Sendable (FakeTarget) async -> Void)?
    func setMonitorHook(_ hook: (@Sendable (FakeTarget) async -> Void)?) { monitorHook = hook }
    func monitorCommand(_ line: String) async throws -> String {
        monitorLines.append(line)
        if let hook = monitorHook {
            monitorHook = nil
            await hook(self)
        }
        if !monitorReplies.isEmpty { return monitorReplies.removeFirst() }
        let remove = "hostfwd_remove \(VMController.netdevID) "
        return line.hasPrefix(remove) ? "host forwarding rule for \(line.dropFirst(remove.count)) removed\r\n" : ""
    }
    func setNetworkLink(up: Bool) async throws {
        linkCalls.append(up)
        if let linkError { throw linkError }
    }
    /// What `setNetworkLink` throws when set.
    var linkError: Error?
    func setLinkError(_ e: Error?) { linkError = e }
    func staticForwards() async -> [VMConfig.PortForward] { forwards }
    func engineInstance() async -> Int { instance }
    func agentHostPort() async -> Int { agentPort }
    func setInstance(_ i: Int) { instance = i }
    func setSnapshotList(_ l: [VMController.SnapshotInfo]) { snapshotList = l }
    func setMonitorReplies(_ r: [String]) { monitorReplies = r }
    func setForwards(_ f: [VMConfig.PortForward]) { forwards = f }
    func setRestoreHook(_ h: (@Sendable (FakeTarget) async -> Void)?) { restoreHook = h }
    /// Whether `agentLink()` answers `connecting` when no agent is set.
    var connectingAgent = false
    func setConnectingAgent(_ value: Bool) { connectingAgent = value }
    /// What `agentLink()` answers when set, whatever agent is set.
    var linkState: AgentLinkState?
    func setLinkState(_ value: AgentLinkState?) { linkState = value }
    /// The agent that the connection attempt of the next `agentLink()` without an agent adopts through `connectAgent`.
    var linkAgent: AgentClient?
    func setLinkAgent(_ a: AgentClient?) { linkAgent = a }
    /// Runs once, at the start of the next `agent(timeout:)` call.
    var agentHook: (@Sendable (FakeTarget) async -> Void)?
    func setAgentHook(_ hook: (@Sendable (FakeTarget) async -> Void)?) { agentHook = hook }
    /// Counted in `agentCalls` as a call without a timeout.
    func agentLink() async -> AgentLinkState {
        agentCalls.append((.zero, sent.count))
        if let linkState { return linkState }
        if let agentClient { return .connected(agentClient) }
        if let adopted = linkAgent {
            linkAgent = nil
            await connectAgent(adopted)
            return .connecting
        }
        return connectingAgent ? .connecting : .notConnected
    }
    /// One entry per `dropAgent` call: whether it dropped the agent.
    var drops: [Bool] = []
    func dropAgent(_ only: AgentClient?) async {
        let dropped = agentClient != nil && (only == nil || only === agentClient)
        drops.append(dropped)
        if dropped { setAgent(nil) }
    }
    func setAgent(_ a: AgentClient?) {
        agentClient = a
        eventFeed?.cancel()
        eventFeed = a.map { guestEvents.follow($0) }
    }
    /// The receiver of the agent connections that `connectAgent` announces.
    var agentObserver: (@Sendable (any VMTarget, AgentClient) async -> Void)?
    func setAgentObserver(_ observer: (@Sendable (any VMTarget, AgentClient) async -> Void)?) async { agentObserver = observer }
    /// Sets `a` as the agent and calls the observer with it, as a target does for a connection it adopts.
    func connectAgent(_ a: AgentClient) async {
        setAgent(a)
        await agentObserver?(self, a)
    }
    func events(since seq: Int) async -> (events: [GuestEvent], next: Int, first: Int) { await guestEvents.since(seq) }
    func setAgentWait(_ d: Duration) { agentWait = d }
    func setPNG(_ d: Data) { png = d }
    func setFrames(_ f: [Frame]) { frames = f }
    func setFailingFrameCalls(_ calls: Set<Int>) { failingFrameCalls = calls }
    func setState(_ s: VMController.State) { stateValue = s }
    /// What `bundlePath()` answers.
    var bundle: String?
    func setBundle(_ path: String?) { bundle = path }
    func bundlePath() async -> String? { bundle }
    /// What `agentRefusal()` answers.
    var refusal: String?
    func setRefusal(_ text: String?) { refusal = text }
    func agentRefusal() async -> String? { refusal }
}

/// What `FakeTarget.frame()` throws for a call listed in `failingFrameCalls`.
struct FrameUnavailable: Error, CustomStringConvertible {
    var description: String { "no surface is mapped" }
}

/// The capture directory of handlers whose test does not look at the capture journal: a folder of this test process
/// that no test creates.
let scratchCaptureDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("alcove-test-captures-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")

struct FakeRegistry: VMRegistry {
    let targets: [String: FakeTarget]
    func names() async -> [String] { targets.keys.sorted() }
    func target(named name: String) async -> VMTarget? { targets[name] }
}

/// A WxH PNG of one colour, encoded with ImageIO.
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
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory)
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

    func testStatusReportsTheSizeOfTheCurrentFrame() async throws {
        let (h, t) = setup(size: (640, 480))
        let booting = try await h.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertEqual(booting["width"]?.intValue, 640); XCTAssertEqual(booting["height"]?.intValue, 480)
        await t.setPNG(makePNG(width: 1280, height: 800))
        let later = try await h.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertEqual(later["width"]?.intValue, 1280); XCTAssertEqual(later["height"]?.intValue, 800)
        let listed = try await h.handle(op: "vm.list", params: [:])
        XCTAssertEqual(listed["vms"]?[0]?["width"]?.intValue, 1280); XCTAssertEqual(listed["vms"]?[0]?["height"]?.intValue, 800)
        let frames = await t.frameCalls
        XCTAssertEqual(frames, 0)
    }

    func testPointerCoordinatesAreScaledToTheCurrentFrame() async throws {
        let (h, t) = setup(size: (640, 480))
        _ = try await h.handle(op: "vm.status", params: ["name": "Win"])
        await t.setPNG(makePNG(width: 1280, height: 800))
        func expected(_ x: Int, _ y: Int) -> ToQEMU {
            .abs(con: 0, x: Int((Double(x) / 1279 * Double(ToQEMU.absoluteMax)).rounded()),
                 y: Int((Double(y) / 799 * Double(ToQEMU.absoluteMax)).rounded()))
        }
        _ = try await h.handle(op: "vm.mouse.move", params: ["name": "Win", "x": 1000, "y": 700])
        var sent = await t.sent
        XCTAssertEqual(sent.first, expected(1000, 700))
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 300, "y": 200])
        sent = Array(await t.sent.dropFirst(sent.count))
        XCTAssertEqual(sent.first, expected(300, 200))

        await t.setPNG(makePNG(width: 800, height: 600))
        let before = await t.sent.count
        _ = try await h.handle(op: "vm.mouse.drag", params: ["name": "Win", "fromX": 799, "fromY": 599, "toX": 0, "toY": 0])
        sent = Array(await t.sent.dropFirst(before))
        XCTAssertEqual(sent.first, .abs(con: 0, x: ToQEMU.absoluteMax, y: ToQEMU.absoluteMax))
        let frames = await t.frameCalls
        XCTAssertEqual(frames, 0)
    }

    func testEachPointerOpReadsTheFrameSizeOnce() async throws {
        let (h, t) = setup()
        let ops: [(String, JSON)] = [
            ("vm.mouse.drag", ["name": "Win", "fromX": 0, "fromY": 0, "toX": 100, "toY": 100]),
            ("vm.mouse.click", ["name": "Win", "x": 5, "y": 5, "count": 3]),
            ("vm.mouse.scroll", ["name": "Win", "x": 5, "y": 5, "dy": 2]),
            ("vm.mouse.move", ["name": "Win", "x": 5, "y": 5]),
            ("vm.mouse.down", ["name": "Win", "x": 5, "y": 5]),
            ("vm.mouse.up", ["name": "Win"]),
        ]
        var expected = 0
        for (op, params) in ops {
            _ = try await h.handle(op: op, params: params)
            if params["x"] != nil || params["fromX"] != nil { expected += 1 }
            let calls = await t.frameSizeCalls
            XCTAssertEqual(calls, expected, op)
        }
    }

    func testABatchCancelledWhileTheFrameSizeIsReadEndsAsCancelled() async throws {
        let (h, t) = setup()
        await t.setFrameSizeError(CancellationError())
        do {
            let r = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": [["op": "vm.mouse.move", "x": 5, "y": 5]]])
            XCTFail("the batch returned \(r)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
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
        let local = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tools-required-\(UUID().uuidString).bin")
        try Data("x".utf8).write(to: local)
        addTeardownBlock { try? FileManager.default.removeItem(at: local) }
        for (op, params) in [("vm.exec", ["name": "Win", "command": "hostname"] as JSON), ("vm.clipboard.get", ["name": "Win"]),
                             ("vm.clipboard.set", ["name": "Win", "text": "x"]), ("vm.push_file", ["name": "Win", "path": .string(local.path)])] {
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
        XCTAssertEqual(r["areaWidth"]?.intValue, 400); XCTAssertEqual(r["areaHeight"]?.intValue, 300)
        XCTAssertEqual(r["mime"]?.stringValue, "image/png")
        let png = Data(base64Encoded: r["png"]!.stringValue!)!
        XCTAssertEqual(Frame(png: png)?.width, 200)

        let capped = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "region": ["x": 100, "y": 200, "w": 400, "h": 300], "scale": 0.5, "maxWidth": 100])
        XCTAssertEqual(capped["sentWidth"]?.intValue, 100)
        XCTAssertEqual(capped["scale"]?.doubleValue, 0.25)

        let clamped = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "region": ["x": 1500, "y": 900, "w": 400, "h": 400]])
        XCTAssertEqual(clamped["x"]?.intValue, 1500); XCTAssertEqual(clamped["sentWidth"]?.intValue, 100)
        XCTAssertEqual(clamped["sentHeight"]?.intValue, 100); XCTAssertEqual(clamped["scale"]?.doubleValue, 1)
        XCTAssertEqual(clamped["areaWidth"]?.intValue, 100); XCTAssertEqual(clamped["areaHeight"]?.intValue, 100)

        let full = try await h.handle(op: "vm.screenshot", params: ["name": "Win"])
        XCTAssertEqual(full["x"]?.intValue, 0); XCTAssertEqual(full["y"]?.intValue, 0)
        XCTAssertEqual(full["scale"]?.doubleValue, 1)
        XCTAssertEqual(full["areaWidth"]?.intValue, 1600); XCTAssertEqual(full["areaHeight"]?.intValue, 1000)
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
            } catch let e as ControlHandler.ControlError { XCTAssertEqual(e.description, ControlHandler.regionSentence) }
        }
    }

    func testRegionSentenceNamesTheRanges() {
        XCTAssertEqual(ControlHandler.regionSentence,
                       "region needs integer x, y, w, h with x and y between -65536 and 65536 and w and h between 1 and 65536")
    }

    func testExtremeIntegerParametersAreRefusedWithTheirRangeBeforeAnyInput() async throws {
        let (h, t) = setup()
        let huge = JSON.int(Int64.max), tiny = JSON.int(Int64.min)
        let cases: [(String, JSON, String)] = [
            ("vm.mouse.scroll", ["name": "Win", "x": 5, "y": 5, "dy": tiny], "dy must be an integer between -1000 and 1000"),
            ("vm.mouse.scroll", ["name": "Win", "x": 5, "y": 5, "dx": huge], "dx must be an integer between -1000 and 1000"),
            ("vm.mouse.scroll", ["name": "Win", "x": tiny, "y": 5, "dy": 1], "x must be an integer between -65536 and 65536"),
            ("vm.mouse.drag", ["name": "Win", "fromX": tiny, "fromY": 0, "toX": huge, "toY": 0], "fromX must be an integer between -65536 and 65536"),
            ("vm.mouse.drag", ["name": "Win", "fromX": 0, "fromY": 0, "toX": huge, "toY": 0], "toX must be an integer between -65536 and 65536"),
            ("vm.mouse.move", ["name": "Win", "x": 5, "y": huge], "y must be an integer between -65536 and 65536"),
            ("vm.mouse.down", ["name": "Win", "x": huge, "y": 0], "x must be an integer between -65536 and 65536"),
            ("vm.mouse.click", ["name": "Win", "x": 5, "y": 5, "hold": huge], "hold must be an integer between 0 and 10000"),
            ("vm.mouse.click", ["name": "Win", "x": 5, "y": 5, "hold": -1], "hold must be an integer between 0 and 10000"),
            ("vm.key.press", ["name": "Win", "keys": "a", "hold": huge], "hold must be an integer between 0 and 10000"),
            ("vm.type", ["name": "Win", "text": "a", "delay": huge], "delay must be an integer between 0 and 1000"),
            ("vm.type", ["name": "Win", "text": "a", "delay": "fast"], "delay must be an integer between 0 and 1000"),
            ("vm.screenshot", ["name": "Win", "region": ["x": huge, "y": 0, "w": 1, "h": 1]], ControlHandler.regionSentence),
            ("vm.screenshot", ["name": "Win", "region": ["x": 0, "y": 0, "w": huge, "h": 1]], ControlHandler.regionSentence),
            ("vm.find_text", ["name": "Win", "region": ["x": 0, "y": tiny, "w": 1, "h": 1]], ControlHandler.regionSentence),
            ("vm.wait_idle", ["name": "Win", "seconds": huge], "seconds must be an integer between 0 and 600"),
            ("vm.wait_idle", ["name": "Win", "timeout": tiny], "timeout must be an integer between 1 and 600"),
        ]
        for (op, params, expected) in cases {
            do {
                _ = try await h.handle(op: op, params: params)
                XCTFail("\(op) \(params) succeeded")
            } catch let e as ControlHandler.ControlError {
                XCTAssertEqual(e.description, expected, "\(op) \(params)")
            }
        }
        let sent = await t.sent
        XCTAssertEqual(sent, [])
        let batch = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": [["op": "vm.mouse.scroll", "x": 5, "y": 5, "dy": tiny]]])
        XCTAssertEqual(batch["error"]?.stringValue, "dy must be an integer between -1000 and 1000")
    }

    func testBoundaryIntegerParametersAreAccepted() async throws {
        let (h, t) = setup()
        _ = try await h.handle(op: "vm.mouse.scroll", params: ["name": "Win", "x": -65536, "y": 65536, "dy": -2, "dx": 1])
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 65536, "y": -65536, "hold": 0])
        _ = try await h.handle(op: "vm.type", params: ["name": "Win", "text": "a", "delay": 0])
        let shot = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "region": ["x": -100, "y": -100, "w": 65536, "h": 65536]])
        XCTAssertEqual(shot["areaWidth"]?.intValue, 800)
        let sent = await t.sent
        XCTAssertEqual(sent.filter { if case .btn(_, .wheelUp, true) = $0 { return true }; return false }.count, 2)
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

    /// The keys and buttons `sent` leaves pressed: each down without a later up of the same key or button.
    private func pressed(_ sent: [ToQEMU]) -> [String] {
        var down: [String] = []
        for message in sent {
            switch message {
            case .btn(_, let button, let isDown):
                if isDown { down.append("\(button)") } else { down.removeAll { $0 == "\(button)" } }
            case .key(let code, _, let isDown):
                if isDown { down.append("key \(code ?? -1)") } else { down.removeAll { $0 == "key \(code ?? -1)" } }
            default: break
            }
        }
        return down
    }

    /// Starts `op` in a task, waits until `t` has received a message that `started` accepts, cancels the task and returns
    /// what the task threw.
    private func cancelled(_ h: ControlHandler, _ t: FakeTarget, _ op: String, _ params: JSON,
                           once started: @escaping @Sendable ([ToQEMU]) -> Bool) async -> Error? {
        let task = Task { try await h.handle(op: op, params: params) }
        guard await eventually("\(op) has begun", { started(await t.sent) }) else { task.cancel(); return nil }
        task.cancel()
        do { _ = try await task.value; return nil } catch { return error }
    }

    func testACancelledClickReleasesItsButton() async throws {
        let (h, t) = setup()
        let error = await cancelled(h, t, "vm.mouse.click", ["name": "Win", "x": 5, "y": 5, "hold": 10_000, "button": "right"]) {
            $0.contains(.btn(con: 0, button: .right, down: true))
        }
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        let sent = await t.sent
        XCTAssertEqual(pressed(sent), [])
        XCTAssertEqual(Array(sent.suffix(2)), [.btn(con: 0, button: .right, down: false), .sync])
    }

    func testACancelledDragReleasesItsButton() async throws {
        let (h, t) = setup()
        let error = await cancelled(h, t, "vm.mouse.drag", ["name": "Win", "fromX": 0, "fromY": 0, "toX": 100, "toY": 100]) {
            $0.contains(.btn(con: 0, button: .left, down: true))
        }
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        let sent = await t.sent
        XCTAssertEqual(pressed(sent), [])
    }

    func testACancelledKeyPressReleasesItsKeysInReverseOrder() async throws {
        let (h, t) = setup()
        let error = await cancelled(h, t, "vm.key.press", ["name": "Win", "keys": "ctrl+shift+a", "hold": 10_000]) {
            $0.contains(.key(mac: 0, q: nil, down: true))
        }
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        let sent = await t.sent
        XCTAssertEqual(pressed(sent), [])
        XCTAssertEqual(Array(sent.suffix(3)), [.key(mac: 0, q: nil, down: false), .key(mac: 56, q: nil, down: false), .key(mac: 59, q: nil, down: false)])
    }

    func testACancelledTypeReleasesTheKeyItPressed() async throws {
        let (h, t) = setup()
        let error = await cancelled(h, t, "vm.type", ["name": "Win", "text": "Hello", "delay": 1000]) { !$0.isEmpty }
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        let sent = await t.sent
        XCTAssertEqual(pressed(sent), [])
        XCTAssertEqual(sent.first, .key(mac: 56, q: nil, down: true))
    }

    func testACancelledBatchReleasesWhatItsDownStepsPressed() async throws {
        let (h, t) = setup()
        let steps: JSON = [["op": "vm.key.down", "key": "shift"], ["op": "vm.mouse.down", "button": "middle"],
                           ["op": "vm.key.down", "key": "a"], ["op": "vm.key.up", "key": "a"], ["op": "sleep", "ms": 10_000]]
        let error = await cancelled(h, t, "vm.batch", ["name": "Win", "steps": steps]) { $0.contains(.key(mac: 0, q: nil, down: false)) }
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        let sent = await t.sent
        XCTAssertEqual(pressed(sent), [])
        XCTAssertEqual(Array(sent.suffix(3)), [.btn(con: 0, button: .middle, down: false), .sync, .key(mac: 56, q: nil, down: false)])
    }

    func testAFailedBatchReleasesWhatItsDownStepsPressed() async throws {
        let (h, t) = setup()
        let steps: JSON = [["op": "vm.key.down", "key": "ctrl"], ["op": "vm.mouse.down"], ["op": "vm.mouse.click", "x": 5]]
        let r = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": steps])
        XCTAssertEqual(r["failedStep"]?.intValue, 2)
        let sent = await t.sent
        XCTAssertEqual(pressed(sent), [])
        XCTAssertEqual(Array(sent.suffix(3)), [.btn(con: 0, button: .left, down: false), .sync, .key(mac: 59, q: nil, down: false)])
    }

    func testABatchThatEndsWithAKeyDownLeavesItDown() async throws {
        let (h, t) = setup()
        _ = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": [["op": "vm.key.down", "key": "shift"]]])
        let sent = await t.sent
        XCTAssertEqual(pressed(sent), ["key 56"])
    }

    func testAnInputOpCancelledWhileItWaitsForTheGateSendsNothing() async throws {
        let (h, t) = setup()
        let first = Task { try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "hold": 300]) }
        guard await eventually("the first click holds its button", { await t.sent.contains(.btn(con: 0, button: .left, down: true)) }) else { return }
        let second = Task { try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 50, "y": 50, "button": "right"]) }
        guard await eventually("the second click waits for the gate", { await h.inputGate.waiterCount(for: "Win") == 1 }) else { return }
        second.cancel()
        _ = try await first.value
        do { _ = try await second.value; XCTFail("the second click ran") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let sent = await t.sent
        XCTAssertFalse(sent.contains { if case .btn(_, .right, _) = $0 { return true }; return false })
        XCTAssertEqual(sent.filter { if case .abs = $0 { return true }; return false }.count, 1)
    }

    func testAnInputOpQueuedBeforeALeaseIsRefusedByThatLease() async throws {
        let (h, t) = setup()
        let first = Task { try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "hold": 300]) }
        guard await eventually("the first click holds its button", { await t.sent.contains(.btn(con: 0, button: .left, down: true)) }) else { return }
        let second = Task { try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 50, "y": 50, "button": "right"]) }
        guard await eventually("the second click waits for the gate", { await h.inputGate.waiterCount(for: "Win") == 1 }) else { return }
        _ = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "agent-b", "seconds": 60])
        _ = try await first.value
        do {
            _ = try await second.value
            XCTFail("the second click ran")
        } catch let e as ControlHandler.ControlError {
            XCTAssertTrue(e.description.hasPrefix("VM 'Win' is leased by agent-b for another "), e.description)
        }
        let sent = await t.sent
        XCTAssertFalse(sent.contains { if case .btn(_, .right, _) = $0 { return true }; return false })
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
