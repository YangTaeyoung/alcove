import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveDisplayProtocol
import AlcoveTestSupport

/// What the fake agent answers to one op: result fields, an error sentence, nothing, or what a request is answered with.
private indirect enum Reply: Sendable {
    case ok([String: JSON])
    case fail(String)
    case silent
    case by(@Sendable (JSON) -> Reply)
}

/// One trace line of VM "Win" in the shape a recording writes; `extra` holds further fields of the line.
private func entry(_ seq: Int, _ op: String, _ params: [String: JSON] = [:], ok: Bool = true, result: JSON = [:],
                   _ extra: [String: JSON] = [:]) -> JSON {
    var fields = params
    fields["name"] = "Win"
    var line: [String: JSON] = ["seq": .int(Int64(seq)), "time": "2026-10-14T09:00:00.000Z", "ms": .int(Int64(seq * 100)),
                                "op": .string(op), "params": .object(fields), "durationMs": 12, "ok": .bool(ok)]
    if ok { line["result"] = result } else { line["error"] = "the op failed" }
    for (key, value) in extra { line[key] = value }
    return .object(line)
}

private func node(_ ref: String, _ role: String, _ name: String, aid: String? = nil, flags: [String] = [], value: String? = nil) -> JSON {
    var o: [String: JSON] = ["ref": .string(ref), "depth": 0, "role": .string(role), "name": .string(name),
                             "x": 150, "y": 100, "w": 80, "h": 24, "flags": .array(flags.map(JSON.string))]
    if let aid { o["aid"] = .string(aid) }
    if let value { o["value"] = .string(value) }
    return .object(o)
}

private let fixtureWindow: JSON = ["id": "0x2a", "title": "Alcove Fixture", "pid": 4242, "process": "alcove-fixture.exe",
                                   "class": "AlcoveFixture", "x": 100, "y": 50, "w": 400, "h": 300, "state": "normal",
                                   "foreground": true, "responding": true, "modal": false]
private let sendButton = node("e5", "Button", "Send", aid: "send")

/// A `ui.at` reply: a node at (`x`, 100) of 80x24 in the window titled `title`, with the counts given as (matches, index).
private func at(_ role: String, _ name: String, id: String? = nil, x: Int = 150, title: String = "Alcove Fixture", flags: [String] = ["enabled"],
                byID: (Int, Int)? = nil, byName: (Int, Int)? = nil) -> [String: JSON] {
    var node: [String: JSON] = ["role": .string(role), "name": .string(name), "x": .int(Int64(x)), "y": 100, "w": 80, "h": 24,
                                "flags": .array(flags.map(JSON.string))]
    if let id { node["aid"] = .string(id) }
    var reply: [String: JSON] = ["node": .object(node), "window": ["id": "0x2a", "title": .string(title)]]
    if let byID { reply["byAutomationId"] = ["matches": .int(Int64(byID.0)), "index": .int(Int64(byID.1))] }
    if let byName { reply["byName"] = ["matches": .int(Int64(byName.0)), "index": .int(Int64(byName.1))] }
    return reply
}

/// The `target` of a trace line: an element of 80x24 at (150, 100) unless `rect` says otherwise, with the counts given
/// as (matches, index).
private func target(_ window: String?, _ role: String, _ name: String, id: String? = nil, rect: [Int]? = [150, 100, 80, 24],
                    byID: (Int, Int)? = nil, byName: (Int, Int)? = nil, password: Bool = false) -> JSON {
    var facts: [String: JSON] = ["role": .string(role), "name": .string(name)]
    if let window { facts["window"] = .string(window) }
    if let id { facts["automationId"] = .string(id) }
    if let rect { facts["rect"] = ["x": .int(Int64(rect[0])), "y": .int(Int64(rect[1])), "w": .int(Int64(rect[2])), "h": .int(Int64(rect[3]))] }
    if let byID { facts["byAutomationId"] = ["matches": .int(Int64(byID.0)), "index": .int(Int64(byID.1))] }
    if let byName { facts["byName"] = ["matches": .int(Int64(byName.0)), "index": .int(Int64(byName.1))] }
    if password { facts["password"] = true }
    return .object(facts)
}

private let sendAt = at("Button", "Send", id: "send", byID: (1, 0), byName: (3, 2))
private let sendTarget = target("Alcove Fixture", "Button", "Send", id: "send", byID: (1, 0), byName: (3, 2))
private let sendSelector: JSON = ["window": "Alcove Fixture", "role": "Button", "automationId": "send"]
private let sendAltSelector: JSON = ["window": "Alcove Fixture", "role": "Button", "name": "Send", "index": 2]
private let noMatch = "no element matches {\"automationId\":\"send\",\"name\":\"Send\",\"role\":\"Button\",\"window\":\"Alcove Fixture\"}; call ui.tree to see what exists"

final class ScriptBuilderTests: XCTestCase {
    override func setUp() {
        WaitTiming.tick = .milliseconds(20)
        WaitTiming.agentPeriod = .milliseconds(40)
    }

    override func tearDown() {
        WaitTiming.tick = .milliseconds(250)
        WaitTiming.agentPeriod = .milliseconds(500)
        UITiming.targetBudget = .milliseconds(300)
        UITiming.factBudgetEnd = { try? await Task.sleep(until: $0, clock: .continuous) }
    }

    // MARK: - helpers

    private func build(_ trace: [JSON], from: Int? = nil, to: Int? = nil) -> Script {
        ScriptBuilder.build(trace: trace, vm: "Win", from: from, to: to)
    }

