import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveDisplayProtocol
import AlcoveTestSupport

/// What a scripted agent op answers: result fields, an error sentence, or nothing.
private enum Answer {
    case ok([String: JSON])
    case fail(String)
    case silent
}

/// Per agent op: the answer to a request, given the request and how many requests of that op came before it.
private typealias Script = [String: @Sendable (JSON, Int) -> Answer]

/// The agent reply lines for `m` under `script`; an op outside the script answers the agent's unknown-op error.
private func scripted(_ script: Script, _ counts: LockedBox<[String: Int]>, _ m: JSON) -> [JSON] {
    guard m["t"]?.stringValue == "req", let op = m["op"]?.stringValue else { return [] }
    var seen = counts.value
    let n = seen[op] ?? 0
    seen[op] = n + 1
    counts.value = seen
    guard let answer = script[op] else {
        return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": .string("unknown op '\(op)'; update alcove-agent")]]
    }
    switch answer(m, n) {
    case .ok(let fields): return [agentReply(m, fields)]
    case .fail(let message): return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": .string(message)]]
    case .silent: return []
    }
}

private func node(_ ref: String, _ role: String, _ name: String, depth: Int = 0, x: Int = 0, y: Int = 0, w: Int = 10, h: Int = 10,
                  flags: [String] = [], value: String? = nil) -> JSON {
    var o: [String: JSON] = ["ref": .string(ref), "depth": .int(Int64(depth)), "role": .string(role), "name": .string(name),
                             "x": .int(Int64(x)), "y": .int(Int64(y)), "w": .int(Int64(w)), "h": .int(Int64(h)),
                             "flags": .array(flags.map(JSON.string))]
    if let value { o["value"] = .string(value) }
    return .object(o)
}

private func window(_ id: String, _ title: String, x: Int, y: Int, w: Int, h: Int, foreground: Bool = false, state: String = "normal") -> JSON {
    ["id": .string(id), "title": .string(title), "pid": 4242, "process": "alcove-fixture.exe", "class": "AlcoveFixture",
     "x": .int(Int64(x)), "y": .int(Int64(y)), "w": .int(Int64(w)), "h": .int(Int64(h)), "state": .string(state),
     "foreground": .bool(foreground), "responding": true, "modal": false]
}

private let fixtureWindow = window("0x2a", "Alcove Fixture", x: 100, y: 50, w: 400, h: 300, foreground: true)
private let notesWindow = window("0x3b", "메모 \"초안\" - Notepad", x: 300, y: 200, w: 320, h: 240)
private let sendButton = node("e5", "Button", "Send", depth: 1, x: 150, y: 100, w: 80, h: 24)
private let messageEdit = node("e4", "Edit", "Message", depth: 1, x: 150, y: 60, w: 200, h: 24, flags: ["focused"], value: "안녕 \"fixture\"")

private let noUISentence = "UI Automation is only available on Windows guests with current guest tools; update alcove-agent in 'Win'"

/// A registry of one VM whose target can be replaced.
private actor SwapRegistry: VMRegistry {
    private var current: FakeTarget
    init(_ target: FakeTarget) { current = target }
    func names() async -> [String] { [current.name] }
    func target(named name: String) async -> VMTarget? { name == current.name ? current : nil }
    func swap(_ target: FakeTarget) { current = target }
}

final class ControlUITests: XCTestCase {
    override func setUp() {
        WaitTiming.tick = .milliseconds(20)
        WaitTiming.agentPeriod = .milliseconds(40)
        WaitTiming.agentCallTimeout = .seconds(10)
        UITiming.focusDelay = .milliseconds(5)
        UITiming.processPoll = .milliseconds(20)
    }

    override func tearDown() {
        WaitTiming.tick = .milliseconds(250)
        WaitTiming.agentPeriod = .milliseconds(500)
        WaitTiming.agentCallTimeout = .seconds(5)
        UITiming.focusDelay = .milliseconds(120)
        UITiming.processPoll = .milliseconds(200)
        UITiming.processExitTimeout = .seconds(5)
    }

    /// A running 800x600 VM "Win" whose agent offers `caps` and answers from `script`.
    private func rig(caps: [String] = ["clipboard", "files", "exec", "ui"], _ script: Script = [:]) async throws -> (ControlHandler, FakeTarget, FakeAgent) {
        let agent = FakeAgent()
        agent.caps = caps
        let counts = LockedBox<[String: Int]>([:])
        agent.handler = { m, _ in scripted(script, counts, m) }
        let (h, t) = try await handlerWithAgent(agent, in: self)
        return (h, t, agent)
    }

    private func failure(_ h: ControlHandler, _ op: String, _ params: JSON, file: StaticString = #filePath, line: UInt = #line) async -> String {
        do { _ = try await h.handle(op: op, params: params); XCTFail("\(op) succeeded", file: file, line: line); return "" }
        catch let e as ControlHandler.ControlError { return e.description }
        catch { XCTFail("\(op) threw \(error)", file: file, line: line); return "" }
    }

    /// The request fields of `m` without the transport fields.
    private func fields(_ m: JSON?) -> [String: JSON] {
        var o = m?.objectValue ?? [:]
        for key in ["t", "id", "op"] { o[key] = nil }
        return o
    }

    private func absolute(_ x: Int, _ y: Int) -> ToQEMU {
        .abs(con: 0, x: Int((Double(x) / 799 * Double(ToQEMU.absoluteMax)).rounded()),
             y: Int((Double(y) / 599 * Double(ToQEMU.absoluteMax)).rounded()))
    }

    private func keys(_ sent: [ToQEMU]) -> [String] {
        sent.compactMap { if case .key(let mac, _, let down) = $0 { return "\(mac ?? -1)\(down ? "d" : "u")" }; return nil }
    }

    private func keys(_ sequence: [(code: Int, down: Bool)]) -> [String] {
        sequence.map { "\($0.code)\($0.down ? "d" : "u")" }
    }

