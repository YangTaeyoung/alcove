import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveDisplayProtocol
import AlcoveTestSupport

/// What a scripted agent op answers: result fields, an error sentence, nothing, or what the rig's fake file system answers.
private enum Answer {
    case ok([String: JSON])
    case fail(String)
    case silent
    case fileSystem
}

/// Per agent op: the answer to a request, given the request and how many requests of that op came before it.
private typealias Script = [String: @Sendable (JSON, Int) -> Answer]

/// The agent reply lines for `m` under `script`; an op outside the script answers the agent's unknown-op error.
/// `fileSystem` gives the lines of an op whose answer is `.fileSystem`.
private func scripted(_ script: Script, _ counts: LockedBox<[String: Int]>, _ m: JSON, fileSystem: (JSON) -> [JSON] = { _ in [] }) -> [JSON] {
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
    case .fileSystem: return fileSystem(m)
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

/// A registry of one VM that counts its lookups.
private actor CountingRegistry: VMRegistry {
    private let only: FakeTarget
    private(set) var lookups = 0
    init(_ target: FakeTarget) { only = target }
    func names() async -> [String] { [only.name] }
    func target(named name: String) async -> VMTarget? {
        lookups += 1
        return name == only.name ? only : nil
    }
}

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
        UITiming.queueTimeout = .seconds(60)
        UITiming.factBudget = .seconds(3)
        UITiming.treeFactBudget = .seconds(20)
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

    /// The value of `task` once it finished; nil when it has not finished within `limit`.
    private func finished<T: Sendable>(_ task: Task<T, Error>, within limit: Duration = .seconds(20)) async throws -> T? {
        let box = LockedBox<Result<T, Error>?>(nil)
        Task { box.value = await task.result }
        guard await eventually(timeout: limit, { box.value != nil }), let result = box.value else { return nil }
        return try result.get()
    }

    private struct StillRunning: Error, CustomStringConvertible {
        let description: String
    }

    /// The value of `task`; throws `StillRunning` with `message` when it has not finished within 20 s.
    private func completed<T: Sendable>(_ task: Task<T, Error>, _ message: String = "the call did not return") async throws -> T {
        guard let value = try await finished(task) else { throw StillRunning(description: message) }
        return value
    }

    private func requestOps(_ agent: FakeAgent) -> [String] {
        agent.received.filter { $0["t"]?.stringValue == "req" }.compactMap { $0["op"]?.stringValue }
    }

    private static let busyFacts = "the UI helper is busy with another request; call vm.ui.tree when you need the tree"

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

    func testUITreeTextKeepsOneNodeOnOneLine() {
        let breaks = "a\u{2028}b\u{2029}c\u{85}d\u{0B}e\u{0C}f\u{1B}g\u{7F}h\u{9F}i\u{0}j"
        XCTAssertEqual(UITreeText.quoted(breaks), "\"a\\u{2028}b\\u{2029}c\\u{85}d\\u{b}e\\u{c}f\\u{1b}g\\u{7f}h\\u{9f}i\\u{0}j\"")
        XCTAssertEqual(UITreeText.quoted("é 한글 \u{A0}\u{200B}"), "\"é 한글 \u{A0}\u{200B}\"")

        let long = String(repeating: "가", count: 250)
        let line = UITreeText.render([node("e1", "Text", long, value: breaks), node("e2", "Text", String(repeating: "x", count: 200))])
        let lines = line.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("[e1] Text \"" + String(repeating: "가", count: 200) + "…\" (0,0 10x10)"), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("[e2] Text \"" + String(repeating: "x", count: 200) + "\" "), lines[1])
        XCTAssertNil(line.unicodeScalars.first { $0 != "\n" && ($0.value < 0x20 || (0x7F...0x9F).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029) })
        XCTAssertEqual(UITreeText.label(node("e3", "Button", long)), "Button \"" + String(repeating: "가", count: 200) + "…\"")

        let cut = UITreeText.line(node("e4", "Edit", "Notes", value: String(repeating: "값", count: 199) + "\n" + String(repeating: "z", count: 300)))
        XCTAssertEqual(cut, "[e4] Edit \"Notes\" (0,0 10x10) value=\"" + String(repeating: "값", count: 199) + "\\n…\"")
        let whole = UITreeText.line(node("e5", "Edit", "Notes", value: String(repeating: "v", count: 200)))
        XCTAssertEqual(whole, "[e5] Edit \"Notes\" (0,0 10x10) value=\"" + String(repeating: "v", count: 200) + "\"")
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
        XCTAssertEqual(move, ["window": moved, "eventSeq": 0])
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

    func testUITreeOfAnElementWithoutAWindow() async throws {
        let (h, _, _) = try await rig(["ui.tree": { _, _ in .ok(["window": .null, "nodes": [sendButton], "truncated": false]) }])
        let r = try await h.handle(op: "vm.ui.tree", params: ["name": "Win", "root": "e6000535"])
        XCTAssertEqual(r, ["tree": .string(UITreeText.render([sendButton])), "count": 1, "truncated": false, "window": .null])
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

        let byRef = try await h.handle(op: "vm.ui.find", params: ["name": "Win", "ref": "e6000535"])
        XCTAssertEqual(byRef, ["nodes": [sendButton], "text": .string(UITreeText.render([sendButton]))])
        XCTAssertEqual(fields(agentRequests(agent, "ui.rect").last), ["ref": "e6000535"])
        XCTAssertEqual(agentRequests(agent, "ui.find").count, 1)
    }

    func testUIFindReportsASearchThatRanOutOfTime() async throws {
        let (h, _, _) = try await rig(["ui.find": { m, _ in
            m["role"] == nil ? .ok(["nodes": []]) : .ok(["nodes": [sendButton], "truncated": true])
        }])
        let cut = try await h.handle(op: "vm.ui.find", params: ["name": "Win", "selector": ["role": "Button"]])
        XCTAssertEqual(cut, ["nodes": [sendButton], "truncated": true, "text": .string(UITreeText.render([sendButton])
            + "\n… the search ran out of time after these matches; add window or role to the selector, or read a part with vm.ui.tree and root")])
        let none = try await h.handle(op: "vm.ui.find", params: ["name": "Win", "selector": ["name": "Nothing"]])
        XCTAssertEqual(none, ["nodes": [], "text": ""])
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
        XCTAssertEqual(r, ["x": 190, "y": 112, "node": sendButton, "eventSeq": 0])
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
        let covered = "window 0x50 \"Fixture Dialog\" covers the centre of the element; focus the element's window with win.action"
        let (h, t, agent) = try await rig(["ui.rect": { m, _ in
            switch m["ref"]?.stringValue {
            case "e3": return .fail("element e3 no longer exists; call ui.tree again")
            case "e5": return .ok(["node": sendButton, "cx": 190, "cy": 112, "clickable": false, "blocked": .string(covered)])
            default: return .ok(["node": hidden, "cx": 0, "cy": 0, "clickable": false])
            }
        }])
        let text = await failure(h, "vm.ui.click", ["name": "Win", "ref": "e8", "observe": "summary", "settleMs": 20])
        XCTAssertEqual(text, "element e8 has no clickable point (off screen or covered); use vm.ui.action or scroll it into view")
        XCTAssertEqual(agentRequests(agent, "ui.rect").last?["scroll"]?.boolValue, true)

        let blocked = await failure(h, "vm.ui.click", ["name": "Win", "ref": "e5"])
        XCTAssertEqual(blocked, "element e5 has no clickable point: \(covered); or act on it with vm.ui.action")
        let blockedType = await failure(h, "vm.ui.type", ["name": "Win", "ref": "e5", "text": "x"])
        XCTAssertEqual(blockedType, "element e5 has no clickable point: \(covered); or act on it with vm.ui.action")

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
        XCTAssertEqual(r, ["node": messageEdit, "eventSeq": 0])
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
        XCTAssertEqual(r, ["node": after, "eventSeq": 0])
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
                           "observationError": "the screen could not be read after vm.ui.action: no surface is mapped; call vm.screenshot to see the result", "eventSeq": 0])
    }

    func testWindowAndElementActionsPassTheAgentsFlagsAndSentences() async throws {
        let disabled = "the element is disabled; wait until it is enabled"
        let unsupported = "the element does not support toggle; it supports invoke, focus; click it through the display for anything else"
        let hung = "window 0x400b8 \"Alcove Fixture (Not Responding)\" is not responding; wait and retry, or end its process with proc.kill "
            + "when win.list still shows responding false after 10 s"
        let crowded = "9 earlier ui.act calls are still running in the app; wait for them or end its process with proc.kill"
        let unlocked = "could not start the UI helper through PowerShell: the UI helper folder C:\\ProgramData\\Alcove\\uia could not be locked "
            + "(SetNamedSecurityInfo(C:\\ProgramData\\Alcove\\uia): Access is denied.); fix its owner and access list, then retry"
        let reparse = "C:\\ProgramData\\Alcove\\uia is a reparse point; remove it"
        let shutDown = "the UI helper is shut down; restart alcove-agent"
        let (h, _, _) = try await rig([
            "ui.tree": { _, n in .fail([unlocked, reparse, shutDown][min(n, 2)]) },
            "win.action": { m, _ in
                switch (m["action"]?.stringValue, m["window"]?.stringValue) {
                case ("close", "0x50"): return .ok(["closed": true, "window": .null])
                case ("close", _): return .ok(["closed": false, "window": fixtureWindow])
                case ("minimize", "0x400b8"): return .fail(hung)
                default: return .ok(["window": fixtureWindow])
                }
            },
            "ui.act": { m, _ in
                switch m["ref"]?.stringValue {
                case "e1": return .ok(["node": sendButton, "unresponsive": true])
                case "e2": return .ok(["node": sendButton, "gone": true])
                case "e3": return .fail(disabled)
                case "e4": return .fail(unsupported)
                case "e8": return .fail(crowded)
                case "e9": return .ok(["node": sendButton, "pending": true])
                default: return .fail(hung)
                }
            },
        ])
        let closed = try await h.handle(op: "vm.window.action", params: ["name": "Win", "window": "0x50", "action": "close"])
        XCTAssertEqual(closed, ["window": .null, "closed": true, "eventSeq": 0])
        let kept = try await h.handle(op: "vm.window.action", params: ["name": "Win", "window": "0x2a", "action": "close"])
        XCTAssertEqual(kept, ["window": fixtureWindow, "closed": false, "eventSeq": 0])
        let focused = try await h.handle(op: "vm.window.action", params: ["name": "Win", "window": "0x2a", "action": "focus"])
        XCTAssertEqual(focused, ["window": fixtureWindow, "eventSeq": 0])
        let notMinimized = await failure(h, "vm.window.action", ["name": "Win", "window": "0x400b8", "action": "minimize"])
        XCTAssertEqual(notMinimized, hung)

        let unresponsive = try await h.handle(op: "vm.ui.action", params: ["name": "Win", "ref": "e1", "action": "invoke"])
        XCTAssertEqual(unresponsive, ["node": sendButton, "unresponsive": true, "eventSeq": 0])
        let gone = try await h.handle(op: "vm.ui.action", params: ["name": "Win", "ref": "e2", "action": "invoke", "observe": "summary", "settleMs": 20])
        XCTAssertEqual(gone["node"], sendButton)
        XCTAssertEqual(gone["gone"], true)
        XCTAssertNil(gone["unresponsive"])
        XCTAssertEqual(gone["observation"]?["settled"]?.boolValue, true)
        let pending = try await h.handle(op: "vm.ui.action", params: ["name": "Win", "ref": "e9", "action": "invoke"])
        XCTAssertEqual(pending, ["node": sendButton, "pending": true, "eventSeq": 0])
        for (ref, sentence) in [("e3", disabled), ("e4", unsupported), ("e7", hung), ("e8", crowded)] {
            let text = await failure(h, "vm.ui.action", ["name": "Win", "ref": .string(ref), "action": "toggle"])
            XCTAssertEqual(text, sentence)
        }
        for sentence in [unlocked, reparse, shutDown] {
            let text = await failure(h, "vm.ui.tree", ["name": "Win"])
            XCTAssertEqual(text, sentence)
        }
    }

    // MARK: - launch

    func testHelperSentencesAreToldByTheirStableParts() {
        let cases: [(String, HelperSentence)] = [
            ("element e12 no longer exists; call ui.tree again", .staleRef("e12")),
            ("element e6000535 no longer exists; call ui.tree again", .staleRef("e6000535")),
            ("no element matches {\"name\":\"x is a reparse point; remove it\"}; call ui.tree to see what exists", .noMatch),
            ("no window has \"Chat is not responding; \" in its title; call win.list to see the open windows", .windowGone),
            ("window 0x50 no longer exists; call win.list again", .windowGone),
            ("the element is a password field; its text is not read; it cannot be read through UI Automation", .passwordField),
            ("the element is a password field; its text is not read", .passwordField),
            ("window 0x400b8 \"Alcove Fixture (Not Responding)\" is not responding; wait and retry, or end its process with proc.kill "
                + "when win.list still shows responding false after 10 s", .notResponding),
            ("window 0x9 \"File no longer exists\" is not responding; wait for it or end its process with proc.kill", .notResponding),
            ("the UI helper is shut down; restart alcove-agent", .shutDown),
            ("could not start the UI helper through PowerShell: the UI helper folder C:\\ProgramData\\Alcove\\uia could not be locked "
                + "(SetNamedSecurityInfo(C:\\ProgramData\\Alcove\\uia): Access is denied.); fix its owner and access list, then retry", .cannotStart),
            ("the UI helper folder D:\\x could not be locked (denied); fix its owner and access list, then retry", .cannotStart),
            ("C:\\ProgramData\\Alcove\\uia is a reparse point; remove it", .cannotStart),
            ("the request was cancelled", .cancelled),
            ("UI helper is closed", .other),
            ("UI helper exited; retry", .other),
            ("the UI helper is busy with 'ui.tree'; retry", .other),
            ("UI helper did not answer 'ui.find' within 20 s; it was restarted", .other),
            ("window 0x1 \"T\" was not minimized within 2 s; the app may not allow it", .other),
            ("element five no longer exists", .other),
            ("", .other),
        ]
        for (message, expected) in cases { XCTAssertEqual(HelperSentence(message), expected, message) }
        for (message, expected) in cases {
            XCTAssertEqual(HelperSentence(message).isPermanent, expected == .shutDown || expected == .cannotStart, message)
        }
        XCTAssertTrue(HelperSentence.staleRef("e5").saysAbsent(ref: "e5"))
        XCTAssertFalse(HelperSentence.staleRef("e5").saysAbsent(ref: "e6"))
        XCTAssertFalse(HelperSentence.staleRef("e5").saysAbsent(ref: nil, orNoMatch: true))
        XCTAssertFalse(HelperSentence.windowGone.saysAbsent(ref: "e5"))
        XCTAssertTrue(HelperSentence.windowGone.saysAbsent(ref: nil))
        XCTAssertFalse(HelperSentence.noMatch.saysAbsent(ref: nil))
        XCTAssertTrue(HelperSentence.noMatch.saysAbsent(ref: nil, orNoMatch: true))
        XCTAssertFalse(HelperSentence.notResponding.saysAbsent(ref: nil, orNoMatch: true))
    }

    func testAppLaunch() async throws {
        let (h, _, agent) = try await rig(["app.launch": { m, n in
            n == 0 ? .ok(["pid": 77, "window": fixtureWindow]) : m["path"]?.stringValue == "C:\\missing.exe"
                ? .fail("'C:\\missing.exe' does not exist in the guest; check the path") : .ok(["pid": 78])
        }])
        let r = try await h.handle(op: "vm.app.launch", params: [
            "name": "Win", "path": "C:\\앱 폴더\\app.exe", "args": ["--log", "C:\\logs\\x y.log"], "cwd": "C:\\앱 폴더",
            "env": ["MODE": "test"], "waitWindow": 2.5,
        ])
        XCTAssertEqual(r, ["pid": 77, "window": fixtureWindow, "eventSeq": 0])
        XCTAssertEqual(fields(agentRequests(agent, "app.launch").last), [
            "path": "C:\\앱 폴더\\app.exe", "args": ["--log", "C:\\logs\\x y.log"], "cwd": "C:\\앱 폴더", "env": ["MODE": "test"],
            "wait_window_ms": 2500,
        ])

        let plain = try await h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "notepad.exe"])
        XCTAssertEqual(plain, ["pid": 78, "windowTimedOut": true, "eventSeq": 0])
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
            if let op = m["op"]?.stringValue, script[op] != nil { return scripted(script, counts, m) { files?($0, a) ?? [] } }
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
            "exec.run": { _, _ in .ok(["code": 0, "stdout": "900\r\n", "stderr": "", "timed_out": false]) },
            "app.launch": { _, n in .ok(["pid": .int(Int64(77 + n)), "window": fixtureWindow]) },
        ])
        let launch: JSON = ["exe": "app.exe", "args": ["--log", "C:\\logs\\x y.log"], "env": ["MODE": "test"]]
        let r = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path), "launch": launch])
        XCTAssertEqual(r, ["guestDir": .string(guestDir), "sent": ["app.exe", "data/설정.json"], "skipped": 0, "bytes": 9,
                           "pid": 77, "window": fixtureWindow, "eventSeq": 0])
        XCTAssertEqual(fs[guestDir + "\\app.exe"], Data("new exe".utf8))
        XCTAssertEqual(fs[guestDir + "\\data\\설정.json"], Data("{}".utf8))
        XCTAssertNil(fs[guestDir + "\\old.dll"])
        XCTAssertNotNil(fs[guestDir + "\\.alcove-deploy"])

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
        XCTAssertTrue(agentRequests(agent, "exec.run").allSatisfy { $0["argv"] == nil })

        let again = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path), "launch": launch, "waitWindow": 0,
                                                                   "killRunning": false])
        XCTAssertEqual(again, ["guestDir": .string(guestDir), "sent": [], "skipped": 2, "bytes": 0, "pid": 78, "window": fixtureWindow, "eventSeq": 0])
        XCTAssertEqual(agentRequests(agent, "app.launch").last?["wait_window_ms"]?.intValue, 0)
        XCTAssertEqual(agentRequests(agent, "proc.kill").count, 1)
    }

    func testDeployPushesAFileAndResolvesLaunchPaths() async throws {
        let dir = try tempDir("out")
        let file = dir.appendingPathComponent("tool one.exe")
        try Data("binary".utf8).write(to: file)
        let fs = FakeFS()
        fs["D:\\apps\\tool one.exe"] = Data("previous".utf8)
        fs["D:\\apps\\.alcove-deploy"] = Data("x".utf8)
        let (h, agent) = try await deployRig(fs: fs, [
            "proc.list": { _, _ in .ok(["procs": []]) },
            "app.launch": { _, _ in .ok(["pid": 5]) },
        ])
        let r = try await h.handle(op: "vm.deploy", params: [
            "name": "Win", "path": .string(file.path), "guestDir": "D:\\apps\\",
            "launch": ["exe": "C:\\Windows\\notepad.exe", "cwd": "C:\\Users"], "waitWindow": 3,
        ])
        XCTAssertEqual(r, ["guestDir": "D:\\apps", "sent": ["tool one.exe"], "skipped": 0, "bytes": 6, "pid": 5, "windowTimedOut": true, "eventSeq": 0])
        XCTAssertEqual(fs["D:\\apps\\tool one.exe"], Data("binary".utf8))
        XCTAssertEqual(fields(agentRequests(agent, "app.launch").last), ["path": "C:\\Windows\\notepad.exe", "cwd": "C:\\Users", "wait_window_ms": 3000])

        let plain = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(file.path)])
        XCTAssertEqual(plain, ["guestDir": "C:\\alcove-apps\\tool one", "sent": ["tool one.exe"], "skipped": 0, "bytes": 6, "eventSeq": 0])
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
            "exec.run": { _, _ in .ok(["code": 0, "stdout": "900\r\n", "stderr": "", "timed_out": false]) },
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
        XCTAssertEqual(r, ["guestDir": "/opt/tool", "sent": ["run.sh"], "skipped": 0, "bytes": 1, "eventSeq": 0])
        XCTAssertEqual(fs["/opt/tool/run.sh"], Data("x".utf8))
        XCTAssertNotNil(fs["/opt/tool/.alcove-deploy"])
        XCTAssertTrue(agentRequests(agent, "proc.kill").isEmpty)
    }

    private func requestCount(_ agent: FakeAgent) -> Int {
        agent.received.filter { $0["t"]?.stringValue == "req" }.count
    }

    func testDeployRefusesUnsafeGuestFolders() async throws {
        let dir = try tempDir("build")
        let (h, agent) = try await deployRig(fs: FakeFS(), [:])
        let root = "is a filesystem root; pass a folder below it such as C:\\alcove-apps\\build"
        let system = "is a system or profile folder; pass a folder of its own such as C:\\alcove-apps\\build"
        let relative = "is not an absolute path; pass a full path such as C:\\alcove-apps\\build"
        let dots = "has a '.' or '..' segment; pass the folder's full path such as C:\\alcove-apps\\build"
        let apps = "holds every deployed app; pass a folder below it such as C:\\alcove-apps\\build"
        let cases: [(String, String)] = [
            ("C:\\", root), ("c:/", root), ("\\\\server\\share", root), ("\\\\server\\share\\", root),
            ("C:\\Windows", system), ("c:\\windows\\System32\\drivers", system), ("C:/WINDOWS/Temp", system),
            ("C:\\Program Files", system), ("C:\\Program Files (x86)\\", system), ("c:\\program files (arm)", system),
            ("C:\\ProgramData", system), ("C:\\ProgramData\\Alcove", system), ("C:\\programdata\\alcove\\uia", system),
            ("C:\\Users", system), ("C:\\Users\\alcove", system), ("C:\\Users\\alcove\\Desktop", system),
            ("C:\\Users\\alcove\\documents\\", system), ("C:\\Users\\alcove\\Downloads", system),
            ("C:\\Users\\alcove\\AppData", system), ("C:\\Users\\alcove\\AppData\\Local\\app", system),
            ("\\\\localhost\\C$\\Windows\\Temp", system),
            ("C:\\apps\\..\\Windows", dots), ("C:\\apps\\.\\x", dots), ("C:\\apps\\..", dots),
            ("apps\\x", relative), ("C:apps", relative), ("\\apps", relative), ("/opt/x", relative), ("\\\\server", relative),
            ("\\\\\\server\\share\\x", relative),
            ("C:\\alcove-apps", apps), ("c:/ALCOVE-APPS/", apps), ("C:\\alcove-apps\\\\", apps),
        ]
        for (guestDir, expected) in cases {
            let text = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.path), "guestDir": .string(guestDir)])
            XCTAssertEqual(text, "guestDir '\(guestDir)' \(expected)")
        }
        for (guestDir, segment) in [("C:\\apps\\CON", "CON"), ("C:\\apps\\nul.txt\\x", "nul.txt"), ("C:\\apps\\x.", "x."), ("C:\\apps \\x", "apps "),
                                    ("C:\\apps\\a<b", "a<b"), ("C:\\apps\\a:b", "a:b"), ("C:\\apps\\COM7", "COM7"), ("C:\\Windows.\\x", "Windows."),
                                    ("\\\\ser\u{1}ver\\share\\x", "ser\u{1}ver"), ("\\\\server\\sh<are\\x", "sh<are"), ("\\\\..\\share\\x", ".."),
                                    ("\\\\server\\.\\x", "."), ("//server/NUL/x", "NUL"), ("\\\\server.\\share\\x", "server.")] {
            let text = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.path), "guestDir": .string(guestDir)])
            XCTAssertEqual(text, "guestDir '\(guestDir)' has the segment '\(segment)', which Windows cannot use as a folder name; "
                           + "pass a plain folder path such as C:\\alcove-apps\\build")
        }
        for guestDir in ["\\\\?\\C:\\apps", "\\\\.\\C:\\apps", "//?/C:/apps", "\\\\?\\UNC\\server\\share\\apps", "\\\\.\\pipe", "\\\\?"] {
            let text = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.path), "guestDir": .string(guestDir)])
            XCTAssertEqual(text, "device paths such as \\\\?\\ cannot be used; pass a drive or share path", guestDir)
        }
        for (guestDir, segment) in [("C:\\PROGRA~1\\app", "PROGRA~1"), ("C:\\apps\\ALCOVE~2", "ALCOVE~2"), ("c:/users/alcove/docume~1/x", "docume~1"),
                                    ("C:\\ALCOVE~1", "ALCOVE~1"), ("D:\\a~9b\\x", "a~9b")] {
            let text = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.path), "guestDir": .string(guestDir)])
            XCTAssertEqual(text, "guestDir '\(guestDir)' has the short name '\(segment)'; pass the long path")
        }
        XCTAssertEqual(requestCount(agent), 0)
    }

    func testDeployRefusesUnsafeFoldersOfOtherGuests() async throws {
        let dir = try tempDir("tool")
        let (h, t, agent) = try await rig()
        await t.setOS(.linux)
        let root = "is a filesystem root; pass a folder below it such as /opt/tool"
        let system = "is a system or home folder; pass a folder of its own such as /opt/tool"
        let relative = "is not an absolute path of this guest; pass a full path such as /opt/tool"
        let dots = "has a '.' or '..' segment; pass the folder's full path such as /opt/tool"
        let cases: [(String, String)] = [
            ("/", root), ("//", root),
            ("/usr", system), ("/etc/", system), ("/bin", system), ("/sbin", system), ("/lib", system), ("/lib64", system), ("/var", system),
            ("/boot", system), ("/home", system), ("/home/alcove", system), ("/root", system), ("/opt", system), ("/USR", system),
            ("/opt/../etc", dots), ("/opt/./tool", dots),
            ("opt/tool", relative), ("C:\\alcove-apps\\tool", relative), ("/opt\\tool", relative),
        ]
        for (guestDir, expected) in cases {
            let text = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.path), "guestDir": .string(guestDir)])
            XCTAssertEqual(text, "guestDir '\(guestDir)' \(expected)")
        }
        XCTAssertEqual(requestCount(agent), 0)
    }

    func testDeployTargetAcceptsAndNormalisesOrdinaryFolders() throws {
        let windows: [(String, String)] = [
            ("C:\\alcove-apps\\앱 build", "C:\\alcove-apps\\앱 build"), ("d:/apps//tool/", "d:\\apps\\tool"),
            ("C:\\Program Files\\My App", "C:\\Program Files\\My App"), ("C:\\ProgramData\\MyApp", "C:\\ProgramData\\MyApp"),
            ("C:\\Users\\alcove\\Desktop\\app", "C:\\Users\\alcove\\Desktop\\app"), ("C:\\Users\\alcove\\source\\repo", "C:\\Users\\alcove\\source\\repo"),
            ("\\\\server\\share\\apps", "\\\\server\\share\\apps"), ("C:\\Windowsill", "C:\\Windowsill"),
            ("C:\\apps\\~tmp~", "C:\\apps\\~tmp~"), ("\\\\10.0.2.4\\C$\\apps", "\\\\10.0.2.4\\C$\\apps"), ("D:\\alcove-apps", "D:\\alcove-apps"),
            ("C:\\alcove-apps-2", "C:\\alcove-apps-2"),
        ]
        for (given, expected) in windows { XCTAssertEqual(try DeployTarget.directory(given, windows: true, example: "x"), expected) }
        let others: [(String, String)] = [
            ("/opt/tool", "/opt/tool"), ("/opt//tool/", "/opt/tool"), ("/home/alcove/app", "/home/alcove/app"), ("/usr/local/app", "/usr/local/app"),
            ("/srv", "/srv"), ("/opt/lib", "/opt/lib"), ("/opt/TOOL~1", "/opt/TOOL~1"),
        ]
        for (given, expected) in others { XCTAssertEqual(try DeployTarget.directory(given, windows: false, example: "x"), expected) }
        XCTAssertTrue(DeployTarget.isUnderDefaultRoot("c:\\ALCOVE-APPS\\x"))
        XCTAssertFalse(DeployTarget.isUnderDefaultRoot("C:\\alcove-apps"))
        XCTAssertFalse(DeployTarget.isUnderDefaultRoot("C:\\alcove-apps-2\\x"))
        XCTAssertFalse(DeployTarget.isUnderDefaultRoot("D:\\alcove-apps\\x"))
    }

    func testDeployChecksTheHostPathAndTheDefaultFolderName() async throws {
        let dir = try tempDir("앱 build")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("data"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("app.exe"))
        let parent = dir.deletingLastPathComponent()
        let names = ["CON", "nul.d", "a:b", "tail.", "tail ", "q?", "LPT1"]
        for name in names { try FileManager.default.createDirectory(at: parent.appendingPathComponent(name), withIntermediateDirectories: true) }
        try Data("x".utf8).write(to: parent.appendingPathComponent("aux.exe"))
        try Data("x".utf8).write(to: parent.appendingPathComponent(".alcove-deploy"))
        let fs = FakeFS()
        let (h, agent) = try await deployRig(fs: fs, ["proc.list": { _, _ in .ok(["procs": []]) }])

        for path in ["build", "./build", "~/build", ""] {
            let text = await failure(h, "vm.deploy", ["name": "Win", "path": .string(path)])
            XCTAssertEqual(text, "pass an absolute host path", path)
        }
        for name in names {
            let text = await failure(h, "vm.deploy", ["name": "Win", "path": .string(parent.appendingPathComponent(name).path)])
            XCTAssertEqual(text, "pass guestDir; '\(name)' cannot be used as a folder name")
        }
        let file = await failure(h, "vm.deploy", ["name": "Win", "path": .string(parent.appendingPathComponent("aux.exe").path)])
        XCTAssertEqual(file, "pass guestDir; 'aux' cannot be used as a folder name")
        let top = await failure(h, "vm.deploy", ["name": "Win", "path": "/"])
        XCTAssertEqual(top, "pass guestDir; '/' cannot be used as a folder name")
        let up = await failure(h, "vm.deploy", ["name": "Win", "path": "/.."])
        XCTAssertEqual(up, "pass guestDir; '/' cannot be used as a folder name")
        let marker = await failure(h, "vm.deploy", ["name": "Win", "path": .string(parent.appendingPathComponent(".alcove-deploy").path)])
        XCTAssertEqual(marker, "a file named .alcove-deploy cannot be deployed, vm.deploy keeps its own file under that name; rename the file")
        for name in [".alcove-deploy", ".ALCOVE-Deploy"] {
            let holder = try tempDir("holder")
            try Data("x".utf8).write(to: holder.appendingPathComponent("app.exe"))
            try Data("mine".utf8).write(to: holder.appendingPathComponent(name))
            let inside = await failure(h, "vm.deploy", ["name": "Win", "path": .string(holder.path)])
            XCTAssertEqual(inside, "a file named .alcove-deploy cannot be deployed, vm.deploy keeps its own file under that name; rename the file", name)
        }
        let folder = try tempDir("folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".alcove-deploy"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent(".alcove-deploy/app.exe"))
        let asFolder = await failure(h, "vm.deploy", ["name": "Win", "path": .string(folder.path)])
        XCTAssertEqual(asFolder, "a file named .alcove-deploy cannot be deployed, vm.deploy keeps its own file under that name; rename the file")
        XCTAssertEqual(requestCount(agent), 0)

        let r = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path + "/data/../")])
        XCTAssertEqual(r["guestDir"], "C:\\alcove-apps\\앱 build")
        XCTAssertEqual(r["sent"], ["app.exe"])
        XCTAssertFalse(agent.received.contains { ($0["path"]?.stringValue ?? "").contains("..") })
    }

    func testDeployRefusesAFolderThatHoldsForeignFiles() async throws {
        let dir = try tempDir("build")
        try Data("new".utf8).write(to: dir.appendingPathComponent("app.exe"))
        let fs = FakeFS()
        fs["D:\\data\\notes.txt"] = Data("mine".utf8)
        fs["D:\\data\\sub\\more.txt"] = Data("mine".utf8)
        fs["D:\\file.bin"] = Data("x".utf8)
        let (h, agent) = try await deployRig(fs: fs, ["proc.list": { _, _ in .ok(["procs": [["pid": 5, "name": "x.exe", "path": "D:\\data\\x.exe"]]]) }])
        let before = fs.paths()
        for given in ["D:\\data", "d:/DATA/"] {
            let text = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.path), "guestDir": .string(given)])
            let shown = given == "D:\\data" ? given : "d:\\DATA"
            XCTAssertEqual(text, "'\(shown)' already holds files that Alcove did not deploy; choose an empty or new folder, or one under C:\\alcove-apps")
        }
        let aFile = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.path), "guestDir": "D:\\file.bin"])
        XCTAssertEqual(aFile, "'D:\\file.bin' is a file in the guest; pass a folder as guestDir")
        XCTAssertEqual(fs.paths(), before)
        let ops = Set(agent.received.compactMap { $0["op"]?.stringValue })
        XCTAssertTrue(ops.isSubset(of: ["fs.stat", "fs.list"]), "\(ops)")
    }

    func testDeployIntoAFolderItDeployedBefore() async throws {
        let dir = try tempDir("build")
        try Data("new".utf8).write(to: dir.appendingPathComponent("app.exe"))
        let fs = FakeFS()
        fs["D:\\tools\\mine\\app.exe"] = Data("old".utf8)
        fs["D:\\tools\\mine\\stale.dll"] = Data("old".utf8)
        fs["D:\\tools\\mine\\.alcove-deploy"] = Data("earlier".utf8)
        let (h, _) = try await deployRig(fs: fs, ["proc.list": { _, _ in .ok(["procs": []]) }])
        let r = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path), "guestDir": "D:\\tools\\mine"])
        XCTAssertEqual(r, ["guestDir": "D:\\tools\\mine", "sent": ["app.exe"], "skipped": 0, "bytes": 3, "eventSeq": 0])
        XCTAssertEqual(fs.paths(), ["D:\\tools\\mine\\.alcove-deploy", "D:\\tools\\mine\\app.exe"])
        XCTAssertEqual(fs["D:\\tools\\mine\\.alcove-deploy"], Data(DeployTarget.markerText.utf8))

        let fresh = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path), "guestDir": "D:\\tools\\new one"])
        XCTAssertEqual(fresh["sent"], ["app.exe"])
        XCTAssertNotNil(fs["D:\\tools\\new one\\.alcove-deploy"])
        let again = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path), "guestDir": "D:\\tools\\new one"])
        XCTAssertEqual(again, ["guestDir": "D:\\tools\\new one", "sent": [], "skipped": 1, "bytes": 0, "eventSeq": 0])
    }

    func testDeployMarksItsFolderBeforeItCopies() async throws {
        let dir = try tempDir("partial")
        try Data("library".utf8).write(to: dir.appendingPathComponent("a.dll"))
        try Data("program".utf8).write(to: dir.appendingPathComponent("b.exe"))
        let guestDir = "D:\\fresh\\partial"
        let full = LockedBox(true)
        let fs = FakeFS()
        let (h, agent) = try await deployRig(fs: fs, [
            "proc.list": { _, _ in .ok(["procs": []]) },
            "fs.rename": { m, _ in full.value && m["to"]?.stringValue == guestDir + "\\b.exe" ? .fail("the disk is full") : .fileSystem },
        ])
        let params: JSON = ["name": "Win", "path": .string(dir.path), "guestDir": .string(guestDir)]
        let stopped = await failure(h, "vm.deploy", params)
        XCTAssertEqual(stopped, "the disk is full")
        XCTAssertEqual(fs.paths(), [guestDir + "\\.alcove-deploy", guestDir + "\\a.dll"])
        XCTAssertEqual(fs.written().first, guestDir + "\\.alcove-deploy")

        full.value = false
        let retried = try await h.handle(op: "vm.deploy", params: params)
        XCTAssertEqual(retried, ["guestDir": .string(guestDir), "sent": ["b.exe"], "skipped": 1, "bytes": 7, "eventSeq": 0])
        XCTAssertEqual(fs.paths(), [guestDir + "\\.alcove-deploy", guestDir + "\\a.dll", guestDir + "\\b.exe"])
        XCTAssertEqual(agentRequests(agent, "fs.write").filter { $0["path"]?.stringValue == guestDir + "\\.alcove-deploy" }.count, 2)

        let file = dir.appendingPathComponent("b.exe")
        let single = "D:\\fresh\\single"
        full.value = true
        let pushed = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(file.path), "guestDir": .string(single)])
        XCTAssertEqual(pushed["sent"], ["b.exe"])
        let writes = agentRequests(agent, "fs.write").compactMap { $0["path"]?.stringValue }.filter { $0.hasPrefix(single) }
        XCTAssertEqual(writes.first, single + "\\.alcove-deploy")
    }

    func testDeployRefusesAGuestFolderThatIsALink() async throws {
        let dir = try tempDir("linked")
        try Data("new".utf8).write(to: dir.appendingPathComponent("app.exe"))
        let fs = FakeFS()
        fs.links = ["D:\\link", "C:\\alcove-apps\\linked"]
        fs["D:\\link\\.alcove-deploy"] = Data("planted".utf8)
        let (h, agent) = try await deployRig(fs: fs, ["proc.list": { _, _ in .ok(["procs": []]) }])
        let before = fs.paths()
        for (given, shown) in [("D:\\link", "D:\\link"), ("d:/LINK/", "d:\\LINK")] {
            let text = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.path), "guestDir": .string(given)])
            XCTAssertEqual(text, "'\(shown)' is a link in the guest; pass the folder it points to")
        }
        let underTheAppsFolder = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.path)])
        XCTAssertEqual(underTheAppsFolder, "'C:\\alcove-apps\\linked' is a link in the guest; pass the folder it points to")
        let file = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.appendingPathComponent("app.exe").path), "guestDir": "D:\\link"])
        XCTAssertEqual(file, "'D:\\link' is a link in the guest; pass the folder it points to")
        XCTAssertEqual(fs.paths(), before)
        XCTAssertTrue(fs.written().isEmpty)
        XCTAssertEqual(Set(agent.received.compactMap { $0["op"]?.stringValue }), ["fs.stat"])
    }

    func testDeployDoesNotWriteThroughALinkBelowItsFolder() async throws {
        let dir = try tempDir("nested")
        try Data("new".utf8).write(to: dir.appendingPathComponent("app.exe"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Data/cache"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("Data/cache/state.json"))
        let guestDir = "C:\\alcove-apps\\nested"
        let fs = FakeFS()
        fs[guestDir + "\\app.exe"] = Data("old".utf8)
        let (h, agent) = try await deployRig(fs: fs, ["proc.list": { _, _ in .ok(["procs": []]) }])
        let params: JSON = ["name": "Win", "path": .string(dir.path)]

        for reported in [true, false] {
            fs.reportsLinks = reported
            fs.links = [guestDir + "\\data\\cache"]
            let deep = await failure(h, "vm.deploy", params)
            XCTAssertEqual(deep, reported ? "'\(guestDir)\\data\\cache' in the guest is a link; remove it or deploy to another folder"
                                          : "'\(guestDir)\\data\\cache' in the guest is not a folder; remove it or deploy to another folder")
            fs.links = [guestDir + "\\DATA"]
            let top = await failure(h, "vm.deploy", params)
            XCTAssertEqual(top, reported ? "'\(guestDir)\\DATA' in the guest is a link; remove it or deploy to another folder"
                                         : "'\(guestDir)\\DATA' in the guest is not a folder; remove it or deploy to another folder")
        }
        XCTAssertEqual(fs[guestDir + "\\app.exe"], Data("old".utf8))
        XCTAssertEqual(Set(fs.written()), [guestDir + "\\.alcove-deploy"])
        XCTAssertTrue(agentRequests(agent, "fs.rename").isEmpty)

        fs.links = []
        fs.reportsLinks = true
        fs[guestDir + "\\Data"] = Data("a file".utf8)
        let aFile = await failure(h, "vm.deploy", params)
        XCTAssertEqual(aFile, "'\(guestDir)\\Data' in the guest is not a folder; remove it or deploy to another folder")

        fs[guestDir + "\\Data"] = nil
        fs.links = [guestDir + "\\other", guestDir + "\\app.exe.bak"]
        let r = try await h.handle(op: "vm.deploy", params: params)
        XCTAssertEqual(r["sent"], ["Data/cache/state.json", "app.exe"])
    }

    func testDeployTreatsALinkedFolderOfAnAgentThatDoesNotReportLinksAsAFolder() async throws {
        let dir = try tempDir("older")
        try Data("new".utf8).write(to: dir.appendingPathComponent("app.exe"))
        let fs = FakeFS()
        fs.links = ["D:\\link"]
        fs.reportsLinks = false
        let (h, _) = try await deployRig(fs: fs, ["proc.list": { _, _ in .ok(["procs": []]) }])
        let r = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path), "guestDir": "D:\\link"])
        XCTAssertEqual(r["sent"], ["app.exe"])
    }

    func testDeployTakesTheMarkerOnlyWhenItIsAFile() async throws {
        let dir = try tempDir("marked")
        try Data("new".utf8).write(to: dir.appendingPathComponent("app.exe"))
        let fs = FakeFS()
        fs["D:\\data\\.alcove-deploy\\notes.txt"] = Data("mine".utf8)
        fs["D:\\data\\report.docx"] = Data("mine".utf8)
        fs["D:\\photos\\cat.jpg"] = Data("mine".utf8)
        fs.links = ["D:\\photos\\.alcove-deploy"]
        let (h, agent) = try await deployRig(fs: fs, ["proc.list": { _, _ in .ok(["procs": []]) }])
        let before = fs.paths()
        for folder in ["D:\\data", "D:\\photos"] {
            let text = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.path), "guestDir": .string(folder)])
            XCTAssertEqual(text, "'\(folder)' already holds files that Alcove did not deploy; choose an empty or new folder, or one under C:\\alcove-apps")
        }
        XCTAssertEqual(fs.paths(), before)
        XCTAssertTrue(Set(agent.received.compactMap { $0["op"]?.stringValue }).isSubset(of: ["fs.stat", "fs.list"]))
    }

    func testACancelledDeployDoesNotRunAfterItsWait() async throws {
        let dir = try tempDir("first")
        try Data("x".utf8).write(to: dir.appendingPathComponent("app.exe"))
        let other = try tempDir("second")
        try Data("y".utf8).write(to: other.appendingPathComponent("app.exe"))
        let fs = FakeFS()
        let (h, agent) = try await deployRig(fs: fs, ["proc.list": { _, n in n == 0 ? .silent : .ok(["procs": []]) }])
        let first = Task { try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path)]) }
        let inside = await eventually { agentRequests(agent, "proc.list").count == 1 }
        XCTAssertTrue(inside)
        let second = Task { try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(other.path)]) }
        let queued = await eventually { await h.deployGate.waiterCount(for: "Win") == 1 }
        XCTAssertTrue(queued)
        second.cancel()
        agent.sendLine(agentReply(try XCTUnwrap(agentRequests(agent, "proc.list").first), ["procs": []]))
        _ = try await completed(first)
        do {
            let value = try await finished(second)
            XCTFail(value == nil ? "the cancelled deploy stayed in the queue" : "the cancelled deploy ran")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(agent.received.contains { ($0["path"]?.stringValue ?? "").contains("second") })
        XCTAssertFalse(fs.paths().contains { $0.contains("second") })
        let free = await eventually { await h.deployGate.waiterCount(for: "Win") == 0 }
        XCTAssertTrue(free)
        let third = try await completed(Task { try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(other.path)]) })
        XCTAssertEqual(third["sent"], ["app.exe"])
    }

    func testDeployNeverStopsTheAgentOrItsParents() async throws {
        let dir = try tempDir("svc")
        try Data("x".utf8).write(to: dir.appendingPathComponent("app.exe"))
        let guestDir = "C:\\alcove-apps\\svc"
        let procs = LockedBox<[JSON]>([])
        let probe = LockedBox<Answer>(.ok(["code": 0, "stdout": "500\r\n", "stderr": "", "timed_out": false]))
        let fs = FakeFS()
        let (h, agent) = try await deployRig(fs: fs, [
            "proc.list": { _, _ in .ok(["procs": .array(procs.value)]) },
            "proc.kill": { _, _ in .ok(["killed": 1]) },
            "exec.run": { _, _ in probe.value },
        ])
        let app: JSON = ["pid": 10, "ppid": 1, "name": "app.exe", "path": .string(guestDir + "\\app.exe")]
        let params: JSON = ["name": "Win", "path": .string(dir.path)]

        procs.value = [app, ["pid": 500, "ppid": 400, "name": "alcove-agent.exe", "path": .string(guestDir + "\\alcove-agent.exe")],
                       ["pid": 400, "ppid": 4, "name": "services.exe", "path": "C:\\Windows\\System32\\services.exe"]]
        let own = await failure(h, "vm.deploy", params)
        XCTAssertEqual(own, "the guest agent or a process that started it (alcove-agent.exe, pid 500) runs from '\(guestDir)'; pass another guestDir")

        procs.value = [app, ["pid": 500, "ppid": 400, "name": "alcove-agent.exe", "path": "C:\\ProgramData\\Alcove\\alcove-agent.exe"],
                       ["pid": 400, "ppid": 300, "name": "cmd.exe", "path": "C:\\Windows\\System32\\cmd.exe"],
                       ["pid": 300, "ppid": 300, "name": "start.exe", "path": .string("c:\\ALCOVE-APPS\\SVC\\bin\\start.exe")]]
        let parent = await failure(h, "vm.deploy", params)
        XCTAssertEqual(parent, "the guest agent or a process that started it (start.exe, pid 300) runs from '\(guestDir)'; pass another guestDir")

        procs.value = [app]
        for answer in [Answer.fail("exec is disabled"), .ok(["code": 1, "stdout": "", "stderr": "no", "timed_out": false]),
                       .ok(["code": 0, "stdout": "not a number", "stderr": "", "timed_out": false])] {
            probe.value = answer
            let unknown = await failure(h, "vm.deploy", params)
            XCTAssertEqual(unknown, "vm.deploy could not find the guest agent's own process, so it stopped nothing under '\(guestDir)'; "
                           + "stop the running copies with vm.process.kill, or pass killRunning: false")
        }
        XCTAssertTrue(agentRequests(agent, "proc.kill").isEmpty)
        XCTAssertTrue(agentRequests(agent, "fs.write").isEmpty)
        XCTAssertTrue(fs.paths().isEmpty)
        XCTAssertEqual(fields(agentRequests(agent, "exec.run").first)["cmd"]?.stringValue,
                       "(Get-CimInstance Win32_Process -Filter \"ProcessId=$PID\").ParentProcessId")
    }

    func testDeployKeepsRelativeInstallAndLaunchPathsInsideTheFolder() async throws {
        let dir = try tempDir("inside")
        let (h, agent) = try await deployRig(fs: FakeFS(), [:])
        let path = JSON.string(dir.path)
        for exe in ["..\\..\\Windows\\System32\\cmd.exe", "bin/../../x.exe", "./x.exe", "bin\\.\\x.exe", "..",
                    ".. \\..\\x.exe", "...\\x.exe", "bin\\.. \\x.exe", "bin/. /x.exe", "bin\\x.exe.", "bin\\x.exe ", "NUL\\x.exe", "a<b\\x.exe", "bin\\x\u{7}.exe"] {
            let text = await failure(h, "vm.deploy", ["name": "Win", "path": path, "launch": ["exe": .string(exe)]])
            XCTAssertEqual(text, "launch.exe must stay inside guestDir; pass an absolute path to start something else", exe)
        }
        for file in ["..\\setup.msi", "pkg/../../setup.exe", "./setup.exe", ".. \\setup.msi", "...\\setup.exe", "pkg\\setup.exe.", "aux.d\\setup.exe"] {
            let text = await failure(h, "vm.deploy", ["name": "Win", "path": path, "install": ["kind": "exe", "file": .string(file)]])
            XCTAssertEqual(text, "install.file must stay inside guestDir; pass an absolute path to run something else", file)
        }
        XCTAssertEqual(requestCount(agent), 0)
    }

    func testDeploysOfOneVMRunOneAtATime() async throws {
        let dir = try tempDir("serial")
        try Data("x".utf8).write(to: dir.appendingPathComponent("app.exe"))
        let (h, agent) = try await deployRig(fs: FakeFS(), ["proc.list": { _, n in n == 0 ? .silent : .ok(["procs": []]) }])
        let params: JSON = ["name": "Win", "path": .string(dir.path)]
        let first = Task { try await h.handle(op: "vm.deploy", params: params) }
        let inside = await eventually { agentRequests(agent, "proc.list").count == 1 }
        XCTAssertTrue(inside)
        let sentByFirst = requestCount(agent)

        let second = Task { try await h.handle(op: "vm.deploy", params: params) }
        let queued = await eventually { await h.deployGate.waiterCount(for: "Win") == 1 }
        XCTAssertTrue(queued)
        XCTAssertEqual(requestCount(agent), sentByFirst)

        agent.sendLine(agentReply(try XCTUnwrap(agentRequests(agent, "proc.list").first), ["procs": []]))
        let one = try await first.value
        XCTAssertEqual(one["sent"], ["app.exe"])
        let two = try await second.value
        XCTAssertEqual(two["sent"], [])
        XCTAssertEqual(two["skipped"]?.intValue, 1)
    }

    func testLaunchReportsAWindowThatDidNotAppear() async throws {
        let dir = try tempDir("launching")
        try Data("x".utf8).write(to: dir.appendingPathComponent("app.exe"))
        let (h, agent) = try await deployRig(fs: FakeFS(), [
            "proc.list": { _, _ in .ok(["procs": []]) },
            "app.launch": { m, _ in
                switch m["args"]?[0]?.stringValue {
                case "window": return .ok(["pid": 7, "window": fixtureWindow])
                case "broken": return .fail("'C:\\alcove-apps\\launching\\app.exe' is not a valid application; check the file")
                default: return .ok(["pid": 7, "window": .null])
                }
            },
        ])
        let none = try await h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "app.exe", "waitWindow": 1])
        XCTAssertEqual(none, ["pid": 7, "windowTimedOut": true, "eventSeq": 0])
        let unwaited = try await h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "app.exe", "waitWindow": 0])
        XCTAssertEqual(unwaited, ["pid": 7, "eventSeq": 0])
        let shown = try await h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "app.exe", "args": ["window"]])
        XCTAssertEqual(shown, ["pid": 7, "window": fixtureWindow, "eventSeq": 0])

        let deployed = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path), "launch": ["exe": "app.exe"]])
        XCTAssertEqual(deployed["windowTimedOut"], true)
        XCTAssertNil(deployed["window"])
        let withWindow = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path),
                                                                        "launch": ["exe": "app.exe", "args": ["window"]]])
        XCTAssertNil(withWindow["windowTimedOut"])
        let unwaitedDeploy = try await h.handle(op: "vm.deploy", params: ["name": "Win", "path": .string(dir.path), "launch": ["exe": "app.exe"],
                                                                           "waitWindow": 0])
        XCTAssertNil(unwaitedDeploy["windowTimedOut"])

        let broken = await failure(h, "vm.deploy", ["name": "Win", "path": .string(dir.path), "launch": ["exe": "app.exe", "args": ["broken"]]])
        XCTAssertEqual(broken, "the files were copied to C:\\alcove-apps\\launching, but starting C:\\alcove-apps\\launching\\app.exe failed: "
                       + "'C:\\alcove-apps\\launching\\app.exe' is not a valid application; check the file")
        XCTAssertEqual(agentRequests(agent, "app.launch").count, 7)
    }

    // MARK: - events

    func testEventsOp() async throws {
        let (h, t, agent) = try await rig()
        let empty = try await h.handle(op: "vm.events", params: ["name": "Win"])
        XCTAssertEqual(empty, ["events": [], "next": 0, "first": 0])

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
        XCTAssertEqual(tail["first"]?.intValue, 1)
        let none = try await h.handle(op: "vm.events", params: ["name": "Win", "since": 2])
        XCTAssertEqual(none, ["events": [], "next": 2, "first": 1])
        let fromAnEarlierServer = try await h.handle(op: "vm.events", params: ["name": "Win", "since": 3])
        XCTAssertEqual(fromAnEarlierServer["events"]?.arrayValue?.map { $0["seq"]?.intValue }, [1, 2])
        XCTAssertEqual(fromAnEarlierServer["next"]?.intValue, 2)

        for since: JSON in [-1, "2", 1.5] {
            let text = await failure(h, "vm.events", ["name": "Win", "since": since])
            XCTAssertEqual(text, "since must be an integer of 0 or more; pass the next value of an earlier vm.events reply")
        }

        await t.setState(.stopped)
        let stopped = try await h.handle(op: "vm.events", params: ["name": "Win", "since": 1])
        XCTAssertEqual(stopped["events"]?.arrayValue?.count, 1)
    }

    func testEventsOpNamesTheOldestEventItStillHolds() async throws {
        let (h, t, agent) = try await rig()
        let count = EventBuffer.capacity + 40
        for i in 1...count { agent.sendLine(["t": "ev", "name": "job.exited", "job": .string("j\(i)"), "code": 0]) }
        let arrived = await eventually { await t.events(since: 0).next == count }
        XCTAssertTrue(arrived)
        let r = try await h.handle(op: "vm.events", params: ["name": "Win", "since": 10])
        XCTAssertEqual(r["first"]?.intValue, 41)
        XCTAssertEqual(r["next"]?.intValue, count)
        XCTAssertEqual(r["events"]?[0]?["seq"]?.intValue, 41)
        XCTAssertEqual(r["events"]?.arrayValue?.count, EventBuffer.capacity)
    }

    func testAnEventThatCountsDroppedEventsIsKeptLikeAnyOther() async throws {
        let (h, t, agent) = try await rig(["ui.focused": { _, _ in .ok(["node": messageEdit, "window": fixtureWindow]) }])
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "observe": "summary", "settleMs": 20])
        agent.sendLine(["t": "ev", "name": "window.opened", "window": fixtureWindow])
        agent.sendLine(["t": "ev", "name": "events.dropped", "count": 37])
        let arrived = await eventually { await t.events(since: 0).next == 2 }
        XCTAssertTrue(arrived)

        let listed = try await h.handle(op: "vm.events", params: ["name": "Win", "since": 1])
        XCTAssertEqual(listed["events"], [["seq": 2, "time": listed["events"]?[0]?["time"] ?? .null, "name": "events.dropped", "count": 37]])
        let matched = try await waitFor(h, [["type": "event", "event": "window.closed"], ["type": "event", "event": "events.dropped"]])
        XCTAssertEqual(matched["matched"]?.intValue, 1)
        XCTAssertEqual(matched["detail"]?["seq"]?.intValue, 2)
        XCTAssertEqual(matched["detail"]?["count"]?.intValue, 37)
        let observed = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "a", "observe": "summary", "settleMs": 20])
        XCTAssertEqual(observed["observation"]?["events"], ["window.opened \"Alcove Fixture\"", "events.dropped (37)"])
    }

    func testRepliesOfChangingOpsCarryTheEventSequence() async throws {
        let (h, t, agent) = try await rig([
            "win.list": { _, _ in .ok(["windows": []]) },
            "fs.write": { _, _ in .ok(["size": 2]) },
            "fs.read": { _, _ in .ok(["data": "", "size": 0, "eof": true]) },
        ])
        let first = try await h.handle(op: "vm.key.down", params: ["name": "Win", "key": "shift"])
        XCTAssertEqual(first, ["eventSeq": 0])
        agent.sendLine(["t": "ev", "name": "window.opened", "window": fixtureWindow])
        agent.sendLine(["t": "ev", "name": "window.foreground", "window": fixtureWindow])
        let arrived = await eventually { await t.events(since: 0).next == 2 }
        XCTAssertTrue(arrived)
        let input = try await h.handle(op: "vm.key.up", params: ["name": "Win", "key": "shift"])
        XCTAssertEqual(input, ["eventSeq": 2])
        let written = try await h.handle(op: "vm.fs.write", params: ["name": "Win", "path": "C:\\x.txt", "text": "hi"])
        XCTAssertEqual(written["eventSeq"]?.intValue, 2)
        let batch = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": [["op": "vm.key.press", "keys": "a"]]])
        XCTAssertEqual(batch, ["completed": 1, "results": [[:]], "eventSeq": 2])
        for (op, params) in [("vm.window.list", ["name": "Win"] as JSON), ("vm.events", ["name": "Win"]), ("vm.screenshot", ["name": "Win"]),
                             ("vm.status", ["name": "Win"]), ("vm.wait_for", ["name": "Win", "timeout": 1, "conditions": [["type": "screen_idle", "seconds": 0]]])] {
            let r = try await h.handle(op: op, params: params)
            XCTAssertNil(r["eventSeq"], op)
        }
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
        agent.sendLine(["t": "ev", "name": "dialog.opened", "window": window("0x50", "Fixture \"Dialog\"", x: 0, y: 0, w: 10, h: 10)])
        agent.sendLine(["t": "ev", "name": "window.foreground", "window": window("0x100ce", "", x: 0, y: 752, w: 1280, h: 48)])
        agent.sendLine(["t": "ev", "name": "process.exited", "pid": 44, "code": 3, "path": "C:\\apps\\crash me.exe"])
        agent.sendLine(["t": "ev", "name": "job.exited", "job": "j7", "code": 0])
        let arrived = await eventually { await t.events(since: 0).next == 5 }
        XCTAssertTrue(arrived)

        let second = try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "a", "observe": "summary", "settleMs": 20])
        XCTAssertEqual(second["observation"]?["events"],
                       ["window.opened \"Alcove Fixture\"", "dialog.opened \"Fixture \\\"Dialog\\\"\"", "window.foreground alcove-fixture.exe",
                        "process.exited crash me.exe code 3", "job.exited j7 code 0"])
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
        for i in 1...25 { agent.sendLine(["t": "ev", "name": "window.title", "window": window("0x3b", "t\(i)", x: 0, y: 0, w: 10, h: 10)]) }
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

    func testObservationOfAVMWhoseToolsAreNotConnectedYet() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 64, height: 64))
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test")
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5])
        var calls = await t.agentCalls
        XCTAssertTrue(calls.isEmpty)

        let summary = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "observe": "summary", "settleMs": 20])
        XCTAssertEqual(summary["observation"]?.objectValue?.keys.sorted(), ["changedFraction", "height", "settled", "width"])
        calls = await t.agentCalls
        let sentByTheFirstClick = 5
        XCTAssertEqual(calls.first?.timeout, .zero)
        XCTAssertEqual(calls.first?.sent, sentByTheFirstClick)
        XCTAssertTrue(calls.allSatisfy { $0.timeout == .zero })

        let ui: JSON = ["name": "Win", "x": 5, "y": 5, "observe": "ui", "settleMs": 20]
        let unreachable = try await h.handle(op: "vm.mouse.click", params: ui)
        XCTAssertEqual(unreachable["observation"]?["uiError"]?.stringValue, "the guest tools are not connected; UI facts need alcove-agent running in the guest")
        await t.setConnectingAgent(true)
        let connecting = try await h.handle(op: "vm.mouse.click", params: ui)
        XCTAssertEqual(connecting["observation"]?["uiError"]?.stringValue, "the guest tools are not connected yet; the next observation will carry the UI facts")
        await t.setConnectingAgent(false)
        let summaryAgain = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "observe": "summary", "settleMs": 20])
        XCTAssertNil(summaryAgain["observation"]?["uiError"])

        let before = await (t.agentCalls.count, t.sent.count)
        _ = try await h.handle(op: "vm.batch", params: ["name": "Win", "observe": "summary", "settleMs": 20, "steps": [["op": "vm.key.press", "keys": "a"]]])
        calls = await t.agentCalls
        XCTAssertEqual(calls[before.0].sent, before.1)
        XCTAssertEqual(calls[before.0].timeout, .zero)
    }

    func testAnOpLooksItsVMUpOnce() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 64, height: 64))
        let registry = CountingRegistry(t)
        let h = ControlHandler(registry: registry, hostKind: "test")
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5])
        var lookups = await registry.lookups
        XCTAssertEqual(lookups, 1)
        _ = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": [["op": "vm.key.press", "keys": "a"], ["op": "vm.mouse.move", "x": 1, "y": 1]]])
        lookups = await registry.lookups
        XCTAssertEqual(lookups, 2)
        _ = try await h.handle(op: "vm.screenshot", params: ["name": "Win"])
        lookups = await registry.lookups
        XCTAssertEqual(lookups, 3)
        let missing = await failure(h, "vm.mouse.click", ["name": "Other", "x": 5, "y": 5])
        XCTAssertEqual(missing, "no VM named 'Other'; call vm.list")
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
        let disabled = node("e5", "Button", "Send", flags: ["disabled"])
        let (h, _, agent) = try await rig(["ui.find": { m, n in
            switch m["name"]?.stringValue {
            case "Send": return .ok(["nodes": n < 2 ? [] : [sendButton]])
            case "Busy": return .ok(["nodes": n < 5 ? [sendButton] : []])
            default: return .ok(["nodes": [n < 8 ? disabled : sendButton]])
            }
        }])
        let exists = try await waitFor(h, [["type": "ui_exists", "window": "Alcove", "role": "Button", "name": "Send", "index": 0]])
        XCTAssertEqual(exists["matched"]?.intValue, 0)
        XCTAssertEqual(exists["type"]?.stringValue, "ui_exists")
        XCTAssertEqual(exists["detail"], sendButton)
        XCTAssertNil(exists["problems"])
        XCTAssertEqual(fields(agentRequests(agent, "ui.find").last), ["window": "Alcove", "role": "Button", "name": "Send", "index": 0, "limit": 1])
        XCTAssertEqual(agentRequests(agent, "ui.find").count, 3)

        let gone = try await waitFor(h, [["type": "ui_gone", "name": "Busy"]])
        XCTAssertEqual(gone["matched"]?.intValue, 0)
        XCTAssertEqual(gone["type"]?.stringValue, "ui_gone")
        XCTAssertNil(gone["detail"])
        XCTAssertEqual(agentRequests(agent, "ui.find").count, 6)

        let enabled = try await waitFor(h, [["type": "ui_enabled", "automationId": "send-1"]])
        XCTAssertEqual(enabled["matched"]?.intValue, 0)
        XCTAssertEqual(enabled["type"]?.stringValue, "ui_enabled")
        XCTAssertEqual(enabled["detail"], sendButton)
        XCTAssertEqual(agentRequests(agent, "ui.find").count, 9)
    }

    func testUIGoneHoldsOnAnEmptySearchResultOrAGoneWindow() async throws {
        let searchErrors = [
            "the search for {\"name\":\"Busy\"} did not finish within 12 s; read the window in parts with ui.tree and root, then use a ref",
            "UI helper did not answer 'ui.find' within 20 s; it was restarted",
            "UI helper exited; retry",
            "the UI helper is busy with 'ui.tree'; retry",
            "window 0x400b8 \"Alcove Fixture (Not Responding)\" is not responding; wait for it or end its process with proc.kill",
        ]
        let hung = "window 0x9 \"File no longer exists\" is not responding; wait for it or end its process with proc.kill"
        let noTitle = "no window has \"Fixture Dialog\" in its title; call win.list to see the open windows"
        let noHandle = "window 0x50 no longer exists; call win.list again"
        let (h, _, agent) = try await rig(["ui.find": { m, n in
            switch m["name"]?.stringValue {
            case "Busy": return n < searchErrors.count ? .fail(searchErrors[n]) : .ok(["nodes": []])
            case "Closed": return .fail(m["window"]?.stringValue == "0x50" ? noHandle : noTitle)
            case "Front": return .fail("no window is in the foreground; pass a window id from win.list")
            case "Hung": return .fail(hung)
            default: return .fail("UI helper exited; retry")
            }
        }])
        let gone = try await waitFor(h, [["type": "ui_gone", "name": "Busy"]])
        XCTAssertEqual(gone["matched"]?.intValue, 0)
        XCTAssertEqual(agentRequests(agent, "ui.find").count, searchErrors.count + 1)

        let notResponding = try await waitFor(h, [["type": "ui_gone", "window": "File", "name": "Hung"]], timeout: 1)
        XCTAssertEqual(notResponding["matched"]?.intValue, -1)
        XCTAssertEqual(notResponding["problems"]?[0]?["error"]?.stringValue, hung)

        let unknown = try await waitFor(h, [["type": "ui_gone", "name": "Other"]], timeout: 1)
        XCTAssertEqual(unknown["matched"]?.intValue, -1)
        XCTAssertEqual(unknown["problems"]?[0]?["type"]?.stringValue, "ui_gone")
        XCTAssertEqual(unknown["problems"]?[0]?["error"]?.stringValue, "UI helper exited; retry")

        for window in ["Fixture Dialog", "0x50"] {
            let before = agentRequests(agent, "ui.find").count
            let closed = try await waitFor(h, [["type": "ui_gone", "window": .string(window), "name": "Closed"]])
            XCTAssertEqual(closed["matched"]?.intValue, 0, window)
            XCTAssertEqual(closed["type"]?.stringValue, "ui_gone")
            XCTAssertNil(closed["problems"])
            XCTAssertEqual(agentRequests(agent, "ui.find").count, before + 1)

            for type in ["ui_exists", "ui_enabled"] {
                let notYet = try await waitFor(h, [["type": .string(type), "window": .string(window), "name": "Closed"]], timeout: 1)
                XCTAssertEqual(notYet["matched"]?.intValue, -1, type)
                XCTAssertNil(notYet["problems"], type)
            }
        }

        let noForeground = try await waitFor(h, [["type": "ui_gone", "name": "Front"]], timeout: 1)
        XCTAssertEqual(noForeground["matched"]?.intValue, -1)
        XCTAssertEqual(noForeground["problems"]?[0]?["error"]?.stringValue, "no window is in the foreground; pass a window id from win.list")

        let exists = try await waitFor(h, [["type": "ui_exists", "name": "Other"]], timeout: 1)
        XCTAssertEqual(exists["matched"]?.intValue, -1)
        XCTAssertEqual(exists["problems"]?[0]?["error"]?.stringValue, "UI helper exited; retry")
    }

    func testAHelperThatCannotStartOrIsShutDownEndsTheWait() async throws {
        let sentences = [
            "could not start the UI helper through PowerShell: the UI helper folder C:\\ProgramData\\Alcove\\uia could not be locked "
                + "(SetNamedSecurityInfo(C:\\ProgramData\\Alcove\\uia): Access is denied.); fix its owner and access list, then retry",
            "C:\\ProgramData\\Alcove\\uia is a reparse point; remove it",
            "the UI helper is shut down; restart alcove-agent",
        ]
        let conditions: [JSON] = [
            ["type": "ui_exists", "name": "Send"], ["type": "ui_gone", "name": "Send"], ["type": "ui_enabled", "ref": "e5"],
            ["type": "window_title", "contains": "Fixture"], ["type": "ui_text_stable", "ref": "e4"],
        ]
        for sentence in sentences {
            let (h, _, agent) = try await rig([
                "ui.find": { _, _ in .fail(sentence) }, "ui.rect": { _, _ in .fail(sentence) },
                "win.list": { _, _ in .fail(sentence) }, "ui.text": { _, _ in .fail(sentence) },
            ])
            for condition in conditions {
                do {
                    _ = try await waitFor(h, [["type": "event", "event": "window.opened"], condition], timeout: 300)
                    XCTFail("the wait went on: \(condition)")
                } catch {
                    XCTAssertEqual("\(error)", sentence)
                }
            }
            XCTAssertEqual(requestOps(agent).count, conditions.count)
        }
    }

    func testWaitUIConditionsTakeARef() async throws {
        let (h, _, agent) = try await rig(["ui.rect": { m, n in
            switch m["ref"]?.stringValue {
            case "e5": return n < 2 ? .ok(["node": sendButton, "cx": 1, "cy": 1, "clickable": true]) : .fail("element e5 no longer exists; call ui.tree again")
            case "e6": return n < 4 ? .fail("UI helper exited; retry") : .ok(["node": sendButton, "cx": 1, "cy": 1, "clickable": true])
            default: return .fail("UI helper exited; retry")
            }
        }])
        let gone = try await waitFor(h, [["type": "ui_gone", "ref": "e5"]])
        XCTAssertEqual(gone["matched"]?.intValue, 0)
        XCTAssertEqual(fields(agentRequests(agent, "ui.rect").last), ["ref": "e5"])
        XCTAssertEqual(agentRequests(agent, "ui.rect").count, 3)

        let exists = try await waitFor(h, [["type": "ui_exists", "ref": "e6"]])
        XCTAssertEqual(exists["matched"]?.intValue, 0)
        XCTAssertEqual(exists["detail"], sendButton)
        XCTAssertEqual(agentRequests(agent, "ui.rect").count, 5)

        let unknown = try await waitFor(h, [["type": "ui_gone", "ref": "e7"]], timeout: 1)
        XCTAssertEqual(unknown["matched"]?.intValue, -1)
        XCTAssertEqual(unknown["problems"]?[0]?["error"]?.stringValue, "UI helper exited; retry")
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
        let (other, _, otherAgent) = try await rig(["ui.text": { m, n in
            m["name"]?.stringValue == "Transcript" && n == 0 ? .ok(["text": "partial", "total": 7, "source": "value"]) : .fail(noMatch)
        }])
        let vanished = try await waitFor(other, [["type": "ui_text_stable", "name": "Transcript", "quietMs": 60_000]])
        XCTAssertEqual(vanished["matched"]?.intValue, -1)
        XCTAssertEqual(vanished["type"]?.stringValue, "ui_text_stable")
        XCTAssertEqual(vanished["detail"]?.stringValue, noMatch)
        XCTAssertEqual(agentRequests(otherAgent, "ui.text").count, 2)

        let neverRead = try await waitFor(other, [["type": "ui_text_stable", "name": "Later"]], timeout: 1)
        XCTAssertEqual(neverRead["matched"]?.intValue, -1)
        XCTAssertNil(neverRead["type"])
        XCTAssertNil(neverRead["detail"])
        XCTAssertEqual(neverRead["problems"]?[0]?["error"]?.stringValue, noMatch)

        let otherRef = try await waitFor(other, [["type": "ui_text_stable", "ref": "e9"]], timeout: 1)
        XCTAssertEqual(otherRef["matched"]?.intValue, -1)
        XCTAssertNil(otherRef["detail"])
        XCTAssertEqual(otherRef["problems"]?[0]?["error"]?.stringValue, noMatch)

        let closed = "no window has \"Chat\" in its title; call win.list to see the open windows"
        let (third, _, thirdAgent) = try await rig(["ui.text": { m, n in
            m["name"]?.stringValue == "Transcript" && n == 0 ? .ok(["text": "partial", "total": 7, "source": "value"]) : .fail(closed)
        }])
        let windowGone = try await waitFor(third, [["type": "ui_text_stable", "window": "Chat", "name": "Transcript", "quietMs": 60_000]])
        XCTAssertEqual(windowGone["matched"]?.intValue, -1)
        XCTAssertEqual(windowGone["type"]?.stringValue, "ui_text_stable")
        XCTAssertEqual(windowGone["detail"]?.stringValue, closed)
        XCTAssertEqual(agentRequests(thirdAgent, "ui.text").count, 2)
        let notOpened = try await waitFor(third, [["type": "ui_text_stable", "window": "Chat", "name": "Later"]], timeout: 1)
        XCTAssertNil(notOpened["type"])
        XCTAssertEqual(notOpened["problems"]?[0]?["error"]?.stringValue, closed)
    }

    func testTextStableOnAPasswordFieldFailsTheWait() async throws {
        let refusal = "the element is a password field; its text is not read; it cannot be read through UI Automation"
        let (h, _, agent) = try await rig(["ui.text": { _, _ in .fail(refusal) }])
        do {
            _ = try await waitFor(h, [["type": "window_title", "contains": "never"], ["type": "ui_text_stable", "role": "Edit", "name": "Secret"]])
            XCTFail("the wait went on")
        } catch {
            XCTAssertEqual("\(error)", refusal)
        }
        XCTAssertEqual(agentRequests(agent, "ui.text").count, 1)
    }

    func testTextStableWatchesTheTotalOfATextLongerThanItReads() async throws {
        let shown = String(repeating: "a", count: 64)
        let totals = [300_000, 300_050, 300_100, 300_150]
        let (h, _, agent) = try await rig(["ui.text": { _, n in
            .ok(["text": .string(shown), "total": .int(Int64(totals[min(n, totals.count - 1)])), "source": "text"])
        }])
        let r = try await waitFor(h, [["type": "ui_text_stable", "ref": "e4", "quietMs": 0]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertEqual(r["detail"]?.intValue, 300_150)
        XCTAssertEqual(agentRequests(agent, "ui.text").count, 5)
    }

    private func titled(_ title: String, id: String = "0x60") -> JSON {
        window(id, title, x: 0, y: 0, w: 10, h: 10)
    }

    func testWaitEvent() async throws {
        let (h, t, agent) = try await rig()
        _ = try await h.handle(op: "vm.key.down", params: ["name": "Win", "key": "shift"])
        agent.sendLine(["t": "ev", "name": "dialog.opened", "window": titled("Fixture Dialog", id: "0x50")])
        agent.sendLine(["t": "ev", "name": "dialog.opened", "window": titled("다른 이름으로 저장")])
        let arrived = await eventually { await t.events(since: 0).next == 2 }
        XCTAssertTrue(arrived)

        let saveAs = try await waitFor(h, [["type": "event", "event": "dialog.opened", "titleContains": "저장"]])
        XCTAssertEqual(saveAs["matched"]?.intValue, 0)
        XCTAssertEqual(saveAs["type"]?.stringValue, "event")
        XCTAssertEqual(saveAs["detail"]?["seq"]?.intValue, 2)
        XCTAssertEqual(saveAs["detail"]?["name"]?.stringValue, "dialog.opened")
        XCTAssertEqual(saveAs["detail"]?["window"], titled("다른 이름으로 저장"))

        let earlier = try await waitFor(h, [["type": "event", "event": "dialog.opened"]])
        XCTAssertEqual(earlier["matched"]?.intValue, 0)
        XCTAssertEqual(earlier["detail"]?["seq"]?.intValue, 1)
        let flat = try await waitFor(h, [["type": "event", "event": "dialog.opened", "titleContains": "none of them"]], timeout: 1)
        XCTAssertEqual(flat["matched"]?.intValue, -1)

        let pending = Task {
            try await h.handle(op: "vm.wait_for", params: ["name": "Win", "timeout": 30, "conditions": [
                ["type": "window_title", "contains": "never"], ["type": "event", "event": "process.exited"],
            ]])
        }
        try await Task.sleep(for: .milliseconds(100))
        agent.sendLine(["t": "ev", "name": "window.closed", "window": titled("x")])
        agent.sendLine(["t": "ev", "name": "process.exited", "pid": 44, "code": -1, "path": "C:\\x.exe"])
        let exited = try await pending.value
        XCTAssertEqual(exited["matched"]?.intValue, 1)
        XCTAssertEqual(exited["detail"]?["pid"]?.intValue, 44)
        XCTAssertEqual(exited["detail"]?["seq"]?.intValue, 4)
    }

    func testWaitEventSeesEventsSinceTheLatestChangingOp() async throws {
        let (h, t, agent) = try await rig()
        agent.sendLine(["t": "ev", "name": "window.opened", "window": titled("old")])
        let first = await eventually { await t.events(since: 0).next == 1 }
        XCTAssertTrue(first)
        _ = try await h.handle(op: "vm.key.down", params: ["name": "Win", "key": "shift"])
        let stale = try await waitFor(h, [["type": "event", "event": "window.opened"]], timeout: 1)
        XCTAssertEqual(stale["matched"]?.intValue, -1)

        _ = try await h.handle(op: "vm.key.up", params: ["name": "Win", "key": "shift"])
        agent.sendLine(["t": "ev", "name": "window.opened", "window": titled("new")])
        let second = await eventually { await t.events(since: 0).next == 2 }
        XCTAssertTrue(second)
        let fresh = try await waitFor(h, [["type": "event", "event": "window.opened"]])
        XCTAssertEqual(fresh["matched"]?.intValue, 0)
        XCTAssertEqual(fresh["detail"]?["window"]?["title"]?.stringValue, "new")
    }

    func testWaitEventStillMatchesAfterAnOpThatCausesNoEvents() async throws {
        let (h, t, agent) = try await rig([
            "fs.write": { _, _ in .ok(["size": 2]) },
            "win.list": { _, _ in .ok(["windows": []]) },
        ])
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5])
        agent.sendLine(["t": "ev", "name": "dialog.opened", "window": titled("Fixture Dialog")])
        let arrived = await eventually { await t.events(since: 0).next == 1 }
        XCTAssertTrue(arrived)
        _ = try await h.handle(op: "vm.fs.write", params: ["name": "Win", "path": "C:\\notes.txt", "text": "hi"])
        _ = try await h.handle(op: "vm.window.list", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.set_resolution", params: ["name": "Win", "width": 1024, "height": 768])
        let r = try await waitFor(h, [["type": "event", "event": "dialog.opened"]])
        XCTAssertEqual(r["matched"]?.intValue, 0)
        XCTAssertEqual(r["detail"]?["seq"]?.intValue, 1)
    }

    func testWaitEventMatchesAnEarlierEventAfterALaterOneMatched() async throws {
        let (h, t, agent) = try await rig(["app.launch": { _, _ in .ok(["pid": 7]) }])
        _ = try await h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "app.exe", "waitWindow": 0])
        agent.sendLine(["t": "ev", "name": "window.opened", "window": titled("Splash", id: "0x61")])
        agent.sendLine(["t": "ev", "name": "window.opened", "window": titled("Fixture Main", id: "0x62")])
        agent.sendLine(["t": "ev", "name": "window.foreground", "window": titled("Fixture Main", id: "0x62")])
        let arrived = await eventually { await t.events(since: 0).next == 3 }
        XCTAssertTrue(arrived)
        let foreground = try await waitFor(h, [["type": "event", "event": "window.foreground"]])
        XCTAssertEqual(foreground["detail"]?["seq"]?.intValue, 3)
        let opened = try await waitFor(h, [["type": "event", "event": "window.opened", "titleContains": "Main"]])
        XCTAssertEqual(opened["matched"]?.intValue, 0)
        XCTAssertEqual(opened["detail"]?["seq"]?.intValue, 2)
        let again = try await waitFor(h, [["type": "event", "event": "window.foreground"]])
        XCTAssertEqual(again["detail"]?["seq"]?.intValue, 3)
    }

    func testWaitEventSinceKeepsTwoClientsApart() async throws {
        let (h, t, agent) = try await rig()
        let a = try await h.handle(op: "vm.key.down", params: ["name": "Win", "key": "shift"])
        let aSeq = try XCTUnwrap(a["eventSeq"]?.intValue)
        agent.sendLine(["t": "ev", "name": "dialog.opened", "window": titled("A's dialog", id: "0x71")])
        let first = await eventually { await t.events(since: 0).next == 1 }
        XCTAssertTrue(first)
        let b = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5])
        let bSeq = try XCTUnwrap(b["eventSeq"]?.intValue)
        XCTAssertEqual([aSeq, bSeq], [0, 1])
        agent.sendLine(["t": "ev", "name": "window.opened", "window": titled("B's window", id: "0x72")])
        let second = await eventually { await t.events(since: 0).next == 2 }
        XCTAssertTrue(second)

        let hidden = try await waitFor(h, [["type": "event", "event": "dialog.opened"]], timeout: 1)
        XCTAssertEqual(hidden["matched"]?.intValue, -1)
        let forA = try await waitFor(h, [["type": "event", "event": "dialog.opened", "since": .int(Int64(aSeq))]])
        XCTAssertEqual(forA["matched"]?.intValue, 0)
        XCTAssertEqual(forA["detail"]?["seq"]?.intValue, 1)
        let forB = try await waitFor(h, [["type": "event", "event": "window.opened", "since": .int(Int64(bSeq))]])
        XCTAssertEqual(forB["detail"]?["seq"]?.intValue, 2)
        XCTAssertEqual(forB["detail"]?["window"]?["title"]?.stringValue, "B's window")

        let next = try XCTUnwrap(forA["detail"]?["seq"]?.intValue)
        let noMore = try await waitFor(h, [["type": "event", "event": "dialog.opened", "since": .int(Int64(next))]], timeout: 1)
        XCTAssertEqual(noMore["matched"]?.intValue, -1)
        let stillHidden = try await waitFor(h, [["type": "event", "event": "dialog.opened"]], timeout: 1)
        XCTAssertEqual(stillHidden["matched"]?.intValue, -1)
        let stillThere = try await waitFor(h, [["type": "event", "event": "window.opened"]])
        XCTAssertEqual(stillThere["detail"]?["seq"]?.intValue, 2)

        let fromAnEarlierServer = try await waitFor(h, [["type": "event", "event": "dialog.opened", "since": 500]])
        XCTAssertEqual(fromAnEarlierServer["detail"]?["seq"]?.intValue, 1)
        for since: JSON in [-1, "2", 1.5] {
            do { _ = try await waitFor(h, [["type": "event", "event": "dialog.opened", "since": since]]); XCTFail("\(since) was accepted") }
            catch { XCTAssertEqual("\(error)", "condition 0: 'since' must be an integer of 0 or more; pass the eventSeq of an earlier reply") }
        }
    }

    func testEachInputStepOfABatchMovesTheEventBaseline() async throws {
        let (h, _, agent) = try await rig()
        agent.handler = { m, _ in
            guard m["t"]?.stringValue == "clipboard.set" else { return [] }
            return [["t": "ev", "name": "window.opened", "window": window("0x81", "Typed", x: 0, y: 0, w: 10, h: 10)],
                    ["t": "ev", "name": "window.title", "window": window("0x81", "Typed more", x: 0, y: 0, w: 10, h: 10)]]
        }
        let batch = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": [
            ["op": "vm.key.press", "keys": "a"],
            ["op": "vm.type", "text": "한글"],
            ["op": "vm.wait_for", "timeout": 30, "conditions": [["type": "event", "event": "window.title"]]],
            ["op": "vm.wait_for", "timeout": 30, "conditions": [["type": "event", "event": "window.opened"]]],
            ["op": "vm.key.press", "keys": "b"],
        ]])
        XCTAssertEqual(batch["completed"]?.intValue, 5)
        XCTAssertEqual(batch["results"]?[2]?["detail"]?["seq"]?.intValue, 2)
        XCTAssertEqual(batch["results"]?[3]?["detail"]?["seq"]?.intValue, 1)
        let after = try await waitFor(h, [["type": "event", "event": "window.opened"]], timeout: 1)
        XCTAssertEqual(after["matched"]?.intValue, -1)
        let bySeq = try await waitFor(h, [["type": "event", "event": "window.opened", "since": 0]])
        XCTAssertEqual(bySeq["detail"]?["seq"]?.intValue, 1)
    }

    func testWaitEventDoesNotMatchEventsFromBeforeARestoreOrAnEarlierSession() async throws {
        let (h, t, agent) = try await rig()
        await t.setSnapshotList([VMController.SnapshotInfo(name: "clean", vmStateSize: 1, date: Date())])
        let opened: JSON = ["type": "event", "event": "window.opened"]
        func send(_ title: String, expecting count: Int) async {
            agent.sendLine(["t": "ev", "name": "window.opened", "window": titled(title)])
            let arrived = await eventually { await t.events(since: 0).next == count }
            XCTAssertTrue(arrived)
        }
        _ = try await h.handle(op: "vm.key.down", params: ["name": "Win", "key": "shift"])
        await send("before the restore", expecting: 1)
        let visible = try await waitFor(h, [opened])
        XCTAssertEqual(visible["detail"]?["seq"]?.intValue, 1)

        await t.setRestoreHook { target in
            agent.sendLine(["t": "ev", "name": "window.opened", "window": window("0x61", "while it is restored", x: 0, y: 0, w: 10, h: 10)])
            _ = await eventually { await target.events(since: 0).next == 2 }
        }
        let restored = try await h.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "clean", "waitTools": 0])
        XCTAssertEqual(restored["eventSeq"]?.intValue, 2)
        let hidden = try await waitFor(h, [opened], timeout: 1)
        XCTAssertEqual(hidden["matched"]?.intValue, -1)
        await send("after the restore", expecting: 3)
        let fresh = try await waitFor(h, [opened])
        XCTAssertEqual(fresh["detail"]?["seq"]?.intValue, 3)

        let stopped = try await h.handle(op: "vm.stop", params: ["name": "Win"])
        XCTAssertEqual(stopped["eventSeq"]?.intValue, 3)
        await send("while stopped", expecting: 4)
        let started = try await h.handle(op: "vm.start", params: ["name": "Win"])
        XCTAssertEqual(started["eventSeq"]?.intValue, 4)
        let earlier = try await waitFor(h, [opened], timeout: 1)
        XCTAssertEqual(earlier["matched"]?.intValue, -1)
        let bySeq = try await waitFor(h, [["type": "event", "event": "window.opened", "since": 3]])
        XCTAssertEqual(bySeq["detail"]?["seq"]?.intValue, 4)
        await send("in the new session", expecting: 5)
        let now = try await waitFor(h, [opened])
        XCTAssertEqual(now["detail"]?["seq"]?.intValue, 5)

        await t.setSnapshotError(NSError(domain: "test", code: 1))
        _ = await failure(h, "vm.snapshot.restore", ["name": "Win", "snapshot": "clean", "waitTools": 0])
        let afterAFailedRestore = try await waitFor(h, [opened], timeout: 1)
        XCTAssertEqual(afterAFailedRestore["matched"]?.intValue, -1)
    }

    func testEventPositionsDoNotKeepAReplacedVMAlive() async throws {
        final class Weak: @unchecked Sendable { weak var target: FakeTarget? }
        let holder = Weak()
        let fresh = FakeTarget(name: "Win", state: .running, png: makePNG(width: 64, height: 64))
        let registry: SwapRegistry
        do {
            let old = FakeTarget(name: "Win", state: .running, png: makePNG(width: 64, height: 64))
            holder.target = old
            registry = SwapRegistry(old)
        }
        let h = ControlHandler(registry: registry, hostKind: "test")
        _ = try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "observe": "summary", "settleMs": 20])
        XCTAssertNotNil(holder.target)
        await registry.swap(fresh)
        let released = await eventually { holder.target == nil }
        XCTAssertTrue(released, "an event position keeps the replaced VM")
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

    /// A fake agent with the `ui` capability, connected to a new running VM "Win". Every `ui.find` request is answered with
    /// no nodes followed by the `emitted` event.
    private func target(emitting emitted: JSON) async throws -> (FakeTarget, FakeAgent) {
        let agent = FakeAgent()
        agent.caps = ["clipboard", "files", "exec", "ui"]
        agent.handler = { m, _ in
            switch m["op"]?.stringValue {
            case "ui.focused": return [agentReply(m, ["node": messageEdit, "window": fixtureWindow])]
            case "ui.find": return [agentReply(m, ["nodes": []]), emitted]
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
        for i in 1...3 { oldAgent.sendLine(["t": "ev", "name": "window.opened", "window": titled("old \(i)")]) }
        let arrived = await eventually { await old.events(since: 0).next == 3 }
        XCTAssertTrue(arrived)
        let click: JSON = ["name": "Win", "x": 5, "y": 5, "observe": "summary", "settleMs": 20]
        _ = try await h.handle(op: "vm.mouse.click", params: click)
        _ = try await h.handle(op: "vm.mouse.click", params: click)

        let (fresh, _) = try await target(emitting: ["t": "ev", "name": "window.opened", "window": titled("fresh")])
        await registry.swap(fresh)
        let waited = try await h.handle(op: "vm.wait_for", params: ["name": "Win", "timeout": 30, "observe": "summary", "settleMs": 20, "conditions": [
            ["type": "ui_exists", "name": "Nothing"], ["type": "event", "event": "window.opened"],
        ]])
        XCTAssertEqual(waited["matched"]?.intValue, 1)
        XCTAssertEqual(waited["detail"]?["seq"]?.intValue, 1)
        XCTAssertEqual(waited["detail"]?["window"]?["title"]?.stringValue, "fresh")
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
        let restarted = "UI helper did not answer 'ui.find' within 20 s; it was restarted"
        let (h, _, agent) = try await rig(["ui.find": { _, _ in .fail(restarted) }])
        let r = try await waitFor(h, [["type": "ui_exists", "name": "Send"]], timeout: 1)
        XCTAssertEqual(r["matched"]?.intValue, -1)
        let problem = try XCTUnwrap(r["problems"]?[0])
        XCTAssertEqual(problem["condition"]?.intValue, 0)
        XCTAssertEqual(problem["type"]?.stringValue, "ui_exists")
        XCTAssertEqual(problem["error"]?.stringValue, restarted)
        XCTAssertGreaterThanOrEqual(problem["failures"]?.intValue ?? 0, 1)
        XCTAssertGreaterThanOrEqual(agentRequests(agent, "ui.find").count, 1)
    }

    // MARK: - one helper call at a time

    func testHelperCallsOfOneVMRunOneAtATime() async throws {
        UITiming.factBudget = .milliseconds(50)
        let (h, _, agent) = try await rig([
            "ui.tree": { _, _ in .silent },
            "win.list": { _, _ in .ok(["windows": [fixtureWindow]]) },
            "ui.find": { _, _ in .ok(["nodes": [sendButton]]) },
            "ui.focused": { _, _ in .ok(["node": messageEdit, "window": fixtureWindow]) },
        ])
        let tree = Task { try await h.handle(op: "vm.ui.tree", params: ["name": "Win"]) }
        let sent = await eventually { agentRequests(agent, "ui.tree").count == 1 }
        XCTAssertTrue(sent)

        let list = Task { try await h.handle(op: "vm.window.list", params: ["name": "Win"]) }
        let listQueued = await eventually { await h.helperGate.waiterCount(for: "Win") == 1 }
        XCTAssertTrue(listQueued)
        let wait = Task {
            try await h.handle(op: "vm.wait_for", params: ["name": "Win", "timeout": 60, "conditions": [["type": "ui_exists", "name": "Send"]]])
        }
        let waitQueued = await eventually { await h.helperGate.waiterCount(for: "Win") == 2 }
        XCTAssertTrue(waitQueued)
        XCTAssertEqual(requestOps(agent), ["ui.tree"])

        let click = Task { try await h.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 5, "y": 5, "observe": "summary", "settleMs": 20]) }
        let clicked = try await completed(click, "the click waited for the helper")
        XCTAssertEqual(clicked["observation"]?["settled"]?.boolValue, true)
        XCTAssertEqual(clicked["observation"]?["uiError"]?.stringValue, ControlUITests.busyFacts)
        XCTAssertNil(clicked["observation"]?["foreground"])
        XCTAssertNil(clicked["observation"]?["focused"])
        XCTAssertEqual(clicked["observation"]?["events"], [])
        let left = await eventually { await h.helperGate.waiterCount(for: "Win") == 2 }
        XCTAssertTrue(left)
        XCTAssertEqual(requestOps(agent), ["ui.tree"])

        let request = try XCTUnwrap(agentRequests(agent, "ui.tree").first)
        agent.sendLine(agentReply(request, ["window": fixtureWindow, "nodes": [sendButton], "truncated": false]))
        let treeResult = try await tree.value
        XCTAssertEqual(treeResult["count"]?.intValue, 1)
        let listResult = try await list.value
        XCTAssertEqual(listResult["windows"], [fixtureWindow])
        let waitResult = try await wait.value
        XCTAssertEqual(waitResult["matched"]?.intValue, 0)
        XCTAssertEqual(requestOps(agent), ["ui.tree", "win.list", "ui.find"])
    }

    func testAWaitSendsNoSecondProbeBeforeTheFirstIsAnsweredAndCollectsTheLateReply() async throws {
        WaitTiming.agentCallTimeout = .milliseconds(50)
        let (h, _, agent) = try await rig([
            "ui.find": { _, _ in .silent },
            "fs.stat": { _, _ in .ok(["exists": false]) },
            "win.list": { _, _ in .ok(["windows": [fixtureWindow]]) },
        ])
        let wait = Task {
            try await h.handle(op: "vm.wait_for", params: ["name": "Win", "timeout": 120, "conditions": [
                ["type": "ui_exists", "name": "Send"], ["type": "file_exists", "path": "C:\\never"],
            ]])
        }
        let ticked = await eventually { agentRequests(agent, "fs.stat").count >= 4 }
        XCTAssertTrue(ticked)
        XCTAssertEqual(agentRequests(agent, "ui.find").count, 1)

        let list = Task { try await h.handle(op: "vm.window.list", params: ["name": "Win"]) }
        let queued = await eventually { await h.helperGate.waiterCount(for: "Win") == 1 }
        XCTAssertTrue(queued, "the helper was free while it still served the probe")
        XCTAssertTrue(agentRequests(agent, "win.list").isEmpty)
        XCTAssertEqual(agentRequests(agent, "ui.find").count, 1)

        agent.sendLine(agentReply(try XCTUnwrap(agentRequests(agent, "ui.find").first), ["nodes": [sendButton]]))
        let result = try await completed(wait, "the wait did not collect the late reply")
        XCTAssertEqual(result["matched"]?.intValue, 0)
        XCTAssertEqual(result["type"]?.stringValue, "ui_exists")
        XCTAssertEqual(result["detail"], sendButton)
        let listed = try await completed(list)
        XCTAssertEqual(listed["windows"], [fixtureWindow])
        XCTAssertEqual(agentRequests(agent, "ui.find").count, 1)
    }

    func testAWaitWhoseProbeIsNotAnsweredSaysSo() async throws {
        WaitTiming.agentCallTimeout = .milliseconds(50)
        let (h, _, agent) = try await rig(["ui.find": { _, _ in .silent }])
        let r = try await waitFor(h, [["type": "ui_exists", "name": "Slow"]], timeout: 1)
        XCTAssertEqual(r["matched"]?.intValue, -1)
        let problem = try XCTUnwrap(r["problems"]?[0])
        XCTAssertEqual(problem["condition"]?.intValue, 0)
        XCTAssertEqual(problem["type"]?.stringValue, "ui_exists")
        let sentence = try XCTUnwrap(problem["error"]?.stringValue)
        XCTAssertNotNil(sentence.range(of: #"^the UI helper has not answered ui\.find for \d+ s$"#, options: .regularExpression), sentence)
        XCTAssertNil(problem["failures"])
        XCTAssertEqual(agentRequests(agent, "ui.find").count, 1)
    }

    func testAProbeInFlightWhenTheWaitEndsIsNotReportedAsSilence() async throws {
        let (h, _, agent) = try await rig()
        agent.handler = { m, a in
            guard m["op"]?.stringValue == "ui.find" else { return [] }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(60)) { a.sendLine(agentReply(m, ["nodes": []])) }
            return []
        }
        for _ in 0..<4 {
            let r = try await waitFor(h, [["type": "ui_exists", "name": "Never"]], timeout: 1)
            XCTAssertEqual(r["matched"]?.intValue, -1)
            XCTAssertNil(r["problems"])
        }
    }

    func testAnUnansweredProbeKeepsTheFailuresRecordedBefore() async throws {
        let (h, _, agent) = try await rig([
            "ui.find": { _, n in n == 0 ? .fail("UI helper exited; retry") : .silent },
            "fs.stat": { m, n in m["path"]?.stringValue == "C:\\denied" && n == 0 ? .fail("access denied") : .silent },
        ])
        let r = try await waitFor(h, [["type": "ui_exists", "name": "Send"], ["type": "file_exists", "path": "C:\\denied"]], timeout: 1)
        XCTAssertEqual(r["matched"]?.intValue, -1)
        XCTAssertEqual(r["problems"], [
            ["condition": 0, "type": "ui_exists", "error": "UI helper exited; retry", "failures": 1],
            ["condition": 1, "type": "file_exists", "error": "access denied", "failures": 1],
        ])
        XCTAssertEqual(agentRequests(agent, "ui.find").count, 2)
    }

    func testAWaitWhoseProbeGetsNoTurnReportsABusyHelperWithinItsTimeout() async throws {
        let (h, _, agent) = try await rig([
            "ui.tree": { _, _ in .silent },
            "ui.find": { _, _ in .ok(["nodes": [sendButton]]) },
            "win.list": { _, _ in .ok(["windows": [fixtureWindow]]) },
        ])
        let tree = Task { try await h.handle(op: "vm.ui.tree", params: ["name": "Win"]) }
        let sent = await eventually { agentRequests(agent, "ui.tree").count == 1 }
        XCTAssertTrue(sent)

        let wait = Task {
            try await h.handle(op: "vm.wait_for", params: ["name": "Win", "timeout": 1, "conditions": [["type": "ui_exists", "name": "Send"]]])
        }
        let r = try await completed(wait, "the wait outlasted its timeout in the queue")
        XCTAssertEqual(r["matched"]?.intValue, -1)
        XCTAssertEqual(r["problems"], [["condition": 0, "type": "ui_exists", "error": "the UI helper was busy with other requests"]])
        let left = await eventually { await h.helperGate.waiterCount(for: "Win") == 0 }
        XCTAssertTrue(left)

        let list = Task { try await h.handle(op: "vm.window.list", params: ["name": "Win"]) }
        let queued = await eventually { await h.helperGate.waiterCount(for: "Win") == 1 }
        XCTAssertTrue(queued)
        agent.sendLine(agentReply(try XCTUnwrap(agentRequests(agent, "ui.tree").first), ["window": fixtureWindow, "nodes": [], "truncated": false]))
        _ = try await tree.value
        _ = try await list.value
        XCTAssertEqual(requestOps(agent), ["ui.tree", "win.list"])
    }

    func testACancelledQueuedUIActionIsNeverSent() async throws {
        let (h, _, agent) = try await rig([
            "ui.tree": { _, _ in .silent },
            "ui.act": { _, _ in .ok(["node": sendButton]) },
            "win.list": { _, _ in .ok(["windows": [fixtureWindow]]) },
        ])
        let tree = Task { try await h.handle(op: "vm.ui.tree", params: ["name": "Win"]) }
        let sent = await eventually { agentRequests(agent, "ui.tree").count == 1 }
        XCTAssertTrue(sent)

        let action = Task { try await h.handle(op: "vm.ui.action", params: ["name": "Win", "ref": "e5", "action": "invoke"]) }
        let queued = await eventually { await h.helperGate.waiterCount(for: "Win") == 1 }
        XCTAssertTrue(queued)
        action.cancel()
        do {
            let value = try await finished(action)
            XCTFail(value == nil ? "the cancelled action stayed in the queue" : "the cancelled action ran")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let left = await eventually { await h.helperGate.waiterCount(for: "Win") == 0 }
        XCTAssertTrue(left)

        let list = Task { try await h.handle(op: "vm.window.list", params: ["name": "Win"]) }
        let listQueued = await eventually { await h.helperGate.waiterCount(for: "Win") == 1 }
        XCTAssertTrue(listQueued)
        agent.sendLine(agentReply(try XCTUnwrap(agentRequests(agent, "ui.tree").first), ["window": fixtureWindow, "nodes": [], "truncated": false]))
        _ = try await tree.value
        _ = try await list.value
        XCTAssertEqual(requestOps(agent), ["ui.tree", "win.list"])
    }

    func testAUIOpThatGetsNoTurnAnswersThatTheHelperIsBusy() async throws {
        UITiming.queueTimeout = .milliseconds(50)
        let (h, _, agent) = try await rig([
            "ui.tree": { _, _ in .silent },
            "win.list": { _, _ in .ok(["windows": [fixtureWindow]]) },
            "win.action": { _, _ in .ok(["window": fixtureWindow]) },
        ])
        let tree = Task { try await h.handle(op: "vm.ui.tree", params: ["name": "Win"]) }
        let sent = await eventually { agentRequests(agent, "ui.tree").count == 1 }
        XCTAssertTrue(sent)
        let calls: [(String, JSON)] = [
            ("vm.window.list", ["name": "Win"]),
            ("vm.window.action", ["name": "Win", "window": "0x2a", "action": "focus"]),
            ("vm.screenshot", ["name": "Win", "window": "Alcove"]),
        ]
        for (op, params) in calls {
            let call = Task { try await h.handle(op: op, params: params) }
            do {
                let value = try await finished(call)
                XCTFail(value == nil ? "\(op) stayed in the queue" : "\(op) ran")
            } catch {
                XCTAssertEqual("\(error)", "the UI helper is busy with other requests; retry", op)
            }
        }
        XCTAssertEqual(requestOps(agent), ["ui.tree"])
        agent.sendLine(agentReply(try XCTUnwrap(agentRequests(agent, "ui.tree").first), ["window": fixtureWindow, "nodes": [], "truncated": false]))
        _ = try await tree.value
    }

    func testObservationFactsShareOneBudgetAndTheHelperStaysTakenUntilItAnswers() async throws {
        UITiming.factBudget = .milliseconds(50)
        UITiming.treeFactBudget = .seconds(3)
        let (h, _, agent) = try await rig([
            "ui.focused": { _, _ in .ok(["node": messageEdit, "window": fixtureWindow]) },
            "ui.tree": { _, _ in .silent },
        ])
        let click: JSON = ["name": "Win", "x": 5, "y": 5, "observe": "ui", "settleMs": 20]
        let withTree = try await completed(Task { try await h.handle(op: "vm.mouse.click", params: click) })
        XCTAssertEqual(withTree["observation"]?["foreground"], "Alcove Fixture")
        XCTAssertEqual(withTree["observation"]?["focused"], "Edit \"Message\"")
        XCTAssertNil(withTree["observation"]?["tree"])
        XCTAssertEqual(withTree["observation"]?["uiError"]?.stringValue, ControlUITests.busyFacts)
        XCTAssertEqual(requestOps(agent), ["ui.focused", "ui.tree"])

        let summary: JSON = ["name": "Win", "x": 5, "y": 5, "observe": "summary", "settleMs": 20]
        let behind = try await completed(Task { try await h.handle(op: "vm.mouse.click", params: summary) })
        XCTAssertEqual(behind["observation"]?["uiError"]?.stringValue, ControlUITests.busyFacts)
        XCTAssertNil(behind["observation"]?["foreground"])
        XCTAssertEqual(requestOps(agent), ["ui.focused", "ui.tree"])

        agent.sendLine(agentReply(try XCTUnwrap(agentRequests(agent, "ui.tree").first), ["window": fixtureWindow, "nodes": [], "truncated": false]))
        let free = await eventually {
            let r = try? await h.handle(op: "vm.mouse.click", params: summary)
            return r?["observation"]?["foreground"]?.stringValue == "Alcove Fixture"
        }
        XCTAssertTrue(free)
    }

    func testAHelperCallCancelledAfterItsTurnCameIsNotSent() async throws {
        let (h, t, agent) = try await rig(["ui.act": { _, _ in .ok(["node": sendButton]) }])
        let found = await t.agent(timeout: .zero)
        let client = try XCTUnwrap(found)
        let latch = Latch()
        let far = ContinuousClock.now + .seconds(120)
        let call = Task { try await h.helperTurn(client, "ui.act", ["ref": "e5", "action": "invoke"], vm: "Win", turnBy: far) { await latch.pass() } }
        let taken = await eventually { await latch.arrivals == 1 }
        XCTAssertTrue(taken)
        let held = try await h.helperGate.acquire("Win", until: .now)
        XCTAssertFalse(held)
        call.cancel()
        await latch.open()
        do {
            let reply = try await finished(call)
            XCTFail(reply == nil ? "the call did not end" : "the cancelled call was sent")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(agentRequests(agent, "ui.act").isEmpty)
        let free = try await h.helperGate.acquire("Win", until: .now)
        XCTAssertTrue(free)
        await h.helperGate.release("Win")

        let sent = try await h.helperTurn(client, "ui.act", ["ref": "e5", "action": "invoke"], vm: "Win", turnBy: far)
        XCTAssertEqual(sent["node"], sendButton)
        XCTAssertEqual(agentRequests(agent, "ui.act").count, 1)
    }

    // MARK: - the gate

    func testGateHandsTheLockOverInArrivalOrderAndDropsCancelledWaiters() async throws {
        let gate = InputGate()
        let far = ContinuousClock.now + .seconds(120)
        let first = try await gate.acquire("Win", until: far)
        XCTAssertTrue(first)
        let other = try await gate.acquire("Linux", until: far)
        XCTAssertTrue(other)

        let order = LockedBox<[String]>([])
        let b = Task { let got = try await gate.acquire("Win", until: far); order.value = order.value + ["b"]; return got }
        let bQueued = await eventually { await gate.waiterCount(for: "Win") == 1 }
        XCTAssertTrue(bQueued)
        let c = Task { let got = try await gate.acquire("Win", until: far); order.value = order.value + ["c"]; return got }
        let cQueued = await eventually { await gate.waiterCount(for: "Win") == 2 }
        XCTAssertTrue(cQueued)
        let d = Task { let got = try await gate.acquire("Win", until: far); order.value = order.value + ["d"]; return got }
        let dQueued = await eventually { await gate.waiterCount(for: "Win") == 3 }
        XCTAssertTrue(dQueued)

        b.cancel()
        do {
            let got = try await finished(b)
            XCTFail(got == nil ? "a cancelled waiter stayed in the queue" : "a cancelled waiter got the lock")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let waiting = await gate.waiterCount(for: "Win")
        XCTAssertEqual(waiting, 2)
        XCTAssertEqual(order.value, [])

        await gate.release("Win")
        let cGot = try await finished(c)
        XCTAssertEqual(cGot, true)
        XCTAssertEqual(order.value, ["c"])
        await gate.release("Win")
        let dGot = try await finished(d)
        XCTAssertEqual(dGot, true)
        XCTAssertEqual(order.value, ["c", "d"])
        await gate.release("Win")
        let free = try await gate.acquire("Win", until: .now)
        XCTAssertTrue(free)
    }

    func testGateWaiterLeavesAtItsDeadline() async throws {
        let gate = InputGate()
        let held = try await gate.acquire("Win", until: .now + .seconds(120))
        XCTAssertTrue(held)
        let past = try await gate.acquire("Win", until: .now)
        XCTAssertFalse(past)
        let soon = try await finished(Task { try await gate.acquire("Win", until: .now + .milliseconds(30)) })
        XCTAssertEqual(soon, false)
        let waiting = await gate.waiterCount(for: "Win")
        XCTAssertEqual(waiting, 0)

        let cancelled = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await gate.acquire("Linux", until: .now + .seconds(120))
        }
        do { _ = try await cancelled.value; XCTFail("a cancelled task took the lock") } catch { XCTAssertTrue(error is CancellationError) }
        let untouched = try await gate.acquire("Linux", until: .now)
        XCTAssertTrue(untouched)

        await gate.release("Win")
        let again = try await gate.acquire("Win", until: .now)
        XCTAssertTrue(again)
        let ran = await gate.withLock("Other") { 7 }
        XCTAssertEqual(ran, 7)
    }

    // MARK: - screenshot

    func testScreenshotWindowCrop() async throws {
        let minimized = window("0x77", "Hidden Tool", x: 0, y: 0, w: 0, h: 0, state: "minimized")
        let onScreenMinimized = window("0x78", "Tray Tool", x: 10, y: 10, w: 100, h: 80, state: "minimized")
        let empty = window("0x79", "Empty Tool", x: 0, y: 0, w: 0, h: 0)
        let (h, _, agent) = try await rig(["win.list": { _, _ in .ok(["windows": [notesWindow, fixtureWindow, minimized, onScreenMinimized, empty]]) }])
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
            (["name": "Win", "window": "Hidden Tool"], "window 'Hidden Tool' is minimized or has no area on the 800x600 frame; call vm.window.action restore first"),
            (["name": "Win", "window": "0x78"], "window 'Tray Tool' is minimized or has no area on the 800x600 frame; call vm.window.action restore first"),
            (["name": "Win", "window": "Empty Tool"], "window 'Empty Tool' is minimized or has no area on the 800x600 frame; call vm.window.action restore first"),
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

    func testScreenshotMarksSayWhenElementsAreLeftOut() async throws {
        let buttons: [JSON] = (0..<101).map { node("e\(100 + $0)", "Button", "b\($0)", depth: 1, x: 100 + ($0 % 20) * 20, y: 50 + ($0 / 20) * 20, w: 18, h: 18) }
        let header = node("e90", "HeaderItem", "Name", depth: 1, x: 100, y: 200, w: 60, h: 20)
        let count = LockedBox(101)
        let cut = LockedBox(false)
        let (h, _, _) = try await rig([
            "win.list": { _, _ in .ok(["windows": [fixtureWindow]]) },
            "ui.tree": { _, _ in .ok(["window": fixtureWindow, "nodes": .array(Array(buttons.prefix(count.value)) + (count.value < 100 ? [header] : [])),
                                      "truncated": .bool(cut.value)]) },
        ])
        let params: JSON = ["name": "Win", "window": "Alcove", "marks": true]
        let over = try await h.handle(op: "vm.screenshot", params: params)
        XCTAssertEqual(over["marks"]?.arrayValue?.count, 100)
        XCTAssertEqual(over["marks"]?[99]?["n"]?.intValue, 100)
        XCTAssertEqual(over["marks"]?[99]?["ref"]?.stringValue, "e199")
        XCTAssertEqual(over["marksTruncated"], true)

        count.value = 100
        let exact = try await h.handle(op: "vm.screenshot", params: params)
        XCTAssertEqual(exact["marks"]?.arrayValue?.count, 100)
        XCTAssertNil(exact["marksTruncated"])

        count.value = 3
        let few = try await h.handle(op: "vm.screenshot", params: params)
        XCTAssertEqual(few["marks"]?.arrayValue?.map { $0["role"]?.stringValue }, ["Button", "Button", "Button", "HeaderItem"])
        XCTAssertNil(few["marksTruncated"])
        cut.value = true
        let partial = try await h.handle(op: "vm.screenshot", params: params)
        XCTAssertEqual(partial["marks"]?.arrayValue?.count, 4)
        XCTAssertEqual(partial["marksTruncated"], true)
    }

    func testScreenshotMarksKeepTheirOutlineWhenTheImageIsScaledDown() async throws {
        let (h, _, _) = try await rig([
            "win.list": { _, _ in .ok(["windows": [fixtureWindow]]) },
            "ui.tree": { _, _ in .ok(["window": fixtureWindow, "nodes": [messageEdit, sendButton], "truncated": false]) },
        ])
        let plain = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "window": "Alcove", "maxWidth": 200])
        let marked = try await h.handle(op: "vm.screenshot", params: ["name": "Win", "window": "Alcove", "maxWidth": 200, "marks": true])
        XCTAssertEqual(marked["sentWidth"]?.intValue, 200)
        let before = try XCTUnwrap(Frame(png: Data(base64Encoded: plain["png"]?.stringValue ?? "") ?? Data()))
        let after = try XCTUnwrap(Frame(png: Data(base64Encoded: marked["png"]?.stringValue ?? "") ?? Data()))
        let color = Frame.markColors[1]
        let expected = [Int(color.blue), Int(color.green), Int(color.red)]
        for (x, y) in [(45, 25), (45, 26), (25, 30), (26, 30), (63, 30), (64, 30), (45, 35), (45, 36)] {
            let pixel = after.pixel(x: x, y: y).prefix(3).map(Int.init)
            for channel in 0..<3 { XCTAssertLessThanOrEqual(abs(pixel[channel] - expected[channel]), 60, "\(x),\(y): \(pixel)") }
            let unmarked = before.pixel(x: x, y: y).prefix(3).map(Int.init)
            XCTAssertGreaterThan(zip(unmarked, expected).map { abs($0 - $1) }.max() ?? 0, 120)
        }
        XCTAssertEqual(after.pixel(x: 45, y: 31), before.pixel(x: 45, y: 31))
    }

    func testDrawingMarksAtTheEdgesAndWithThinOrEmptyRectangles() throws {
        let base = try XCTUnwrap(Frame(png: makePNG(width: 200, height: 120)))
        func bgr(_ number: Int) -> [UInt8] {
            let c = Frame.markColors[(number - 1) % Frame.markColors.count]
            return [c.blue, c.green, c.red, 255]
        }
        let thin = base.drawingMarks([Frame.Mark(number: 1, rect: Frame.Rect(x: 50, y: 30, w: 1, h: 20))])
        for y in [30, 40, 49] { XCTAssertEqual(thin.pixel(x: 50, y: y), bgr(1), "\(y)") }
        XCTAssertEqual(thin.pixel(x: 51, y: 40), base.pixel(x: 51, y: 40))
        let flat = base.drawingMarks([Frame.Mark(number: 2, rect: Frame.Rect(x: 60, y: 70, w: 30, h: 3))])
        XCTAssertEqual(flat.pixel(x: 75, y: 71), bgr(2))

        XCTAssertEqual(base.drawingMarks([Frame.Mark(number: 3, rect: Frame.Rect(x: 80, y: 80, w: 0, h: 0)),
                                          Frame.Mark(number: 4, rect: Frame.Rect(x: 80, y: 80, w: 10, h: 0)),
                                          Frame.Mark(number: 5, rect: Frame.Rect(x: 80, y: 80, w: -4, h: 10))]), base)

        let left = base.drawingMarks([Frame.Mark(number: 3, rect: Frame.Rect(x: -40, y: 40, w: 60, h: 20))])
        XCTAssertEqual(left.pixel(x: 19, y: 50), bgr(3))
        XCTAssertEqual(left.pixel(x: 0, y: 36), bgr(3))
        XCTAssertNotEqual(left.pixel(x: 5, y: 34), base.pixel(x: 5, y: 34))

        let top = base.drawingMarks([Frame.Mark(number: 4, rect: Frame.Rect(x: 100, y: 0, w: 60, h: 40))])
        XCTAssertEqual(top.pixel(x: 100, y: 0), bgr(4))
        XCTAssertEqual(top.pixel(x: 103, y: 3), bgr(4))
        XCTAssertEqual(top.pixel(x: 150, y: 20), base.pixel(x: 150, y: 20))

        let right = base.drawingMarks([Frame.Mark(number: 5, rect: Frame.Rect(x: 196, y: 60, w: 4, h: 20))])
        XCTAssertNotEqual(right.pixel(x: 192, y: 55), base.pixel(x: 192, y: 55))
        XCTAssertEqual(right.pixel(x: 199, y: 55), bgr(5))

        let one = base.drawingMarks([Frame.Mark(number: 1, rect: Frame.Rect(x: 40, y: 60, w: 60, h: 30))])
        let hundred = base.drawingMarks([Frame.Mark(number: 100, rect: Frame.Rect(x: 40, y: 60, w: 60, h: 30))])
        XCTAssertEqual(hundred.pixel(x: 40, y: 60), bgr(100))
        XCTAssertEqual(one.pixel(x: 58, y: 55), base.pixel(x: 58, y: 55))
        XCTAssertEqual(hundred.pixel(x: 41, y: 55), bgr(100))
        XCTAssertNotEqual(hundred.pixel(x: 58, y: 55), base.pixel(x: 58, y: 55))
        for frame in [thin, left, top, right, hundred] {
            for i in stride(from: 3, to: frame.pixels.count, by: 4) where frame.pixels[i] != 255 { XCTFail("alpha at \(i)"); break }
        }
    }

    func testDrawingMarksKeepsTheOutlineAndTheTagWithinBoundsAtAnyScale() throws {
        let base = try XCTUnwrap(Frame(png: makePNG(width: 400, height: 300)))
        let mark = [Frame.Mark(number: 7, rect: Frame.Rect(x: 100, y: 150, w: 200, h: 100))]
        let color = Frame.markColors[(7 - 1) % Frame.markColors.count]
        let bgr: [UInt8] = [color.blue, color.green, color.red, 255]

        for scale in [1000.0, 40.0, Double.infinity, 1e300] {
            let big = base.drawingMarks(mark, scale: scale)
            let expected = scale.isFinite ? 8 : 2
            for inside in 0..<expected { XCTAssertEqual(big.pixel(x: 100 + inside, y: 200), bgr, "\(scale) \(inside)") }
            XCTAssertEqual(big.pixel(x: 100 + expected, y: 200), base.pixel(x: 100 + expected, y: 200), "\(scale)")
            XCTAssertEqual(big.pixel(x: 200, y: 200), base.pixel(x: 200, y: 200), "\(scale)")
            XCTAssertEqual(big.pixel(x: 101, y: 148), bgr, "\(scale)")
            XCTAssertEqual(big.pixel(x: 101, y: 80), base.pixel(x: 101, y: 80), "\(scale)")
            XCTAssertEqual(big.pixel(x: 180, y: 140), base.pixel(x: 180, y: 140), "\(scale)")
        }
        for scale in [0.001, 0.0, -5.0, Double.nan] {
            let small = base.drawingMarks(mark, scale: scale)
            let expected = scale.isNaN ? 2 : 1
            XCTAssertEqual(small.pixel(x: 100, y: 200), bgr, "\(scale)")
            XCTAssertEqual(small.pixel(x: 100 + expected, y: 200), base.pixel(x: 100 + expected, y: 200), "\(scale)")
            XCTAssertEqual(small.pixel(x: 101, y: 148), bgr, "\(scale)")
            XCTAssertEqual(small.pixel(x: 101, y: 130), base.pixel(x: 101, y: 130), "\(scale)")
        }
        XCTAssertEqual(base.drawingMarks(mark, scale: 1), base.drawingMarks(mark))
        XCTAssertEqual(base.drawingMarks(mark, scale: 4).pixel(x: 107, y: 200), bgr)
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
        XCTAssertEqual(events, ["events": [], "next": 0, "first": 0])
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
            XCTAssertEqual(ControlHandler.capturesFrames(op: op), input.contains(op) || op == "vm.app.launch" || op == "vm.deploy", op)
            XCTAssertEqual(ControlHandler.movesEventBaseline(op: op), !readOnly.contains(op), op)
        }
        for op in ["vm.mouse.click", "vm.key.press", "vm.type", "vm.batch", "vm.exec", "vm.exec.start", "vm.exec.write", "vm.exec.kill", "vm.process.kill",
                   "vm.start", "vm.stop", "vm.snapshot.restore"] {
            XCTAssertTrue(ControlHandler.movesEventBaseline(op: op), op)
        }
        for op in ["vm.exec.read", "vm.exec.list", "vm.process.list", "vm.fs.write", "vm.fs.delete", "vm.push_file", "vm.sync_dir", "vm.clipboard.set",
                   "vm.set_resolution", "vm.snapshot.create", "vm.snapshot.delete", "vm.snapshot.list", "vm.pause", "vm.resume", "vm.wait_for",
                   "vm.screenshot", "script.run"] {
            XCTAssertFalse(ControlHandler.movesEventBaseline(op: op), op)
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
        let (h, _, _) = try await rig([
            "ui.act": { _, _ in .ok(["node": sendButton]) },
            "ui.tree": { _, _ in .ok(["window": fixtureWindow, "nodes": [], "truncated": false]) },
            "ui.find": { _, _ in .ok(["nodes": []]) },
            "ui.text": { _, _ in .ok(["text": "", "total": 0, "source": "value"]) },
            "win.list": { _, _ in .ok(["windows": []]) },
            "app.launch": { _, _ in .ok(["pid": 7]) },
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("control-ui-trace-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        _ = try await h.handle(op: "vm.record.start", params: ["name": "Win", "dir": .string(dir.path), "video": false])
        _ = try await h.handle(op: "vm.ui.action", params: ["name": "Win", "ref": "e5", "action": "invoke"])
        _ = try await h.handle(op: "vm.events", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.ui.tree", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.ui.find", params: ["name": "Win", "selector": ["name": "x"]])
        _ = try await h.handle(op: "vm.ui.text", params: ["name": "Win", "ref": "e4"])
        _ = try await h.handle(op: "vm.window.list", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "app.exe", "waitWindow": 0])
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        let lines = try String(contentsOf: dir.appendingPathComponent("trace.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSON.parse(Data($0.utf8)) }
        XCTAssertEqual(lines.map { $0["op"]?.stringValue },
                       ["vm.ui.action", "vm.events", "vm.ui.tree", "vm.ui.find", "vm.ui.text", "vm.window.list", "vm.app.launch"])
        XCTAssertEqual(lines.map { $0["before"] != nil && $0["after"] != nil }, [true, false, false, false, false, false, true])
        XCTAssertEqual(lines.map { $0["before"] != nil || $0["after"] != nil }, [true, false, false, false, false, false, true])
        XCTAssertEqual(lines[1]["result"], ["events": [], "next": 0, "first": 0])
        XCTAssertEqual(lines[0]["result"]?["eventSeq"], 0)
    }
}

private extension Frame {
    /// The BGRA bytes of the pixel at (x, y).
    func pixel(x: Int, y: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(pixels[pixels.startIndex + offset..<pixels.startIndex + offset + 4])
    }
}