    private func ops(_ script: Script) -> [String] { script.steps.map(\.op) }

    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("script-builder-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A recording directory holding `trace` as its `trace.jsonl`, each element on one line; a string element is written as it is.
    private func recordingDir(_ trace: [JSON]) throws -> URL {
        let dir = try tempDir().appendingPathComponent("recording")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var text = ""
        for line in trace {
            if let raw = line.stringValue { text += raw + "\n" } else { text += String(decoding: try line.serialized(), as: UTF8.self) + "\n" }
        }
        try Data(text.utf8).write(to: dir.appendingPathComponent("trace.jsonl"))
        return dir
    }

    private func handler() -> ControlHandler {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 800, height: 600))
        return ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory)
    }

    /// An agent that offers `caps` and answers each op as `answers` says at that moment; an op without an entry gets
    /// the agent's unknown-op error.
    private func fakeAgent(caps: [String] = ["clipboard", "files", "exec", "ui"], _ answers: LockedBox<[String: Reply]>) -> FakeAgent {
        let agent = FakeAgent()
        agent.caps = caps
        agent.handler = { m, _ in
            guard m["t"]?.stringValue == "req", let op = m["op"]?.stringValue else { return [] }
            var reply = answers.value[op]
            while case .by(let choose) = reply { reply = choose(m) }
            switch reply {
            case .ok(let fields): return [agentReply(m, fields)]
            case .fail(let message): return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": .string(message)]]
            case .silent, .by: return []
            case nil: return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": .string("unknown op '\(op)'; update alcove-agent")]]
            }
        }
        return agent
    }

    /// A running 800x600 VM "Win" whose agent is `fakeAgent(caps:answers)`.
    private func rig(caps: [String] = ["clipboard", "files", "exec", "ui"],
                     _ answers: LockedBox<[String: Reply]>) async throws -> (ControlHandler, FakeTarget, FakeAgent) {
        let agent = fakeAgent(caps: caps, answers)
        let (h, t) = try await handlerWithAgent(agent, in: self)
        return (h, t, agent)
    }

    private func startRecording(_ h: ControlHandler) async throws -> URL {
        let dir = try tempDir().appendingPathComponent("recording")
        _ = try await h.handle(op: "vm.record.start", params: ["name": "Win", "dir": .string(dir.path), "video": false])
        return dir
    }

    private func lines(_ dir: URL) throws -> [JSON] {
        try String(contentsOf: dir.appendingPathComponent("trace.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSON.parse(Data($0.utf8)) }
    }

    /// The request fields of `m` without the transport fields.
    private func fields(_ m: JSON) -> JSON {
        var o = m.objectValue ?? [:]
        for key in ["t", "id", "op"] { o[key] = nil }
        return .object(o)
    }

    private func failure(_ h: ControlHandler, _ op: String, _ params: JSON, file: StaticString = #filePath, line: UInt = #line) async -> String {
        do { _ = try await h.handle(op: op, params: params); XCTFail("\(op) succeeded", file: file, line: line); return "" }
        catch { return "\(error)" }
    }

    private struct StillRunning: Error {}

    /// The value of `task`; throws `StillRunning` when it has not finished within 20 s.
    private func value<T: Sendable>(of task: Task<T, Error>) async throws -> T {
        let box = LockedBox<Result<T, Error>?>(nil)
        Task { box.value = await task.result }
        guard await eventually({ box.value != nil }), let result = box.value else { throw StillRunning() }
        return try result.get()
    }

    private func absolute(_ x: Int, _ y: Int) -> ToQEMU {
        .abs(con: 0, x: Int((Double(x) / 799 * Double(ToQEMU.absoluteMax)).rounded()),
             y: Int((Double(y) / 599 * Double(ToQEMU.absoluteMax)).rounded()))
    }

    private func click(_ x: Int, _ y: Int) -> JSON { ["name": "Win", "x": .int(Int64(x)), "y": .int(Int64(y))] }

    // MARK: - builder

    func testDropsReadOnlyAndFailedEntries() {
        let idle: JSON = ["type": "screen_idle"]
        let script = build([
            entry(1, "vm.screenshot", result: ["png": "<image omitted>"]),
            entry(2, "vm.mouse.click", ["x": 5, "y": 6]),
            entry(3, "vm.key.press", ["keys": "ctrl+s"], ok: false),
            entry(4, "vm.status"),
            entry(5, "vm.wait_for", ["conditions": [idle]], result: ["matched": 0]),
            entry(6, "vm.wait_idle", ["seconds": 1], result: ["idle": true]),
            entry(7, "vm.ui.find", ["selector": ["name": "Send"]], result: ["nodes": []]),
            entry(8, "vm.lease.acquire", ["owner": "me"]),
            entry(9, "vm.key.press", ["keys": "enter"]),
            entry(10, "vm.wait_for", ["conditions": [idle]], result: ["matched": -1]),
            entry(11, "vm.events", result: ["events": []]),
            entry(12, "vm.exec", ["command": "dir"], result: ["code": 0]),
        ])
        XCTAssertEqual(script.vm, "Win")
        XCTAssertEqual(script.variables, [:])
        XCTAssertEqual(ops(script), ["vm.mouse.click", "vm.wait_for", "vm.wait_idle", "vm.key.press", "vm.exec"])
        XCTAssertEqual(script.steps.map(\.params), [["x": 5, "y": 6], ["conditions": [idle]], ["seconds": 1], ["keys": "enter"], ["command": "dir"]])
        XCTAssertEqual(script.steps.map(\.label), ["vm.mouse.click (5, 6)", "vm.wait_for screen_idle", "vm.wait_idle", "vm.key.press enter", "vm.exec dir"])
        XCTAssertEqual(script.steps.map(\.expect), [[], [], [], [], []])
        XCTAssertEqual(script.steps.map(\.timeout), [10, 10, 10, 10, 10])
        XCTAssertNoThrow(try script.validate())
    }

    func testClickWithTargetBecomesSelectorWithFallback() {
        let script = build([
            entry(1, "vm.mouse.click", ["x": 190, "y": 112, "button": "right", "count": 2, "observe": "summary", "settleMs": 50], ["target": sendTarget]),
            entry(2, "vm.mouse.click", ["x": 10, "y": 20], ["target": target("Alcove Fixture", "Button", "", id: "send", byID: (2, 1))]),
            entry(3, "vm.mouse.click", ["x": 30, "y": 40], ["target": target("Notes", "MenuItem", "File", byName: (1, 0))]),
            entry(4, "vm.mouse.click", ["x": 190, "y": 112, "hold": 900], ["target": sendTarget]),
            entry(5, "vm.mouse.drag", ["fromX": 190, "fromY": 112, "toX": 300, "toY": 112], ["target": sendTarget]),
        ])
        XCTAssertEqual(ops(script), ["vm.ui.click", "vm.ui.click", "vm.ui.click", "vm.mouse.click", "vm.mouse.drag"])
        XCTAssertEqual(script.steps[0].params, ["selector": sendSelector, "altSelector": sendAltSelector, "fallback": ["x": 190, "y": 112],
                                                "button": "right", "count": 2, "observe": "summary", "settleMs": 50])
        XCTAssertEqual(script.steps[1].params, ["selector": ["window": "Alcove Fixture", "role": "Button", "automationId": "send", "index": 1],
                                                "fallback": ["x": 10, "y": 20]])
        XCTAssertEqual(script.steps[2].params, ["selector": ["window": "Notes", "role": "MenuItem", "name": "File"], "fallback": ["x": 30, "y": 40]])
        XCTAssertEqual(script.steps[3].params, ["x": 190, "y": 112, "hold": 900])
        XCTAssertEqual(script.steps[4].params, ["fromX": 190, "fromY": 112, "toX": 300, "toY": 112])
        XCTAssertEqual(script.steps.map(\.label), ["vm.ui.click Button \"Send\"", "vm.ui.click Button #send", "vm.ui.click MenuItem \"File\"",
                                                   "vm.mouse.click Button \"Send\"", "vm.mouse.drag Button \"Send\""])
        XCTAssertNoThrow(try script.validate())
    }

    func testAnElementAmongEquallyNamedOnesIsSelectedByItsIndex() {
        let script = build([
            entry(1, "vm.mouse.click", ["x": 190, "y": 112], ["target": target("Orders", "Button", "Delete", byName: (3, 2))]),
            entry(2, "vm.mouse.click", ["x": 190, "y": 112], ["target": target("Orders", "Button", "Delete", byName: (3, 0))]),
            entry(3, "vm.mouse.click", ["x": 190, "y": 112], ["target": target("Orders", "Button", "Delete", byName: (1, 0))]),
            entry(4, "vm.ui.action", ["ref": "e7", "action": "invoke"], result: ["node": node("e7", "Button", "Delete")],
                  ["target": target("Orders", "Button", "Delete", byName: (3, 2))]),
        ])
        XCTAssertEqual(script.steps.map { $0.params["selector"] }, [
            ["window": "Orders", "role": "Button", "name": "Delete", "index": 2],
            ["window": "Orders", "role": "Button", "name": "Delete", "index": 0],
            ["window": "Orders", "role": "Button", "name": "Delete"],
            ["window": "Orders", "role": "Button", "name": "Delete", "index": 2],
        ])
        XCTAssertEqual(script.steps.map { $0.params["altSelector"] }, [nil, nil, nil, nil])
        XCTAssertNoThrow(try script.validate())
    }

    func testASelectorNeedsACountedMatchInATitledWindow() {
        let long = String(repeating: "n", count: 2000) + "…"
        var cutName = target("Notes", "Button", long, id: "body", byID: (1, 0), byName: (1, 0)).objectValue ?? [:]
        cutName["nameTruncated"] = true
        var cutID = target("Notes", "Button", "Body", id: long, byID: (1, 0), byName: (2, 1)).objectValue ?? [:]
        cutID["automationIdTruncated"] = true
        let targets: [JSON] = [
            target("Notes", "Button", "Send", id: "send"),
            target(nil, "Button", "Send", id: "send", byID: (1, 0), byName: (1, 0)),
            target("0x2a", "Button", "Send", id: "send", byID: (1, 0), byName: (1, 0)),
            target("foreground", "Button", "Send", id: "send", byID: (1, 0), byName: (1, 0)),
            target("Notes", "Button", "", byName: (1, 0)),
            target("Notes", "Button", "Send", id: "send", byName: (2, 1)),
            target("Notes", "Button", "Send", id: "send", byID: (2, 1)),
            .object(cutName),
            .object(cutID),
            ["window": "Notes", "role": "Button", "name": "Send", "byName": ["matches": 2, "index": 2]],
            ["window": "Notes", "role": "Button", "name": "Send", "byName": ["matches": 0, "index": 0]],
            ["window": "Notes", "name": "Send", "byName": ["matches": 1, "index": 0]],
            target("report.docx - Word", "Button", "Send", id: "send", byID: (1, 0), byName: (1, 0)),
        ]
        let script = build(targets.enumerated().map { entry($0.offset + 1, "vm.mouse.click", ["x": 190, "y": 112], ["target": $0.element]) })
        XCTAssertEqual(script.steps.map { $0.params["selector"] }, [
            nil, nil, nil, nil, nil,
            ["window": "Notes", "role": "Button", "name": "Send", "index": 1],
            ["window": "Notes", "role": "Button", "automationId": "send", "index": 1],
            ["window": "Notes", "role": "Button", "automationId": "body"],
            ["window": "Notes", "role": "Button", "name": "Body", "index": 1],
            nil, nil, nil,
            ["window": "Word", "role": "Button", "automationId": "send"],
        ])
        XCTAssertEqual(script.steps.map { $0.params["altSelector"] }, [
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
            ["window": "Word", "role": "Button", "name": "Send"],
        ])
        XCTAssertEqual(script.steps.map(\.op), script.steps.map { $0.params["selector"] == nil ? "vm.mouse.click" : "vm.ui.click" })
        for step in script.steps where step.op == "vm.mouse.click" { XCTAssertEqual(step.params, ["x": 190, "y": 112]) }
    }

    func testAClickWhosePointMattersKeepsItsCoordinates() {
        func facts(_ role: String, rect: [Int]? = [100, 100, 400, 200]) -> JSON { target("Notes", role, "Body", id: "body", rect: rect, byID: (1, 0)) }
        func kept(_ role: String, _ x: Int, _ y: Int, rect: [Int]? = [100, 100, 400, 200]) -> Bool {
            let step = build([entry(1, "vm.mouse.click", ["x": .int(Int64(x)), "y": .int(Int64(y))], ["target": facts(role, rect: rect)])]).steps[0]
            if step.op == "vm.mouse.click" {
                XCTAssertEqual(step.params, ["x": .int(Int64(x)), "y": .int(Int64(y))], role)
                XCTAssertEqual(step.label, "vm.mouse.click \(role) \"Body\"")
                return true
            }
            XCTAssertEqual(step.params, ["selector": ["window": "Notes", "role": .string(role), "automationId": "body"],
                                         "fallback": ["x": .int(Int64(x)), "y": .int(Int64(y))]], role)
            return false
        }
        for role in ["Button", "CheckBox", "RadioButton", "MenuItem", "TabItem", "ListItem", "TreeItem", "Hyperlink"] {
            XCTAssertFalse(kept(role, 101, 101), role)
            XCTAssertFalse(kept(role, 101, 101, rect: nil), role)
        }
        for role in ["Edit", "ComboBox", "SplitButton", "Spinner", "HeaderItem", "DataItem", "Text"] {
            XCTAssertFalse(kept(role, 300, 200), role)
            XCTAssertFalse(kept(role, 400, 250), role)
            XCTAssertFalse(kept(role, 200, 150), role)
            XCTAssertTrue(kept(role, 401, 200), role)
            XCTAssertTrue(kept(role, 199, 200), role)
            XCTAssertTrue(kept(role, 300, 251), role)
            XCTAssertTrue(kept(role, 300, 149), role)
            XCTAssertFalse(kept(role, 300, 250), role)
            XCTAssertFalse(kept(role, 300, 150), role)
            let tall = [100, 100, 200, 400]
            XCTAssertFalse(kept(role, 200, 400, rect: tall), role)
            XCTAssertFalse(kept(role, 200, 351, rect: tall), role)
            XCTAssertFalse(kept(role, 250, 300, rect: tall), role)
            XCTAssertTrue(kept(role, 200, 401, rect: tall), role)
            XCTAssertTrue(kept(role, 200, 199, rect: tall), role)
            XCTAssertTrue(kept(role, 251, 300, rect: tall), role)
            XCTAssertTrue(kept(role, 300, 200, rect: nil), role)
            XCTAssertFalse(kept(role, 111, 105, rect: [100, 100, 10, 10]), role)
            XCTAssertTrue(kept(role, 112, 105, rect: [100, 100, 10, 10]), role)
            XCTAssertFalse(kept(role, 105, 99, rect: [100, 100, 10, 10]), role)
            XCTAssertTrue(kept(role, 105, 98, rect: [100, 100, 10, 10]), role)
        }
        for role in ["Document", "Pane", "Custom", "Image", "Group", "Window", "TitleBar", "List", "Tree", "Table", "DataGrid", "Slider", "ScrollBar",
                     "Thumb", "ToolBar", "Menu", "MenuBar", "StatusBar", "Tab", "Calendar", "ProgressBar", "Separator", "ToolTip", "button"] {
            XCTAssertTrue(kept(role, 300, 200), role)
        }
    }

    func testCoordinateClickWithoutTargetKeepsCoordinates() {
        let script = build([
            entry(1, "vm.mouse.click", ["x": 300, "y": 200]),
            entry(2, "vm.mouse.click", ["x": 310, "y": 210, "button": "right"], ["target": target("Program Manager", "Pane", "")]),
            entry(3, "vm.mouse.click", ["x": 320, "y": 220], ["target": target(nil, "Custom", "", id: "")]),
        ])
        XCTAssertEqual(ops(script), ["vm.mouse.click", "vm.mouse.click", "vm.mouse.click"])
        XCTAssertEqual(script.steps.map(\.params), [["x": 300, "y": 200], ["x": 310, "y": 210, "button": "right"], ["x": 320, "y": 220]])
        XCTAssertEqual(script.steps.map(\.label), ["vm.mouse.click (300, 200)", "vm.mouse.click (310, 210)", "vm.mouse.click (320, 220)"])
    }

    func testRefBecomesSelector() throws {
        let given: JSON = ["window": "Alcove Fixture", "nameContains": "Sen", "index": 1]
        let pane = target("Alcove Fixture", "Pane", "")
        let draft = ScriptBuilder.draft(trace: [
            entry(1, "vm.ui.click", ["ref": "e5", "button": "right"], result: ["x": 190, "y": 112, "node": sendButton], ["target": sendTarget]),
            entry(2, "vm.ui.type", ["ref": "e4", "text": "hi", "clear": true], result: ["node": node("e4", "Edit", "Message")],
                  ["target": target("Alcove Fixture", "Edit", "Message", byName: (1, 0))]),
            entry(3, "vm.ui.action", ["selector": given, "action": "invoke"], result: ["node": sendButton]),
            entry(4, "vm.ui.click", ["ref": "e9", "count": 2], result: ["x": 40, "y": 50, "node": node("e9", "Pane", "")], ["target": pane]),
            entry(5, "vm.ui.action", ["ref": "e9", "action": "focus"], result: ["node": node("e9", "Pane", "")]),
            entry(6, "vm.ui.type", ["ref": "e9", "text": "x"], result: ["node": node("e9", "Pane", "")], ["target": pane]),
            entry(7, "vm.ui.click", ["ref": "e5"], result: ["x": 190, "y": 112, "node": sendButton]),
            entry(8, "vm.ui.action", ["ref": "e5", "action": "invoke"], result: ["node": sendButton], ["target": sendTarget]),
        ], vm: "Win", from: nil, to: nil)
        let script = draft.script
        XCTAssertEqual(ops(script), ["vm.ui.click", "vm.ui.type", "vm.ui.action", "vm.mouse.click", "vm.mouse.click", "vm.ui.action"])
        XCTAssertEqual(script.steps[0].params, ["selector": sendSelector, "altSelector": sendAltSelector, "button": "right"])
        XCTAssertEqual(script.steps[1].params, ["selector": ["window": "Alcove Fixture", "role": "Edit", "name": "Message"], "text": "hi", "clear": true])
        XCTAssertEqual(script.steps[2].params, ["selector": given, "action": "invoke"])
        XCTAssertEqual(script.steps[3].params, ["x": 40, "y": 50, "count": 2])
        XCTAssertEqual(script.steps[4].params, ["x": 190, "y": 112])
        XCTAssertEqual(script.steps[5].params, ["selector": sendSelector, "altSelector": sendAltSelector, "action": "invoke"])
        XCTAssertEqual(script.steps.map(\.label), ["vm.ui.click Button \"Send\"", "vm.ui.type Edit \"Message\"", "vm.ui.action invoke \"Sen\"",
                                                   "vm.mouse.click (40, 50)", "vm.mouse.click (190, 112)", "vm.ui.action invoke Button \"Send\""])
        XCTAssertEqual(draft.warnings, [
            "seq 5 (vm.ui.action) is left out: its element was named by ref and the trace holds no selector that finds it again; add the step by hand with a selector",
            "seq 6 (vm.ui.type) is left out: its element was named by ref and the trace holds no selector that finds it again; add the step by hand with a selector",
            "step 1 (vm.ui.click Button \"Send\") selects number 3 of 3 elements that look the same; it replays whatever is at that position",
            "step 6 (vm.ui.action invoke Button \"Send\") selects number 3 of 3 elements that look the same; it replays whatever is at that position",
        ])
        XCTAssertFalse(String(decoding: try script.encoded(), as: UTF8.self).contains("\"ref\""))
        XCTAssertNoThrow(try script.validate())
    }

    func testARefStepSelectsTheElementAsItWasBeforeTheAction() throws {
        let script = build([
            entry(1, "vm.ui.action", ["ref": "e8", "action": "invoke"], result: ["node": node("e8", "Button", "Unmute", aid: "mute")],
                  ["target": target("Player", "Button", "Mute", id: "mute", byID: (1, 0), byName: (1, 0))]),
            entry(2, "vm.ui.action", ["ref": "e9", "action": "toggle"], result: ["node": node("e9", "CheckBox", "Shown")],
                  ["target": target("Player", "CheckBox", "Hidden", byName: (1, 0))]),
        ])
        XCTAssertEqual(script.steps.map(\.params), [
            ["selector": ["window": "Player", "role": "Button", "automationId": "mute"],
             "altSelector": ["window": "Player", "role": "Button", "name": "Mute"], "action": "invoke"],
            ["selector": ["window": "Player", "role": "CheckBox", "name": "Hidden"], "action": "toggle"],
        ])
        let text = String(decoding: try script.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("Unmute"))
        XCTAssertFalse(text.contains("Shown"))
    }

    func testConsecutiveTypesMerge() {
        let script = build([
            entry(1, "vm.type", ["text": "hel"]),
            entry(2, "vm.screenshot"),
            entry(3, "vm.type", ["text": "lo"]),
            entry(4, "vm.type", ["text": "!"], ok: false),
            entry(5, "vm.key.press", ["keys": "enter"]),
            entry(6, "vm.type", ["text": "x", "delay": 5]),
            entry(7, "vm.type", ["text": "y"]),
            entry(8, "vm.type", ["text": "z"]),
        ])
        XCTAssertEqual(ops(script), ["vm.type", "vm.key.press", "vm.type", "vm.type"])
        XCTAssertEqual(script.steps.map(\.params), [["text": "hello"], ["keys": "enter"], ["text": "x", "delay": 5], ["text": "yz"]])
        XCTAssertEqual(script.steps.map(\.label), ["vm.type \"hello\"", "vm.key.press enter", "vm.type \"x\"", "vm.type \"yz\""])
    }

    func testSavedTextIsEscaped() throws {
        let script = build([
            entry(1, "vm.type", ["text": "cost ${amount}"]),
            entry(2, "vm.type", ["text": "$"]),
            entry(3, "vm.type", ["text": "{x}"]),
            entry(4, "vm.exec", ["command": "echo ${HOME}", "argv": ["${a}", 3]]),
            entry(5, "vm.mouse.click", ["x": 1, "y": 2], ["target": target("${w}", "Button", "${n}", id: "${i}", byID: (1, 0), byName: (1, 0))]),
        ])
        XCTAssertEqual(script.steps[0].params, ["text": "cost $${amount}$${x}"])
        XCTAssertEqual(script.steps[1].params, ["command": "echo $${HOME}", "argv": ["$${a}", 3]])
        XCTAssertEqual(script.steps[2].params["selector"], ["window": "$${w}", "role": "Button", "automationId": "$${i}"])
        XCTAssertEqual(script.steps[2].params["altSelector"], ["window": "$${w}", "role": "Button", "name": "$${n}"])
        let replayed = try Script.parse(try script.encoded()).resolved(with: [:])
        XCTAssertEqual(replayed.steps[0].params, ["text": "cost ${amount}${x}"])
        XCTAssertEqual(replayed.steps[1].params, ["command": "echo ${HOME}", "argv": ["${a}", 3]])
        XCTAssertEqual(replayed.steps[2].params["selector"], ["window": "${w}", "role": "Button", "automationId": "${i}"])
        XCTAssertEqual(replayed.steps[2].params["altSelector"], ["window": "${w}", "role": "Button", "name": "${n}"])
    }

    func testForegroundChangeAddsExpectation() throws {
        func shows(_ title: String) -> JSON { ["observation": ["settled": true, "foreground": .string(title)]] }
        let script = build([
            entry(1, "vm.mouse.click", ["x": 1, "y": 2, "observe": "summary"], result: shows("Notepad")),
            entry(2, "vm.type", ["text": "a", "observe": "summary"], result: shows("Notepad")),
            entry(3, "vm.key.press", ["keys": "ctrl+s"], result: [:]),
            entry(4, "vm.key.press", ["keys": "ctrl+s", "observe": "summary"], result: shows("Save ${as}")),
            entry(5, "vm.screenshot", result: ["png": "<image omitted>"]),
            entry(6, "vm.type", ["text": "b", "observe": "summary"], result: shows("Save ${as}")),
            entry(7, "vm.type", ["text": "c", "observe": "summary"], result: shows("Notepad")),
            entry(8, "vm.type", ["text": "d", "observe": "summary"], result: shows("Notepad")),
            entry(9, "vm.key.press", ["keys": "a", "observe": "summary"], result: ["observation": ["settled": true, "foreground": ""]]),
        ])
        let notepad: JSON = ["type": "window_title", "contains": "Notepad"]
        XCTAssertEqual(ops(script), ["vm.mouse.click", "vm.type", "vm.key.press", "vm.key.press", "vm.type", "vm.type", "vm.key.press"])
        XCTAssertEqual(script.steps.map(\.expect), [[], [], [], [["type": "window_title", "contains": "Save $${as}"]], [notepad], [], []])
        XCTAssertEqual(script.steps.map { $0.params["text"] }, [nil, "a", nil, nil, "bc", "d", nil])
        XCTAssertNoThrow(try script.validateConditions())
        XCTAssertEqual(try script.resolved(with: [:]).steps[3].expect, [["type": "window_title", "contains": "Save ${as}"]])

        let ranged = build([
            entry(1, "vm.type", ["text": "a", "observe": "summary"], result: shows("Notepad")),
            entry(2, "vm.type", ["text": "b", "observe": "summary"], result: shows("Save As")),
        ], from: 2)
        XCTAssertEqual(ranged.steps.map(\.expect), [[["type": "window_title", "contains": "Save As"]]])
    }

    func testRangeSelection() {
        let trace = (1...5).map { entry($0, "vm.key.press", ["keys": .string("f\($0)")]) }
        func keys(from: Int?, to: Int?) -> [JSON?] { build(trace, from: from, to: to).steps.map { $0.params["keys"] } }
        XCTAssertEqual(keys(from: nil, to: nil), ["f1", "f2", "f3", "f4", "f5"])
        XCTAssertEqual(keys(from: 2, to: 3), ["f2", "f3"])
        XCTAssertEqual(keys(from: 4, to: nil), ["f4", "f5"])
        XCTAssertEqual(keys(from: nil, to: 2), ["f1", "f2"])
        XCTAssertEqual(keys(from: 3, to: 3), ["f3"])
        XCTAssertEqual(keys(from: 6, to: 9), [])
    }

    func testRunnerCallsInATraceNeverBecomeSteps() {
        let exists: JSON = ["type": "file_exists", "path": "C:\\a"]
        let script = build([
            entry(1, "vm.lease.acquire", ["owner": "script:flow.json", "ttl": 600], result: ["expiresIn": 600], ["script": "lease"]),
            entry(2, "vm.snapshot.restore", ["snapshot": "clean"], ["script": "snapshot"]),
            entry(3, "vm.exec", ["command": "one"], result: ["code": 0], ["script": "step"]),
            entry(4, "vm.wait_for", ["conditions": [exists], "timeout": 9.5], result: ["matched": 0], ["script": "expect"]),
            entry(5, "vm.wait_for", ["conditions": [exists]], result: ["matched": 0], ["script": "step"]),
            entry(6, "vm.screenshot", result: ["png": "<image omitted>"], ["script": "failure"]),
            entry(7, "vm.lease.release", ["script": "lease"]),
            entry(8, "vm.snapshot.restore", ["snapshot": "clean"]),
            entry(9, "vm.key.press", ["keys": "a"], ["script": "anything else"]),
        ])
        XCTAssertEqual(ops(script), ["vm.exec", "vm.wait_for", "vm.snapshot.restore"])
        XCTAssertEqual(script.steps.map(\.params), [["command": "one"], ["conditions": [exists]], ["snapshot": "clean"]])
    }

    func testPasswordTextBecomesAVariable() async throws {
        let secret = target("Sign in", "Edit", "", id: "pw", byID: (1, 0), password: true)
        let user = target("Sign in", "Edit", "User", byName: (1, 0))
        let secretNode = node("e7", "Edit", "", aid: "pw", flags: ["password"])
        let byID: JSON = ["window": "Sign in", "role": "Edit", "automationId": "pw"]
        let draft = ScriptBuilder.draft(trace: [
            entry(1, "vm.key.press", ["keys": "tab"]),
            entry(2, "vm.type", ["text": "<masked>"], ["target": secret]),
            entry(3, "vm.type", ["text": "<masked>"], ["target": secret]),
            entry(4, "vm.ui.type", ["ref": "e7", "text": "<masked>", "clear": true], result: ["node": secretNode], ["target": secret]),
            entry(5, "vm.ui.action", ["ref": "e7", "action": "set_value", "value": "<masked>"], result: ["node": secretNode], ["target": secret]),
            entry(6, "vm.ui.type", ["selector": byID, "text": "<masked>"], result: ["node": secretNode]),
            entry(7, "vm.ui.action", ["selector": byID, "action": "set_value", "value": "<masked>"], result: ["node": secretNode]),
            entry(8, "vm.type", ["text": "<masked>"], ["target": user]),
            entry(9, "vm.type", ["text": "ada"], ["target": user]),
            entry(10, "vm.mouse.click", ["x": 190, "y": 112], ["target": secret]),
            entry(11, "vm.type", ["text": "typed-unseen"]),
            entry(12, "vm.type", ["text": "typed-seen"], ["target": secret]),
            entry(13, "vm.mouse.click", ["x": 190, "y": 112], ["target": user]),
            entry(14, "vm.type", ["text": "bob"]),
            entry(15, "vm.exec", ["command": "x", "env": ["password": "<masked>", "DB_PASSWORD": "<masked>"]], result: ["code": 0]),
            entry(16, "vm.ui.click", ["selector": byID], result: ["x": 190, "y": 112, "node": secretNode]),
            entry(17, "vm.type", ["text": "after-selector"]),
        ], vm: "Win", from: nil, to: nil)
        let script = draft.script
        XCTAssertEqual(script.steps.map(\.params), [
            ["keys": "tab"],
            ["text": "${password}"],
            ["text": "${password2}"],
            ["selector": byID, "text": "${password3}", "clear": true],
            ["selector": byID, "action": "set_value", "value": "${password4}"],
            ["selector": byID, "text": "${password5}"],
            ["selector": byID, "action": "set_value", "value": "${password6}"],
            ["text": "${password7}"],
            ["text": "ada"],
            ["selector": byID, "fallback": ["x": 190, "y": 112]],
            ["text": "${password8}"],
            ["text": "${password9}"],
            ["selector": ["window": "Sign in", "role": "Edit", "name": "User"], "fallback": ["x": 190, "y": 112]],
            ["text": "bob"],
            ["command": "x", "env": ["password": "${password10}", "DB_PASSWORD": "${DB_PASSWORD}"]],
            ["selector": byID],
            ["text": "${password11}"],
        ])
        XCTAssertEqual(script.steps.map(\.label), [
            "vm.key.press tab", "vm.type into a password field", "vm.type into a password field", "vm.ui.type Edit #pw",
            "vm.ui.action set_value Edit #pw", "vm.ui.type Edit #pw", "vm.ui.action set_value Edit #pw", "vm.type into a password field", "vm.type \"ada\"", "vm.ui.click Edit #pw",
            "vm.type into a password field", "vm.type into a password field", "vm.ui.click Edit \"User\"", "vm.type \"bob\"", "vm.exec x",
            "vm.ui.click Edit #pw", "vm.type into a password field",
        ])
        XCTAssertEqual(script.variables, [:])
        XCTAssertEqual(draft.required, ["password", "password2", "password3", "password4", "password5", "password6", "password7", "password8",
                                        "password9", "DB_PASSWORD", "password10", "password11"])
        func reads(_ line: String, _ param: String, _ variable: String) -> String {
            "\(line): its \(param) goes into a password field and is not written to the script; the step reads it from the variable '\(variable)', "
                + "pass it in variables when running the script"
        }
        XCTAssertEqual(draft.warnings, [
            reads("seq 2 (vm.type)", "text", "password"), reads("seq 3 (vm.type)", "text", "password2"),
            reads("seq 4 (vm.ui.type)", "text", "password3"), reads("seq 5 (vm.ui.action)", "value", "password4"),
            reads("seq 6 (vm.ui.type)", "text", "password5"), reads("seq 7 (vm.ui.action)", "value", "password6"),
            "step 8 (vm.type) typed text that the recording masked; it is the variable ${password7} and must be passed",
            reads("seq 11 (vm.type)", "text", "password8"), reads("seq 12 (vm.type)", "text", "password9"),
            "seq 15 (vm.exec): the trace masks the env value 'DB_PASSWORD'; the step reads it from the variable 'DB_PASSWORD', pass it in variables when running the script",
            "seq 15 (vm.exec): the trace masks the env value 'password'; the step reads it from the variable 'password10', pass it in variables when running the script",
            reads("seq 17 (vm.type)", "text", "password11"),
        ])
        let text = String(decoding: try script.encoded(), as: UTF8.self)
        for hidden in ["typed-unseen", "typed-seen", "after-selector"] { XCTAssertFalse(text.contains(hidden), hidden) }
        XCTAssertThrowsError(try script.resolved(with: [:])) {
            XCTAssertEqual("\($0)", "variable 'password' is not defined; pass it or add a default")
        }
        XCTAssertNoThrow(try script.resolved(with: Dictionary(uniqueKeysWithValues: draft.required.map { ($0, "x") })))

        let h = handler()
        let run = await ScriptRunner(handler: h).run(script, vm: nil, variables: [:], progress: nil)
        XCTAssertEqual(run.stepsRun, 0)
        XCTAssertEqual(run.error, "variable 'password' is not defined; pass it or add a default")
    }

    func testMaskedEnvValuesBecomeVariables() throws {
        let draft = ScriptBuilder.draft(trace: [
            entry(1, "vm.exec", ["command": "deploy", "env": ["API_TOKEN": "<masked>", "REGION": "eu", "MY_KEY": "<masked>"]], result: ["code": 0]),
            entry(2, "vm.exec", ["command": "again", "env": ["MY_KEY": "<masked>"]], result: ["code": 0]),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(draft.script.steps[0].params, ["command": "deploy", "env": ["API_TOKEN": "${API_TOKEN}", "REGION": "eu", "MY_KEY": "${MY_KEY}"]])
        XCTAssertEqual(draft.script.steps[1].params, ["command": "again", "env": ["MY_KEY": "${MY_KEY}"]])
        XCTAssertEqual(draft.required, ["API_TOKEN", "MY_KEY"])
        XCTAssertEqual(draft.warnings, [
            "seq 1 (vm.exec): the trace masks the env value 'API_TOKEN'; the step reads it from the variable 'API_TOKEN', pass it in variables when running the script",
            "seq 1 (vm.exec): the trace masks the env value 'MY_KEY'; the step reads it from the variable 'MY_KEY', pass it in variables when running the script",
            "seq 2 (vm.exec): the trace masks the env value 'MY_KEY'; the step reads it from the variable 'MY_KEY', pass it in variables when running the script",
        ])
        XCTAssertThrowsError(try draft.script.resolved(with: ["MY_KEY": "k"])) {
            XCTAssertEqual("\($0)", "variable 'API_TOKEN' is not defined; pass it or add a default")
        }
        XCTAssertNoThrow(try draft.script.resolved(with: ["API_TOKEN": "t", "MY_KEY": "k"]))
    }

    func testAStepWithCutParamsIsLeftOut() throws {
        let cut = String(repeating: "a", count: 2000) + "…"
        let draft = ScriptBuilder.draft(trace: [
            entry(1, "vm.type", ["text": "a"]),
            entry(2, "vm.type", ["text": .string(cut), "textTruncated": true]),
            entry(3, "vm.type", ["text": "b"]),
            entry(4, "vm.exec", ["argv": ["cmd", .string(cut)]], result: ["code": 0]),
            entry(5, "vm.ui.type", ["selector": ["name": .string(cut), "nameTruncated": true], "text": "c"], result: ["node": sendButton]),
            entry(6, "vm.exec", ["command": "x", "env": ["NOTE": .string(cut), "NOTETruncated": true]], result: ["code": 0]),
            entry(7, "vm.exec", ["command": .string(cut), "commandTruncated": false, "outputTruncated": true], result: ["code": 0]),
            entry(8, "vm.key.press", ["keys": "enter"]),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(ops(draft.script), ["vm.type", "vm.type", "vm.exec", "vm.key.press"])
        XCTAssertEqual(draft.script.steps.map(\.params), [["text": "a"], ["text": "b"], ["command": .string(cut), "commandTruncated": false, "outputTruncated": true],
                                                          ["keys": "enter"]])
        XCTAssertEqual(draft.sources, [1, 3, 7, 8])
        func left(_ line: String, _ param: String) -> String {
            "\(line) is left out: the trace holds only the first 2000 characters of '\(param)'; add the step by hand with the full value"
        }
        XCTAssertEqual(draft.warnings, [left("seq 2 (vm.type)", "text"), left("seq 4 (vm.exec)", "argv"), left("seq 5 (vm.ui.type)", "selector.name"),
                                        left("seq 6 (vm.exec)", "env.NOTE")])
    }

    func testABatchWithARefIsLeftOut() throws {
        let draft = ScriptBuilder.draft(trace: [
            entry(1, "vm.batch", ["steps": [["op": "vm.key.press", "keys": "a"],
                                            ["op": "vm.wait_for", "conditions": [["type": "ui_exists", "ref": "e5"]]]]],
                  result: ["completed": 2, "results": [[:], [:]]]),
            entry(2, "vm.batch", ["steps": [["op": "vm.key.press", "keys": "b"]]], result: ["completed": 1, "results": [[:]]]),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(draft.script.steps.map(\.params), [["steps": [["op": "vm.key.press", "keys": "b"]]]])
        XCTAssertEqual(draft.warnings, ["seq 1 (vm.batch) is left out: one of its steps names an element by ref; add the steps by hand with selector fields"])
        XCTAssertFalse(String(decoding: try draft.script.encoded(), as: UTF8.self).contains("\"ref\""))
    }

    func testTypesAreNotMergedAcrossALeftOutStep() {
        let draft = ScriptBuilder.draft(trace: [
            entry(1, "vm.type", ["text": "a"]),
            entry(2, "vm.wait_for", ["conditions": [["type": "ui_exists", "ref": "e5"]]], result: ["matched": 0]),
            entry(3, "vm.type", ["text": "b"]),
            entry(4, "vm.type", ["text": "c"]),
            entry(5, "vm.ui.type", ["ref": "e9", "text": "x"], result: ["node": node("e9", "Pane", "")]),
            entry(6, "vm.screenshot"),
            entry(7, "vm.type", ["text": "d"]),
            entry(8, "vm.window.action", ["window": "0x3b", "action": "close"], result: ["window": .null, "closed": true]),
            entry(9, "vm.type", ["text": "e"]),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(draft.script.steps.map { $0.params["text"] }, ["a", "bc", "d", "e"])
        XCTAssertEqual(draft.warnings.count, 3)
    }

    func testEventConditionsLoseTheirSinceCursor() throws {
        let script = build([
            entry(1, "vm.wait_for", ["conditions": [["type": "event", "event": "window.opened", "since": 40], ["type": "screen_idle"]], "timeout": 5],
                  result: ["matched": 0]),
            entry(2, "vm.batch", ["steps": [["op": "vm.wait_for", "conditions": [["type": "event", "event": "window.closed", "since": 41, "titleContains": "Save"]]],
                                            ["op": "vm.key.press", "keys": "a"]]],
                  result: ["completed": 2, "results": [[:], [:]]]),
        ])
        XCTAssertEqual(script.steps.map(\.params), [
            ["conditions": [["type": "event", "event": "window.opened"], ["type": "screen_idle"]], "timeout": 5],
            ["steps": [["op": "vm.wait_for", "conditions": [["type": "event", "event": "window.closed", "titleContains": "Save"]]],
                       ["op": "vm.key.press", "keys": "a"]]],
        ])
        XCTAssertFalse(String(decoding: try script.encoded(), as: UTF8.self).contains("since"))
        XCTAssertNoThrow(try script.validateConditions())
    }

    func testWindowTitlesAreNamedByTheirStablePart() {
        let parts: [(String, String)] = [
            ("report-final.docx - Word", "Word"),
            ("Inbox (3) - Outlook", "Outlook"),
            ("*Untitled - Notepad", "Notepad"),
            ("a - b – c — Visual Studio", "Visual Studio"),
            ("x — y - Paint", "Paint"),
            ("x - y – Paint", "Paint"),
            ("Notes - abc", "abc"),
            ("Notes – ab", "Notes – ab"),
            ("Ends with - ", "Ends with - "),
            ("Alcove Fixture", "Alcove Fixture"),
            ("well-known", "well-known"),
            ("", ""),
        ]
        for (title, expected) in parts { XCTAssertEqual(ScriptBuilder.stablePart(ofTitle: title), expected, title) }

        func shows(_ title: String) -> JSON { ["observation": ["settled": true, "foreground": .string(title)]] }
        let script = build([
            entry(1, "vm.key.press", ["keys": "a", "observe": "summary"], result: shows("Untitled - Notepad")),
            entry(2, "vm.key.press", ["keys": "b", "observe": "summary"], result: shows("*Untitled - Notepad")),
            entry(3, "vm.key.press", ["keys": "c", "observe": "summary"], result: shows("Save As")),
            entry(4, "vm.key.press", ["keys": "d", "observe": "summary"], result: shows("report-final.docx - Word")),
            entry(5, "vm.key.press", ["keys": "e", "observe": "summary"], result: shows("other.docx - Word")),
        ])
        XCTAssertEqual(script.steps.map(\.expect), [[], [], [["type": "window_title", "contains": "Save As"]], [["type": "window_title", "contains": "report-final.docx - Word"]], []])
    }

    func testAStablePartNamesAWindowOnlyWhenNoOtherTitleHasIt() {
        func click(_ seq: Int, _ title: String) -> JSON {
            entry(seq, "vm.mouse.click", ["x": 190, "y": 112], ["target": target(title, "Button", "Close", byName: (1, 0))])
        }
        func windows(_ draft: ScriptBuilder.Draft) -> [String?] { draft.script.steps.map { $0.params["selector"]?["window"]?.stringValue } }
        func part(_ title: String) -> String {
            "steps name the window \"\(ScriptBuilder.stablePart(ofTitle: title))\" by a part of its title \"\(title)\"; another window whose title contains \"\(ScriptBuilder.stablePart(ofTitle: title))\" would be used instead"
        }
        func shows(_ title: String) -> JSON { ["observation": ["settled": true, "foreground": .string(title)]] }

        let alone = ScriptBuilder.draft(trace: [click(1, "Untitled - Notepad"), click(2, "Untitled - Notepad")], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(windows(alone), ["Notepad", "Notepad"])
        XCTAssertEqual(alone.warnings.filter { $0.hasPrefix("steps name the window") }, [part("Untitled - Notepad")])

        let plus = ScriptBuilder.draft(trace: [click(1, "Untitled - Notepad"), click(2, "x.txt - Notepad++")], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(windows(plus), ["Untitled - Notepad", "Notepad++"])
        XCTAssertEqual(plus.warnings.filter { $0.hasPrefix("steps name the window") }, [part("x.txt - Notepad++")])

        let docs = ScriptBuilder.draft(trace: [click(1, "a.docx - Word"), click(2, "b.docx - Word")], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(windows(docs), ["a.docx - Word", "b.docx - Word"])

        let caseless = ScriptBuilder.draft(trace: [click(1, "Inbox - Mail"), click(2, "gmail - Google Chrome")], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(windows(caseless), ["Inbox - Mail", "Google Chrome"])

        let listed = ScriptBuilder.draft(trace: [
            entry(1, "vm.window.list", result: ["windows": [["id": "0x1", "title": "Untitled - Notepad"], ["id": "0x2", "title": "x.txt - Notepad++"]]]),
            click(2, "Untitled - Notepad"),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(windows(listed), ["Untitled - Notepad"])

        let launched = ScriptBuilder.draft(trace: [
            entry(1, "vm.app.launch", ["path": "C:\\x.exe"], result: ["window": ["id": "0x3", "title": "x.txt - Notepad++"]]),
            entry(2, "vm.deploy", ["path": "C:\\x.exe"], result: ["window": ["id": "0x3", "title": "x.txt - Notepad++"]]),
            click(3, "Untitled - Notepad"),
        ], vm: "Win", from: 3, to: nil)
        XCTAssertEqual(windows(launched), ["Untitled - Notepad"])
        let inRange = ScriptBuilder.draft(trace: [
            entry(1, "vm.app.launch", ["path": "C:\\x.exe"], result: ["window": ["id": "0x3", "title": "x.txt - Notepad++"]]),
            click(2, "Untitled - Notepad"),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(windows(inRange), [nil, "Untitled - Notepad"])

        let foreground = ScriptBuilder.draft(trace: [
            entry(1, "vm.key.press", ["keys": "a", "observe": "summary"], result: shows("x.txt - Notepad++")),
            click(2, "Untitled - Notepad"),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(windows(foreground), [nil, "Untitled - Notepad"])

        let expectations = ScriptBuilder.draft(trace: [
            entry(1, "vm.key.press", ["keys": "a", "observe": "summary"], result: shows("Untitled - Notepad")),
            entry(2, "vm.key.press", ["keys": "b", "observe": "summary"], result: shows("Save As")),
            entry(3, "vm.key.press", ["keys": "c", "observe": "summary"], result: shows("x.txt - Notepad++")),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(expectations.script.steps.map(\.expect), [[], [["type": "window_title", "contains": "Save As"]],
                                                                  [["type": "window_title", "contains": "Notepad++"]]])

        let actions = ScriptBuilder.draft(trace: [
            entry(1, "vm.window.action", ["window": "0x2a", "action": "close"], result: ["window": ["id": "0x2a", "title": "Untitled - Notepad"]]),
            entry(2, "vm.window.action", ["window": "0x2b", "action": "close"], result: ["window": ["id": "0x2b", "title": "report.docx - Word"]]),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(actions.script.steps.map { $0.params["window"] }, ["Notepad", "Word"])
        let confusing = ScriptBuilder.draft(trace: [
            entry(1, "vm.window.action", ["window": "0x2a", "action": "close"], result: ["window": ["id": "0x2a", "title": "Untitled - Notepad"]]),
            click(2, "x.txt - Notepad++"),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(confusing.script.steps.map { $0.params["window"] ?? $0.params["selector"]?["window"] }, ["Untitled - Notepad", "Notepad++"])

        let altogether = ScriptBuilder.draft(trace: [
            entry(1, "vm.mouse.click", ["x": 190, "y": 112], ["target": sendTarget]),
            entry(2, "vm.mouse.click", ["x": 190, "y": 112], ["target": target("report.docx - Word", "Button", "Send", id: "send", byID: (1, 0), byName: (1, 0))]),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(altogether.script.steps[1].params["altSelector"]?["window"], "Word")
        XCTAssertEqual(altogether.warnings.filter { $0.hasPrefix("steps name the window") }, [part("report.docx - Word")])
    }

    func testWindowTitlesComeFromEventsAndInspectionsAndTheWholeTrace() {
        func click(_ seq: Int, _ title: String) -> JSON {
            entry(seq, "vm.mouse.click", ["x": 190, "y": 112], ["target": target(title, "Button", "Close", byName: (1, 0))])
        }
        func window(_ draft: ScriptBuilder.Draft) -> String? { draft.script.steps.last?.params["selector"]?["window"]?.stringValue }
        func shows(_ events: [String]) -> JSON { ["observation": ["settled": true, "events": .array(events.map(JSON.string))]] }

        let events: [(String, String)] = [
            ("window.opened", "x.txt - Notepad++"), ("window.created", "x.txt - Notepad++"), ("window.title", "x.txt - Notepad++"),
            ("window.foreground", "x.txt - Notepad++"), ("window.closed", "x.txt - Notepad++"), ("dialog.opened", "x.txt - Notepad++"),
        ]
        for (name, title) in events {
            let draft = ScriptBuilder.draft(trace: [entry(1, "vm.key.press", ["keys": "a", "observe": "summary"], result: shows(["\(name) \"\(title)\""])),
                                                    click(2, "Untitled - Notepad")], vm: "Win", from: nil, to: nil)
            XCTAssertEqual(window(draft), "Untitled - Notepad", name)
        }
        let quoted = ScriptBuilder.draft(trace: [
            entry(1, "vm.key.press", ["keys": "a", "observe": "summary"], result: shows(["window.opened \"say \\\"hi\\\" - Notepad++\"", "window.foreground notepad.exe"])),
            click(2, "say \"hi\" - Notepad++"), click(3, "Untitled - Notepad"),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(quoted.script.steps.map { $0.params["selector"]?["window"]?.stringValue }, [nil, "Notepad++", "Untitled - Notepad"])
        XCTAssertEqual(ScriptBuilder.windowTitle(ofEvent: "window.opened \"a\\u{9}b\\n\""), "a\tb\n")
        XCTAssertNil(ScriptBuilder.windowTitle(ofEvent: "window.opened notepad.exe"))
        XCTAssertNil(ScriptBuilder.windowTitle(ofEvent: "process.exited \"x\""))

        for op in ["vm.ui.tree", "vm.ui.find", "vm.ui.text", "vm.ui.click", "vm.ui.type", "vm.ui.action"] {
            let draft = ScriptBuilder.draft(trace: [
                entry(1, op, ["selector": ["name": "Close"]], result: ["window": ["id": "0x9", "title": "x.txt - Notepad++"]]),
                click(2, "Untitled - Notepad"),
            ], vm: "Win", from: nil, to: nil)
            XCTAssertEqual(window(draft), "Untitled - Notepad", op)
        }

        let outside = ScriptBuilder.draft(trace: [
            entry(1, "vm.app.launch", ["path": "C:\\x.exe"], result: ["window": ["id": "0x3", "title": "x.txt - Notepad++"]]),
            click(2, "Untitled - Notepad"),
            entry(3, "vm.window.list", result: ["windows": [["id": "0x4", "title": "y.txt - Notepad++"]]]),
        ], vm: "Win", from: 2, to: 2)
        XCTAssertEqual(outside.script.steps.map { $0.params["selector"]?["window"]?.stringValue }, ["Untitled - Notepad"])
    }

    func testTwoWindowsWithOneTitleAreReportedAndOneWindowWithSuccessiveTitlesIsNot() {
        func click(_ seq: Int, _ title: String) -> JSON {
            entry(seq, "vm.mouse.click", ["x": 190, "y": 112], ["target": target(title, "Button", "Close", byName: (1, 0))])
        }
        func list(_ seq: Int, _ windows: [(String, String)]) -> JSON {
            entry(seq, "vm.window.list", result: ["windows": .array(windows.map { ["id": .string($0.0), "title": .string($0.1)] })])
        }
        let shared = "steps name the window \"a.docx - Word\"; more than one window had that title while recording, the first one found is used"

        let two = ScriptBuilder.draft(trace: [list(1, [("0x1", "a.docx - Word"), ("0x2", "a.docx - Word")]), click(2, "a.docx - Word"), click(3, "a.docx - Word")],
                                      vm: "Win", from: nil, to: nil)
        XCTAssertEqual(two.script.steps.map { $0.params["selector"]?["window"]?.stringValue }, ["Word", "Word"])
        XCTAssertEqual(two.warnings.filter { $0.contains("more than one window") }, [shared])

        let one = ScriptBuilder.draft(trace: [list(1, [("0x1", "a.docx - Word")]), list(2, [("0x1", "a.docx - Word")]), click(3, "a.docx - Word")],
                                      vm: "Win", from: nil, to: nil)
        XCTAssertEqual(one.script.steps.map { $0.params["selector"]?["window"]?.stringValue }, ["Word"])
        XCTAssertFalse(one.warnings.contains { $0.contains("more than one window") })

        let renamed = ScriptBuilder.draft(trace: [
            list(1, [("0x1", "Untitled - Notepad")]), list(2, [("0x1", "*Untitled - Notepad")]), list(3, [("0x1", "x.txt - Notepad")]),
            click(4, "x.txt - Notepad"),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(renamed.script.steps.map { $0.params["selector"]?["window"]?.stringValue }, ["Notepad"])
        XCTAssertFalse(renamed.warnings.contains { $0.contains("more than one window") })

        let withoutIDs = ScriptBuilder.draft(trace: [
            entry(1, "vm.key.press", ["keys": "a", "observe": "summary"], result: ["observation": ["settled": true, "foreground": "*Untitled - Notepad"]]),
            click(2, "Untitled - Notepad"),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(withoutIDs.script.steps.map { $0.params["selector"]?["window"]?.stringValue }, [nil, "Untitled - Notepad"])

        let other = ScriptBuilder.draft(trace: [list(1, [("0x1", "Untitled - Notepad"), ("0x2", "x.txt - Notepad++")]), click(2, "Untitled - Notepad")],
                                        vm: "Win", from: nil, to: nil)
        XCTAssertEqual(other.script.steps.map { $0.params["selector"]?["window"]?.stringValue }, ["Untitled - Notepad"])
    }

    func testDroppedKeyStepsGiveOneWarningPerRun() {
        func key(_ seq: Int) -> JSON { entry(seq, "vm.key.press", ["keys": "<masked>"]) }
        let draft = ScriptBuilder.draft(trace: [
            key(1), entry(2, "vm.batch", ["steps": [["op": "vm.ui.click", "ref": "e1"]]]), key(3),
            entry(4, "vm.key.press", ["keys": "enter"]), key(5),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(draft.warnings.filter { $0.contains("pressed keys") }, [
            "step 1 pressed keys in a password field; type the password with vm.type and a variable instead",
            "step 2 pressed keys in a password field; type the password with vm.type and a variable instead",
        ])
    }

    func testAStepWithAnIndexSaysItIsPositional() {
        let draft = ScriptBuilder.draft(trace: [
            entry(1, "vm.key.press", ["keys": "a"]),
            entry(2, "vm.mouse.click", ["x": 190, "y": 112], ["target": target("Orders", "Button", "Delete", byName: (4, 0))]),
            entry(3, "vm.mouse.click", ["x": 190, "y": 112], ["target": target("Orders", "Button", "Delete", byName: (1, 0))]),
            entry(4, "vm.mouse.click", ["x": 190, "y": 112], ["target": target("Orders", "Button", "Delete", id: "del", byID: (1, 0), byName: (3, 1))]),
            entry(5, "vm.mouse.click", ["x": 190, "y": 112], ["target": target("Orders", "Button", "Delete", id: "del", byID: (2, 1), byName: (3, 1))]),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(draft.warnings, [
            "step 2 (vm.ui.click Button \"Delete\") selects number 1 of 4 elements that look the same; it replays whatever is at that position",
            "step 4 (vm.ui.click Button \"Delete\") selects number 2 of 3 elements that look the same; it replays whatever is at that position",
            "step 5 (vm.ui.click Button \"Delete\") selects number 2 of 2 elements that look the same; it replays whatever is at that position",
        ])
    }

    func testWindowIdsAndRefsOfWaitsDoNotReachTheScript() throws {
        let draft = ScriptBuilder.draft(trace: [
            entry(1, "vm.window.action", ["window": "0x2A", "action": "maximize"], result: ["window": fixtureWindow]),
            entry(2, "vm.window.action", ["window": "Fixture", "action": "focus"], result: ["window": fixtureWindow]),
            entry(3, "vm.window.action", ["window": "0x3b", "action": "close"], result: ["window": .null, "closed": true]),
            entry(4, "vm.wait_for", ["conditions": [["type": "ui_exists", "ref": "e5"]]], result: ["matched": 0]),
            entry(5, "vm.ui.click", ["selector": ["window": "0x2a", "role": "Button", "name": "Send"]], result: ["x": 1, "y": 2, "node": sendButton]),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(draft.script.steps.map(\.params), [["window": "Alcove Fixture", "action": "maximize"], ["window": "Fixture", "action": "focus"],
                                                          ["selector": ["role": "Button", "name": "Send"]]])
        XCTAssertEqual(draft.script.steps.map(\.label), ["vm.window.action maximize \"Alcove Fixture\"", "vm.window.action focus \"Fixture\"",
                                                         "vm.ui.click Button \"Send\""])
        XCTAssertEqual(draft.warnings, [
            "seq 3 (vm.window.action) is left out: its window was named by id and the trace holds no title for it; add the step by hand with a title part",
            "seq 4 (vm.wait_for) is left out: a condition names its element by ref; add the step by hand with selector fields",
            "seq 5 (vm.ui.click): its selector named the window by id; the step looks in the foreground window, add a title part by hand",
        ])
        let text = String(decoding: try draft.script.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("0x"))
        XCTAssertFalse(text.contains("\"ref\""))
    }

    func testBatchStepsLoseTheVMName() throws {
        let script = build([
            entry(1, "vm.batch", ["steps": [["op": "vm.key.press", "keys": "a", "name": "Win"], ["op": "vm.type", "text": "${x}"], ["op": "sleep", "ms": 50]]],
                  result: ["completed": 3, "results": [[:], [:], [:]]]),
        ])
        XCTAssertEqual(script.steps.map(\.params),
                       [["steps": [["op": "vm.key.press", "keys": "a"], ["op": "vm.type", "text": "$${x}"], ["op": "sleep", "ms": 50]]]])
        XCTAssertEqual(script.steps.map(\.label), ["vm.batch"])
        XCTAssertFalse(String(decoding: try script.encoded(), as: UTF8.self).contains("\"name\""))
    }

    func testStepsThatNameAJobOrAPidAreReported() {
        let draft = ScriptBuilder.draft(trace: [
            entry(1, "vm.exec.start", ["command": "server"], result: ["job": "j3"]),
            entry(2, "vm.exec.write", ["job": "j3", "data": "quit\n"]),
            entry(3, "vm.wait_for", ["conditions": [["type": "job_output_matches", "job": "j3", "pattern": "bye"]]], result: ["matched": 0]),
            entry(4, "vm.exec.kill", ["job": "j3"]),
            entry(5, "vm.process.kill", ["pid": 4242]),
            entry(6, "vm.process.kill", ["processName": "server.exe"]),
            entry(7, "vm.wait_for", ["conditions": [["type": "process_exited", "pid": 4242]]], result: ["matched": 0]),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(ops(draft.script), ["vm.exec.start", "vm.exec.write", "vm.wait_for", "vm.exec.kill", "vm.process.kill", "vm.process.kill", "vm.wait_for"])
        let jobID = "its job id belongs to the recorded session and a replay gets another one; change the step by hand"
        let pid = "its pid belongs to the recorded session and a replay gets another one; change the step by hand"
        XCTAssertEqual(draft.warnings, ["seq 2 (vm.exec.write): \(jobID)", "seq 3 (vm.wait_for): \(jobID)", "seq 4 (vm.exec.kill): \(jobID)",
                                        "seq 5 (vm.process.kill): \(pid)", "seq 7 (vm.wait_for): \(pid)"])
    }

    func testHTTPCaptureOpsAreLeftOutWithAWarning() {
        let draft = ScriptBuilder.draft(trace: [
            entry(1, "vm.http.start", ["hosts": ["api.example.com"]], result: ["proxy": "10.0.2.2:5000"]),
            entry(2, "vm.http.rule.add", ["match": ["path": "/v1/*"], "action": ["status": 500]], result: ["rule": 1]),
            entry(3, "vm.mouse.click", ["x": 5, "y": 6]),
            entry(4, "vm.http.requests", result: ["exchanges": []]),
            entry(5, "vm.http.rule.remove", ["rule": 1]),
            entry(6, "vm.http.rule.clear"),
            entry(7, "vm.http.clear"),
            entry(8, "vm.http.stop", result: ["exchanges": 3]),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(ops(draft.script), ["vm.mouse.click"])
        let reason = "an HTTP capture and its rules belong to the setup of a run, not to its steps; start the capture and add its rules with the vm.http ops before running the script"
        XCTAssertEqual(draft.warnings, [1, 2, 5, 6, 7, 8].map { seq in
            let op = ["vm.http.start", "vm.http.rule.add", "", "", "vm.http.rule.remove", "vm.http.rule.clear", "vm.http.clear", "vm.http.stop"][seq - 1]
            return "seq \(seq) (\(op)) is left out: \(reason)"
        })
    }

    func testLabelsNeverCarryTheMaskMarker() {
        let masked = target("Sign in", "Button", "<masked>", byName: (1, 0))
        let draft = ScriptBuilder.draft(trace: [
            entry(2, "vm.mouse.click", ["x": 190, "y": 112], ["target": masked]),
            entry(3, "vm.ui.click", ["selector": ["role": "Button", "name": "<masked>"]], result: ["x": 190, "y": 112]),
        ], vm: "Win", from: nil, to: nil)
        XCTAssertEqual(draft.script.steps.map(\.label), ["vm.ui.click Button \"hidden text\"", "vm.ui.click Button \"hidden text\""])
        XCTAssertFalse(String(decoding: try! draft.script.encoded(), as: UTF8.self).contains("<masked>"))
    }

    func testMaskMarkerNeverReachesAScript() {
        let user = target("Sign in", "Edit", "User", byName: (1, 0))
        let entries: [JSON] = [
            entry(1, "vm.type", ["text": "<masked>"], ["target": user]),
            entry(2, "vm.exec", ["command": "login <masked> now"], result: ["code": 0]),
            entry(3, "vm.exec", ["command": "x", "env": ["PLAIN": "<masked>"]], result: ["code": 0]),
            entry(4, "vm.exec", ["command": "x", "args": ["<masked>"]], result: ["code": 0]),
            entry(5, "vm.batch", ["steps": [["op": "vm.type", "text": "pre <masked>"]]], result: ["steps": []]),
            entry(6, "vm.batch", ["steps": [["op": "vm.type", "text": "<masked>"]]], result: ["steps": []]),
            entry(7, "vm.wait_for", ["conditions": [["type": "file_exists", "path": "C:\\<masked>.txt"]]], result: ["matched": 0]),
            entry(8, "vm.wait_for", ["conditions": [["type": "file_contains", "path": "C:\\a.txt", "text": "<masked>"]]], result: ["matched": 0]),
        ]
        let draft = ScriptBuilder.draft(trace: entries, vm: "Win", from: nil, to: nil)
        XCTAssertEqual(ops(draft.script), ["vm.type", "vm.exec", "vm.exec", "vm.batch", "vm.wait_for"])
        XCTAssertEqual(draft.script.steps.map(\.params), [
            ["text": "${password}"],
            ["command": "x", "env": ["PLAIN": "${PLAIN}"]],
            ["command": "x", "args": ["${secret}"]],
            ["steps": [["op": "vm.type", "text": "${text}"]]],
            ["conditions": [["type": "file_contains", "path": "C:\\a.txt", "text": "${text2}"]]],
        ])
        XCTAssertEqual(draft.required, ["password", "PLAIN", "secret", "text", "text2"])
        XCTAssertEqual(draft.warnings.filter { $0.contains("holds a masked value") }, [
            "step 2 (vm.exec) holds a masked value inside \"command\"; write the step by hand with a variable",
            "step 4 (vm.batch) holds a masked value inside \"steps\"; write the step by hand with a variable",
            "step 5 (vm.wait_for) holds a masked value inside \"conditions\"; write the step by hand with a variable",
        ])
        XCTAssertFalse(String(decoding: try! draft.script.encoded(), as: UTF8.self).contains("<masked>"))
    }

    // MARK: - script.save

    func testSaveOpWritesParsableScript() async throws {
        let h = handler()
        let positional = "step 1 (vm.ui.click Button \"Send\") selects number 3 of 3 elements that look the same; it replays whatever is at that position"
        let dir = try recordingDir([
            entry(1, "vm.mouse.click", ["x": 190, "y": 112], ["target": sendTarget]),
            entry(2, "vm.type", ["text": "hello ${name}"]),
            entry(3, "vm.screenshot", result: ["png": "<image omitted>"]),
            entry(4, "vm.key.press", ["keys": "enter"]),
        ])
        let out = try tempDir().appendingPathComponent("flow.json")
        let saved = try await h.handle(op: "script.save", params: ["dir": .string(dir.path), "path": .string(out.path)])
        XCTAssertEqual(saved, ["path": .string(out.path), "steps": 3, "skipped": 0, "warnings": [.string(positional)]])
        let script = try Script.parse(try Data(contentsOf: out))
        XCTAssertEqual(script.vm, "Win")
        XCTAssertEqual(ops(script), ["vm.ui.click", "vm.type", "vm.key.press"])
        XCTAssertEqual(script.steps[0].params, ["selector": sendSelector, "altSelector": sendAltSelector, "fallback": ["x": 190, "y": 112]])
        XCTAssertEqual(script.steps[1].params, ["text": "hello $${name}"])
        XCTAssertEqual(script.steps[0].label, "vm.ui.click Button \"Send\"")
        XCTAssertNoThrow(try script.resolved(with: [:]).validateConditions())

        let ranged = try tempDir().appendingPathComponent("part.JSON")
        let trace = dir.appendingPathComponent("trace.jsonl").path
        let part = try await h.handle(op: "script.save", params: ["trace": .string(trace), "path": .string(ranged.path), "name": "Other",
                                                                  "from": 2, "to": 3])
        XCTAssertEqual(part, ["path": .string(ranged.path), "steps": 1, "skipped": 0])
        let partial = try Script.parse(try Data(contentsOf: ranged))
        XCTAssertEqual(partial.vm, "Other")
        XCTAssertEqual(ops(partial), ["vm.type"])
    }

    func testSaveRefusesAScriptThatStillHoldsTheMaskMarker() async throws {
        let h = handler()
        let dir = try recordingDir([
            entry(1, "vm.mouse.click", ["x": 190, "y": 112], ["target": target("<masked>", "Button", "Send", byName: (1, 0))]),
        ])
        let out = try tempDir().appendingPathComponent("flow.json")
        do {
            _ = try await h.handle(op: "script.save", params: ["dir": .string(dir.path), "path": .string(out.path)])
            XCTFail("saved a script with the marker")
        } catch {
            XCTAssertTrue("\(error)".hasPrefix("step 1 (vm.ui.click Button \"Send\") still holds the mask marker '<masked>' of the trace; "), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testASavedRecordingReplaysTheRecordedInput() async throws {
        let positional = "step 1 (vm.ui.click Button \"Send\") selects number 3 of 3 elements that look the same; it replays whatever is at that position"
        let answers = LockedBox<[String: Reply]>([
            "ui.at": .by { $0["focused"] == true ? .ok(at("Edit", "Message", byName: (1, 0))) : .ok(sendAt) },
            "ui.rect": .ok(["node": sendButton, "cx": 190, "cy": 112, "clickable": true]),
        ])
        let (h, t, agent) = try await rig(answers)
        let dir = try await startRecording(h)
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        _ = try await h.handle(op: "vm.type", params: ["name": "Win", "text": "hi"])
        _ = try await h.handle(op: "vm.screenshot", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "enter"])
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        let recorded = await t.sent

        let out = try tempDir().appendingPathComponent("flow.json")
        let saved = try await h.handle(op: "script.save", params: ["dir": .string(dir.path), "path": .string(out.path)])
        XCTAssertEqual(saved, ["path": .string(out.path), "steps": 3, "skipped": 0, "warnings": [.string(positional)]])
        let run = try await h.handle(op: "script.run", params: ["path": .string(out.path)])
        XCTAssertEqual(run["passed"], true, run["error"]?.stringValue ?? "")
        XCTAssertEqual(run["steps"]?.arrayValue?.map { $0["label"] }, ["vm.ui.click Button \"Send\"", "vm.type \"hi\"", "vm.key.press enter"])
        let all = await t.sent
        XCTAssertEqual(Array(all.dropFirst(recorded.count)), recorded)
        XCTAssertEqual(agentRequests(agent, "ui.rect").map(fields), [["window": "Alcove Fixture", "role": "Button", "automationId": "send", "scroll": true]])
        XCTAssertEqual(run["steps"]?[0]?["usedAltSelector"], nil)
        XCTAssertEqual(run["steps"]?[0]?["usedFallback"], nil)
        XCTAssertEqual(agentRequests(agent, "ui.at").map(fields), [["x": 190, "y": 112, "budgetMs": 200], ["focused": true, "budgetMs": 200]])
    }

    func testSaveSkipsLinesThatAreNotTraceLines() async throws {
        let h = handler()
        let dir = try recordingDir([
            entry(1, "vm.key.press", ["keys": "a"]),
            "not json at all",
            "[1, 2]",
            "{\"seq\": \"3\", \"op\": \"vm.key.press\"}",
            entry(4, "vm.exec", ["command": "x", "env": ["TOKEN": "<masked>"]], result: ["code": 0]),
            "{\"seq\":5,\"time\":\"2026-10-14T09:00:00.000Z\",\"ms\":500,\"op\":\"vm.key.pr",
        ])
        let out = try tempDir().appendingPathComponent("flow.json")
        let saved = try await h.handle(op: "script.save", params: ["dir": .string(dir.path), "path": .string(out.path)])
        XCTAssertEqual(saved["steps"], 2)
        XCTAssertEqual(saved["skipped"], 4)
        XCTAssertEqual(saved["warnings"], [
            "seq 4 (vm.exec): the trace masks the env value 'TOKEN'; the step reads it from the variable 'TOKEN', pass it in variables when running the script",
            "trace line 2 was skipped (it is not a trace line); a step may be missing",
            "trace line 3 was skipped (it is not a trace line); a step may be missing",
            "trace line 4 was skipped (it is not a trace line); a step may be missing",
            "trace line 6 was skipped (it is not a trace line); a step may be missing",
        ])
        XCTAssertEqual(ops(try Script.parse(try Data(contentsOf: out))), ["vm.key.press", "vm.exec"])
    }

    func testSaveNamesTheSkippedLinesInsideTheRange() async throws {
        let h = handler()
        let long = String(repeating: "x", count: ScriptLimits.traceLineBytes + 1)
        let dir = try recordingDir([
            entry(1, "vm.key.press", ["keys": "a"]),
            "not json",
            "",
            entry(2, "vm.key.press", ["keys": "b"]),
            .string(long),
            entry(3, "vm.key.press", ["keys": "c"]),
            "not json either",
            entry(4, "vm.key.press", ["keys": "d"]),
        ])
        let trace = dir.appendingPathComponent("trace.jsonl").path
        let out = try tempDir().appendingPathComponent("flow.json")
        let ranged = try await h.handle(op: "script.save", params: ["trace": .string(trace), "path": .string(out.path), "from": 2, "to": 3])
        XCTAssertEqual(ranged["skipped"], 3)
        XCTAssertEqual(ranged["warnings"], [
            "trace line 2 was skipped (it is not a trace line); a step may be missing",
            "trace line 5 was skipped (it is longer than 8388608 bytes); a step may be missing",
        ])
        let open = try await h.handle(op: "script.save", params: ["trace": .string(trace), "path": .string(out.path), "overwrite": true, "from": 4])
        XCTAssertEqual(open["warnings"], ["trace line 7 was skipped (it is not a trace line); a step may be missing"])
    }

    func testSaveRefusesToReplaceAFileWithoutOverwrite() async throws {
        let h = handler()
        let dir = try recordingDir([entry(1, "vm.key.press", ["keys": "a"])])
        let out = try tempDir().appendingPathComponent("flow.json")
        try Data("mine".utf8).write(to: out)
        let params: [String: JSON] = ["dir": .string(dir.path), "path": .string(out.path)]
        let refused = await failure(h, "script.save", .object(params))
        XCTAssertEqual(refused, "'\(out.path)' exists; pass overwrite: true or another path")
        XCTAssertEqual(try Data(contentsOf: out), Data("mine".utf8))
        let kept = await failure(h, "script.save", .object(params.merging(["overwrite": false]) { $1 }))
        XCTAssertEqual(kept, "'\(out.path)' exists; pass overwrite: true or another path")

        let replaced = try await h.handle(op: "script.save", params: .object(params.merging(["overwrite": true]) { $1 }))
        XCTAssertEqual(replaced["steps"], 1)
        XCTAssertEqual(ops(try Script.parse(try Data(contentsOf: out))), ["vm.key.press"])
        let left = try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path)
        XCTAssertEqual(left, ["flow.json"])
    }

    func testSaveCreatesOneMissingFolderAndNoMore() async throws {
        let h = handler()
        let dir = try recordingDir([entry(1, "vm.key.press", ["keys": "a"])])
        let base = try tempDir()
        let one = base.appendingPathComponent("scripts/flow.json")
        _ = try await h.handle(op: "script.save", params: ["dir": .string(dir.path), "path": .string(one.path)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.path))

        let two = base.appendingPathComponent("a/b/flow.json")
        let refused = await failure(h, "script.save", ["dir": .string(dir.path), "path": .string(two.path)])
        XCTAssertEqual(refused, "the folder '\(base.path)/a' does not exist; create it or choose another path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("a").path))
    }

    func testSaveChecksItsParameters() async throws {
        let h = handler()
        let dir = try recordingDir([entry(1, "vm.key.press", ["keys": "a"]), entry(2, "vm.screenshot")])
        let empty = try recordingDir([entry(1, "vm.screenshot")])
        let base = try tempDir()
        let out = base.appendingPathComponent("flow.json").path
        let trace = dir.appendingPathComponent("trace.jsonl").path
        let good: [String: JSON] = ["dir": .string(dir.path), "path": .string(out)]
        func with(_ changes: [String: JSON?]) -> JSON {
            var params = good
            for (key, value) in changes { params[key] = value }
            return .object(params)
        }
        let cases: [(JSON, String)] = [
            (with(["dir": nil]), "missing parameter; pass 'dir' or 'trace'"),
            (with(["trace": .string(trace)]), "pass dir or trace, not both"),
            (with(["dir": "recordings/one"]), "dir must be an absolute path"),
            (with(["dir": nil, "trace": "trace.jsonl"]), "trace must be an absolute path"),
            (with(["dir": .string(base.path)]), "'\(base.path)' holds no recording (no trace.jsonl in it); pass the dir that vm.record.start returned"),
            (with(["dir": .string(base.path + "/missing")]),
             "'\(base.path)/missing' holds no recording (no trace.jsonl in it); pass the dir that vm.record.start returned"),
            (with(["dir": nil, "trace": .string(dir.path)]), "'\(dir.path)' is not a file on the host; check the path"),
            (with(["path": nil]), "missing or invalid parameter 'path'"),
            (with(["path": "flow.json"]), "path must be an absolute path"),
            (with(["path": .string(base.path + "/flow.txt")]), "path must end in .json; a script is a JSON file"),
            (with(["path": .string(base.path)]), "path must end in .json; a script is a JSON file"),
            (with(["overwrite": "yes"]), "parameter 'overwrite' must be a boolean"),
            (with(["name": ""]), "missing or invalid parameter 'name'"),
            (with(["from": 0]), "from must be an integer of 1 or more; pass a seq of the trace"),
            (with(["to": "3"]), "to must be an integer of 1 or more; pass a seq of the trace"),
            (with(["from": 5, "to": 3]), "from (5) must not exceed to (3)"),
            (with(["from": 2]), "the trace holds no op to replay between seq 2 and its end; check from and to against the seq values of the trace"),
            (with(["dir": .string(empty.path)]), "the trace holds no op to replay; record clicks, keys or other changing ops first"),
        ]
        for (params, expected) in cases {
            let message = await failure(h, "script.save", params)
            XCTAssertEqual(message, expected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out))

        let folder = base.appendingPathComponent("taken.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let onFolder = await failure(h, "script.save", with(["path": .string(folder.path), "overwrite": true]))
        XCTAssertEqual(onFolder, "'\(folder.path)' is a folder; pass the path of a file")
    }

    func testSaveRefusesATraceWhoseScriptWouldNotRun() async throws {
        let h = handler()
        let base = try tempDir()
        let out = base.appendingPathComponent("flow.json")
        let condition = try recordingDir([
            entry(4, "vm.key.press", ["keys": "a"]),
            entry(5, "vm.wait_for", ["conditions": [["type": "nonsense"]]], result: ["matched": 0]),
        ])
        let first = await failure(h, "script.save", ["dir": .string(condition.path), "path": .string(out.path)])
        XCTAssertTrue(first.hasPrefix("the trace does not make a script that script.run accepts: step 2 condition 1: unknown type 'nonsense'; "), first)
        XCTAssertTrue(first.hasSuffix(" (step 2 is seq 5 of the trace); save another part of the trace with from and to"), first)

        let observe = try recordingDir([entry(7, "vm.key.press", ["keys": "a", "observe": "everything"])])
        let second = await failure(h, "script.save", ["dir": .string(observe.path), "path": .string(out.path)])
        let levels = ObserveLevel.allCases.map(\.rawValue).joined(separator: ", ")
        XCTAssertEqual(second, "the trace does not make a script that script.run accepts: step 1: observe must be one of \(levels) "
            + "(step 1 is seq 7 of the trace); save another part of the trace with from and to")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [])

        let masked = try recordingDir([entry(1, "vm.exec", ["command": "x", "env": ["TOKEN": "<masked>"]], result: ["code": 0])])
        let saved = try await h.handle(op: "script.save", params: ["dir": .string(masked.path), "path": .string(out.path)])
        XCTAssertEqual(saved["steps"], 1)
    }

    func testSaveWritesTheScriptWithOwnerOnlyAccess() async throws {
        let h = handler()
        let dir = try recordingDir([entry(1, "vm.key.press", ["keys": "a"])])
        let base = try tempDir()
        func mode(_ url: URL) throws -> Int? { try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }
        let fresh = base.appendingPathComponent("flow.json")
        _ = try await h.handle(op: "script.save", params: ["dir": .string(dir.path), "path": .string(fresh.path)])
        XCTAssertEqual(try mode(fresh), 0o600)

        let open = base.appendingPathComponent("open.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: open.path, contents: Data("mine".utf8), attributes: [.posixPermissions: 0o644]))
        _ = try await h.handle(op: "script.save", params: ["dir": .string(dir.path), "path": .string(open.path), "overwrite": true])
        XCTAssertEqual(try mode(open), 0o600)
        XCTAssertEqual(ops(try Script.parse(try Data(contentsOf: open))), ["vm.key.press"])
    }

    func testSaveSkipsATraceLineLongerThanEightMebibytes() async throws {
        XCTAssertEqual(ScriptLimits.traceLineBytes, 8 * 1024 * 1024)
        let h = handler()
        func line(_ seq: Int, _ keys: String, bytes: Int) throws -> JSON {
            let bare = try entry(seq, "vm.key.press", ["keys": .string(keys)], result: ["pad": ""]).serialized().count
            return entry(seq, "vm.key.press", ["keys": .string(keys)], result: ["pad": .string(String(repeating: "x", count: bytes - bare))])
        }
        let dir = try recordingDir([
            entry(1, "vm.key.press", ["keys": "a"]),
            try line(2, "b", bytes: ScriptLimits.traceLineBytes + 1),
            try line(3, "c", bytes: ScriptLimits.traceLineBytes),
            entry(4, "vm.key.press", ["keys": "d"]),
        ])
        let out = try tempDir().appendingPathComponent("flow.json")
        let saved = try await h.handle(op: "script.save", params: ["dir": .string(dir.path), "path": .string(out.path)])
        XCTAssertEqual(saved, ["path": .string(out.path), "steps": 3, "skipped": 1,
                               "warnings": ["trace line 2 was skipped (it is longer than 8388608 bytes); a step may be missing"]])
        XCTAssertEqual(try Script.parse(try Data(contentsOf: out)).steps.map { $0.params["keys"] }, ["a", "c", "d"])
    }

    func testTraceLinesAreReadInPiecesAndLongOnesAreCounted() throws {
        let file = try tempDir().appendingPathComponent("trace.jsonl")
        func read(_ text: String, limit: Int, chunk: Int) throws -> (lines: [String], long: Int) {
            try Data(text.utf8).write(to: file)
            var seen: [String] = []
            let long = try TraceReader.lines(at: file.path, limit: limit, chunk: chunk) { seen.append(String(decoding: $0, as: UTF8.self)) }
            return (seen, long)
        }
        for chunk in [1, 4, 5, 64] {
            let mixed = try read("one\n\nthree3\nseven77\nx\ntail", limit: 6, chunk: chunk)
            XCTAssertEqual(mixed.lines, ["one", "", "three3", "x", "tail"], "chunk \(chunk)")
            XCTAssertEqual(mixed.long, 1, "chunk \(chunk)")
            let ending = try read("a\nlonger than six", limit: 6, chunk: chunk)
            XCTAssertEqual(ending.lines, ["a"], "chunk \(chunk)")
            XCTAssertEqual(ending.long, 1, "chunk \(chunk)")
            let closed = try read("a\nb\n", limit: 6, chunk: chunk)
            XCTAssertEqual(closed.lines, ["a", "b"], "chunk \(chunk)")
            XCTAssertEqual(closed.long, 0, "chunk \(chunk)")
        }
        let none = try read("", limit: 6, chunk: 4)
        XCTAssertEqual(none.lines, [])
        XCTAssertThrowsError(try TraceReader.lines(at: file.path + ".missing", limit: 6, chunk: 4) { _ in })
    }

    func testAnAssemblyKeepsOnlyTheStepsOfItsRange() {
        var assembly = ScriptBuilder.Assembly(from: 3, to: 4)
        for seq in 1...6 { assembly.add(entry(seq, "vm.key.press", ["keys": .string("f\(seq)")])) }
        XCTAssertEqual(assembly.recordedVM, "Win")
        let draft = assembly.draft(vm: "Other")
        XCTAssertEqual(draft.script.vm, "Other")
        XCTAssertEqual(draft.script.steps.map { $0.params["keys"] }, ["f3", "f4"])
        XCTAssertEqual(draft.sources, [3, 4])
        XCTAssertEqual(draft, ScriptBuilder.draft(trace: (1...6).map { entry($0, "vm.key.press", ["keys": .string("f\($0)")]) }, vm: "Other", from: 3, to: 4))
    }

    func testSaveNeedsNoLeaseAndIsNotTraced() async throws {
        let (h, _, _) = try await rig(LockedBox([:]))
        let recording = try await startRecording(h)
        _ = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "a"])
        _ = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "someone", "ttl": 60])
        let out = try tempDir().appendingPathComponent("flow.json")
        let saved = try await h.handle(op: "script.save", params: ["dir": .string(recording.path), "path": .string(out.path), "name": "Win"])
        XCTAssertEqual(saved["steps"], 1)
        XCTAssertEqual(try lines(recording).map { $0["op"]?.stringValue }, ["vm.key.press", "vm.lease.acquire"])
    }

    func testSaveOpClassification() {
        XCTAssertTrue(ControlHandler.knownOps.contains("script.save"))
        XCTAssertTrue(ControlHandler.isReadOnly(op: "script.save"))
        XCTAssertFalse(ControlHandler.isConcurrent(op: "script.save"))
        XCTAssertFalse(ControlHandler.isInput(op: "script.save"))
        XCTAssertFalse(ControlHandler.movesEventBaseline(op: "script.save"))
        XCTAssertFalse(Script.allows(op: "script.save"))
    }

    // MARK: - runner

    private func run(_ h: ControlHandler, _ step: String, snapshot: String? = nil) async throws -> ScriptResult {
        let script = try Script.parse(Data("{\"version\": 1, \"vm\": \"Win\", \"steps\": [\(step)]}".utf8))
        return await ScriptRunner(handler: h).run(script, vm: nil, variables: [:], owner: "script:flow.json", snapshot: snapshot, progress: nil)
    }

    func testRunnerUsesFallbackCoordinates() async throws {
        let answers = LockedBox<[String: Reply]>(["ui.rect": .fail(noMatch)])
        let (h, t, agent) = try await rig(answers)
        let selector = "\"selector\": {\"window\": \"Alcove Fixture\", \"role\": \"Button\", \"name\": \"Send\", \"automationId\": \"send\"}"
        let step = "{\"op\": \"vm.ui.click\", \"params\": {\(selector), \"fallback\": {\"x\": 190, \"y\": 112}, \"button\": \"right\"}}"

        let missed = try await run(h, step)
        XCTAssertTrue(missed.passed, missed.error ?? "")
        XCTAssertEqual(missed.stepResults[0]["usedFallback"], true)
        XCTAssertEqual(missed.stepResults[0]["ok"], true)
        XCTAssertEqual(fields(try XCTUnwrap(agentRequests(agent, "ui.rect").last)),
                       ["window": "Alcove Fixture", "role": "Button", "name": "Send", "automationId": "send", "scroll": true])
        var sent = await t.sent
        XCTAssertEqual(sent, [absolute(190, 112), .btn(con: 0, button: .right, down: true), .sync, .btn(con: 0, button: .right, down: false), .sync])

        answers.value["ui.rect"] = .fail("no window has \"Alcove Fixture\" in its title; call win.list to see the open windows")
        let closed = try await run(h, step)
        XCTAssertTrue(closed.passed, closed.error ?? "")
        XCTAssertEqual(closed.stepResults[0]["usedFallback"], true)
        sent = await t.sent
        XCTAssertEqual(sent.count, 10)

        answers.value["ui.rect"] = .ok(["node": sendButton, "cx": 200, "cy": 120, "clickable": true])
        let found = try await run(h, step)
        XCTAssertTrue(found.passed, found.error ?? "")
        XCTAssertNil(found.stepResults[0]["usedFallback"])
        sent = await t.sent
        XCTAssertEqual(Array(sent.dropFirst(10)).first, absolute(200, 120))
        XCTAssertEqual(sent.count, 15)

        answers.value["ui.rect"] = .fail("the UI helper is shut down; reconnect the guest tools")
        let down = try await run(h, step)
        XCTAssertFalse(down.passed)
        XCTAssertEqual(down.error, "step 1 failed: the UI helper is shut down; reconnect the guest tools")
        XCTAssertNil(down.stepResults[0]["usedFallback"])

        answers.value["ui.rect"] = .ok(["node": sendButton, "cx": 200, "cy": 120, "clickable": false, "blocked": "the element is disabled"])
        let blocked = try await run(h, step)
        XCTAssertFalse(blocked.passed)
        XCTAssertNil(blocked.stepResults[0]["usedFallback"])

        answers.value["ui.rect"] = .fail(noMatch)
        let bare = try await run(h, "{\"op\": \"vm.ui.click\", \"params\": {\(selector)}}")
        XCTAssertFalse(bare.passed)
        XCTAssertEqual(bare.error, "step 1 failed: \(noMatch)")
        sent = await t.sent
        XCTAssertEqual(sent.count, 15)
    }

    func testFallbackIsCheckedBeforeAnyStep() async throws {
        let (h, _, agent) = try await rig(LockedBox(["ui.rect": .fail(noMatch)]))
        let selector = "\"selector\": {\"name\": \"Send\"}"
        let cases: [(String, String)] = [
            ("{\"op\": \"vm.ui.click\", \"params\": {\(selector), \"fallback\": {\"x\": 1}}}",
             "step 1 has a fallback without integer 'x' and 'y'; write it as {\"x\": 120, \"y\": 80} or remove it"),
            ("{\"op\": \"vm.ui.click\", \"params\": {\(selector), \"fallback\": \"190,112\"}}",
             "step 1 has a fallback without integer 'x' and 'y'; write it as {\"x\": 120, \"y\": 80} or remove it"),
            ("{\"op\": \"vm.ui.type\", \"params\": {\(selector), \"text\": \"a\", \"fallback\": {\"x\": 1, \"y\": 2}}}",
             "step 1 has a fallback, which only vm.ui.click takes; remove it"),
        ]
        for (step, expected) in cases {
            XCTAssertThrowsError(try Script.parse(Data("{\"version\": 1, \"steps\": [\(step)]}".utf8)), step) { XCTAssertEqual("\($0)", expected) }
        }
        let built = Script(vm: "Win", variables: [:], steps: [
            Script.Step(label: nil, op: "vm.ui.click", params: ["selector": ["name": "Send"], "fallback": ["x": 1.5, "y": 2]], expect: [], timeout: 5),
        ])
        let result = await ScriptRunner(handler: h).run(built, vm: nil, variables: [:], progress: nil)
        XCTAssertEqual(result.stepsRun, 0)
        XCTAssertEqual(result.error, cases[0].1)
        XCTAssertTrue(agentRequests(agent, "ui.rect").isEmpty)
    }

    /// Answers `ui.rect` and `ui.act` by the selector field a request carries: `byID` for `automationId`, `byName` for `name`.
    private func bySelector(byID: Reply, byName: Reply) -> Reply {
        .by { $0["automationId"] != nil ? byID : byName }
    }

    private let aidSelector = "\"selector\": {\"window\": \"Alcove Fixture\", \"role\": \"Button\", \"automationId\": \"send\"}"
    private let nameSelector = "\"altSelector\": {\"window\": \"Alcove Fixture\", \"role\": \"Button\", \"name\": \"Send\", \"index\": 2}"
    private let noAidMatch = "no element matches {\"automationId\":\"send\",\"role\":\"Button\",\"window\":\"Alcove Fixture\"}; call ui.tree to see what exists"
    private let noNameMatch = "no element matches {\"index\":2,\"name\":\"Send\",\"role\":\"Button\",\"window\":\"Alcove Fixture\"}; call ui.tree to see what exists"

    func testRunnerRetriesWithAltSelectorWhenNoElementMatches() async throws {
        let found: Reply = .ok(["node": sendButton, "cx": 200, "cy": 120, "clickable": true])
        let answers = LockedBox<[String: Reply]>(["ui.rect": bySelector(byID: .fail(noAidMatch), byName: found)])
        let (h, t, agent) = try await rig(answers)
        let click = "{\"op\": \"vm.ui.click\", \"params\": {\(aidSelector), \(nameSelector), \"fallback\": {\"x\": 190, \"y\": 112}}}"

        let retried = try await run(h, click)
        XCTAssertTrue(retried.passed, retried.error ?? "")
        XCTAssertEqual(retried.stepResults[0]["usedAltSelector"], true)
        XCTAssertNil(retried.stepResults[0]["usedFallback"])
        XCTAssertEqual(agentRequests(agent, "ui.rect").map(fields), [
            ["window": "Alcove Fixture", "role": "Button", "automationId": "send", "scroll": true],
            ["window": "Alcove Fixture", "role": "Button", "name": "Send", "index": 2, "scroll": true],
        ])
        var sent = await t.sent
        XCTAssertEqual(sent.first, absolute(200, 120))
        XCTAssertEqual(sent.count, 5)

        answers.value["ui.rect"] = bySelector(byID: .fail(noAidMatch), byName: .fail(noNameMatch))
        let neither = try await run(h, click)
        XCTAssertTrue(neither.passed, neither.error ?? "")
        XCTAssertEqual(neither.stepResults[0]["usedAltSelector"], true)
        XCTAssertEqual(neither.stepResults[0]["usedFallback"], true)
        sent = await t.sent
        XCTAssertEqual(Array(sent.dropFirst(5)).first, absolute(190, 112))
        XCTAssertEqual(sent.count, 10)

        answers.value["ui.rect"] = bySelector(byID: .fail("no window has \"Alcove Fixture\" in its title; call win.list to see the open windows"), byName: found)
        let closed = try await run(h, click)
        XCTAssertTrue(closed.passed, closed.error ?? "")
        XCTAssertNil(closed.stepResults[0]["usedAltSelector"])
        XCTAssertEqual(closed.stepResults[0]["usedFallback"], true)
        XCTAssertEqual(agentRequests(agent, "ui.rect").count, 5)

        answers.value["ui.rect"] = bySelector(byID: found, byName: .fail(noNameMatch))
        let first = try await run(h, click)
        XCTAssertTrue(first.passed, first.error ?? "")
        XCTAssertNil(first.stepResults[0]["usedAltSelector"])
        XCTAssertNil(first.stepResults[0]["usedFallback"])
        XCTAssertEqual(agentRequests(agent, "ui.rect").count, 6)

        answers.value["ui.rect"] = bySelector(byID: .fail(noAidMatch), byName: .fail("the UI helper is shut down; reconnect the guest tools"))
        let down = try await run(h, click)
        XCTAssertFalse(down.passed)
        XCTAssertEqual(down.error, "step 1 failed: the selector matched no element (\(noAidMatch)) and the retry with altSelector failed: "
            + "the UI helper is shut down; reconnect the guest tools")
        XCTAssertEqual(down.stepResults[0]["usedAltSelector"], true)
        XCTAssertNil(down.stepResults[0]["usedFallback"])
        sent = await t.sent
        XCTAssertEqual(sent.count, 20)
    }

    func testRunnerMarksTheStepsThatRanWithAPositionalSelector() async throws {
        let found: Reply = .ok(["node": sendButton, "cx": 200, "cy": 120, "clickable": true])
        let answers = LockedBox<[String: Reply]>(["ui.rect": bySelector(byID: found, byName: found)])
        let (h, _, _) = try await rig(answers)
        let plain = try await run(h, "{\"op\": \"vm.ui.click\", \"params\": {\(aidSelector)}}")
        XCTAssertTrue(plain.passed, plain.error ?? "")
        XCTAssertNil(plain.stepResults[0]["positional"])
        let indexed = try await run(h, "{\"op\": \"vm.ui.click\", \"params\": {\"selector\": {\"window\": \"Alcove Fixture\", \"role\": \"Button\", \"name\": \"Send\", \"index\": 0}}}")
        XCTAssertEqual(indexed.stepResults[0]["positional"], true)
        let withAlt = try await run(h, "{\"op\": \"vm.ui.click\", \"params\": {\(aidSelector), \(nameSelector)}}")
        XCTAssertNil(withAlt.stepResults[0]["positional"])
        XCTAssertNil(withAlt.stepResults[0]["usedAltSelector"])

        answers.value["ui.rect"] = bySelector(byID: .fail(noAidMatch), byName: found)
        let retried = try await run(h, "{\"op\": \"vm.ui.click\", \"params\": {\(aidSelector), \(nameSelector)}}")
        XCTAssertEqual(retried.stepResults[0]["usedAltSelector"], true)
        XCTAssertEqual(retried.stepResults[0]["positional"], true)

        let indexedPrimary = "\"selector\": {\"window\": \"Alcove Fixture\", \"role\": \"Button\", \"automationId\": \"send\", \"index\": 1}"
        let plainAlt = "\"altSelector\": {\"window\": \"Alcove Fixture\", \"role\": \"Button\", \"name\": \"Send\"}"
        let unindexedAlt = try await run(h, "{\"op\": \"vm.ui.click\", \"params\": {\(indexedPrimary), \(plainAlt)}}")
        XCTAssertEqual(unindexedAlt.stepResults[0]["usedAltSelector"], true)
        XCTAssertNil(unindexedAlt.stepResults[0]["positional"])

        answers.value["ui.rect"] = .fail(noAidMatch)
        let fallback = try await run(h, "{\"op\": \"vm.ui.click\", \"params\": {\(indexedPrimary), \"fallback\": {\"x\": 190, \"y\": 112}}}")
        XCTAssertTrue(fallback.passed, fallback.error ?? "")
        XCTAssertEqual(fallback.stepResults[0]["usedFallback"], true)
        XCTAssertNil(fallback.stepResults[0]["positional"])
    }

    func testTypeAndActionStepsRetryWithAltSelector() async throws {
        let field = node("e4", "Edit", "Message", aid: "send")
        let answers = LockedBox<[String: Reply]>([
            "ui.rect": bySelector(byID: .fail(noAidMatch), byName: .ok(["node": field, "cx": 200, "cy": 120, "clickable": true])),
            "ui.act": bySelector(byID: .fail(noAidMatch), byName: .ok(["node": field])),
        ])
        let (h, t, agent) = try await rig(answers)
        let typed = try await run(h, "{\"op\": \"vm.ui.type\", \"params\": {\(aidSelector), \(nameSelector), \"text\": \"a\"}}")
        XCTAssertTrue(typed.passed, typed.error ?? "")
        XCTAssertEqual(typed.stepResults[0]["usedAltSelector"], true)
        let sent = await t.sent
        XCTAssertEqual(sent.first, absolute(200, 120))
        XCTAssertEqual(sent.count, 7)

        let step = "{\"op\": \"vm.ui.action\", \"params\": {\(aidSelector), \(nameSelector), \"action\": \"invoke\"}}"
        let acted = try await run(h, step)
        XCTAssertTrue(acted.passed, acted.error ?? "")
        XCTAssertEqual(acted.stepResults[0]["usedAltSelector"], true)
        XCTAssertEqual(agentRequests(agent, "ui.act").map(fields), [
            ["window": "Alcove Fixture", "role": "Button", "automationId": "send", "action": "invoke"],
            ["window": "Alcove Fixture", "role": "Button", "name": "Send", "index": 2, "action": "invoke"],
        ])

        answers.value["ui.act"] = bySelector(byID: .fail(noAidMatch), byName: .fail(noNameMatch))
        let neither = try await run(h, step)
        XCTAssertFalse(neither.passed)
        XCTAssertEqual(neither.error, "step 1 failed: the selector matched no element (\(noAidMatch)) and the retry with altSelector failed: \(noNameMatch)")
        XCTAssertEqual(neither.stepResults[0]["usedAltSelector"], true)

        let bare = try await run(h, "{\"op\": \"vm.ui.action\", \"params\": {\(aidSelector), \"action\": \"invoke\"}}")
        XCTAssertFalse(bare.passed)
        XCTAssertEqual(bare.error, "step 1 failed: \(noAidMatch)")
        XCTAssertNil(bare.stepResults[0]["usedAltSelector"])
    }

    func testAltSelectorIsCheckedBeforeAnyStep() async throws {
        let (h, _, agent) = try await rig(LockedBox(["ui.rect": .fail(noMatch)]))
        let selector = "\"selector\": {\"name\": \"Send\"}"
        let cases: [(String, String)] = [
            ("{\"op\": \"vm.mouse.click\", \"params\": {\"x\": 1, \"y\": 2, \"altSelector\": {\"name\": \"Send\"}}}",
             "step 1 has an altSelector, which only vm.ui.click, vm.ui.type, vm.ui.action, vm.ui.find and vm.ui.text take; remove it"),
            ("{\"op\": \"vm.ui.tree\", \"params\": {\"altSelector\": {\"name\": \"Send\"}}}",
             "step 1 has an altSelector, which only vm.ui.click, vm.ui.type, vm.ui.action, vm.ui.find and vm.ui.text take; remove it"),
            ("{\"op\": \"vm.ui.click\", \"params\": {\"ref\": \"e5\", \"altSelector\": {\"name\": \"Send\"}}}",
             "step 1 has an altSelector without a selector; add the selector it stands in for or remove it"),
            ("{\"op\": \"vm.ui.click\", \"params\": {\(selector), \"altSelector\": \"Send\"}}",
             "step 1 has an altSelector that is not a selector: selector must be an object with window, role, name, nameContains, automationId or index"),
            ("{\"op\": \"vm.ui.type\", \"params\": {\(selector), \"text\": \"a\", \"altSelector\": {\"title\": \"Send\"}}}",
             "step 1 has an altSelector that is not a selector: selector has no field 'title'; valid fields: window, role, name, nameContains, automationId, index"),
            ("{\"op\": \"vm.ui.action\", \"params\": {\(selector), \"action\": \"invoke\", \"altSelector\": {\"window\": \"Notes\", \"index\": 1}}}",
             "step 1 has an altSelector without any of role, name, nameContains, automationId; add one or remove it"),
        ]
        for (step, expected) in cases {
            XCTAssertThrowsError(try Script.parse(Data("{\"version\": 1, \"steps\": [\(step)]}".utf8)), step) { XCTAssertEqual("\($0)", expected) }
        }
        for op in ["vm.ui.click", "vm.ui.type", "vm.ui.action", "vm.ui.find", "vm.ui.text"] {
            let step = "{\"op\": \"\(op)\", \"params\": {\(selector), \"altSelector\": {\"role\": \"Button\", \"index\": 0}}}"
            XCTAssertNoThrow(try Script.parse(Data("{\"version\": 1, \"steps\": [\(step)]}".utf8)), op)
        }
        let built = Script(vm: "Win", variables: [:], steps: [
            Script.Step(label: nil, op: "vm.ui.click", params: ["selector": ["name": "Send"], "altSelector": ["index": 1]], expect: [], timeout: 5),
        ])
        let result = await ScriptRunner(handler: h).run(built, vm: nil, variables: [:], progress: nil)
        XCTAssertEqual(result.stepsRun, 0)
        XCTAssertEqual(result.error, cases[5].1)
        XCTAssertTrue(agentRequests(agent, "ui.rect").isEmpty)
    }

    func testARecordingMarksTheCallsOfAScriptRun() async throws {
        let answers = LockedBox<[String: Reply]>([
            "exec.run": .ok(["code": 0, "stdout": "", "stderr": ""]),
            "fs.stat": .ok(["exists": true, "dir": false, "size": 1, "path": "C:\\a"]),
            "ui.rect": .fail(noMatch),
        ])
        let (h, t, _) = try await rig(answers)
        await t.setSnapshotList([VMController.SnapshotInfo(name: "clean", vmStateSize: 1, date: Date())])
        let dir = try await startRecording(h)
        let passed = try await run(h, "{\"op\": \"vm.exec\", \"params\": {\"command\": \"one\"}, \"expect\": [{\"type\": \"file_exists\", \"path\": \"C:\\\\a\"}]},"
                                   + "{\"op\": \"vm.ui.click\", \"params\": {\"selector\": {\"name\": \"Send\"}, \"fallback\": {\"x\": 5, \"y\": 6}}}", snapshot: "clean")
        XCTAssertTrue(passed.passed, passed.error ?? "")
        let failed = try await run(h, "{\"op\": \"vm.mouse.click\", \"params\": {\"x\": 1}}")
        XCTAssertFalse(failed.passed)
        _ = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "a"])
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])

        let rows = try lines(dir)
        XCTAssertEqual(rows.map { "\($0["op"]?.stringValue ?? "?") \($0["script"]?.stringValue ?? "-")" }, [
            "vm.lease.acquire lease", "vm.snapshot.restore snapshot", "vm.exec step", "vm.wait_for expect", "vm.ui.click step",
            "vm.mouse.click step", "vm.lease.release lease",
            "vm.lease.acquire lease", "vm.mouse.click step", "vm.screenshot failure", "vm.lease.release lease",
            "vm.key.press -",
        ])
        let text = try String(contentsOf: dir.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        XCTAssertFalse(text.contains("\"lease\":"))
        let script = build(rows)
        XCTAssertEqual(ops(script), ["vm.exec", "vm.mouse.click", "vm.key.press"])
        XCTAssertEqual(script.steps.map(\.params), [["command": "one"], ["x": 5, "y": 6], ["keys": "a"]])
    }

    // MARK: - recording

    /// A running 800x600 VM "Win" behind a `ParkingRegistry`, whose agent is `fakeAgent(answers)`.
    private func parkingRig(_ answers: LockedBox<[String: Reply]>) async throws -> (ControlHandler, FakeTarget, FakeAgent, ParkingRegistry) {
        let agent = fakeAgent(answers)
        _ = agent.start()
        addTeardownBlock { agent.stop() }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 800, height: 600))
        await t.setAgent(client)
        let registry = ParkingRegistry(t)
        return (ControlHandler(registry: registry, hostKind: "test", captureDirectory: scratchCaptureDirectory), t, agent, registry)
    }

    func testRecordingAddsTargetToClicks() async throws {
        let message = at("Edit", "Message", id: "101", x: 250, flags: ["enabled", "focused"], byID: (1, 0), byName: (1, 0))
        let messageTarget = target("Alcove Fixture", "Edit", "Message", id: "101", rect: [250, 100, 80, 24], byID: (1, 0), byName: (1, 0))
        let answers = LockedBox<[String: Reply]>([
            "ui.at": .by { $0["focused"] == true || $0["ref"] == "e4" ? .ok(message) : .ok(sendAt) },
            "ui.rect": .ok(["node": sendButton, "cx": 190, "cy": 112, "clickable": true]),
            "ui.act": .ok(["node": node("e5", "Button", "Sent", aid: "send")]),
            "win.action": .ok(["window": fixtureWindow]),
        ])
        let (h, _, agent) = try await rig(answers)
        let dir = try await startRecording(h)
        let clicked = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        XCTAssertEqual(clicked, ["eventSeq": 0])
        _ = try await h.handle(op: "vm.mouse.drag", params: ["name": "Win", "fromX": 150, "fromY": 100, "toX": 300, "toY": 100])
        _ = try await h.handle(op: "vm.mouse.move", params: click(1, 1))
        _ = try await h.handle(op: "vm.ui.click", params: ["name": "Win", "ref": "e5"])
        _ = try await h.handle(op: "vm.ui.click", params: ["name": "Win", "selector": ["name": "Send"]])
        _ = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": [["op": "vm.mouse.click", "x": 2, "y": 2], ["op": "vm.type", "text": "b"]]])
        _ = try await h.handle(op: "vm.type", params: ["name": "Win", "text": "hi"])
        _ = try await h.handle(op: "vm.ui.type", params: ["name": "Win", "ref": "e4", "text": "yo"])
        _ = try await h.handle(op: "vm.ui.action", params: ["name": "Win", "ref": "e5", "action": "invoke"])
        _ = try await h.handle(op: "vm.ui.action", params: ["name": "Win", "selector": ["name": "Send"], "action": "invoke"])
        _ = try await h.handle(op: "vm.window.action", params: ["name": "Win", "window": "Fixture", "action": "focus"])
        _ = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "enter"])
        answers.value["ui.at"] = .fail("no element at (700, 500); take a screenshot to see what is there")
        let bare = try await h.handle(op: "vm.mouse.click", params: click(700, 500))
        XCTAssertEqual(bare, ["eventSeq": 0])
        let status = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["ops"], 13)
        let positions = await h.eventPositions("Win")
        XCTAssertEqual(positions.baseline, 0)
        XCTAssertNil(positions.observed)
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.mouse.click", params: click(5, 5))

        let rows = try lines(dir)
        XCTAssertEqual(rows.map { $0["op"]?.stringValue },
                       ["vm.mouse.click", "vm.mouse.drag", "vm.mouse.move", "vm.ui.click", "vm.ui.click", "vm.batch", "vm.type", "vm.ui.type",
                        "vm.ui.action", "vm.ui.action", "vm.window.action", "vm.key.press", "vm.mouse.click"])
        XCTAssertEqual(rows.map { $0["target"] },
                       [sendTarget, sendTarget, nil, sendTarget, nil, nil, messageTarget, messageTarget, sendTarget, nil, nil, nil, nil])
        XCTAssertEqual(rows.map { $0["selector"] }, Array(repeating: nil, count: 13))
        XCTAssertEqual(rows.map { $0["ok"] }, Array(repeating: true, count: 13))
        XCTAssertEqual(rows.map { $0["script"] }, Array(repeating: nil, count: 13))
        XCTAssertEqual(agentRequests(agent, "ui.at").map(fields), [
            ["x": 190, "y": 112, "budgetMs": 200], ["x": 150, "y": 100, "budgetMs": 200], ["ref": "e5", "budgetMs": 200],
            ["focused": true, "budgetMs": 200], ["ref": "e4", "budgetMs": 200], ["ref": "e5", "budgetMs": 200], ["x": 700, "y": 500, "budgetMs": 200],
        ])
        let script = build(rows)
        XCTAssertEqual(ops(script), ["vm.ui.click", "vm.mouse.drag", "vm.mouse.move", "vm.ui.click", "vm.ui.click", "vm.batch", "vm.type", "vm.ui.type",
                                     "vm.ui.action", "vm.ui.action", "vm.window.action", "vm.key.press", "vm.mouse.click"])
        XCTAssertEqual(script.steps[8].params, ["selector": sendSelector, "altSelector": sendAltSelector, "action": "invoke"])
    }

    func testTargetFactsOfAReply() {
        let window: JSON = ["id": "0x2a", "title": "Alcove Fixture"]
        func facts(_ reply: [String: JSON]) -> JSON? { ControlHandler.targetFacts(.object(reply)) }
        XCTAssertEqual(facts(sendAt), sendTarget)
        XCTAssertEqual(facts(["node": ["role": "Button", "name": "Send", "aid": "1004", "x": 612, "y": 480, "w": 88, "h": 28, "flags": ["enabled"]],
                              "window": ["id": "0x50a3c", "title": "Alcove Fixture"],
                              "byAutomationId": ["matches": 1, "index": 0], "byName": ["matches": 3, "index": 2]]),
                       ["window": "Alcove Fixture", "role": "Button", "name": "Send", "automationId": "1004", "rect": ["x": 612, "y": 480, "w": 88, "h": 28],
                        "byAutomationId": ["matches": 1, "index": 0], "byName": ["matches": 3, "index": 2]])
        XCTAssertEqual(facts(["node": ["ref": "e5", "depth": 0, "role": "Button", "name": "Send", "aid": "send", "x": 1, "y": 2, "w": 3, "h": 4],
                              "window": window, "byAutomationId": ["matches": 2, "index": 1], "byName": .null]),
                       ["window": "Alcove Fixture", "role": "Button", "name": "Send", "automationId": "send", "rect": ["x": 1, "y": 2, "w": 3, "h": 4],
                        "byAutomationId": ["matches": 2, "index": 1]])
        XCTAssertEqual(facts(["node": ["role": "Edit", "name": "", "aid": "pw", "x": 1, "y": 2, "w": 3, "h": 4, "flags": ["enabled", "password"],
                                       "value": "shown"],
                              "window": window, "byAutomationId": ["matches": 1, "index": 0]]),
                       ["window": "Alcove Fixture", "role": "Edit", "name": "", "automationId": "pw", "rect": ["x": 1, "y": 2, "w": 3, "h": 4],
                        "password": true, "byAutomationId": ["matches": 1, "index": 0]])
        XCTAssertEqual(facts(["node": ["role": "Pane", "aid": ""], "window": ["id": "0x1", "title": ""]]), ["role": "Pane", "name": ""])
        XCTAssertEqual(facts(["node": ["role": "Pane", "automationId": "other"]]), ["role": "Pane", "name": ""])
        XCTAssertEqual(facts(["node": ["role": "Pane", "name": "Desk", "x": 1, "y": 2, "w": 3], "window": .null,
                              "byName": ["matches": 2, "index": 2], "byAutomationId": ["matches": "1", "index": 0]]),
                       ["role": "Pane", "name": "Desk"])
        XCTAssertEqual(facts(["node": ["role": "Pane", "name": "Desk"], "byName": ["matches": 0, "index": 0]]), ["role": "Pane", "name": "Desk"])
        XCTAssertNil(facts(["node": ["name": "Send"], "window": window]))
        XCTAssertNil(facts(["node": .null, "window": window]))
        XCTAssertNil(facts(["window": window]))
    }

    func testPasswordTextIsMaskedInTheTrace() async throws {
        let secretAt = at("Edit", "", id: "pw", flags: ["enabled", "focused", "password"], byID: (1, 0))
        let userAt = at("Edit", "User", id: "user", x: 250, byID: (1, 0), byName: (1, 0))
        let secretNode = node("e7", "Edit", "", aid: "pw", flags: ["password"])
        let userNode = node("e3", "Edit", "User", aid: "user")
        let focused = LockedBox(secretAt)
        let answers = LockedBox<[String: Reply]>([
            "ui.at": .by { $0["ref"] == "e3" ? .ok(userAt) : $0["ref"] == "e7" ? .ok(secretAt) : .ok(focused.value) },
            "ui.rect": .by { $0["ref"] == "e3" ? .ok(["node": userNode, "cx": 290, "cy": 112, "clickable": true])
                                               : .ok(["node": secretNode, "cx": 190, "cy": 112, "clickable": true]) },
            "ui.act": .ok(["node": secretNode]),
        ])
        let (h, t, _) = try await rig(answers)
        let dir = try await startRecording(h)
        let byID: JSON = ["window": "Alcove Fixture", "role": "Edit", "automationId": "pw"]
        _ = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "tab"])
        _ = try await h.handle(op: "vm.type", params: ["name": "Win", "text": "hunter2"])
        let keys = await t.sent.count
        XCTAssertEqual(keys, 16)
        _ = try await h.handle(op: "vm.ui.type", params: ["name": "Win", "ref": "e7", "text": "s3cret"])
        _ = try await h.handle(op: "vm.ui.action", params: ["name": "Win", "ref": "e7", "action": "set_value", "value": "pa55"])
        _ = try await h.handle(op: "vm.ui.type", params: ["name": "Win", "selector": byID, "text": "by-selector"])
        _ = try await h.handle(op: "vm.ui.action", params: ["name": "Win", "selector": byID, "action": "set_value", "value": "by-action"])
        _ = try await h.handle(op: "vm.ui.type", params: ["name": "Win", "ref": "e3", "text": "ada"])
        focused.value = userAt
        _ = try await h.handle(op: "vm.type", params: ["name": "Win", "text": "bob"])
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])

        let rows = try lines(dir)
        XCTAssertEqual(rows.map { $0["params"]?["text"] ?? $0["params"]?["value"] }, [nil, "<masked>", "<masked>", "<masked>", "<masked>", "<masked>", "ada", "bob"])
        XCTAssertEqual(rows.map { $0["target"]?["password"] }, [nil, true, true, true, nil, nil, nil, nil])
        XCTAssertEqual(rows.map { $0["ok"] }, Array(repeating: true, count: 8))
        let trace = try String(contentsOf: dir.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        for typed in ["hunter2", "s3cret", "pa55", "by-selector", "by-action"] { XCTAssertFalse(trace.contains(typed), typed) }

        let out = try tempDir().appendingPathComponent("flow.json")
        let saved = try await h.handle(op: "script.save", params: ["dir": .string(dir.path), "path": .string(out.path)])
        XCTAssertEqual(saved["steps"], 8)
        let script = try Script.parse(try Data(contentsOf: out))
        XCTAssertEqual(script.steps.map { $0.params["text"] ?? $0.params["value"] },
                       [nil, "${password}", "${password2}", "${password3}", "${password4}", "${password5}", "ada", "bob"])
        XCTAssertEqual(script.variables, [:])
        let before = await t.sent.count
        let refused = await failure(h, "script.run", ["path": .string(out.path)])
        XCTAssertEqual(refused, "variable 'password' is not defined; pass it or add a default")
        let after = await t.sent.count
        XCTAssertEqual(after, before)
    }

    func testATargetQuestionIsWaitedForFromItsSendAndKeepsTheHelperUntilItsAnswer() async throws {
        UITiming.targetBudget = .seconds(600)
        let budget = Latch()
        let ends = LockedBox<[ContinuousClock.Instant]>([])
        UITiming.factBudgetEnd = { end in
            ends.value.append(end)
            await budget.pass()
        }
        let answers = LockedBox<[String: Reply]>(["ui.at": .silent])
        let (h, t, agent, registry) = try await parkingRig(answers)
        let dir = try await startRecording(h)

        let lookup = Latch()
        await registry.park(at: lookup)
        let press = click(190, 112)
        let first = Task { try await h.handle(op: "vm.mouse.click", params: press) }
        let parked = await eventually { await lookup.arrivals == 1 }
        XCTAssertTrue(parked)
        let beforeSend = ContinuousClock.now
        await registry.park(at: nil)
        await lookup.open()
        let asked = await eventually { agentRequests(agent, "ui.at").count == 1 && ends.value.count == 1 }
        XCTAssertTrue(asked)
        let afterSend = ContinuousClock.now
        let end = try XCTUnwrap(ends.value.first)
        XCTAssertGreaterThanOrEqual(end, beforeSend + .seconds(600))
        XCTAssertLessThanOrEqual(end, afterSend + .seconds(600))
        XCTAssertEqual(agentRequests(agent, "ui.at").map(fields), [["x": 190, "y": 112, "budgetMs": 200]])
        let untouched = await t.sent.isEmpty
        XCTAssertTrue(untouched)
        await budget.open()
        let late = try await value(of: first)
        XCTAssertEqual(late, ["eventSeq": 0])
        let taken = try await h.helperGate.acquire("Win", until: .now)
        XCTAssertFalse(taken)

        _ = try await h.handle(op: "vm.mouse.click", params: click(5, 5))
        XCTAssertEqual(agentRequests(agent, "ui.at").count, 1)
        XCTAssertEqual(ends.value.count, 1)
        let waiting = await h.helperGate.waiterCount(for: "Win")
        XCTAssertEqual(waiting, 0)

        agent.sendLine(agentReply(try XCTUnwrap(agentRequests(agent, "ui.at").first), sendAt))
        let free = await eventually { (try? await h.helperGate.acquire("Win", until: .now)) == true }
        XCTAssertTrue(free)
        await h.helperGate.release("Win")
        UITiming.factBudgetEnd = { try? await Task.sleep(until: $0, clock: .continuous) }
        answers.value["ui.at"] = .ok(sendAt)
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(try lines(dir).map { $0["target"] }, [nil, nil, sendTarget])
        XCTAssertEqual(agentRequests(agent, "ui.at").count, 2)
    }

    func testABusyHelperIsNotAskedForTheTarget() async throws {
        UITiming.targetBudget = .seconds(600)
        let budget = Latch()
        UITiming.factBudgetEnd = { _ in await budget.pass() }
        addTeardownBlock { await budget.open() }
        let (h, _, agent) = try await rig(LockedBox(["ui.at": .ok(sendAt)]))
        let dir = try await startRecording(h)

        let taken = try await h.helperGate.acquire("Win", until: .now)
        XCTAssertTrue(taken)
        let press = click(190, 112)
        let clicked = try await value(of: Task { try await h.handle(op: "vm.mouse.click", params: press) })
        XCTAssertEqual(clicked, ["eventSeq": 0])
        let typed = try await value(of: Task { try await h.handle(op: "vm.type", params: ["name": "Win", "text": "a"]) })
        XCTAssertEqual(typed, ["eventSeq": 0])
        let waited = await budget.arrivals
        XCTAssertEqual(waited, 0)
        let waiting = await h.helperGate.waiterCount(for: "Win")
        XCTAssertEqual(waiting, 0)
        await h.helperGate.release("Win")
        XCTAssertTrue(agentRequests(agent, "ui.at").isEmpty)
        let free = try await h.helperGate.acquire("Win", until: .now)
        XCTAssertTrue(free)
        await h.helperGate.release("Win")

        _ = try await h.handle(op: "vm.mouse.click", params: press)
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(try lines(dir).map { $0["target"] }, [nil, nil, sendTarget])
    }

    func testACancelledActionAsksNoTarget() async throws {
        let (h, t, agent, registry) = try await parkingRig(LockedBox(["ui.at": .ok(sendAt)]))
        _ = try await startRecording(h)
        let asksBefore = await t.agentCalls.count

        let lookup = Latch()
        await registry.park(at: lookup)
        let press = click(190, 112)
        let action = Task { try await h.handle(op: "vm.mouse.click", params: press) }
        let parked = await eventually { await lookup.arrivals == 1 }
        XCTAssertTrue(parked)
        action.cancel()
        await registry.park(at: nil)
        await lookup.open()
        do { _ = try await value(of: action); XCTFail("the cancelled click succeeded") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let asksAfter = await t.agentCalls.count
        XCTAssertEqual(asksAfter, asksBefore)
        XCTAssertTrue(agentRequests(agent, "ui.at").isEmpty)
        let free = try await h.helperGate.acquire("Win", until: .now)
        XCTAssertTrue(free)
        await h.helperGate.release("Win")
    }

    func testAnAgentThatDoesNotKnowTheTargetOpIsAskedOncePerConnection() async throws {
        let (h, t, agent) = try await rig(LockedBox([:]))
        let dir = try await startRecording(h)
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        _ = try await h.handle(op: "vm.type", params: ["name": "Win", "text": "a"])
        XCTAssertEqual(agentRequests(agent, "ui.at").map(fields), [["x": 190, "y": 112, "budgetMs": 200]])

        let (_, other, newerAgent) = try await rig(LockedBox(["ui.at": .ok(sendAt)]))
        await t.setAgent(await other.agentClient)
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(agentRequests(newerAgent, "ui.at").count, 1)
        XCTAssertEqual(agentRequests(agent, "ui.at").count, 1)
        XCTAssertEqual(try lines(dir).map { $0["target"] }, [nil, nil, nil, sendTarget])
    }

    func testAnUnknownOpAnswerThatComesLateIsRemembered() async throws {
        UITiming.targetBudget = .seconds(600)
        let budget = Latch()
        UITiming.factBudgetEnd = { _ in await budget.pass() }
        let (h, t, agent, _) = try await parkingRig(LockedBox<[String: Reply]>(["ui.at": .silent]))
        let dir = try await startRecording(h)
        let press = click(190, 112)
        let first = Task { try await h.handle(op: "vm.mouse.click", params: press) }
        let asked = await eventually { await budget.arrivals == 1 }
        XCTAssertTrue(asked)
        await budget.open()
        _ = try await value(of: first)
        let request = try XCTUnwrap(agentRequests(agent, "ui.at").first)
        agent.sendLine(["t": "res", "id": request["id"] ?? .null, "ok": false, "error": "unknown op 'ui.at'; update alcove-agent"])
        let free = await eventually { (try? await h.helperGate.acquire("Win", until: .now)) == true }
        XCTAssertTrue(free)
        await h.helperGate.release("Win")

        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        _ = try await h.handle(op: "vm.type", params: ["name": "Win", "text": "a"])
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(agentRequests(agent, "ui.at").count, 1)
        XCTAssertEqual(try lines(dir).map { $0["target"] }, [nil, nil, nil])
        let sent = await t.sent
        XCTAssertFalse(sent.isEmpty)
    }

    func testTextKeysAreMaskedByTheElementTheyAreAimedAt() async throws {
        let secretAt = at("Edit", "", id: "pw", flags: ["enabled", "focused", "password"], byID: (1, 0))
        let userAt = at("Edit", "User", id: "user", byID: (1, 0), byName: (1, 0))
        let focused = LockedBox(userAt)
        let answers = LockedBox<[String: Reply]>(["ui.at": .by { _ in .ok(focused.value) }])
        let (h, _, agent) = try await rig(answers)
        let dir = try await startRecording(h)
        func press(_ keys: String) async throws { _ = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": .string(keys)]) }
        func key(_ op: String, _ key: String) async throws { _ = try await h.handle(op: op, params: ["name": "Win", "key": .string(key)]) }
        try await press("q")
        focused.value = secretAt
        _ = try await h.handle(op: "vm.type", params: ["name": "Win", "text": "hunter2"])
        try await press("a")
        try await key("vm.key.down", "B")
        try await key("vm.key.up", "B")
        try await press("shift+c")
        try await press(" ")
        try await press("enter")
        try await press("ctrl+a")
        try await press("tab")
        try await key("vm.key.down", "ctrl")
        focused.value = userAt
        try await press("y")
        _ = try await h.handle(op: "vm.type", params: ["name": "Win", "text": "bob"])
        try await key("vm.key.down", "z")
        try await key("vm.key.up", "z")
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])

        XCTAssertEqual(agentRequests(agent, "ui.at").map(fields), Array(repeating: ["focused": true, "budgetMs": 200], count: 9))
        let rows = try lines(dir)
        XCTAssertEqual(rows.map { $0["params"]?["keys"] ?? $0["params"]?["key"] ?? $0["params"]?["text"] },
                       ["q", "<masked>", "<masked>", "<masked>", "<masked>", "<masked>", "<masked>", "enter", "ctrl+a", "tab", "ctrl", "y", "bob", "z", "z"])
        XCTAssertEqual(rows.map { $0["target"]?["password"] }, [nil, true, true, true, nil, true, true, nil, nil, nil, nil, nil, nil, nil, nil])
        let trace = try String(contentsOf: dir.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        XCTAssertFalse(trace.contains("hunter2"))

        let out = try tempDir().appendingPathComponent("flow.json")
        let saved = try await h.handle(op: "script.save", params: ["dir": .string(dir.path), "path": .string(out.path)])
        let script = try Script.parse(try Data(contentsOf: out))
        XCTAssertEqual(script.steps.map { $0.params["keys"] ?? $0.params["key"] ?? $0.params["text"] },
                       ["q", "${password}", "enter", "ctrl+a", "tab", "ctrl", "y", "bob", "z", "z"])
        let leftOut = "step 3 pressed keys in a password field; type the password with vm.type and a variable instead"
        XCTAssertEqual(saved["warnings"]?.arrayValue?.filter { $0.stringValue?.contains("pressed keys") == true }, [.string(leftOut)])
    }

    func testTextKeys() {
        for keys in ["a", "Z", "7", "+", " ", "é", "shift+a", "Shift+shift+a", "shift+ ", "shift++"] { XCTAssertTrue(ControlHandler.isTextKey(keys), keys) }
        for keys in ["", "ab", "enter", "tab", "ctrl+a", "alt+a", "shift+ctrl+a", "shift+", "shift", "ctrl", "\n", "\t", "space", "shift+enter"] {
            XCTAssertFalse(ControlHandler.isTextKey(keys), keys)
        }
    }

    func testAFailedTargetQuestionIsAskedAgain() async throws {
        let answers = LockedBox<[String: Reply]>(["ui.at": .fail("no element at (190, 112); take a screenshot to see what is there")])
        let (h, _, agent) = try await rig(answers)
        let dir = try await startRecording(h)
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        answers.value["ui.at"] = .fail("no element at (190, 112): the app did not answer within 250 ms; retry")
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        answers.value["ui.at"] = .ok(sendAt)
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(agentRequests(agent, "ui.at").count, 3)
        XCTAssertEqual(try lines(dir).map { $0["target"] }, [nil, nil, sendTarget])
    }

    func testNoTargetQuestionWithoutTheUICapabilityOrAConnectedAgent() async throws {
        let answers = LockedBox<[String: Reply]>(["ui.at": .ok(sendAt)])
        let (plain, _, plainAgent) = try await rig(caps: ["clipboard", "files", "exec"], answers)
        let plainDir = try await startRecording(plain)
        _ = try await plain.handle(op: "vm.mouse.click", params: click(190, 112))
        _ = try await plain.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertTrue(agentRequests(plainAgent, "ui.at").isEmpty)
        XCTAssertEqual(try lines(plainDir).map { $0["target"] }, [nil])

        let (h, t, agent) = try await rig(answers)
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        XCTAssertTrue(agentRequests(agent, "ui.at").isEmpty)
        await t.setLinkState(.connecting)
        let dir = try await startRecording(h)
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        await t.setLinkState(.notConnected)
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        let waits = await t.agentTimeouts
        XCTAssertEqual(waits, [])
        await t.setLinkState(nil)
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(agentRequests(agent, "ui.at").count, 1)
        XCTAssertEqual(try lines(dir).map { $0["target"] }, [nil, nil, sendTarget])
    }

    func testARecordedActionLooksItsVMUpOnce() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 64, height: 64))
        let registry = ParkingRegistry(t)
        let h = ControlHandler(registry: registry, hostKind: "test", captureDirectory: scratchCaptureDirectory)
        _ = try await startRecording(h)
        for (op, params) in [("vm.mouse.click", click(5, 5)), ("vm.type", ["name": "Win", "text": "a"]), ("vm.key.press", ["name": "Win", "keys": "a"])] {
            let before = await registry.lookups
            _ = try await h.handle(op: op, params: params)
            let after = await registry.lookups
            XCTAssertEqual(after - before, 1, op)
        }
    }
}

private extension ControlHandler {
    /// The event baseline of `vm` and the position up to which its observations have reported events.
    func eventPositions(_ vm: String) -> (baseline: Int?, observed: Int?) {
        (eventBaseline[vm]?.seq, observedEvents[vm]?.seq)
    }
}

/// A registry of one VM that counts its lookups and holds each lookup at a latch while one is set.
private actor ParkingRegistry: VMRegistry {
    private let only: FakeTarget
    private var latch: Latch?
    private(set) var lookups = 0
    init(_ target: FakeTarget) { only = target }
    func park(at latch: Latch?) { self.latch = latch }
    func names() async -> [String] { [only.name] }
    func target(named name: String) async -> VMTarget? {
        lookups += 1
        if let latch { await latch.pass() }
        return name == only.name ? only : nil
    }
}