    private func tempDir(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("control-ui-" + UUID().uuidString).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    // MARK: - tree text

    func testUITreeTextRendering() {
        let nodes: [JSON] = [
            node("e1", "Window", "Alcove Fixture", x: 100, y: 50, w: 400, h: 300),
            messageEdit,
            node("e6", "CheckBox", "줄 바꿈\n\"quoted\" \\ tab\t", depth: 2, x: -5, y: 7, w: 12, h: 13, flags: ["checked", "disabled"]),
            ["ref": "e9", "depth": 1, "role": "Text", "name": ""],
        ]
        XCTAssertEqual(UITreeText.render(nodes), """
        [e1] Window "Alcove Fixture" (100,50 400x300)
          [e4] Edit "Message" (150,60 200x24) focused value="안녕 \\"fixture\\""
            [e6] CheckBox "줄 바꿈\\n\\"quoted\\" \\\\ tab\\t" (-5,7 12x13) checked disabled
          [e9] Text ""
        """)
        XCTAssertEqual(UITreeText.render([]), "")
    }

    // MARK: - windows

    func testWindowListAndAction() async throws {
        let moved = window("0x2a", "Alcove Fixture", x: 40, y: 30, w: 400, h: 300, foreground: true)
        let (h, _, agent) = try await rig([
            "win.list": { _, _ in .ok(["windows": [fixtureWindow, notesWindow]]) },
            "win.action": { _, _ in .ok(["window": moved]) },
        ])
        let list = try await h.handle(op: "vm.window.list", params: ["name": "Win"])
        XCTAssertEqual(list, ["windows": [fixtureWindow, notesWindow]])
        XCTAssertEqual(fields(agentRequests(agent, "win.list").first), [:])

        let move = try await h.handle(op: "vm.window.action", params: ["name": "Win", "window": "Alcove", "action": "move", "x": 40, "y": 30,
                                                                         "width": 9, "height": 9])
        XCTAssertEqual(move, ["window": moved])
        XCTAssertEqual(fields(agentRequests(agent, "win.action").last), ["window": "Alcove", "action": "move", "x": 40, "y": 30])

        _ = try await h.handle(op: "vm.window.action", params: ["name": "Win", "window": "0x2a", "action": "resize", "width": 640, "height": 480, "x": 1])
        XCTAssertEqual(fields(agentRequests(agent, "win.action").last), ["window": "0x2a", "action": "resize", "w": 640, "h": 480])

        _ = try await h.handle(op: "vm.window.action", params: ["name": "Win", "window": "foreground", "action": "close", "x": 3, "y": 4])
        XCTAssertEqual(fields(agentRequests(agent, "win.action").last), ["window": "foreground", "action": "close"])

        let observed = try await h.handle(op: "vm.window.action", params: ["name": "Win", "window": "0x2a", "action": "focus",
                                                                             "observe": "summary", "settleMs": 20])
        XCTAssertEqual(observed["window"], moved)
        XCTAssertEqual(observed["observation"]?["settled"]?.boolValue, true)

        let sentBefore = agentRequests(agent, "win.action").count
        let cases: [(JSON, String)] = [
            (["name": "Win", "action": "focus"], "missing or invalid parameter 'window'"),
            (["name": "Win", "window": "0x2a", "action": "shake"], "action must be one of focus, minimize, maximize, restore, close, move, resize"),
            (["name": "Win", "window": "0x2a"], "action must be one of focus, minimize, maximize, restore, close, move, resize"),
            (["name": "Win", "window": "0x2a", "action": "move", "x": 4], "move needs integer 'x' and 'y' in guest pixels"),
            (["name": "Win", "window": "0x2a", "action": "resize", "width": 0, "height": 10], "resize needs integer 'width' and 'height' above 0 in guest pixels"),
        ]
        for (params, expected) in cases {
            let text = await failure(h, "vm.window.action", params)
            XCTAssertEqual(text, expected)
        }
        XCTAssertEqual(agentRequests(agent, "win.action").count, sentBefore)
    }

    // MARK: - tree, find, text

    func testUITreeOp() async throws {
        let nodes: [JSON] = [node("e1", "Window", "Alcove Fixture", x: 100, y: 50, w: 400, h: 300), messageEdit, sendButton]
        let (h, _, agent) = try await rig(["ui.tree": { _, _ in .ok(["window": fixtureWindow, "nodes": .array(nodes), "truncated": true]) }])
        let r = try await h.handle(op: "vm.ui.tree", params: ["name": "Win", "window": "Alcove", "root": "e1", "depth": 3, "max": 3, "filter": "all"])
        XCTAssertEqual(r, ["tree": .string(UITreeText.render(nodes)), "count": 3, "truncated": true, "window": fixtureWindow])
        XCTAssertEqual(fields(agentRequests(agent, "ui.tree").last), ["window": "Alcove", "root": "e1", "depth": 3, "max": 3, "filter": "all"])

        _ = try await h.handle(op: "vm.ui.tree", params: ["name": "Win"])
        XCTAssertEqual(fields(agentRequests(agent, "ui.tree").last), [:])

        let cases: [(JSON, String)] = [
            (["name": "Win", "filter": "some"], "filter must be 'interactive' or 'all'"),
            (["name": "Win", "max": 2001], "max must be between 1 and 2000"),
            (["name": "Win", "max": 0], "max must be between 1 and 2000"),
            (["name": "Win", "depth": -1], "depth must be 0 or more"),
            (["name": "Win", "depth": "deep"], "parameter 'depth' must be an integer"),
            (["name": "Win", "root": 4], "missing or invalid parameter 'root'"),
        ]
        for (params, expected) in cases {
            let text = await failure(h, "vm.ui.tree", params)
            XCTAssertEqual(text, expected)
        }
        XCTAssertEqual(agentRequests(agent, "ui.tree").count, 2)
    }

    func testUIFindOp() async throws {
        let (h, _, agent) = try await rig([
            "ui.find": { _, _ in .ok(["nodes": [sendButton, messageEdit]]) },
            "ui.rect": { _, _ in .ok(["node": sendButton, "cx": 190, "cy": 112, "clickable": true]) },
        ])
        let selector: JSON = ["window": "Alcove", "role": "button", "name": "Send \"now\"", "nameContains": "en", "automationId": "send-1", "index": 1]
        let r = try await h.handle(op: "vm.ui.find", params: ["name": "Win", "selector": selector, "limit": 5])
        XCTAssertEqual(r, ["nodes": [sendButton, messageEdit], "text": .string(UITreeText.render([sendButton, messageEdit]))])
        XCTAssertEqual(fields(agentRequests(agent, "ui.find").last),
                       ["window": "Alcove", "role": "button", "name": "Send \"now\"", "nameContains": "en", "automationId": "send-1", "index": 1, "limit": 5])

        let byRef = try await h.handle(op: "vm.ui.find", params: ["name": "Win", "ref": "e5"])
        XCTAssertEqual(byRef, ["nodes": [sendButton], "text": .string(UITreeText.render([sendButton]))])
        XCTAssertEqual(fields(agentRequests(agent, "ui.rect").last), ["ref": "e5"])
        XCTAssertEqual(agentRequests(agent, "ui.find").count, 1)
    }

    func testSelectorValidation() async throws {
        let (h, _, agent) = try await rig()
        let cases: [(JSON, String)] = [
            (["name": "Win"], "pass ref or selector"),
            (["name": "Win", "ref": "e5", "selector": ["role": "Button"]], "pass ref or selector, not both"),
            (["name": "Win", "ref": "5"], "ref must be an element ref such as e12; take one from vm.ui.tree or vm.ui.find"),
            (["name": "Win", "ref": 5], "ref must be an element ref such as e12; take one from vm.ui.tree or vm.ui.find"),
            (["name": "Win", "selector": "Send"], "selector must be an object with window, role, name, nameContains, automationId or index"),
            (["name": "Win", "selector": ["role": "Button", "title": "x"]],
             "selector has no field 'title'; valid fields: window, role, name, nameContains, automationId, index"),
            (["name": "Win", "selector": ["role": 3]], "selector field 'role' must be a string"),
            (["name": "Win", "selector": ["role": "Button", "index": -1]], "selector field 'index' must be an integer of 0 or more"),
            (["name": "Win", "selector": ["window": "Alcove", "index": 2]], "selector needs at least one of role, name, nameContains, automationId"),
        ]
        for op in ["vm.ui.find", "vm.ui.text", "vm.ui.click", "vm.ui.type", "vm.ui.action"] {
            for (params, expected) in cases {
                var all = params.objectValue ?? [:]
                all["text"] = "x"
                all["action"] = "invoke"
                let text = await failure(h, op, .object(all))
                XCTAssertEqual(text, expected, op)
            }
        }
        XCTAssertTrue(agent.received.filter { $0["t"]?.stringValue == "req" }.isEmpty)
    }

    func testUITextPaging() async throws {
        let (h, _, agent) = try await rig(["ui.text": { m, _ in
            .ok(["text": .string(m["offset"] == nil ? "first line\n둘째 줄 \"quoted\"" : "line"), "total": 24, "source": "text"])
        }])
        let whole = try await h.handle(op: "vm.ui.text", params: ["name": "Win", "ref": "e4"])
        XCTAssertEqual(whole, ["text": "first line\n둘째 줄 \"quoted\"", "total": 24, "source": "text"])
        XCTAssertEqual(fields(agentRequests(agent, "ui.text").last), ["ref": "e4"])

        let part = try await h.handle(op: "vm.ui.text", params: ["name": "Win", "selector": ["role": "Edit", "name": "Transcript"],
                                                                   "mode": "pattern", "offset": 6, "length": 4])
        XCTAssertEqual(part, ["text": "line", "total": 24, "source": "text"])
        XCTAssertEqual(fields(agentRequests(agent, "ui.text").last), ["role": "Edit", "name": "Transcript", "mode": "pattern", "offset": 6, "length": 4])

        let cases: [(JSON, String)] = [
            (["name": "Win", "ref": "e4", "mode": "fast"], "mode must be one of auto, pattern, descendants"),
            (["name": "Win", "ref": "e4", "offset": -1], "offset must be 0 or more"),
            (["name": "Win", "ref": "e4", "length": 0], "length must be between 1 and 200000"),
            (["name": "Win", "ref": "e4", "length": 200_001], "length must be between 1 and 200000"),
        ]
        for (params, expected) in cases {
            let text = await failure(h, "vm.ui.text", params)
            XCTAssertEqual(text, expected)
        }
        XCTAssertEqual(agentRequests(agent, "ui.text").count, 2)
    }

    // MARK: - click, type, action

    func testUIClickUsesRectCentre() async throws {
        let (h, t, agent) = try await rig(["ui.rect": { _, _ in .ok(["node": sendButton, "cx": 190, "cy": 112, "clickable": true]) }])
        let r = try await h.handle(op: "vm.ui.click", params: ["name": "Win", "selector": ["role": "Button", "name": "Send"]])
        XCTAssertEqual(r, ["x": 190, "y": 112, "node": sendButton])
        XCTAssertEqual(fields(agentRequests(agent, "ui.rect").last), ["role": "Button", "name": "Send", "scroll": true])
        var sent = await t.sent
        XCTAssertEqual(sent, [absolute(190, 112), .btn(con: 0, button: .left, down: true), .sync, .btn(con: 0, button: .left, down: false), .sync])

        let double = try await h.handle(op: "vm.ui.click", params: ["name": "Win", "ref": "e5", "button": "right", "count": 2,
                                                                      "observe": "summary", "settleMs": 20])
        XCTAssertEqual(double["x"]?.intValue, 190)
        XCTAssertEqual(double["node"], sendButton)
        XCTAssertEqual(double["observation"]?["settled"]?.boolValue, true)
        XCTAssertEqual(fields(agentRequests(agent, "ui.rect").last), ["ref": "e5", "scroll": true])
        sent = Array(await t.sent.dropFirst(5))
        XCTAssertEqual(sent, [absolute(190, 112),
                              .btn(con: 0, button: .right, down: true), .sync, .btn(con: 0, button: .right, down: false), .sync,
                              .btn(con: 0, button: .right, down: true), .sync, .btn(con: 0, button: .right, down: false), .sync])

        let badButton = await failure(h, "vm.ui.click", ["name": "Win", "ref": "e5", "button": "fourth"])
        XCTAssertEqual(badButton, "missing or invalid parameter 'button'")
        XCTAssertEqual(agentRequests(agent, "ui.rect").count, 2)
    }

    func testUIClickRefusesOffscreen() async throws {
        let hidden = node("e8", "Button", "Hidden", x: 0, y: 0, w: 0, h: 0, flags: ["offscreen"])
        let (h, t, agent) = try await rig(["ui.rect": { m, _ in
            m["ref"]?.stringValue == "e3" ? .fail("element e3 no longer exists; call ui.tree again")
                : .ok(["node": hidden, "cx": 0, "cy": 0, "clickable": false])
        }])
        let text = await failure(h, "vm.ui.click", ["name": "Win", "ref": "e8", "observe": "summary", "settleMs": 20])
        XCTAssertEqual(text, "element e8 has no clickable point (off screen or covered); use vm.ui.action or scroll it into view")
        XCTAssertEqual(agentRequests(agent, "ui.rect").last?["scroll"]?.boolValue, true)

        let typed = await failure(h, "vm.ui.type", ["name": "Win", "selector": ["name": "Hidden"], "text": "x"])
        XCTAssertEqual(typed, "element e8 has no clickable point (off screen or covered); use vm.ui.action or scroll it into view")

        let stale = await failure(h, "vm.ui.click", ["name": "Win", "ref": "e3"])
        XCTAssertEqual(stale, "element e3 no longer exists; call ui.tree again")
        let sent = await t.sent
        XCTAssertEqual(sent, [])
    }

    func testUITypeClearsAndSubmits() async throws {
        let (h, t, agent) = try await rig(["ui.rect": { _, _ in .ok(["node": messageEdit, "cx": 250, "cy": 72, "clickable": true]) }])
        let r = try await h.handle(op: "vm.ui.type", params: ["name": "Win", "selector": ["role": "Edit", "name": "Message"],
                                                                "text": "Hi 1", "clear": true, "submit": true])
        XCTAssertEqual(r, ["node": messageEdit])
        XCTAssertEqual(fields(agentRequests(agent, "ui.rect").last), ["role": "Edit", "name": "Message", "scroll": true])
        var sent = await t.sent
        XCTAssertEqual(Array(sent.prefix(5)), [absolute(250, 72), .btn(con: 0, button: .left, down: true), .sync,
                                               .btn(con: 0, button: .left, down: false), .sync])
        let expected = try keys(KeyNames.pressSequence("ctrl+a")) + keys(KeyNames.typeSequence("Hi 1")) + keys(KeyNames.pressSequence("enter"))
        XCTAssertEqual(keys(Array(sent.dropFirst(5))), expected)
        XCTAssertEqual(sent.count, 5 + expected.count)

        let before = sent.count
        _ = try await h.handle(op: "vm.ui.type", params: ["name": "Win", "ref": "e4", "text": "ab"])
        sent = Array(await t.sent.dropFirst(before))
        XCTAssertEqual(keys(sent), try keys(KeyNames.typeSequence("ab")))

        let emptied = await t.sent.count
        _ = try await h.handle(op: "vm.ui.type", params: ["name": "Win", "ref": "e4", "text": "", "clear": true])
        sent = Array(await t.sent.dropFirst(emptied))
        XCTAssertEqual(keys(sent), try keys(KeyNames.pressSequence("ctrl+a")) + keys(KeyNames.pressSequence("backspace")))

        let rects = agentRequests(agent, "ui.rect").count
        let missing = await failure(h, "vm.ui.type", ["name": "Win", "ref": "e4"])
        XCTAssertEqual(missing, "missing or invalid parameter 'text'")
        XCTAssertEqual(agentRequests(agent, "ui.rect").count, rects)
    }

    func testUITypePastesTextOutsideTheUSLayout() async throws {
        let (h, t, agent) = try await rig(["ui.rect": { _, _ in .ok(["node": messageEdit, "cx": 250, "cy": 72, "clickable": true]) }])
        _ = try await h.handle(op: "vm.ui.type", params: ["name": "Win", "ref": "e4", "text": "스트리밍 \"테스트\" 1"])
        let clipboard = agent.received.first { $0["t"]?.stringValue == "clipboard.set" }
        XCTAssertEqual(clipboard?["text"]?.stringValue, "스트리밍 \"테스트\" 1")
        let sent = await t.sent
        XCTAssertEqual(keys(Array(sent.dropFirst(5))), try keys(KeyNames.pressSequence("ctrl+v")))
    }

    func testUIActionPassesValue() async throws {
        let after = node("e4", "Edit", "Message", depth: 1, x: 150, y: 60, w: 200, h: 24, value: "새 값 \"x\"")
        let (h, t, agent) = try await rig(["ui.act": { _, _ in .ok(["node": after]) }])
        let r = try await h.handle(op: "vm.ui.action", params: ["name": "Win", "selector": ["role": "Edit", "name": "Message"],
                                                                  "action": "set_value", "value": "새 값 \"x\""])
        XCTAssertEqual(r, ["node": after])
        XCTAssertEqual(fields(agentRequests(agent, "ui.act").last), ["role": "Edit", "name": "Message", "action": "set_value", "value": "새 값 \"x\""])

        let invoked = try await h.handle(op: "vm.ui.action", params: ["name": "Win", "ref": "e5", "action": "invoke", "observe": "summary", "settleMs": 20])
        XCTAssertEqual(invoked["node"], after)
        XCTAssertEqual(invoked["observation"]?["settled"]?.boolValue, true)
        XCTAssertEqual(fields(agentRequests(agent, "ui.act").last), ["ref": "e5", "action": "invoke"])

        let cases: [(JSON, String)] = [
            (["name": "Win", "ref": "e5", "action": "press"], "action must be one of invoke, toggle, expand, collapse, select, set_value, focus, scroll_into_view"),
            (["name": "Win", "ref": "e5"], "action must be one of invoke, toggle, expand, collapse, select, set_value, focus, scroll_into_view"),
            (["name": "Win", "ref": "e5", "action": "set_value"], "set_value needs a string 'value'; pass the new text"),
            (["name": "Win", "ref": "e5", "action": "invoke", "value": 3], "missing or invalid parameter 'value'"),
        ]
        for (params, expected) in cases {
            let text = await failure(h, "vm.ui.action", params)
            XCTAssertEqual(text, expected)
        }
        XCTAssertEqual(agentRequests(agent, "ui.act").count, 2)
        let sent = await t.sent
        XCTAssertEqual(sent, [])
    }

    func testActionWhoseScreenCannotBeReadAfterwardsReportsObservationError() async throws {
        let (h, t, _) = try await rig(["ui.act": { _, _ in .ok(["node": sendButton]) }])
        await t.setFrames([Frame(png: makePNG(width: 64, height: 64))!])
        await t.setFailingFrameCalls([1])
        let r = try await h.handle(op: "vm.ui.action", params: ["name": "Win", "ref": "e5", "action": "invoke", "observe": "summary", "settleMs": 20])
        XCTAssertEqual(r, ["node": sendButton,
                           "observationError": "the screen could not be read after vm.ui.action: no surface is mapped; call vm.screenshot to see the result"])
    }

    // MARK: - launch

    func testAppLaunch() async throws {
        let (h, _, agent) = try await rig(["app.launch": { m, n in
            n == 0 ? .ok(["pid": 77, "window": fixtureWindow]) : m["path"]?.stringValue == "C:\\missing.exe"
                ? .fail("'C:\\missing.exe' does not exist in the guest; check the path") : .ok(["pid": 78])
        }])
        let r = try await h.handle(op: "vm.app.launch", params: [
            "name": "Win", "path": "C:\\앱 폴더\\app.exe", "args": ["--log", "C:\\logs\\x y.log"], "cwd": "C:\\앱 폴더",
            "env": ["MODE": "test"], "waitWindow": 2.5,
        ])
        XCTAssertEqual(r, ["pid": 77, "window": fixtureWindow])
        XCTAssertEqual(fields(agentRequests(agent, "app.launch").last), [
            "path": "C:\\앱 폴더\\app.exe", "args": ["--log", "C:\\logs\\x y.log"], "cwd": "C:\\앱 폴더", "env": ["MODE": "test"],
            "wait_window_ms": 2500,
        ])

        let plain = try await h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "notepad.exe"])
        XCTAssertEqual(plain, ["pid": 78])
        XCTAssertEqual(fields(agentRequests(agent, "app.launch").last), ["path": "notepad.exe", "wait_window_ms": 15000])

