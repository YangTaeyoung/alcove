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
private let sendTarget: JSON = ["window": "Alcove Fixture", "role": "Button", "name": "Send", "aid": "send"]
private let sendSelector: JSON = ["window": "Alcove Fixture", "role": "Button", "name": "Send", "automationId": "send"]
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
        return ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test")
    }

    /// A running 800x600 VM "Win" whose agent offers `caps` and answers each op as `answers` says at that moment;
    /// an op without an entry gets the agent's unknown-op error.
    private func rig(caps: [String] = ["clipboard", "files", "exec", "ui"],
                     _ answers: LockedBox<[String: Reply]>) async throws -> (ControlHandler, FakeTarget, FakeAgent) {
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
            entry(2, "vm.mouse.click", ["x": 10, "y": 20], ["target": ["window": "Alcove Fixture", "role": "Button", "name": "", "aid": "send"]]),
            entry(3, "vm.mouse.click", ["x": 30, "y": 40], ["target": ["role": "MenuItem", "name": "File"]]),
            entry(4, "vm.mouse.click", ["x": 190, "y": 112, "hold": 900], ["target": sendTarget]),
            entry(5, "vm.mouse.drag", ["fromX": 190, "fromY": 112, "toX": 300, "toY": 112], ["target": sendTarget]),
        ])
        XCTAssertEqual(ops(script), ["vm.ui.click", "vm.ui.click", "vm.ui.click", "vm.mouse.click", "vm.mouse.drag"])
        XCTAssertEqual(script.steps[0].params, ["selector": sendSelector, "fallback": ["x": 190, "y": 112], "button": "right", "count": 2,
                                                "observe": "summary", "settleMs": 50])
        XCTAssertEqual(script.steps[1].params, ["selector": ["window": "Alcove Fixture", "role": "Button", "automationId": "send"],
                                                "fallback": ["x": 10, "y": 20]])
        XCTAssertEqual(script.steps[2].params, ["selector": ["role": "MenuItem", "name": "File"], "fallback": ["x": 30, "y": 40]])
        XCTAssertEqual(script.steps[3].params, ["x": 190, "y": 112, "hold": 900])
        XCTAssertEqual(script.steps[4].params, ["fromX": 190, "fromY": 112, "toX": 300, "toY": 112])
        XCTAssertEqual(script.steps.map(\.label), ["vm.ui.click Button \"Send\"", "vm.ui.click Button #send", "vm.ui.click MenuItem \"File\"",
                                                   "vm.mouse.click Button \"Send\"", "vm.mouse.drag Button \"Send\""])
        XCTAssertNoThrow(try script.validate())
    }

    func testCoordinateClickWithoutTargetKeepsCoordinates() {
        let script = build([
            entry(1, "vm.mouse.click", ["x": 300, "y": 200]),
            entry(2, "vm.mouse.click", ["x": 310, "y": 210, "button": "right"], ["target": ["window": "Program Manager", "role": "Pane", "name": ""]]),
            entry(3, "vm.mouse.click", ["x": 320, "y": 220], ["target": ["role": "Custom", "name": "", "aid": ""]]),
        ])
        XCTAssertEqual(ops(script), ["vm.mouse.click", "vm.mouse.click", "vm.mouse.click"])
        XCTAssertEqual(script.steps.map(\.params), [["x": 300, "y": 200], ["x": 310, "y": 210, "button": "right"], ["x": 320, "y": 220]])
        XCTAssertEqual(script.steps.map(\.label), ["vm.mouse.click (300, 200)", "vm.mouse.click (310, 210)", "vm.mouse.click (320, 220)"])
    }

    func testSelectorHoldsOnlyStableFieldsThatTheTraceHoldsInFull() {
        let long = String(repeating: "n", count: 2000) + "…"
        let script = build([
            entry(1, "vm.mouse.click", ["x": 1, "y": 2], ["target": ["window": "0x2a", "role": "Button", "name": "Send", "ref": "e5", "x": 150, "runtimeId": "42.7"]]),
            entry(2, "vm.mouse.click", ["x": 3, "y": 4], ["target": ["window": "foreground", "role": "Button", "name": "Send"]]),
            entry(3, "vm.mouse.click", ["x": 5, "y": 6], ["target": ["window": "Notes", "role": "Text", "name": .string(long), "nameTruncated": true]]),
            entry(4, "vm.mouse.click", ["x": 7, "y": 8], ["target": ["window": "Notes", "role": "Text", "name": .string(long), "nameTruncated": true, "aid": "body"]]),
        ])
        XCTAssertEqual(script.steps.map { $0.params["selector"] },
                       [["role": "Button", "name": "Send"], ["role": "Button", "name": "Send"], nil, ["window": "Notes", "role": "Text", "automationId": "body"]])
        XCTAssertEqual(ops(script), ["vm.ui.click", "vm.ui.click", "vm.mouse.click", "vm.ui.click"])
    }

    func testRefBecomesSelector() throws {
        let given: JSON = ["window": "Alcove Fixture", "nameContains": "Sen", "index": 1]
        let draft = ScriptBuilder.draft(trace: [
            entry(1, "vm.ui.click", ["ref": "e5", "button": "right"], result: ["x": 190, "y": 112, "node": sendButton],
                  ["selector": ["role": "Button", "name": "Send", "aid": "send"]]),
            entry(2, "vm.ui.type", ["ref": "e4", "text": "hi", "clear": true], result: ["node": node("e4", "Edit", "Message")],
                  ["selector": ["role": "Edit", "name": "Message"]]),
            entry(3, "vm.ui.action", ["selector": given, "action": "invoke"], result: ["node": sendButton]),
            entry(4, "vm.ui.click", ["ref": "e9", "count": 2], result: ["x": 40, "y": 50, "node": node("e9", "Pane", "")],
                  ["selector": ["role": "Pane", "name": ""]]),
            entry(5, "vm.ui.action", ["ref": "e9", "action": "focus"], result: ["node": node("e9", "Pane", "")]),
            entry(6, "vm.ui.type", ["ref": "e9", "text": "x"], result: ["node": node("e9", "Pane", "")], ["selector": ["role": "Pane", "name": ""]]),
        ], vm: "Win", from: nil, to: nil)
        let script = draft.script
        XCTAssertEqual(ops(script), ["vm.ui.click", "vm.ui.type", "vm.ui.action", "vm.mouse.click"])
        XCTAssertEqual(script.steps[0].params, ["selector": ["role": "Button", "name": "Send", "automationId": "send"], "button": "right"])
        XCTAssertEqual(script.steps[1].params, ["selector": ["role": "Edit", "name": "Message"], "text": "hi", "clear": true])
        XCTAssertEqual(script.steps[2].params, ["selector": given, "action": "invoke"])
        XCTAssertEqual(script.steps[3].params, ["x": 40, "y": 50, "count": 2])
        XCTAssertEqual(script.steps.map(\.label), ["vm.ui.click Button \"Send\"", "vm.ui.type Edit \"Message\"", "vm.ui.action invoke \"Sen\"",
                                                   "vm.mouse.click (40, 50)"])
        XCTAssertEqual(draft.warnings, [
            "seq 5 (vm.ui.action) is left out: its element was named by ref and has neither a name nor an automation id; add the step by hand with a selector",
            "seq 6 (vm.ui.type) is left out: its element was named by ref and has neither a name nor an automation id; add the step by hand with a selector",
        ])
        XCTAssertFalse(String(decoding: try script.encoded(), as: UTF8.self).contains("\"ref\""))
        XCTAssertNoThrow(try script.validate())
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
            entry(5, "vm.mouse.click", ["x": 1, "y": 2], ["target": ["window": "${w}", "role": "Button", "name": "${n}"]]),
        ])
        XCTAssertEqual(script.steps[0].params, ["text": "cost $${amount}$${x}"])
        XCTAssertEqual(script.steps[1].params, ["command": "echo $${HOME}", "argv": ["$${a}", 3]])
        XCTAssertEqual(script.steps[2].params["selector"], ["window": "$${w}", "role": "Button", "name": "$${n}"])
        let replayed = try Script.parse(try script.encoded()).resolved(with: [:])
        XCTAssertEqual(replayed.steps[0].params, ["text": "cost ${amount}${x}"])
        XCTAssertEqual(replayed.steps[1].params, ["command": "echo ${HOME}", "argv": ["${a}", 3]])
        XCTAssertEqual(replayed.steps[2].params["selector"], ["window": "${w}", "role": "Button", "name": "${n}"])
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

    func testPasswordFieldValuesAreNotWritten() throws {
        let secret: JSON = ["window": "Sign in", "role": "Edit", "name": "Password", "aid": "pw", "password": true, "value": "old-secret"]
        let draft = ScriptBuilder.draft(trace: [
            entry(1, "vm.mouse.click", ["x": 10, "y": 20], ["target": secret]),
            entry(2, "vm.type", ["text": "hunter2"]),
            entry(3, "vm.ui.type", ["ref": "e7", "text": "s3cret"], result: ["node": node("e7", "Edit", "Password", flags: ["password"], value: "shown-value")],
                  ["selector": ["role": "Edit", "name": "Password", "password": true]]),
            entry(4, "vm.type", ["text": "again"]),
            entry(5, "vm.mouse.click", ["x": 30, "y": 40], ["target": ["window": "Sign in", "role": "Edit", "name": "User"]]),
            entry(6, "vm.type", ["text": "ada"]),
        ], vm: "Win", from: nil, to: nil)
        let script = draft.script
        XCTAssertEqual(script.steps[0].params, ["selector": ["window": "Sign in", "role": "Edit", "name": "Password", "automationId": "pw"],
                                                "fallback": ["x": 10, "y": 20]])
        XCTAssertEqual(script.steps[1].params, ["text": "hunter2"])
        XCTAssertEqual(script.steps[2].params, ["selector": ["role": "Edit", "name": "Password"], "text": "s3cret"])
        XCTAssertEqual(script.steps.map(\.label), ["vm.ui.click Edit \"Password\"", "vm.type into a password field", "vm.ui.type Edit \"Password\"",
                                                   "vm.type into a password field", "vm.ui.click Edit \"User\"", "vm.type \"ada\""])
        let text = String(decoding: try script.encoded(), as: UTF8.self)
        for hidden in ["old-secret", "shown-value", "\"password\""] { XCTAssertFalse(text.contains(hidden), hidden) }
        XCTAssertEqual(text.components(separatedBy: "hunter2").count, 2)
        XCTAssertEqual(text.components(separatedBy: "s3cret").count, 2)
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
        XCTAssertEqual(script.steps.map(\.expect), [[], [], [["type": "window_title", "contains": "Save As"]], [["type": "window_title", "contains": "Word"]], []])
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

    // MARK: - script.save

    func testSaveOpWritesParsableScript() async throws {
        let h = handler()
        let dir = try recordingDir([
            entry(1, "vm.mouse.click", ["x": 190, "y": 112], ["target": sendTarget]),
            entry(2, "vm.type", ["text": "hello ${name}"]),
            entry(3, "vm.screenshot", result: ["png": "<image omitted>"]),
            entry(4, "vm.key.press", ["keys": "enter"]),
        ])
        let out = try tempDir().appendingPathComponent("flow.json")
        let saved = try await h.handle(op: "script.save", params: ["dir": .string(dir.path), "path": .string(out.path)])
        XCTAssertEqual(saved, ["path": .string(out.path), "steps": 3, "skipped": 0])
        let script = try Script.parse(try Data(contentsOf: out))
        XCTAssertEqual(script.vm, "Win")
        XCTAssertEqual(ops(script), ["vm.ui.click", "vm.type", "vm.key.press"])
        XCTAssertEqual(script.steps[0].params, ["selector": sendSelector, "fallback": ["x": 190, "y": 112]])
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

    func testASavedRecordingReplaysTheRecordedInput() async throws {
        let answers = LockedBox<[String: Reply]>([
            "ui.at": .ok(["node": sendButton, "window": fixtureWindow]),
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
        XCTAssertEqual(saved, ["path": .string(out.path), "steps": 3, "skipped": 0])
        let run = try await h.handle(op: "script.run", params: ["path": .string(out.path)])
        XCTAssertEqual(run["passed"], true, run["error"]?.stringValue ?? "")
        XCTAssertEqual(run["steps"]?.arrayValue?.map { $0["label"] }, ["vm.ui.click Button \"Send\"", "vm.type \"hi\"", "vm.key.press enter"])
        let all = await t.sent
        XCTAssertEqual(Array(all.dropFirst(recorded.count)), recorded)
        XCTAssertEqual(fields(try XCTUnwrap(agentRequests(agent, "ui.rect").last)),
                       ["window": "Alcove Fixture", "role": "Button", "name": "Send", "automationId": "send", "scroll": true])
        XCTAssertEqual(agentRequests(agent, "ui.at").count, 1)
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
        XCTAssertEqual(saved["warnings"], ["seq 4 (vm.exec): the trace masks the env value 'TOKEN'; the step reads it from the variable 'TOKEN', pass it in variables when running the script"])
        XCTAssertEqual(ops(try Script.parse(try Data(contentsOf: out))), ["vm.key.press", "vm.exec"])
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
        XCTAssertEqual(saved, ["path": .string(out.path), "steps": 3, "skipped": 1])
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

    func testRecordingAddsTargetToClicks() async throws {
        let answers = LockedBox<[String: Reply]>([
            "ui.at": .ok(["node": sendButton, "window": fixtureWindow]),
            "ui.rect": .ok(["node": sendButton, "cx": 190, "cy": 112, "clickable": true]),
        ])
        let (h, _, agent) = try await rig(answers)
        let dir = try await startRecording(h)
        let clicked = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        XCTAssertEqual(clicked, ["eventSeq": 0])
        _ = try await h.handle(op: "vm.mouse.drag", params: ["name": "Win", "fromX": 150, "fromY": 100, "toX": 300, "toY": 100])
        _ = try await h.handle(op: "vm.mouse.move", params: click(1, 1))
        _ = try await h.handle(op: "vm.ui.click", params: ["name": "Win", "ref": "e5"])
        _ = try await h.handle(op: "vm.ui.click", params: ["name": "Win", "selector": ["name": "Send"]])
        _ = try await h.handle(op: "vm.batch", params: ["name": "Win", "steps": [["op": "vm.mouse.click", "x": 2, "y": 2]]])
        answers.value["ui.at"] = .fail("no element at (700, 500); take a screenshot to see what is at that point")
        let bare = try await h.handle(op: "vm.mouse.click", params: click(700, 500))
        XCTAssertEqual(bare, ["eventSeq": 0])
        answers.value["ui.at"] = .ok(["node": node("e9", "Pane", ""), "window": .null])
        _ = try await h.handle(op: "vm.mouse.click", params: click(701, 501))
        let status = try await h.handle(op: "vm.record.status", params: ["name": "Win"])
        XCTAssertEqual(status["ops"], 8)
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        _ = try await h.handle(op: "vm.mouse.click", params: click(5, 5))

        let rows = try lines(dir)
        XCTAssertEqual(rows.map { $0["op"]?.stringValue },
                       ["vm.mouse.click", "vm.mouse.drag", "vm.mouse.move", "vm.ui.click", "vm.ui.click", "vm.batch", "vm.mouse.click", "vm.mouse.click"])
        XCTAssertEqual(rows.map { $0["target"] }, [sendTarget, sendTarget, nil, nil, nil, nil, nil, ["role": "Pane", "name": ""]])
        XCTAssertEqual(rows.map { $0["selector"] }, [nil, nil, nil, ["role": "Button", "name": "Send", "aid": "send"], nil, nil, nil, nil])
        XCTAssertEqual(rows.map { $0["ok"] }, Array(repeating: true, count: 8))
        XCTAssertEqual(rows.map { $0["script"] }, Array(repeating: nil, count: 8))
        XCTAssertEqual(agentRequests(agent, "ui.at").map(fields),
                       [["x": 190, "y": 112], ["x": 150, "y": 100], ["x": 700, "y": 500], ["x": 701, "y": 501]])
        XCTAssertEqual(ops(build(rows)), ["vm.ui.click", "vm.mouse.drag", "vm.mouse.move", "vm.ui.click", "vm.ui.click", "vm.batch",
                                          "vm.mouse.click", "vm.mouse.click"])
    }

    func testRecordedTargetOfAPasswordFieldHoldsNoValue() async throws {
        let field = node("e7", "Edit", "Password", aid: "pw", flags: ["focused", "password"], value: "shown-value")
        let answers = LockedBox<[String: Reply]>([
            "ui.at": .ok(["node": field, "window": fixtureWindow]),
            "ui.rect": .ok(["node": field, "cx": 190, "cy": 112, "clickable": true]),
        ])
        let (h, _, _) = try await rig(answers)
        let dir = try await startRecording(h)
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        _ = try await h.handle(op: "vm.ui.type", params: ["name": "Win", "ref": "e7", "text": "hunter2"])
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        let rows = try lines(dir)
        XCTAssertEqual(rows[0]["target"], ["window": "Alcove Fixture", "role": "Edit", "name": "Password", "aid": "pw", "password": true])
        XCTAssertEqual(rows[1]["selector"], ["role": "Edit", "name": "Password", "aid": "pw", "password": true])
        let text = String(decoding: try build(rows).encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("shown-value"))
        XCTAssertTrue(text.contains("hunter2"))
    }

    func testAClickStopsWaitingForItsTargetWhenTheBudgetEndsAndTheHelperStaysTakenUntilItAnswers() async throws {
        UITiming.targetBudget = .seconds(600)
        let budget = Latch()
        let ends = LockedBox<[ContinuousClock.Instant]>([])
        UITiming.factBudgetEnd = { end in
            ends.value.append(end)
            await budget.pass()
        }
        let answers = LockedBox<[String: Reply]>(["ui.at": .silent])
        let (h, t, agent) = try await rig(answers)
        let dir = try await startRecording(h)

        let press = click(190, 112)
        let before = ContinuousClock.now
        let first = Task { try await h.handle(op: "vm.mouse.click", params: press) }
        let asked = await eventually { agentRequests(agent, "ui.at").count == 1 && ends.value.count == 1 }
        XCTAssertTrue(asked)
        let after = ContinuousClock.now
        let end = try XCTUnwrap(ends.value.first)
        XCTAssertGreaterThanOrEqual(end, before + .seconds(600))
        XCTAssertLessThanOrEqual(end, after + .seconds(600))
        let untouched = await t.sent.isEmpty
        XCTAssertTrue(untouched)
        await budget.open()
        let late = try await value(of: first)
        XCTAssertEqual(late, ["eventSeq": 0])
        let taken = try await h.helperGate.acquire("Win", until: .now)
        XCTAssertFalse(taken)

        _ = try await h.handle(op: "vm.mouse.click", params: click(5, 5))
        XCTAssertEqual(agentRequests(agent, "ui.at").count, 1)
        let left = await eventually { await h.helperGate.waiterCount(for: "Win") == 0 }
        XCTAssertTrue(left)

        UITiming.factBudgetEnd = { try? await Task.sleep(until: $0, clock: .continuous) }
        answers.value["ui.at"] = .ok(["node": sendButton, "window": fixtureWindow])
        agent.sendLine(agentReply(try XCTUnwrap(agentRequests(agent, "ui.at").first), ["node": sendButton, "window": fixtureWindow]))
        let free = await eventually { (try? await h.helperGate.acquire("Win", until: .now)) == true }
        XCTAssertTrue(free)
        await h.helperGate.release("Win")
        _ = try await h.handle(op: "vm.mouse.click", params: click(190, 112))
        _ = try await h.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertEqual(try lines(dir).map { $0["target"] }, [nil, nil, sendTarget])
        XCTAssertEqual(agentRequests(agent, "ui.at").count, 2)
    }

    func testACancelledClickSendsNoTargetProbe() async throws {
        UITiming.targetBudget = .seconds(600)
        let (h, t, agent) = try await rig(LockedBox(["ui.at": .ok(["node": sendButton, "window": fixtureWindow])]))
        _ = try await startRecording(h)

        let taken = try await h.helperGate.acquire("Win", until: .now)
        XCTAssertTrue(taken)
        let press = click(190, 112)
        let queued = Task { try await h.handle(op: "vm.mouse.click", params: press) }
        let waiting = await eventually { await h.helperGate.waiterCount(for: "Win") == 1 }
        XCTAssertTrue(waiting)
        queued.cancel()
        do { _ = try await value(of: queued); XCTFail("the cancelled click succeeded") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let left = await eventually { await h.helperGate.waiterCount(for: "Win") == 0 }
        XCTAssertTrue(left)
        await h.helperGate.release("Win")
        XCTAssertTrue(agentRequests(agent, "ui.at").isEmpty)

        let frames = Latch()
        await t.setFrameHook { await frames.pass() }
        let key = Task { try await h.handle(op: "vm.key.press", params: ["name": "Win", "keys": "a"]) }
        let holding = await eventually { await frames.arrivals == 1 }
        XCTAssertTrue(holding)
        let behind = Task { try await h.handle(op: "vm.mouse.click", params: press) }
        let inLine = await eventually { await h.inputGate.waiterCount(for: "Win") == 1 }
        XCTAssertTrue(inLine)
        behind.cancel()
        await t.setFrameHook(nil)
        await frames.open()
        _ = try await value(of: key)
        do { _ = try await value(of: behind); XCTFail("the cancelled click succeeded") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(agentRequests(agent, "ui.at").isEmpty)
        let free = try await h.helperGate.acquire("Win", until: .now)
        XCTAssertTrue(free)
        await h.helperGate.release("Win")
    }

    func testNoTargetProbeWithoutTheUICapabilityOrAConnectedAgent() async throws {
        let answers = LockedBox<[String: Reply]>(["ui.at": .ok(["node": sendButton, "window": fixtureWindow])])
        let (plain, _, plainAgent) = try await rig(caps: ["clipboard", "files", "exec"], answers)
        let plainDir = try await startRecording(plain)
        _ = try await plain.handle(op: "vm.mouse.click", params: click(190, 112))
        _ = try await plain.handle(op: "vm.record.stop", params: ["name": "Win"])
        XCTAssertTrue(agentRequests(plainAgent, "ui.at").isEmpty)
        XCTAssertEqual(try lines(plainDir).map { $0["target"] }, [nil])

        let (h, t, agent) = try await rig(answers)
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

    func testARecordedClickLooksItsVMUpOnce() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 64, height: 64))
        let registry = LookupCountingRegistry(t)
        let h = ControlHandler(registry: registry, hostKind: "test")
        _ = try await startRecording(h)
        let before = await registry.lookups
        _ = try await h.handle(op: "vm.mouse.click", params: click(5, 5))
        let after = await registry.lookups
        XCTAssertEqual(after - before, 1)
    }
}

/// A registry of one VM that counts its lookups.
private actor LookupCountingRegistry: VMRegistry {
    private let only: FakeTarget
    private(set) var lookups = 0
    init(_ target: FakeTarget) { only = target }
    func names() async -> [String] { [only.name] }
    func target(named name: String) async -> VMTarget? {
        lookups += 1
        return name == only.name ? only : nil
    }
}
