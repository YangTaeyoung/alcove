import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class ScriptSecretTraceTests: XCTestCase {
    private struct Rig {
        let handler: ControlHandler
        let directory: URL
    }

    private func rig() async throws -> Rig {
        let agent = FakeAgent()
        agent.caps = ["clipboard", "files", "exec", "ui"]
        agent.handler = { m, _ in
            guard m["t"]?.stringValue == "req", let op = m["op"]?.stringValue else { return [] }
            switch op {
            case "exec.run":
                return [agentReply(m, ["code": 0, "stdout": m["cmd"] ?? .null, "stderr": ""])]
            case "ui.at":
                return [agentReply(m, ["node": ["role": "Edit", "name": "User", "x": 10, "y": 10, "w": 80, "h": 24, "flags": ["enabled"]],
                                       "window": ["id": "0x2a", "title": "Sign in"]])]
            default:
                return [["t": "res", "id": m["id"] ?? .null, "ok": false, "error": "no element matches role=Edit name=\"Password\""]]
            }
        }
        let (handler, _) = try await handlerWithAgent(agent, in: self)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("script-secret-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        _ = try await handler.handle(op: "vm.record.start", params: ["name": "Win", "dir": .string(directory.path), "video": false])
        return Rig(handler: handler, directory: directory)
    }

    private func replay(_ rig: Rig, _ steps: [String], variables: [String: String]) async throws -> String {
        let text = "{\"version\": 1, \"vm\": \"Win\", \"variables\": {}, \"steps\": [\(steps.joined(separator: ","))]}"
        let script = try Script.parse(Data(text.utf8))
        _ = await ScriptRunner(handler: rig.handler).run(script, vm: nil, variables: variables, owner: "script:test.json", snapshot: nil, progress: nil)
        _ = try await rig.handler.handle(op: "vm.record.stop", params: ["name": "Win"])
        return try String(contentsOf: rig.directory.appendingPathComponent("trace.jsonl"), encoding: .utf8)
    }

    private let typeStep = "{\"op\": \"vm.type\", \"params\": {\"text\": \"${password}\"}}"
    private let execStep = "{\"op\": \"vm.exec\", \"params\": {\"command\": \"login ${password} now\", \"env\": {\"PLAIN\": \"${password}\"}}}"
    private let uiStep = """
    {"op": "vm.ui.type", "params": {"selector": {"role": "Edit", "name": "Password"}, "altSelector": {"role": "Edit", "name": "Pass", "index": 1}, "text": "${password}"}}
    """

    func testSecretValueNeverReachesTheTrace() async throws {
        let rig = try await rig()
        let trace = try await replay(rig, [execStep, typeStep, uiStep], variables: ["password": "S3cret-value", "note": "visible-text"])
        XCTAssertFalse(trace.contains("S3cret-value"), trace)
        let lines = try trace.split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }.filter { $0["script"]?.stringValue == "step" }
        XCTAssertEqual(lines.map { $0["op"]?.stringValue }, ["vm.exec", "vm.type", "vm.ui.type", "vm.ui.type"])
        XCTAssertEqual(lines[1]["params"]?["text"]?.stringValue, "<masked>")
        XCTAssertEqual(lines[0]["params"]?["command"]?.stringValue, "login <masked> now")
        XCTAssertEqual(lines[0]["result"]?["stdout"]?.stringValue?.contains("login <masked> now"), true)
        XCTAssertEqual(lines[2]["params"]?["text"]?.stringValue, "<masked>")
        XCTAssertEqual(lines[3]["params"]?["text"]?.stringValue, "<masked>")
        XCTAssertEqual(lines[2]["ok"]?.boolValue, false)
    }

    func testVariableWithANonSecretNameStaysReadable() async throws {
        let rig = try await rig()
        let step = "{\"op\": \"vm.exec\", \"params\": {\"command\": \"echo ${note} ${password}\"}}"
        let trace = try await replay(rig, [step], variables: ["password": "S3cret-value", "note": "visible-text"])
        XCTAssertTrue(trace.contains("echo visible-text <masked>"), trace)
    }

    func testShortSecretMasksOnlyExactStrings() async throws {
        let rig = try await rig()
        let exact = "{\"op\": \"vm.type\", \"params\": {\"text\": \"${pin_key}\"}}"
        let inside = "{\"op\": \"vm.exec\", \"params\": {\"command\": \"echo 1 and ${pin_key}1\"}}"
        let trace = try await replay(rig, [exact, inside], variables: ["pin_key": "1"])
        let lines = try trace.split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }.filter { $0["script"]?.stringValue == "step" }
        XCTAssertEqual(lines[0]["params"]?["text"]?.stringValue, "<masked>")
        XCTAssertEqual(lines[1]["params"]?["command"]?.stringValue, "echo 1 and 11")
    }

    func testScriptSavedFromTheTraceHoldsNoSecret() async throws {
        let rig = try await rig()
        _ = try await replay(rig, [typeStep], variables: ["password": "S3cret-value"])
        let path = rig.directory.appendingPathComponent("saved.json").path
        let saved = try await rig.handler.handle(op: "script.save", params: ["dir": .string(rig.directory.path), "path": .string(path)])
        XCTAssertEqual(saved["steps"]?.intValue, 1)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.contains("S3cret-value"), text)
        XCTAssertTrue(text.contains("${password}"), text)
    }

    func testMaskingRules() {
        let secrets = ["S3cret-value", "1"]
        let value: JSON = ["a": "S3cret-value", "b": "pre S3cret-value post", "c": "1", "d": "11", "e": ["1", "x S3cret-value"], "n": 1]
        XCTAssertEqual(TraceSanitizer.maskValues(value, secrets: secrets),
                       ["a": "<masked>", "b": "pre <masked> post", "c": "<masked>", "d": "11", "e": ["<masked>", "x <masked>"], "n": 1])
        XCTAssertEqual(TraceSanitizer.maskValues(value, secrets: []), value)
    }
}