        _ = try await h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "notepad.exe", "waitWindow": 0])
        XCTAssertEqual(agentRequests(agent, "app.launch").last?["wait_window_ms"]?.intValue, 0)

        let missing = await failure(h, "vm.app.launch", ["name": "Win", "path": "C:\\missing.exe"])
        XCTAssertEqual(missing, "'C:\\missing.exe' does not exist in the guest; check the path")

        let sentBefore = agentRequests(agent, "app.launch").count
        let cases: [(JSON, String)] = [
            (["name": "Win"], "missing or invalid parameter 'path'"),
            (["name": "Win", "path": "a.exe", "args": "--x"], "missing or invalid parameter 'args'"),
            (["name": "Win", "path": "a.exe", "env": ["A": 1]], "missing or invalid parameter 'env'"),
            (["name": "Win", "path": "a.exe", "waitWindow": 301], "waitWindow must be between 0 and 300 seconds"),
            (["name": "Win", "path": "a.exe", "waitWindow": -1], "waitWindow must be between 0 and 300 seconds"),
            (["name": "Win", "path": "a.exe", "waitWindow": "long"], "waitWindow must be between 0 and 300 seconds"),
        ]
        for (params, expected) in cases {
            let text = await failure(h, "vm.app.launch", params)
            XCTAssertEqual(text, expected)
        }
        XCTAssertEqual(agentRequests(agent, "app.launch").count, sentBefore)
    }

    // MARK: - deploy

    /// A running VM "Win" whose agent serves `fs` and answers the other ops from `script`.
    private func deployRig(fs: FakeFS, _ script: Script) async throws -> (ControlHandler, FakeAgent) {
        let agent = FakeAgent()
        fs.caseInsensitive = true
        fs.install(on: agent)
        let files = agent.handler
        let counts = LockedBox<[String: Int]>([:])
        agent.handler = { m, a in
            if let op = m["op"]?.stringValue, script[op] != nil { return scripted(script, counts, m) }
            return files?(m, a) ?? []
        }
        let (h, _) = try await handlerWithAgent(agent, in: self)
        return (h, agent)
    }

    private func index(of op: String, in agent: FakeAgent) -> Int? {
        agent.received.firstIndex { $0["op"]?.stringValue == op }
    }

    func testDeployDirectorySyncsThenLaunches() async throws {
        let dir = try tempDir("앱 build")
        try Data("new exe".utf8).write(to: dir.appendingPathComponent("app.exe"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("data"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("data/설정.json"))

        let guestDir = "C:\\alcove-apps\\앱 build"
        let fs = FakeFS()
        fs[guestDir + "\\app.exe"] = Data("old exe".utf8)
        fs[guestDir + "\\old.dll"] = Data("stale".utf8)
        let killed = LockedBox<[Int]>([])
        let running: [JSON] = [
            ["pid": 10, "ppid": 1, "name": "app.exe", "path": "c:\\ALCOVE-APPS\\앱 BUILD\\app.exe"],
            ["pid": 11, "ppid": 1, "name": "x.exe", "path": "C:\\alcove-apps\\앱 build-2\\x.exe"],
            ["pid": 12, "ppid": 0, "name": "System", "path": ""],
        ]
        let (h, agent) = try await deployRig(fs: fs, [
            "proc.list": { _, _ in .ok(["procs": .array(running.filter { !killed.value.contains($0["pid"]?.intValue ?? 0) })]) },
            "proc.kill": { m, _ in killed.value = killed.value + [m["pid"]?.intValue ?? 0]; return .ok(["killed": 1]) },
            "app.launch": { _, n in .ok(["pid": .int(Int64(77 + n)), "window": fixtureWindow]) },
        ])
        let launch: JSON = ["exe": "app.exe", "args": ["--log", "C:\\logs\\x y.log"], "env": ["MODE": "test"]]
        let r = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path), "launch": launch])
        XCTAssertEqual(r, ["guestDir": .string(guestDir), "sent": ["app.exe", "data/설정.json"], "skipped": 0, "bytes": 9,
                           "pid": 77, "window": fixtureWindow])
        XCTAssertEqual(fs[guestDir + "\\app.exe"], Data("new exe".utf8))
        XCTAssertEqual(fs[guestDir + "\\data\\설정.json"], Data("{}".utf8))
        XCTAssertNil(fs[guestDir + "\\old.dll"])

        XCTAssertEqual(killed.value, [10])
        XCTAssertEqual(fields(agentRequests(agent, "proc.kill").first), ["pid": 10, "tree": true])
        XCTAssertEqual(fields(agentRequests(agent, "app.launch").first), [
            "path": .string(guestDir + "\\app.exe"), "args": ["--log", "C:\\logs\\x y.log"], "env": ["MODE": "test"],
            "cwd": .string(guestDir), "wait_window_ms": 20000,
        ])
        let kill = try XCTUnwrap(index(of: "proc.kill", in: agent))
        let write = try XCTUnwrap(index(of: "fs.write", in: agent))
        let start = try XCTUnwrap(index(of: "app.launch", in: agent))
        XCTAssertLessThan(try XCTUnwrap(index(of: "proc.list", in: agent)), kill)
        XCTAssertLessThan(kill, write)
        XCTAssertLessThan(write, start)
        XCTAssertNil(index(of: "exec.run", in: agent))

        let again = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path), "launch": launch, "waitWindow": 0,
                                                                   "killRunning": false])
        XCTAssertEqual(again, ["guestDir": .string(guestDir), "sent": [], "skipped": 2, "bytes": 0, "pid": 78, "window": fixtureWindow])
        XCTAssertEqual(agentRequests(agent, "app.launch").last?["wait_window_ms"]?.intValue, 0)
        XCTAssertEqual(agentRequests(agent, "proc.kill").count, 1)
    }

    func testDeployPushesAFileAndResolvesLaunchPaths() async throws {
        let dir = try tempDir("out")
        let file = dir.appendingPathComponent("tool one.exe")
        try Data("binary".utf8).write(to: file)
        let fs = FakeFS()
        fs["D:\\apps\\tool one.exe"] = Data("previous".utf8)
        let (h, agent) = try await deployRig(fs: fs, [
            "proc.list": { _, _ in .ok(["procs": []]) },
            "app.launch": { _, _ in .ok(["pid": 5]) },
        ])
        let r = try await h.handle(op: "vm.deploy", params: [
            "name": "Win", "path": .string(file.path), "guestDir": "D:\\apps\\",
            "launch": ["exe": "C:\\Windows\\notepad.exe", "cwd": "C:\\Users"], "waitWindow": 3,
        ])
        XCTAssertEqual(r, ["guestDir": "D:\\apps", "sent": ["tool one.exe"], "skipped": 0, "bytes": 6, "pid": 5])
        XCTAssertEqual(fs["D:\\apps\\tool one.exe"], Data("binary".utf8))
        XCTAssertEqual(fields(agentRequests(agent, "app.launch").last), ["path": "C:\\Windows\\notepad.exe", "cwd": "C:\\Users", "wait_window_ms": 3000])

        let plain = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(file.path)])
        XCTAssertEqual(plain, ["guestDir": "C:\\alcove-apps\\tool one", "sent": ["tool one.exe"], "skipped": 0, "bytes": 6])
        XCTAssertEqual(fs["C:\\alcove-apps\\tool one\\tool one.exe"], Data("binary".utf8))
        XCTAssertEqual(agentRequests(agent, "app.launch").count, 1)

        let nested = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(file.path), "guestDir": "D:\\apps",
                                                                    "launch": ["exe": "bin/run me.exe"], "killRunning": false])
        XCTAssertEqual(nested["pid"]?.intValue, 5)
        XCTAssertEqual(agentRequests(agent, "app.launch").last?["path"]?.stringValue, "D:\\apps\\bin\\run me.exe")
    }

    func testDeployInstallFailureStops() async throws {
        let dir = try tempDir("installer")
        try Data("msi".utf8).write(to: dir.appendingPathComponent("설치 파일.msi"))
        let code = LockedBox<Int>(1603)
        let (h, agent) = try await deployRig(fs: FakeFS(), [
            "proc.list": { _, _ in .ok(["procs": []]) },
            "exec.run": { _, _ in .ok(["code": .int(Int64(code.value)), "stdout": "", "stderr": "fatal error during installation\r\n", "timed_out": false]) },
            "app.launch": { _, _ in .ok(["pid": 9]) },
        ])
        let params: JSON = ["name": "Win", "path": .string(dir.path), "install": ["kind": "msi", "file": "설치 파일.msi", "args": ["INSTALLDIR=C:\\Program Files\\앱"]],
                            "launch": ["exe": "app.exe"]]
        let text = await failure(h, "vm.deploy", params)
        XCTAssertEqual(text, "installer 'C:\\alcove-apps\\installer\\설치 파일.msi' exited with code 1603: fatal error during installation; "
                       + "fix the installer or its arguments and call vm.deploy again")
        let run = fields(agentRequests(agent, "exec.run").last)
        XCTAssertEqual(run["argv"], ["msiexec.exe", "/i", "C:\\alcove-apps\\installer\\설치 파일.msi", "/qn", "/norestart", "INSTALLDIR=C:\\Program Files\\앱"])
        XCTAssertEqual(run["cwd"], "C:\\alcove-apps\\installer")
        XCTAssertEqual(run["timeout_ms"]?.intValue, 900_000)
        XCTAssertNil(run["cmd"])
        XCTAssertNil(index(of: "app.launch", in: agent))
        XCTAssertLessThan(try XCTUnwrap(index(of: "fs.write", in: agent)), try XCTUnwrap(index(of: "exec.run", in: agent)))

        code.value = 3010
        let restart = try await h.handle(op: "vm.deploy", params: params)
        XCTAssertEqual(restart["installCode"]?.intValue, 3010)
        XCTAssertEqual(restart["pid"]?.intValue, 9)
        XCTAssertLessThan(try XCTUnwrap(agent.received.lastIndex { $0["op"]?.stringValue == "exec.run" }), try XCTUnwrap(index(of: "app.launch", in: agent)))

        code.value = 0
        let exe = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path),
                                                                 "install": ["kind": "exe", "file": "D:\\setup tool.exe", "args": ["/S"]]])
        XCTAssertEqual(exe["installCode"]?.intValue, 0)
        XCTAssertNil(exe["pid"])
        XCTAssertEqual(agentRequests(agent, "exec.run").last?["argv"], ["D:\\setup tool.exe", "/S"])
    }

    func testDeployStopsWhenARunningCopySurvives() async throws {
        UITiming.processExitTimeout = .milliseconds(200)
        let dir = try tempDir("stuck")
        try Data("x".utf8).write(to: dir.appendingPathComponent("app.exe"))
        let fs = FakeFS()
        let (h, agent) = try await deployRig(fs: fs, [
            "proc.list": { _, _ in .ok(["procs": [["pid": 31, "name": "app.exe", "path": "C:\\alcove-apps\\stuck\\app.exe"]]]) },
            "proc.kill": { _, _ in .fail("access denied") },
        ])
        let text = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.path)])
        XCTAssertEqual(text, "app.exe (pid 31) under 'C:\\alcove-apps\\stuck' is still running after vm.deploy tried to stop it; "
                       + "stop it with vm.process.kill or pass another guestDir")
        XCTAssertNil(index(of: "fs.write", in: agent))
        XCTAssertTrue(fs.paths().isEmpty)
    }

    func testDeployValidation() async throws {
        let dir = try tempDir("valid")
        let (h, agent) = try await deployRig(fs: FakeFS(), [:])
        let path = JSON.string(dir.path)
        let cases: [(JSON, String)] = [
            (["name": "Win"], "missing or invalid parameter 'path'"),
            (["name": "Win", "path": "/no/such/build"], "'/no/such/build' does not exist on the host; check the path"),
            (["name": "Win", "path": path, "guestDir": ""], "missing or invalid parameter 'guestDir'"),
            (["name": "Win", "path": path, "killRunning": "yes"], "parameter 'killRunning' must be a boolean"),
            (["name": "Win", "path": path, "waitWindow": 900], "waitWindow must be between 0 and 300 seconds"),
            (["name": "Win", "path": path, "install": ["kind": "zip", "file": "a.zip"]], "install needs kind 'msi' or 'exe' and a string 'file'"),
            (["name": "Win", "path": path, "install": ["kind": "msi"]], "install needs kind 'msi' or 'exe' and a string 'file'"),
            (["name": "Win", "path": path, "install": ["kind": "exe", "file": "a.exe", "args": [1]]], "install.args must be an array of strings"),
            (["name": "Win", "path": path, "launch": ["args": []]], "launch needs a string 'exe'"),
            (["name": "Win", "path": path, "launch": ["exe": "a.exe", "args": "x"]], "launch.args must be an array of strings"),
            (["name": "Win", "path": path, "launch": ["exe": "a.exe", "env": ["A": 1]]], "launch.env must be an object of strings"),
            (["name": "Win", "path": path, "launch": ["exe": "a.exe", "cwd": 1]], "launch.cwd must be a string"),
        ]
        for (params, expected) in cases {
            let text = await failure(h, "vm.deploy", params)
            XCTAssertEqual(text, expected)
        }
        XCTAssertTrue(agent.received.filter { $0["t"]?.stringValue == "req" }.isEmpty)
    }

    func testDeployToAGuestThatIsNotWindowsNeedsGuestDir() async throws {
        let dir = try tempDir("tool")
        try Data("x".utf8).write(to: dir.appendingPathComponent("run.sh"))
        let fs = FakeFS()
        let agent = FakeAgent()
        fs.install(on: agent)
        let files = agent.handler
        agent.handler = { m, a in
            m["op"]?.stringValue == "proc.list" ? [agentReply(m, ["procs": [["pid": 4, "name": "run.sh", "path": "/opt/Tool/run.sh"]]])] : files?(m, a) ?? []
        }
        let (h, t) = try await handlerWithAgent(agent, in: self)
        await t.setOS(.linux)
        let text = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.path)])
        XCTAssertEqual(text, "pass guestDir; the default C:\\alcove-apps\\tool only fits Windows guests")

        let r = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path), "guestDir": "/opt/tool"])
        XCTAssertEqual(r, ["guestDir": "/opt/tool", "sent": ["run.sh"], "skipped": 0, "bytes": 1])
        XCTAssertEqual(fs["/opt/tool/run.sh"], Data("x".utf8))
        XCTAssertTrue(agentRequests(agent, "proc.kill").isEmpty)
    }

    // MARK: - events

    func testEventsOp() async throws {
        let (h, t, agent) = try await rig()
        let empty = try await h.handle(op: "vm.events", params: ["name": "Win"])
        XCTAssertEqual(empty, ["events": [], "next": 0])

        agent.sendLine(["t": "ev", "name": "window.opened", "window": fixtureWindow])
        agent.sendLine(["t": "ev", "name": "process.exited", "pid": 44, "code": 3, "path": "C:\\x.exe"])
        let arrived = await eventually { await t.events(since: 0).next == 2 }
        XCTAssertTrue(arrived)

        let all = try await h.handle(op: "vm.events", params: ["name": "Win"])
        XCTAssertEqual(all["next"]?.intValue, 2)
        let events = all["events"]?.arrayValue ?? []
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.objectValue?.keys.sorted(), ["name", "seq", "time", "window"])
        XCTAssertEqual(events.first?["seq"]?.intValue, 1)
        XCTAssertEqual(events.first?["name"]?.stringValue, "window.opened")
        XCTAssertEqual(events.first?["window"], fixtureWindow)
        let time = try XCTUnwrap(events.first?["time"]?.stringValue)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(formatter.date(from: time), time)
        XCTAssertEqual(events.last, ["seq": 2, "time": events.last?["time"] ?? .null, "name": "process.exited", "pid": 44, "code": 3, "path": "C:\\x.exe"])

        let tail = try await h.handle(op: "vm.events", params: ["name": "Win", "since": 1])
        XCTAssertEqual(tail["events"]?.arrayValue?.map { $0["seq"]?.intValue }, [2])
        XCTAssertEqual(tail["next"]?.intValue, 2)
        let none = try await h.handle(op: "vm.events", params: ["name": "Win", "since": 2])
        XCTAssertEqual(none, ["events": [], "next": 2])

        for since: JSON in [-1, "2", 1.5] {
            let text = await failure(h, "vm.events", ["name": "Win", "since": since])
            XCTAssertEqual(text, "since must be an integer of 0 or more; pass the next value of an earlier vm.events reply")
        }

        await t.setState(.stopped)
        let stopped = try await h.handle(op: "vm.events", params: ["name": "Win", "since": 1])
        XCTAssertEqual(stopped["events"]?.arrayValue?.count, 1)
    }

    // MARK: - observation

    func testObservationCarriesUIFacts() async throws {
        let tree: [JSON] = [node("e1", "Window", "Alcove Fixture", x: 100, y: 50, w: 400, h: 300), messageEdit, sendButton]
        let (h, t, agent) = try await rig([
            "ui.focused": { _, _ in .ok(["node": messageEdit, "window": fixtureWindow]) },
            "ui.tree": { _, _ in .ok(["window": fixtureWindow, "nodes": .array(tree), "truncated": true]) },
        ])
        let click: JSON = ["name": "Win", "x": 5, "y": 5, "observe": "summary", "settleMs": 20]
        let first = try await h.handle(op: "vm.mouse.click", params: click)
        XCTAssertEqual(first["observation"]?["foreground"], "Alcove Fixture")
        XCTAssertEqual(first["observation"]?["focused"], "Edit \"Message\"")
        XCTAssertEqual(first["observation"]?["events"], [])
        XCTAssertNil(first["observation"]?["tree"])
        XCTAssertNil(first["observation"]?["uiError"])

        agent.sendLine(["t": "ev", "name": "window.opened", "window": fixtureWindow])
        agent.sendLine(["t": "ev", "name": "dialog.opened", "title": "Fixture \"Dialog\""])
        agent.sendLine(["t": "ev", "name": "process.exited", "pid": 44, "code": 3, "path": "C:\\apps\\crash me.exe"])
        let arrived = await eventually { await t.events(since: 0).next == 3 }
        XCTAssertTrue(arrived)

        let second = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "a", "observe": "summary", "settleMs": 20])
        XCTAssertEqual(second["observation"]?["events"],
                       ["window.opened \"Alcove Fixture\"", "dialog.opened \"Fixture \\\"Dialog\\\"\"", "process.exited crash me.exe code 3"])
        let third = try await h.handle(op: "vm.mouse.click", params: click)
        XCTAssertEqual(third["observation"]?["events"], [])

        let withTree = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "observe": "ui", "settleMs": 20])
        XCTAssertEqual(withTree["observation"]?["tree"]?.stringValue,
                       UITreeText.render(tree) + "\n… more elements; call vm.ui.tree to read the whole window")
        XCTAssertEqual(withTree["observation"]?["foreground"], "Alcove Fixture")
        XCTAssertNil(withTree["observation"]?["png"])
        XCTAssertEqual(fields(agentRequests(agent, "ui.tree").last), ["window": "foreground", "max": 150])
    }

    func testObservationReportsOnlyTheNewestEvents() async throws {
        let (h, t, agent) = try await rig(["ui.focused": { _, _ in .ok(["node": messageEdit, "window": fixtureWindow]) }])
        let click: JSON = ["name": "Win", "x": 5, "y": 5, "observe": "summary", "settleMs": 20]
        _ = try await h.handle(op: "vm.mouse.click", params: click)
        for i in 1...25 { agent.sendLine(["t": "ev", "name": "window.title", "title": .string("t\(i)")]) }
        let arrived = await eventually { await t.events(since: 0).next == 25 }
        XCTAssertTrue(arrived)
        let r = try await h.handle(op: "vm.mouse.click", params: click)
        let events = r["observation"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(events.count, 21)
        XCTAssertEqual(events.first, "5 earlier events; call vm.events")
        XCTAssertEqual(events.last, "window.title \"t25\"")
        XCTAssertEqual(events[1], "window.title \"t6\"")
    }

    func testObservationWithoutTheUICapabilityHasNoUIFacts() async throws {
        let (h, _, agent) = try await rig(caps: ["clipboard", "files", "exec"])
        let r = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "observe": "summary", "settleMs": 20])
        XCTAssertEqual(r["observation"]?.objectValue?.keys.sorted(), ["changedFraction", "height", "settled", "width"])
        let asked = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "observe": "ui", "settleMs": 20])
        XCTAssertEqual(asked["observation"]?.objectValue?.keys.sorted(), ["changedFraction", "height", "settled", "uiError", "width"])
        XCTAssertEqual(asked["observation"]?["uiError"]?.stringValue, noUISentence)
        XCTAssertTrue(agent.received.filter { $0["t"]?.stringValue == "req" }.isEmpty)
    }

    func testObservationWhoseHelperFailsKeepsTheScreenFacts() async throws {
        let (h, _, _) = try await rig(["ui.focused": { _, _ in .fail("UI helper did not answer in time; call the op again") }])
        let r = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "observe": "summary", "settleMs": 20])
        XCTAssertEqual(r["observation"]?["settled"]?.boolValue, true)
        XCTAssertNil(r["observation"]?["foreground"])
        XCTAssertEqual(r["observation"]?["uiError"]?.stringValue,
                       "the foreground window and focused element could not be read: UI helper did not answer in time; call the op again")
        XCTAssertNil(r["observationError"])
    }

    // MARK: - wait conditions

    private func waitFor(_ h: ControlHandler, _ conditions: [JSON], timeout: Int = 30) async throws -> JSON {
        try await h.handle(op: "vm.wait_for", params: ["name": "Win", "conditions": .array(conditions), "timeout": .int(Int64(timeout))])
    }

    func testWaitUIExistsGoneEnabled() async throws {
        let noMatch = "no element matches {\"name\":\"Send\",\"role\":\"Button\"}; call ui.tree to see what exists"
        let disabled = node("e5", "Button", "Send", flags: ["disabled"])
        let (h, _, agent) = try await rig(["ui.rect": { m, n in
            switch m["name"]?.stringValue {
            case "Send": return n < 2 ? .fail(noMatch) : .ok(["node": sendButton, "cx": 190, "cy": 112, "clickable": true])
            case "Busy": return n < 5 ? .ok(["node": sendButton, "cx": 1, "cy": 1, "clickable": true]) : .fail(noMatch)
            default: return n < 8 ? .ok(["node": disabled, "cx": 1, "cy": 1, "clickable": false]) : .ok(["node": sendButton, "cx": 1, "cy": 1, "clickable": true])
            }
        }])
        let exists = try await waitFor(h, [["type": "ui_exists", "window": "Alcove", "role": "Button", "name": "Send", "index": 0]])
        XCTAssertEqual(exists["matched"]?.intValue, 0)
        XCTAssertEqual(exists["type"]?.stringValue, "ui_exists")
        XCTAssertEqual(exists["detail"], sendButton)
        XCTAssertNil(exists["problems"])
        XCTAssertEqual(fields(agentRequests(agent, "ui.rect").last), ["window": "Alcove", "role": "Button", "name": "Send", "index": 0])
        XCTAssertEqual(agentRequests(agent, "ui.rect").count, 3)

        let gone = try await waitFor(h, [["type": "ui_gone", "name": "Busy"]])
        XCTAssertEqual(gone["matched"]?.intValue, 0)
        XCTAssertEqual(gone["type"]?.stringValue, "ui_gone")
        XCTAssertNil(gone["detail"])
        XCTAssertEqual(agentRequests(agent, "ui.rect").count, 6)

        let enabled = try await waitFor(h, [["type": "ui_enabled", "automationId": "send-1"]])
        XCTAssertEqual(enabled["matched"]?.intValue, 0)
        XCTAssertEqual(enabled["type"]?.stringValue, "ui_enabled")
        XCTAssertEqual(enabled["detail"], sendButton)
        XCTAssertEqual(agentRequests(agent, "ui.rect").count, 9)
    }

    func testWaitUIConditionsTakeARef() async throws {
        let (h, _, agent) = try await rig(["ui.rect": { _, n in
            n < 2 ? .ok(["node": sendButton, "cx": 1, "cy": 1, "clickable": true]) : .fail("element e5 no longer exists; call ui.tree again")
        }])
        let gone = try await waitFor(h, [["type": "ui_gone", "ref": "e5"]])
        XCTAssertEqual(gone["matched"]?.intValue, 0)
        XCTAssertEqual(fields(agentRequests(agent, "ui.rect").last), ["ref": "e5"])
    }

    func testWaitWindowTitle() async throws {
        let saved = window("0x3b", "메모 - Saved", x: 0, y: 0, w: 10, h: 10)
        let (h, _, agent) = try await rig(["win.list": { _, n in .ok(["windows": n < 2 ? [fixtureWindow, notesWindow] : [fixtureWindow, saved]]) }])
        let contains = try await waitFor(h, [["type": "window_title", "contains": "saved"]])
        XCTAssertEqual(contains["matched"]?.intValue, 0)
        XCTAssertEqual(contains["type"]?.stringValue, "window_title")
        XCTAssertEqual(contains["detail"], ["id": "0x3b", "title": "메모 - Saved", "foreground": false])
        XCTAssertEqual(agentRequests(agent, "win.list").count, 3)

        let regex = try await waitFor(h, [["type": "window_title", "regex": "^Alcove F.xture$"]])
        XCTAssertEqual(regex["matched"]?.intValue, 0)
        XCTAssertEqual(regex["detail"], ["id": "0x2a", "title": "Alcove Fixture", "foreground": true])

        let never = try await waitFor(h, [["type": "window_title", "contains": "Nothing"]], timeout: 1)
        XCTAssertEqual(never["matched"]?.intValue, -1)
        XCTAssertNil(never["problems"])
    }

    func testTextStableWaitsForQuiet() async throws {
        let (h, _, agent) = try await rig(["ui.text": { _, n in
            let text = ["Bot: echo", "Bot: echo 안녕", "Bot: echo 안녕 [done]"][min(n, 2)]
            return .ok(["text": .string(text), "total": .int(Int64(text.utf16.count)), "source": "value"])
        }])
        let r = try await waitFor(h, [["type": "ui_text_stable", "role": "Edit", "name": "Transcript", "quietMs": 150]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertEqual(r["type"]?.stringValue, "ui_text_stable")
        XCTAssertEqual(r["detail"]?.intValue, "Bot: echo 안녕 [done]".utf16.count)
        XCTAssertGreaterThanOrEqual(agentRequests(agent, "ui.text").count, 4)
        XCTAssertGreaterThanOrEqual(r["waited"]?.doubleValue ?? 0, 0.1)
        XCTAssertEqual(fields(agentRequests(agent, "ui.text").last), ["role": "Edit", "name": "Transcript"])
    }

    func testTextStableEndsWhenElementGone() async throws {
        let stale = "element e7 no longer exists; call ui.tree again"
        let (h, _, agent) = try await rig(["ui.text": { _, n in
            n < 2 ? .ok(["text": .string("partial \(n)"), "total": 9, "source": "value"]) : .fail(stale)
        }])
        let r = try await waitFor(h, [["type": "ui_text_stable", "ref": "e7", "quietMs": 60_000]])
        XCTAssertEqual(r["matched"]?.intValue, -1)
        XCTAssertEqual(r["type"]?.stringValue, "ui_text_stable")
        XCTAssertEqual(r["detail"]?.stringValue, stale)
        XCTAssertNil(r["problems"])
        XCTAssertEqual(agentRequests(agent, "ui.text").count, 3)
        XCTAssertEqual(fields(agentRequests(agent, "ui.text").last), ["ref": "e7"])

        let noMatch = "no element matches {\"name\":\"Transcript\"}; call ui.tree to see what exists"
        let (other, _, _) = try await rig(["ui.text": { _, _ in .fail(noMatch) }])
        let missing = try await waitFor(other, [["type": "ui_text_stable", "name": "Transcript"]])
        XCTAssertEqual(missing["matched"]?.intValue, -1)
        XCTAssertEqual(missing["detail"]?.stringValue, noMatch)
    }

    func testWaitEvent() async throws {
        let (h, t, agent) = try await rig()
        _ = try await h.handle(op: "vm.key.down", params: ["name": "Win", "key": "shift"])
        agent.sendLine(["t": "ev", "name": "dialog.opened", "window": window("0x50", "Fixture Dialog", x: 0, y: 0, w: 10, h: 10)])
        agent.sendLine(["t": "ev", "name": "dialog.opened", "title": "다른 이름으로 저장"])
        let arrived = await eventually { await t.events(since: 0).next == 2 }
        XCTAssertTrue(arrived)

        let titled = try await waitFor(h, [["type": "event", "event": "dialog.opened", "titleContains": "저장"]])
        XCTAssertEqual(titled["matched"]?.intValue, 0)
        XCTAssertEqual(titled["type"]?.stringValue, "event")
        XCTAssertEqual(titled["detail"]?["seq"]?.intValue, 2)
        XCTAssertEqual(titled["detail"]?["name"]?.stringValue, "dialog.opened")
        XCTAssertEqual(titled["detail"]?["title"]?.stringValue, "다른 이름으로 저장")

        let consumed = try await waitFor(h, [["type": "event", "event": "dialog.opened"]], timeout: 1)
        XCTAssertEqual(consumed["matched"]?.intValue, -1)

        let pending = Task {
            try await h.handle(op: "vm.wait_for", params: ["name": "Win", "timeout": 30, "conditions": [
                ["type": "window_title", "contains": "never"], ["type": "event", "event": "process.exited"],
            ]])
        }
        try await Task.sleep(for: .milliseconds(100))
        agent.sendLine(["t": "ev", "name": "window.closed", "title": "x"])
        agent.sendLine(["t": "ev", "name": "process.exited", "pid": 44, "code": -1, "path": "C:\\x.exe"])
        let exited = try await pending.value
        XCTAssertEqual(exited["matched"]?.intValue, 1)
        XCTAssertEqual(exited["detail"]?["pid"]?.intValue, 44)
        XCTAssertEqual(exited["detail"]?["seq"]?.intValue, 4)
    }

    func testWaitEventSeesEventsSinceTheLatestChangingOp() async throws {
        let (h, t, agent) = try await rig()
        agent.sendLine(["t": "ev", "name": "window.opened", "title": "old"])
        let first = await eventually { await t.events(since: 0).next == 1 }
        XCTAssertTrue(first)
        _ = try await h.handle(op: "vm.key.down", params: ["name": "Win", "key": "shift"])
        let stale = try await waitFor(h, [["type": "event", "event": "window.opened"]], timeout: 1)
        XCTAssertEqual(stale["matched"]?.intValue, -1)

        _ = try await h.handle(op: "vm.key.up", params: ["name": "Win", "key": "shift"])
        agent.sendLine(["t": "ev", "name": "window.opened", "title": "new"])
        let second = await eventually { await t.events(since: 0).next == 2 }
        XCTAssertTrue(second)
        let fresh = try await waitFor(h, [["type": "event", "event": "window.opened"]])
        XCTAssertEqual(fresh["matched"]?.intValue, 0)
        XCTAssertEqual(fresh["detail"]?["title"]?.stringValue, "new")
    }

    func testWaitEventFailsWhenTheAgentDisconnects() async throws {
        let (h, _, agent) = try await rig()
        let pending = Task {
            try await h.handle(op: "vm.wait_for", params: ["name": "Win", "timeout": 30, "conditions": [["type": "event", "event": "window.opened"]]])
        }
        try await Task.sleep(for: .milliseconds(100))
        agent.drop()
        do { _ = try await pending.value; XCTFail("the wait went on without the agent") }
        catch { XCTAssertEqual("\(error)", "guest tools in 'Win' disconnected during vm.wait_for; retry once the guest is back") }
    }

    /// A fake agent with the `ui` capability, connected to a new running VM "Win". Every `ui.rect` request is answered with
    /// the no-match error followed by the `emitted` event.
    private func target(emitting emitted: JSON) async throws -> (FakeTarget, FakeAgent) {
        let agent = FakeAgent()
        agent.caps = ["clipboard", "files", "exec", "ui"]
        agent.handler = { m, _ in
            switch m["op"]?.stringValue {
            case "ui.focused": return [agentReply(m, ["node": messageEdit, "window": fixtureWindow])]
            case "ui.rect": return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": "no element matches {}; call ui.tree to see what exists"], emitted]
            default: return []
            }
        }
        _ = agent.start()
        addTeardownBlock { agent.stop() }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 64, height: 64))
        await t.setAgent(client)
        return (t, agent)
    }

    func testEventPositionsStartOverForAVMWithANewEventSequence() async throws {
        let (old, oldAgent) = try await target(emitting: ["t": "ev", "name": "unused"])
        let registry = SwapRegistry(old)
        let h = ControlHandler(registry: registry, hostKind: "test")
        for i in 1...3 { oldAgent.sendLine(["t": "ev", "name": "window.opened", "title": .string("old \(i)")]) }
        let arrived = await eventually { await old.events(since: 0).next == 3 }
        XCTAssertTrue(arrived)
        let click: JSON = ["name": "Win", "x": 5, "y": 5, "observe": "summary", "settleMs": 20]
        _ = try await h.handle(op: "vm.mouse.click", params: click)
        _ = try await h.handle(op: "vm.mouse.click", params: click)

        let (fresh, _) = try await target(emitting: ["t": "ev", "name": "window.opened", "title": "fresh"])
        await registry.swap(fresh)
        let waited = try await h.handle(op: "vm.wait_for", params: ["name": "Win", "timeout": 30, "observe": "summary", "settleMs": 20, "conditions": [
            ["type": "ui_exists", "name": "Nothing"], ["type": "event", "event": "window.opened"],
        ]])
        XCTAssertEqual(waited["matched"]?.intValue, 1)
        XCTAssertEqual(waited["detail"]?["seq"]?.intValue, 1)
        XCTAssertEqual(waited["detail"]?["title"]?.stringValue, "fresh")
        XCTAssertEqual(waited["observation"]?["events"]?[0], "window.opened \"fresh\"")
    }

    func testUIConditionsValidation() async throws {
        let (h, _, agent) = try await rig()
        let cases: [(JSON, String)] = [
            (["type": "ui_exists"], "condition 0: ui_exists needs 'ref' or at least one of role, name, nameContains, automationId"),
            (["type": "ui_gone", "window": "Alcove"], "condition 0: ui_gone needs 'ref' or at least one of role, name, nameContains, automationId"),
            (["type": "ui_enabled", "ref": "e5", "role": "Button"], "condition 0: ui_enabled takes 'ref' or selector fields, not both"),
            (["type": "ui_exists", "ref": "five"], "condition 0: ref must be an element ref such as e12; take one from vm.ui.tree or vm.ui.find"),
            (["type": "ui_exists", "role": 3], "condition 0: selector field 'role' must be a string"),
            (["type": "ui_text_stable", "ref": "e5", "quietMs": -1], "condition 0: 'quietMs' must be an integer between 0 and 600000"),
            (["type": "ui_text_stable", "ref": "e5", "quietMs": "soon"], "condition 0: 'quietMs' must be an integer between 0 and 600000"),
            (["type": "window_title"], "condition 0: window_title needs exactly one of 'contains' and 'regex'"),
            (["type": "window_title", "contains": "a", "regex": "b"], "condition 0: window_title needs exactly one of 'contains' and 'regex'"),
            (["type": "window_title", "regex": "("], "condition 0: '(' is not a valid regular expression"),
            (["type": "event"], "condition 0: event needs a non-empty string 'event'"),
            (["type": "event", "event": "window.opened", "titleContains": 4], "condition 0: event needs a non-empty string 'titleContains'"),
        ]
        for (condition, expected) in cases {
            do { _ = try await waitFor(h, [condition]); XCTFail("\(condition) was accepted") }
            catch { XCTAssertEqual("\(error)", expected) }
        }
        do { _ = try await waitFor(h, [["type": "bogus"]]); XCTFail() }
        catch {
            for type in ["ui_exists", "ui_gone", "ui_enabled", "window_title", "ui_text_stable", "event"] {
                XCTAssertTrue("\(error)".contains(type), "\(type) in \(error)")
            }
        }
        XCTAssertTrue(agent.received.filter { $0["t"]?.stringValue == "req" }.isEmpty)
    }

    func testHelperErrorsDuringAWaitAreReportedAsProblems() async throws {
        let (h, _, agent) = try await rig(["ui.rect": { _, _ in .fail("UI helper did not answer in time; call the op again") }])
        let r = try await waitFor(h, [["type": "ui_exists", "name": "Send"]], timeout: 1)
        XCTAssertEqual(r["matched"]?.intValue, -1)
        let problem = try XCTUnwrap(r["problems"]?[0])
        XCTAssertEqual(problem["condition"]?.intValue, 0)
        XCTAssertEqual(problem["type"]?.stringValue, "ui_exists")
        XCTAssertEqual(problem["error"]?.stringValue, "UI helper did not answer in time; call the op again")
        XCTAssertGreaterThanOrEqual(problem["failures"]?.intValue ?? 0, 1)
        XCTAssertGreaterThanOrEqual(agentRequests(agent, "ui.rect").count, 1)
    }

    // MARK: - screenshot

    func testScreenshotWindowCrop() async throws {
        let minimized = window("0x77", "Hidden Tool", x: -32000, y: -32000, w: 160, h: 28, state: "minimized")
        let (h, _, agent) = try await rig(["win.list": { _, _ in .ok(["windows": [notesWindow, fixtureWindow, minimized]]) }])
        let byTitle = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "window": "alcove fix"])
        XCTAssertEqual(byTitle["x"]?.intValue, 100); XCTAssertEqual(byTitle["y"]?.intValue, 50)
        XCTAssertEqual(byTitle["areaWidth"]?.intValue, 400); XCTAssertEqual(byTitle["areaHeight"]?.intValue, 300)
        XCTAssertEqual(byTitle["sentWidth"]?.intValue, 400); XCTAssertEqual(byTitle["sentHeight"]?.intValue, 300)
        XCTAssertEqual(byTitle["width"]?.intValue, 800); XCTAssertEqual(byTitle["height"]?.intValue, 600)
        XCTAssertEqual(byTitle["window"], fixtureWindow)
        XCTAssertNil(byTitle["marks"])
        let image = try XCTUnwrap(Frame(png: Data(base64Encoded: byTitle["png"]?.stringValue ?? "") ?? Data()))
        XCTAssertEqual(image.width, 400); XCTAssertEqual(image.height, 300)
        XCTAssertTrue(agentRequests(agent, "ui.tree").isEmpty)

        let byID = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "window": "0X3B", "maxWidth": 160])
        XCTAssertEqual(byID["x"]?.intValue, 300); XCTAssertEqual(byID["y"]?.intValue, 200)
        XCTAssertEqual(byID["areaWidth"]?.intValue, 320); XCTAssertEqual(byID["sentWidth"]?.intValue, 160)
        let foreground = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "window": "foreground"])
        XCTAssertEqual(foreground["window"], fixtureWindow)

        let cases: [(JSON, String)] = [
            (["name": "Win", "window": "Paint"], "no window matches 'Paint'; call vm.window.list"),
            (["name": "Win", "window": "Hidden Tool"], "window 'Hidden Tool' is minimized or outside the 800x600 frame; restore it with vm.window.action"),
            (["name": "Win", "window": "Alcove", "region": ["x": 0, "y": 0, "w": 10, "h": 10]],
             "pass region or window, not both; region is a rectangle of the frame, window crops to a window's rectangle"),
            (["name": "Win", "window": 7], "missing or invalid parameter 'window'"),
            (["name": "Win", "marks": "yes"], "parameter 'marks' must be a boolean"),
        ]
        for (params, expected) in cases {
            let text = await failure(h, "vm.screenshot", params)
            XCTAssertEqual(text, expected)
        }
    }

    func testScreenshotMarksReturnsLegend() async throws {
        let tree: [JSON] = [
            node("e1", "Window", "Alcove Fixture", x: 100, y: 50, w: 400, h: 300),
            node("e2", "Text", "Message", depth: 1, x: 110, y: 60, w: 40, h: 24),
            messageEdit,
            sendButton,
            node("e6", "Button", "Below", depth: 1, x: 150, y: 900, w: 80, h: 24, flags: ["offscreen"]),
            node("e7", "Button", "Empty", depth: 1, x: 150, y: 140, w: 0, h: 0),
            node("e8", "ListItem", "한글 \"항목\"", depth: 2, x: 480, y: 330, w: 60, h: 40, flags: ["disabled"]),
        ]
        let (h, _, agent) = try await rig([
            "win.list": { _, _ in .ok(["windows": [notesWindow, fixtureWindow]]) },
            "ui.tree": { _, _ in .ok(["window": fixtureWindow, "nodes": .array(tree), "truncated": false]) },
        ])
        let plain = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "window": "Alcove"])
        let marked = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "window": "Alcove", "marks": true])
        XCTAssertEqual(marked["marks"], [
            ["n": 1, "ref": "e4", "role": "Edit", "name": "Message", "x": 150, "y": 60, "w": 200, "h": 24],
            ["n": 2, "ref": "e5", "role": "Button", "name": "Send", "x": 150, "y": 100, "w": 80, "h": 24],
            ["n": 3, "ref": "e8", "role": "ListItem", "name": "한글 \"항목\"", "x": 480, "y": 330, "w": 60, "h": 40],
        ])
        XCTAssertEqual(marked["areaWidth"]?.intValue, 400); XCTAssertEqual(marked["x"]?.intValue, 100)
        XCTAssertEqual(fields(agentRequests(agent, "ui.tree").last), ["window": "0x2a", "filter": "interactive", "max": 300])

        let before = try XCTUnwrap(Frame(png: Data(base64Encoded: plain["png"]?.stringValue ?? "") ?? Data()))
        let after = try XCTUnwrap(Frame(png: Data(base64Encoded: marked["png"]?.stringValue ?? "") ?? Data()))
        XCTAssertEqual(after.width, 400); XCTAssertEqual(after.height, 300)
        XCTAssertNotEqual(before.pixel(x: 50, y: 50), after.pixel(x: 50, y: 50))
        XCTAssertEqual(before.pixel(x: 150, y: 60), after.pixel(x: 150, y: 60))
        XCTAssertEqual(before.pixel(x: 300, y: 200), after.pixel(x: 300, y: 200))

        let whole = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "marks": true])
        XCTAssertEqual(whole["marks"]?.arrayValue?.count, 3)
        XCTAssertEqual(whole["areaWidth"]?.intValue, 800)
        XCTAssertNil(whole["window"])
        XCTAssertEqual(fields(agentRequests(agent, "ui.tree").last), ["window": "foreground", "filter": "interactive", "max": 300])

        let part = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "marks": true, "region": ["x": 0, "y": 0, "w": 300, "h": 110]])
        XCTAssertEqual(part["marks"]?.arrayValue?.map { $0["ref"]?.stringValue }, ["e4", "e5"])
        XCTAssertEqual(part["marks"]?[1]?["n"]?.intValue, 2)
    }

    func testDrawingMarksOutlinesEachRectangle() throws {
        let base = try XCTUnwrap(Frame(png: makePNG(width: 200, height: 120)))
        let marked = base.drawingMarks([Frame.Mark(number: 1, rect: Frame.Rect(x: 40, y: 50, w: 60, h: 30)),
                                        Frame.Mark(number: 12, rect: Frame.Rect(x: 150, y: 2, w: 80, h: 40))])
        XCTAssertEqual(marked.width, 200); XCTAssertEqual(marked.height, 120)
        let first = Frame.markColors[0], second = Frame.markColors[(12 - 1) % Frame.markColors.count]
        for (x, y) in [(40, 50), (99, 50), (40, 79), (99, 79), (70, 50), (40, 65)] {
            XCTAssertEqual(marked.pixel(x: x, y: y), [first.blue, first.green, first.red, 255], "\(x),\(y)")
        }
        XCTAssertEqual(marked.pixel(x: 150, y: 20), [second.blue, second.green, second.red, 255])
        XCTAssertEqual(marked.pixel(x: 70, y: 65), base.pixel(x: 70, y: 65))
        XCTAssertEqual(marked.pixel(x: 10, y: 100), base.pixel(x: 10, y: 100))
        XCTAssertNotEqual(marked.pixel(x: 44, y: 42), base.pixel(x: 44, y: 42))
        XCTAssertEqual(base.drawingMarks([]), base)
        for i in stride(from: 3, to: marked.pixels.count, by: 4) where marked.pixels[i] != 255 { XCTFail("alpha at \(i)"); break }
    }

    // MARK: - capability, classification, lease

    func testUIOpsOnOldAgent() async throws {
        let (h, t, agent) = try await rig(caps: ["clipboard", "files", "exec"])
        let calls: [(String, JSON)] = [
            ("vm.window.list", ["name": "Win"]),
            ("vm.window.action", ["name": "Win", "window": "0x2a", "action": "focus"]),
            ("vm.ui.tree", ["name": "Win"]),
            ("vm.ui.find", ["name": "Win", "selector": ["name": "Send"]]),
            ("vm.ui.text", ["name": "Win", "ref": "e4"]),
            ("vm.ui.click", ["name": "Win", "ref": "e5"]),
            ("vm.ui.type", ["name": "Win", "ref": "e4", "text": "x"]),
            ("vm.ui.action", ["name": "Win", "ref": "e5", "action": "invoke"]),
            ("vm.screenshot", ["name": "Win", "window": "Alcove"]),
            ("vm.screenshot", ["name": "Win", "marks": true]),
            ("vm.wait_for", ["name": "Win", "conditions": [["type": "ui_exists", "name": "Send"]]]),
            ("vm.wait_for", ["name": "Win", "conditions": [["type": "window_title", "contains": "x"]]]),
            ("vm.wait_for", ["name": "Win", "conditions": [["type": "ui_text_stable", "ref": "e4"]]]),
        ]
        for (op, params) in calls {
            let text = await failure(h, op, params)
            XCTAssertEqual(text, noUISentence, op)
        }
        XCTAssertTrue(agent.received.filter { $0["t"]?.stringValue == "req" }.isEmpty)
        let sent = await t.sent
        XCTAssertEqual(sent, [])

        let events = try await h.handle(op: "vm.events", params: ["name": "Win"])
        XCTAssertEqual(events, ["events": [], "next": 0])
    }

    func testUIOpsOnAnAgentWithoutRequests() async throws {
        let agent = FakeAgent()
        agent.proto = nil
        agent.caps = ["clipboard", "files", "ui"]
        let (h, _) = try await handlerWithAgent(agent, in: self)
        let tree = await failure(h, "vm.ui.tree", ["name": "Win"])
        XCTAssertEqual(tree, "guest tools in 'Win' are too old for vm.ui.tree; update alcove-agent in the guest")
        let launch = await failure(h, "vm.app.launch", ["name": "Win", "path": "notepad.exe"])
        XCTAssertEqual(launch, "guest tools in 'Win' are too old for vm.app.launch; update alcove-agent in the guest")
    }

    func testUIOpsWithoutTools() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 8, height: 8))
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test")
        let tree = await failure(h, "vm.ui.tree", ["name": "Win"])
        XCTAssertEqual(tree, "guest tools are not connected in 'Win'; install alcove-agent in the guest")
        await t.setState(.stopped)
        let stopped = await failure(h, "vm.ui.click", ["name": "Win", "ref": "e5"])
        XCTAssertEqual(stopped, "VM 'Win' is stopped; call vm.start first")
    }

    func testClassification() {
        let all = ["vm.window.list", "vm.window.action", "vm.ui.tree", "vm.ui.find", "vm.ui.text", "vm.ui.click", "vm.ui.type", "vm.ui.action",
                   "vm.app.launch", "vm.deploy", "vm.events"]
        let readOnly: Set<String> = ["vm.window.list", "vm.ui.tree", "vm.ui.find", "vm.ui.text", "vm.events"]
        let concurrent: Set<String> = ["vm.window.list", "vm.ui.tree", "vm.ui.find", "vm.ui.text", "vm.app.launch", "vm.deploy"]
        let input: Set<String> = ["vm.window.action", "vm.ui.click", "vm.ui.type", "vm.ui.action"]
        for op in all {
            XCTAssertTrue(ControlHandler.knownOps.contains(op), op)
            XCTAssertEqual(ControlHandler.isReadOnly(op: op), readOnly.contains(op), op)
            XCTAssertEqual(ControlHandler.isConcurrent(op: op), concurrent.contains(op), op)
            XCTAssertEqual(ControlHandler.isInput(op: op), input.contains(op), op)
            XCTAssertEqual(ControlHandler.capturesFrames(op: op), input.contains(op) || op.hasPrefix("vm.ui."), op)
        }
    }

    func testLeaseGuardsTheChangingOps() async throws {
        let (h, _, agent) = try await rig([
            "ui.tree": { _, _ in .ok(["window": fixtureWindow, "nodes": [], "truncated": false]) },
            "win.list": { _, _ in .ok(["windows": []]) },
        ])
        _ = try await h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "agent-a", "ttl": 60])
        let dir = try tempDir("leased")
        let guarded: [(String, JSON)] = [
            ("vm.window.action", ["name": "Win", "window": "0x2a", "action": "close"]),
            ("vm.ui.click", ["name": "Win", "ref": "e5"]),
            ("vm.ui.type", ["name": "Win", "ref": "e4", "text": "x"]),
            ("vm.ui.action", ["name": "Win", "ref": "e5", "action": "invoke"]),
            ("vm.app.launch", ["name": "Win", "path": "notepad.exe"]),
            ("vm.deploy", ["name": "Win", "path": .string(dir.path)]),
        ]
        for (op, params) in guarded {
            let text = await failure(h, op, params)
            XCTAssertTrue(text.hasPrefix("VM 'Win' is leased by agent-a for another "), "\(op): \(text)")
        }
        XCTAssertTrue(agent.received.filter { $0["t"]?.stringValue == "req" }.isEmpty)

        _ = try await h.handle(op: "vm.window.list", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.ui.tree", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.events", params: ["name": "Win"])
    }

    func testARecordingTracesUIOpsAndEventPolls() async throws {
        let (h, _, _) = try await rig(["ui.act": { _, _ in .ok(["node": sendButton]) }])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("control-ui-trace-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        _ = try await h.handle(op: "vm.record.start", params: ["name": "Win", "dir": .string(dir.path), "video": false])
        _ = try await h.handle(op: "vm.ui.action", params: ["name": "Win", "ref": "e5", "action": "invoke"])
        _ = try await h.handle(op: "vm.events", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        let lines = try String(contentsOf: dir.appendingPathComponent("trace.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSON.parse(Data($0.utf8)) }
        XCTAssertEqual(lines.map { $0["op"]?.stringValue }, ["vm.ui.action", "vm.events"])
        XCTAssertNotNil(lines[0]["before"]); XCTAssertNotNil(lines[0]["after"])
        XCTAssertNil(lines[1]["before"]); XCTAssertNil(lines[1]["after"])
        XCTAssertEqual(lines[1]["result"], ["events": [], "next": 0])
    }
}

private extension Frame {
    /// The BGRA bytes of the pixel at (x, y).
    func pixel(x: Int, y: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(pixels[pixels.startIndex + offset..<pixels.startIndex + offset + 4])
    }
}
