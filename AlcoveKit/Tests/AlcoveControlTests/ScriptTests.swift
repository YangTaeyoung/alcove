import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

/// Collects the progress callbacks of a run.
private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Int, String, Bool)] = []
    func note(_ number: Int, _ step: Script.Step, _ outcome: Result<JSON, Error>) {
        lock.lock(); defer { lock.unlock() }
        if case .success = outcome { entries.append((number, step.op, true)) } else { entries.append((number, step.op, false)) }
    }
    var numbers: [Int] { lock.lock(); defer { lock.unlock() }; return entries.map(\.0) }
    var outcomes: [Bool] { lock.lock(); defer { lock.unlock() }; return entries.map(\.2) }
}

final class ScriptTests: XCTestCase {
    private struct Rig {
        let handler: ControlHandler
        let target: FakeTarget
        let agent: FakeAgent
        let fs: FakeFS
        let clock: TestClock
    }

    override func setUp() {
        WaitTiming.tick = .milliseconds(20)
        WaitTiming.screenPeriod = .milliseconds(20)
        WaitTiming.ocrPeriod = .milliseconds(60)
        WaitTiming.agentPeriod = .milliseconds(40)
        WaitTiming.agentCallTimeout = .seconds(3)
    }

    override func tearDown() {
        WaitTiming.tick = .milliseconds(250)
        WaitTiming.screenPeriod = .milliseconds(250)
        WaitTiming.ocrPeriod = .milliseconds(700)
        WaitTiming.agentPeriod = .milliseconds(500)
        WaitTiming.agentCallTimeout = .seconds(5)
        ScriptTiming.leaseSeconds = 600
        ScriptTiming.leaseRenewal = .seconds(200)
    }

    /// A running VM "Win" whose agent answers `exec.run` with the command and serves `fs`.
    private func rig() async throws -> Rig {
        let fs = FakeFS()
        let files = FakeAgent()
        fs.install(on: files)
        let fsHandler = files.handler
        let agent = FakeAgent()
        agent.handler = { m, a in
            if m["t"]?.stringValue == "req", m["op"]?.stringValue == "exec.run" {
                let reply = agentReply(m, ["code": 0, "stdout": m["cmd"] ?? .null, "stderr": ""])
                switch m["cmd"]?.stringValue {
                case "slow":
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { a.sendLine(reply) }
                    return []
                case "stall":
                    return []
                default:
                    return [reply]
                }
            }
            return fsHandler?(m, a) ?? []
        }
        _ = agent.start()
        addTeardownBlock { agent.stop() }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        let target = FakeTarget(name: "Win", state: .running, png: makePNG(width: 800, height: 600))
        await target.setAgent(client)
        let clock = TestClock()
        let handler = ControlHandler(registry: FakeRegistry(targets: ["Win": target]), hostKind: "test", clock: { clock.now })
        return Rig(handler: handler, target: target, agent: agent, fs: fs, clock: clock)
    }

    private func script(_ json: String) throws -> Script {
        try Script.parse(Data(json.utf8))
    }

    private func steps(_ items: [String], vm: String? = "Win", variables: String = "{}") -> String {
        let name = vm.map { "\"vm\": \"\($0)\"," } ?? ""
        return "{\"version\": 1, \(name) \"variables\": \(variables), \"steps\": [\(items.joined(separator: ","))]}"
    }

    private func exec(_ command: String, label: String? = nil, expect: String = "[]", timeout: Int = 5) -> String {
        let name = label.map { "\"label\": \"\($0)\"," } ?? ""
        return "{\(name) \"op\": \"vm.exec\", \"params\": {\"command\": \"\(command)\"}, \"expect\": \(expect), \"timeout\": \(timeout)}"
    }

    private func run(_ rig: Rig, _ script: Script, vm: String? = nil, variables: [String: String] = [:], lease: String? = nil,
                     snapshot: String? = nil, progress: Progress? = nil) async -> ScriptResult {
        let callback: (@Sendable (Int, Script.Step, Result<JSON, Error>) -> Void)? = progress.map { collector in
            { @Sendable number, step, outcome in collector.note(number, step, outcome) }
        }
        return await ScriptRunner(handler: rig.handler).run(script, vm: vm, variables: variables, lease: lease, owner: "script:test.json",
                                                            snapshot: snapshot, progress: callback)
    }

    private func execCommands(_ rig: Rig) -> [String] {
        agentRequests(rig.agent, "exec.run").compactMap { $0["cmd"]?.stringValue }.filter { !$0.hasPrefix("$ErrorActionPreference") }
    }

    private func leasedBy(_ rig: Rig) async throws -> String? {
        try await rig.handler.handle(op: "vm.status", params: ["name": "Win"])["leasedBy"]?.stringValue
    }

    private func scriptFile(_ text: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("script-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("flow.json")
        try Data(text.utf8).write(to: file)
        return file.path
    }

    // MARK: - parsing

    func testParseRoundTrip() throws {
        let original = try script("""
        {"version": 1, "vm": "Windows 11", "variables": {"message": "hello"},
         "steps": [{"label": "type it", "op": "vm.type", "params": {"text": "${message}", "nested": {"list": [1, "a"]}},
                    "expect": [{"type": "file_exists", "path": "C:\\\\a"}], "timeout": 7},
                   {"op": "vm.key.press", "params": {"key": "enter"}}]}
        """)
        XCTAssertEqual(original.vm, "Windows 11")
        XCTAssertEqual(original.variables, ["message": "hello"])
        XCTAssertEqual(original.steps[0].timeout, 7)
        XCTAssertEqual(original.steps[1].timeout, 10)
        XCTAssertEqual(original.steps[1].expect, [])
        XCTAssertNil(original.steps[1].label)
        let data = try original.encoded()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\n"), "pretty-printed")
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"steps\"")).lowerBound, try XCTUnwrap(text.range(of: "\"version\"")).lowerBound, "sorted keys")
        XCTAssertEqual(try Script.parse(data), original)
        XCTAssertEqual(try original.encoded(), data)
    }

    func testRejectsMalformedScripts() {
        let cases: [(String, String)] = [
            ("not json", "the script is not valid JSON; fix its syntax"),
            ("[1]", "the script must be a JSON object"),
            ("{\"steps\": []}", "the script has no version; add \"version\": 1"),
            ("{\"version\": 2, \"steps\": []}", "script version 2 is not supported; this build reads version 1"),
            ("{\"version\": 1}", "the script has no steps"),
            ("{\"version\": 1, \"steps\": []}", "the script has no steps"),
            ("{\"version\": 1, \"vm\": 4, \"steps\": [{\"op\": \"vm.type\"}]}", "'vm' must be a non-empty string"),
            ("{\"version\": 1, \"variables\": {\"a\": 1}, \"steps\": [{\"op\": \"vm.type\"}]}", "variable 'a' must be a string"),
            (steps(["{\"op\": \"vm.type\"}", "{\"op\": \"vm.type\"}", "{\"label\": \"x\"}"]), "step 3 has no op; every step needs an op such as vm.type"),
            (steps(["{\"op\": \"vm.type\"}", "{\"op\": \"vm.lease.acquire\"}"]), "step 2 uses op 'vm.lease.acquire', which scripts may not run"),
            (steps(["{\"op\": \"vm.bogus\"}"]), "step 1 uses unknown op 'vm.bogus'"),
            (steps(["{\"op\": \"vm.type\", \"params\": {\"name\": \"Win\"}}"]), "step 1 passes 'name' in params"),
            (steps(["{\"op\": \"vm.type\", \"params\": {\"lease\": \"x\"}}"]), "step 1 passes 'lease' in params"),
            (steps(["{\"op\": \"vm.type\", \"params\": 3}"]), "step 1 has params that are not an object"),
            (steps(["{\"op\": \"vm.type\", \"expect\": {}}"]), "step 1 has an expect that is not an array"),
            (steps(["{\"op\": \"vm.type\", \"expect\": [3]}"]), "step 1 has an expectation that is not an object"),
            (steps(["{\"op\": \"vm.type\", \"timeout\": 0}"]), "step 1 has a timeout outside 1 to 600 seconds"),
            (steps(["{\"op\": \"vm.type\", \"timeout\": \"5\"}"]), "step 1 has a timeout outside 1 to 600 seconds"),
            (steps(["4"]), "step 1 is not an object"),
            (steps(["{\"op\": \"vm.type\", \"timeout\": 601}"]), "step 1 has a timeout outside 1 to 600 seconds"),
            (steps(["{\"op\": \"vm.type\", \"timeout\": -3}"]), "step 1 has a timeout outside 1 to 600 seconds"),
            (steps(["{\"op\": \"vm.type\", \"timeout\": 2.5}"]), "step 1 has a timeout outside 1 to 600 seconds"),
            ("{\"version\": 1, \"steps\": {}}", "'steps' must be an array"),
            (steps(["{\"op\": \"vm.type\", \"label\": 4}"]), "step 1 has a label that is not a string"),
            (steps(["{\"op\": \"vm.type\", \"expects\": []}"]),
             "step 1 has unknown key 'expects'; allowed keys are label, op, params, expect, timeout"),
            ("{\"version\": 1, \"stepz\": [], \"steps\": [{\"op\": \"vm.type\"}]}",
             "the script has unknown key 'stepz'; allowed keys are version, vm, variables, steps"),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try Script.parse(Data(text.utf8)), text) { error in
                XCTAssertTrue("\(error)".contains(expected), "\(error) should contain \(expected)")
            }
        }
        XCTAssertThrowsError(try Script.parse(Data(steps(["{\"op\": \"vm.type\"}", "{\"op\": \"vm.delete\"}"]).utf8))) { error in
            XCTAssertEqual((error as? ScriptError)?.step, 2)
        }
    }

    func testDisallowedOpsRefused() async throws {
        let rig = try await rig()
        for op in ["vm.lease.acquire", "vm.lease.release", "vm.record.start", "vm.record.stop", "vm.record.status",
                   "script.run", "script.anything", "vm.clone", "vm.delete"] {
            XCTAssertFalse(Script.allows(op: op), op)
            XCTAssertThrowsError(try script(steps([exec("first"), "{\"op\": \"\(op)\"}"])), op) { error in
                let message = "\(error)"
                XCTAssertTrue(message.hasPrefix("step 2 "), message)
                XCTAssertTrue(message.contains(op) || op == "script.anything", message)
            }
        }
        for op in ControlHandler.knownOps where !op.hasPrefix("vm.lease.") && !op.hasPrefix("vm.record.") && !op.hasPrefix("script.")
            && op != "vm.clone" && op != "vm.delete" {
            XCTAssertTrue(Script.allows(op: op), op)
        }

        let direct = Script(vm: "Win", variables: [:], steps: [
            Script.Step(label: nil, op: "vm.exec", params: ["command": "first"], expect: [], timeout: 5),
            Script.Step(label: nil, op: "vm.delete", params: [:], expect: [], timeout: 5),
        ])
        let result = await run(rig, direct)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.stepsRun, 0)
        XCTAssertTrue(result.error?.contains("step 2 uses op 'vm.delete'") == true, result.error ?? "")
        XCTAssertEqual(execCommands(rig), [])
        let held = try await leasedBy(rig)
        XCTAssertNil(held)
    }

    // MARK: - variables

    func testVariableSubstitutionInParamsAndExpect() throws {
        let parsed = try script("""
        {"version": 1, "vm": "${vm}", "variables": {"who": "world", "file": "a.txt"},
         "steps": [{"label": "${who}", "op": "vm.type",
                    "params": {"text": "hi ${who}", "deep": {"list": ["${file}", 3, {"k": "x${who}y"}]}},
                    "expect": [{"type": "file_exists", "path": "C:\\\\${file}"}]}]}
        """)
        let resolved = try parsed.resolved(with: ["who": "there"])
        XCTAssertEqual(resolved.vm, "${vm}")
        XCTAssertEqual(resolved.steps[0].label, "${who}")
        XCTAssertEqual(resolved.steps[0].params["text"], "hi there")
        XCTAssertEqual(resolved.steps[0].params["deep"], ["list": ["a.txt", 3, ["k": .string("xtherey")]]])
        XCTAssertEqual(resolved.steps[0].expect, [["type": "file_exists", "path": "C:\\a.txt"]])
        XCTAssertEqual(parsed.steps[0].params["text"], "hi ${who}")
        let extra = try parsed.resolved(with: ["vm": "Z"])
        XCTAssertEqual(extra.variables["vm"], "Z")
    }

    func testUndefinedVariable() async throws {
        let parsed = try script(steps([exec("first"), exec("say ${missing}")]))
        XCTAssertThrowsError(try parsed.resolved(with: [:])) { error in
            XCTAssertEqual("\(error)", "variable 'missing' is not defined; pass it or add a default")
        }
        XCTAssertThrowsError(try script(steps([exec("open ${oops")])).resolved(with: [:])) { error in
            XCTAssertTrue("\(error)".contains("without a closing '}'"), "\(error)")
        }
        let rig = try await rig()
        let result = await run(rig, parsed)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.stepsRun, 0)
        XCTAssertNil(result.failedStep)
        XCTAssertEqual(result.error, "variable 'missing' is not defined; pass it or add a default")
        XCTAssertEqual(execCommands(rig), [])
    }

    func testDollarEscaping() async throws {
        XCTAssertEqual(Script.escape("a ${b} c"), "a $${b} c")
        XCTAssertEqual(Script.escape("plain $ text"), "plain $ text")
        let literals = ["${x}", "$${x}", "cost $5 ${", "a$", "${"]
        for literal in literals {
            let step = Script.Step(label: nil, op: "vm.type", params: ["text": .string(Script.escape(literal))], expect: [], timeout: 5)
            let resolved = try Script(vm: nil, variables: ["x": "VALUE"], steps: [step]).resolved(with: [:])
            XCTAssertEqual(resolved.steps[0].params["text"]?.stringValue, literal)
        }
        let rig = try await rig()
        let parsed = try script(steps([exec("echo " + Script.escape("${HOME} ${v}") + " ${v}")], variables: "{\"v\": \"1\"}"))
        let result = await run(rig, parsed)
        XCTAssertTrue(result.passed, result.error ?? "")
        XCTAssertEqual(execCommands(rig), ["echo ${HOME} ${v} 1"])
    }

    // MARK: - running

    func testRunPassesAllSteps() async throws {
        let rig = try await rig()
        let progress = Progress()
        let result = await run(rig, try script(steps([exec("one", label: "first"), exec("two"), exec("three")])), progress: progress)
        XCTAssertTrue(result.passed, result.error ?? "")
        XCTAssertEqual(result.stepsRun, 3)
        XCTAssertNil(result.failedStep)
        XCTAssertNil(result.error)
        XCTAssertNil(result.failureImage)
        XCTAssertEqual(execCommands(rig), ["one", "two", "three"])
        XCTAssertEqual(progress.numbers, [1, 2, 3])
        XCTAssertEqual(progress.outcomes, [true, true, true])
        XCTAssertEqual(result.stepResults.count, 3)
        XCTAssertEqual(result.stepResults[0]["label"]?.stringValue, "first")
        XCTAssertEqual(result.stepResults[0]["ok"]?.boolValue, true)
        XCTAssertEqual(result.stepResults[0]["result"]?["output"]?.stringValue, "one")
    }

    func testVMNameComesFromTheRunOrTheScript() async throws {
        let rig = try await rig()
        let none = await run(rig, try script(steps([exec("x")], vm: nil)))
        XCTAssertFalse(none.passed)
        XCTAssertEqual(none.error, "the script names no VM; pass name or add \"vm\" to the script")
        XCTAssertEqual(none.stepsRun, 0)
        let override = await run(rig, try script(steps([exec("x")], vm: "Elsewhere")), vm: "Win")
        XCTAssertTrue(override.passed, override.error ?? "")
        let missing = await run(rig, try script(steps([exec("x")], vm: "Elsewhere")))
        XCTAssertFalse(missing.passed)
        XCTAssertTrue(missing.error?.contains("no VM named 'Elsewhere'") == true, missing.error ?? "")
    }

    func testRunStopsAtFirstFailure() async throws {
        let rig = try await rig()
        let progress = Progress()
        let failing = "{\"label\": \"click nowhere\", \"op\": \"vm.mouse.click\", \"params\": {\"x\": 1}}"
        let result = await run(rig, try script(steps([exec("one"), failing, exec("three")])), progress: progress)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.stepsRun, 2)
        XCTAssertEqual(result.failedStep, 2)
        XCTAssertEqual(result.error, "step 2 (click nowhere) failed: missing or invalid parameter 'y'")
        XCTAssertEqual(execCommands(rig), ["one"])
        XCTAssertEqual(progress.numbers, [1, 2])
        XCTAssertEqual(progress.outcomes, [true, false])
        XCTAssertEqual(result.stepResults[1]["ok"]?.boolValue, false)
        XCTAssertEqual(result.stepResults[1]["error"]?.stringValue, "missing or invalid parameter 'y'")
    }

    func testExpectAllMustHold() async throws {
        let rig = try await rig()
        rig.fs["C:\\a.txt"] = Data("a".utf8)
        let both = "[{\"type\": \"file_exists\", \"path\": \"C:\\\\a.txt\"}, {\"type\": \"file_exists\", \"path\": \"C:\\\\b.txt\"}]"
        let failing = await run(rig, try script(steps([exec("one", expect: both, timeout: 1), exec("two")])))
        XCTAssertFalse(failing.passed)
        XCTAssertEqual(failing.failedStep, 1)
        XCTAssertTrue(failing.error?.contains("{\"path\":\"C:\\\\b.txt\",\"type\":\"file_exists\"}") == true, failing.error ?? "")
        XCTAssertFalse(failing.error?.contains("a.txt") == true, failing.error ?? "")
        XCTAssertEqual(execCommands(rig), ["one"])

        rig.fs["C:\\b.txt"] = Data("b".utf8)
        let passing = await run(rig, try script(steps([exec("three", expect: both, timeout: 5)])))
        XCTAssertTrue(passing.passed, passing.error ?? "")
    }

    func testExpectTimeoutFailsStep() async throws {
        let rig = try await rig()
        let never = "[{\"type\": \"file_exists\", \"path\": \"C:\\\\never\"}]"
        let result = await run(rig, try script(steps([exec("one", label: "wait for it", expect: never, timeout: 1), exec("two")])))
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.failedStep, 1)
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.hasPrefix("step 1 (wait for it) failed: expectation "), error)
        XCTAssertTrue(error.contains("did not hold within "), error)
        XCTAssertEqual(execCommands(rig), ["one"])
    }

    func testWaitForStepWithoutMatchFails() async throws {
        let rig = try await rig()
        let wait = "{\"op\": \"vm.wait_for\", \"params\": {\"conditions\": [{\"type\": \"file_exists\", \"path\": \"C:\\\\never\"}], \"timeout\": 1}}"
        let result = await run(rig, try script(steps([wait, exec("after")])))
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.failedStep, 1)
        XCTAssertTrue(result.error?.contains("vm.wait_for matched none of its conditions") == true, result.error ?? "")
        XCTAssertEqual(execCommands(rig), [])

        rig.fs["C:\\there"] = Data("x".utf8)
        let found = "{\"op\": \"vm.wait_for\", \"params\": {\"conditions\": [{\"type\": \"file_exists\", \"path\": \"C:\\\\there\"}]}}"
        let ok = await run(rig, try script(steps([found, exec("after")])))
        XCTAssertTrue(ok.passed, ok.error ?? "")
        XCTAssertEqual(ok.stepResults[0]["result"]?["matched"]?.intValue, 0)
    }

    func testFailureCarriesObservationImage() async throws {
        let rig = try await rig()
        let failing = "{\"op\": \"vm.mouse.click\", \"params\": {\"x\": 1}}"
        let result = await run(rig, try script(steps([failing])))
        XCTAssertFalse(result.passed)
        let png = try XCTUnwrap(result.failureImage)
        XCTAssertEqual(Frame(png: png)?.width, 800)
        XCTAssertEqual(result.failureWidth, 800)
        XCTAssertEqual(result.failureHeight, 600)

        await rig.target.setFailingFrameCalls(Set(0..<100))
        let blind = await run(rig, try script(steps([failing])))
        XCTAssertFalse(blind.passed)
        XCTAssertEqual(blind.failedStep, 1)
        XCTAssertNil(blind.failureImage)
        XCTAssertEqual(blind.error, "step 1 failed: missing or invalid parameter 'y'")
    }

    // MARK: - leases

    func testRunFailsWhenLeasedByOther() async throws {
        let rig = try await rig()
        _ = try await rig.handler.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "agent-a", "ttl": 60])
        let parsed = try script(steps([exec("one")]))
        let result = await run(rig, parsed)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.stepsRun, 0)
        XCTAssertTrue(result.error?.contains("leased by agent-a") == true, result.error ?? "")
        let wrong = await run(rig, parsed, lease: "not-the-token")
        XCTAssertTrue(wrong.error?.contains("leased by agent-a") == true, wrong.error ?? "")
        XCTAssertEqual(execCommands(rig), [])
        let owner = try await leasedBy(rig)
        XCTAssertEqual(owner, "agent-a")

        let path = try scriptFile(steps([exec("one")]))
        do {
            _ = try await rig.handler.handle(op: "script.run", params: ["path": .string(path)])
            XCTFail("expected the run to be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("leased by agent-a"), "\(error)")
        }
        do {
            _ = try await rig.handler.handle(op: "script.run", params: ["path": .string(path), "name": "Win"])
            XCTFail("expected the lease guard to refuse")
        } catch {
            XCTAssertTrue("\(error)".contains("leased by agent-a"), "\(error)")
        }
        XCTAssertEqual(execCommands(rig), [])
    }

    func testRunUsesTheGivenLease() async throws {
        let rig = try await rig()
        let granted = try await rig.handler.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "agent-a", "ttl": 60])
        let token = try XCTUnwrap(granted["lease"]?.stringValue)
        let result = await run(rig, try script(steps([exec("one")])), lease: token)
        XCTAssertTrue(result.passed, result.error ?? "")
        let owner = try await leasedBy(rig)
        XCTAssertEqual(owner, "agent-a")

        let path = try scriptFile(steps([exec("two")], vm: nil))
        let viaOp = try await rig.handler.handle(op: "script.run", params: ["path": .string(path), "name": "Win", "lease": .string(token)])
        XCTAssertEqual(viaOp["passed"]?.boolValue, true)
        let viaScriptVM = try await rig.handler.handle(op: "script.run", params: ["path": .string(try scriptFile(steps([exec("three")]))), "lease": .string(token)])
        XCTAssertEqual(viaScriptVM["passed"]?.boolValue, true)
        XCTAssertEqual(execCommands(rig), ["one", "two", "three"])
        let still = try await leasedBy(rig)
        XCTAssertEqual(still, "agent-a")
    }

    func testRunOnUnleasedVMHoldsAndReleasesItsOwnLease() async throws {
        let rig = try await rig()
        let status = "{\"op\": \"vm.status\", \"params\": {}}"
        let result = await run(rig, try script(steps([status])))
        XCTAssertTrue(result.passed, result.error ?? "")
        XCTAssertEqual(result.stepResults[0]["result"]?["leasedBy"]?.stringValue, "script:test.json")
        let after = try await leasedBy(rig)
        XCTAssertNil(after)
    }

    func testLeaseReleasedAfterRun() async throws {
        let rig = try await rig()
        let passing = await run(rig, try script(steps([exec("one")])))
        XCTAssertTrue(passing.passed)
        let afterPass = try await leasedBy(rig)
        XCTAssertNil(afterPass)

        let failing = await run(rig, try script(steps([exec("one"), "{\"op\": \"vm.mouse.click\", \"params\": {\"x\": 1}}"])))
        XCTAssertFalse(failing.passed)
        let afterFail = try await leasedBy(rig)
        XCTAssertNil(afterFail)

        let path = try scriptFile(steps([exec("two")], vm: nil))
        _ = try await rig.handler.handle(op: "script.run", params: ["path": .string(path), "name": "Win"])
        let afterOp = try await leasedBy(rig)
        XCTAssertNil(afterOp)
    }

    func testCancelledRunReleasesItsLeaseAndStops() async throws {
        let rig = try await rig()
        let wait = "{\"op\": \"vm.wait_for\", \"params\": {\"conditions\": [{\"type\": \"file_exists\", \"path\": \"C:\\\\never\"}], \"timeout\": 60}}"
        let parsed = try script(steps([exec("one"), wait, exec("three")]))
        let handler = rig.handler
        let task = Task { await ScriptRunner(handler: handler).run(parsed, vm: nil, variables: [:], owner: "script:test.json", progress: nil) }
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let requests = agentRequests(rig.agent, "fs.stat")
            if !requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let during = try await leasedBy(rig)
        XCTAssertEqual(during, "script:test.json")
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.stepsRun, 2)
        XCTAssertNil(result.failedStep)
        XCTAssertNil(result.failureImage)
        XCTAssertTrue(result.error?.contains("cancelled") == true, result.error ?? "")
        XCTAssertEqual(execCommands(rig), ["one"])
        let after = try await leasedBy(rig)
        XCTAssertNil(after)
    }

    func testRunRenewsItsLease() async throws {
        let rig = try await rig()
        ScriptTiming.leaseRenewal = .milliseconds(30)
        let wait = "{\"op\": \"vm.wait_for\", \"params\": {\"conditions\": [{\"type\": \"file_exists\", \"path\": \"C:\\\\never\"}], \"timeout\": 60}}"
        let parsed = try script(steps([wait]))
        let handler = rig.handler
        let task = Task { await ScriptRunner(handler: handler).run(parsed, vm: nil, variables: [:], owner: "script:test.json", progress: nil) }
        while try await leasedBy(rig) == nil { try await Task.sleep(for: .milliseconds(20)) }
        rig.clock.advance(.seconds(500))
        var remaining = ""
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            do { _ = try await rig.handler.handle(op: "vm.mouse.click", params: ["name": "Win", "x": 1, "y": 1]) } catch { remaining = "\(error)" }
            if remaining.contains("for another 600 s") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        _ = await task.value
        XCTAssertTrue(remaining.contains("for another 600 s"), remaining)
    }

    // MARK: - snapshot and the control op

    func testSnapshotRestoredFirst() async throws {
        let rig = try await rig()
        await rig.target.setSnapshotList([VMController.SnapshotInfo(name: "clean", vmStateSize: 1, date: Date())])
        let result = await run(rig, try script(steps([exec("one")])), snapshot: "clean")
        XCTAssertTrue(result.passed, result.error ?? "")
        let calls = await rig.target.snapshotCalls
        XCTAssertEqual(calls, ["restore:clean"])
        XCTAssertEqual(execCommands(rig), ["one"])

        let missing = await run(rig, try script(steps([exec("two")])), snapshot: "nope")
        XCTAssertFalse(missing.passed)
        XCTAssertEqual(missing.stepsRun, 0)
        XCTAssertTrue(missing.error?.hasPrefix("restoring snapshot 'nope' failed: ") == true, missing.error ?? "")
        XCTAssertTrue(missing.error?.hasSuffix("; check the snapshot name with vm.snapshot.list") == true, missing.error ?? "")
        XCTAssertEqual(execCommands(rig), ["one"])
        let after = try await leasedBy(rig)
        XCTAssertNil(after)
    }

    func testScriptRunOpResult() async throws {
        let rig = try await rig()
        let path = try scriptFile(steps([exec("one", label: "first"), "{\"label\": \"boom\", \"op\": \"vm.mouse.click\", \"params\": {\"x\": 1}}"],
                                        vm: nil, variables: "{\"unused\": \"u\"}"))
        let result = try await rig.handler.handle(op: "script.run", params: ["path": .string(path), "name": "Win", "variables": ["v": "1"]])
        XCTAssertEqual(result["passed"]?.boolValue, false)
        XCTAssertEqual(result["stepsRun"]?.intValue, 2)
        XCTAssertEqual(result["failedStep"]?.intValue, 2)
        XCTAssertEqual(result["label"]?.stringValue, "boom")
        XCTAssertEqual(result["error"]?.stringValue, "step 2 (boom) failed: missing or invalid parameter 'y'")
        XCTAssertEqual(result["steps"]?.arrayValue?.count, 2)
        XCTAssertNotNil(result["seconds"]?.doubleValue)
        XCTAssertEqual(result["failure"]?["width"]?.intValue, 800)
        XCTAssertEqual(result["failure"]?["height"]?.intValue, 600)
        let png = try XCTUnwrap(result["failure"]?["png"]?.stringValue.flatMap { Data(base64Encoded: $0) })
        XCTAssertEqual(Frame(png: png)?.width, 800)

        let good = try scriptFile(steps([exec("echo ${v}")], variables: "{\"v\": \"default\"}"))
        let passed = try await rig.handler.handle(op: "script.run", params: ["path": .string(good), "variables": ["v": "override"]])
        XCTAssertEqual(passed["passed"]?.boolValue, true)
        XCTAssertNil(passed["failedStep"]); XCTAssertNil(passed["error"]); XCTAssertNil(passed["failure"])
        XCTAssertEqual(execCommands(rig).last, "echo override")

        do { _ = try await rig.handler.handle(op: "script.run", params: ["path": "/nonexistent/flow.json"]); XCTFail() }
        catch { XCTAssertTrue("\(error)".contains("cannot read the script '/nonexistent/flow.json'"), "\(error)") }
        do { _ = try await rig.handler.handle(op: "script.run", params: ["path": .string(try scriptFile("{}"))]); XCTFail() }
        catch { XCTAssertTrue("\(error)".contains("the script has no version"), "\(error)") }
        do { _ = try await rig.handler.handle(op: "script.run", params: [:]); XCTFail() }
        catch { XCTAssertTrue("\(error)".contains("'path'"), "\(error)") }
    }

    // MARK: - run could not start

    func testRunThatCannotStartIsAnError() async throws {
        let rig = try await rig()
        let cases: [(String, [String: JSON], String)] = [
            (steps([exec("x")], vm: nil), [:], "the script names no VM; pass name or add \"vm\" to the script"),
            (steps([exec("say ${missing}")]), [:], "variable 'missing' is not defined; pass it or add a default"),
            (steps([exec("x")]), ["snapshot": "nope"], "restoring snapshot 'nope' failed: "),
            ("not json", [:], "the script is not valid JSON"),
            (steps([exec("x")]), ["variables": 3], "'variables' must be an object of names to string values, for example {\"message\": \"hello\"}"),
        ]
        for (text, extra, expected) in cases {
            var params: [String: JSON] = ["path": .string(try scriptFile(text))]
            for (key, value) in extra { params[key] = value }
            do {
                _ = try await rig.handler.handle(op: "script.run", params: .object(params))
                XCTFail("expected an error for \(expected)")
            } catch {
                XCTAssertTrue("\(error)".contains(expected), "\(error) should contain \(expected)")
            }
        }
        XCTAssertEqual(execCommands(rig), [])
        let after = try await leasedBy(rig)
        XCTAssertNil(after)
    }

    func testFailingStepIsAResultNotAnError() async throws {
        let rig = try await rig()
        let path = try scriptFile(steps([exec("one"), "{\"op\": \"vm.mouse.click\", \"params\": {\"x\": 1}}"]))
        let result = try await rig.handler.handle(op: "script.run", params: ["path": .string(path)])
        XCTAssertEqual(result["passed"]?.boolValue, false)
        XCTAssertEqual(result["failedStep"]?.intValue, 2)
    }

    // MARK: - given lease

    func testGivenLeaseMustBeCurrent() async throws {
        let rig = try await rig()
        let expected = "lease token is not the current lease of 'Win' (expired, released or unknown); acquire a new lease or omit lease"
        let parsed = try script(steps([exec("one")]))

        let unleased = await run(rig, parsed, lease: "never-issued")
        XCTAssertEqual(unleased.error, expected)
        XCTAssertEqual(unleased.stepsRun, 0)

        let granted = try await rig.handler.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "a", "ttl": 60])
        let token = try XCTUnwrap(granted["lease"]?.stringValue)
        rig.clock.advance(.seconds(61))
        let expired = await run(rig, parsed, lease: token)
        XCTAssertEqual(expired.error, expected)

        let second = try await rig.handler.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "a", "ttl": 60])
        let live = try XCTUnwrap(second["lease"]?.stringValue)
        _ = try await rig.handler.handle(op: "vm.lease.release", params: ["name": "Win", "lease": .string(live)])
        let released = await run(rig, parsed, lease: live)
        XCTAssertEqual(released.error, expected)

        let path = try scriptFile(steps([exec("two")]))
        do {
            _ = try await rig.handler.handle(op: "script.run", params: ["path": .string(path), "name": "Win", "lease": "never-issued"])
            XCTFail("expected a refusal")
        } catch { XCTAssertEqual("\(error)", expected) }
        XCTAssertEqual(execCommands(rig), [])
    }

    func testGivenLeaseIsNeitherRenewedNorReleased() async throws {
        let rig = try await rig()
        ScriptTiming.leaseRenewal = .milliseconds(20)
        let granted = try await rig.handler.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "agent-a", "ttl": 60])
        let token = try XCTUnwrap(granted["lease"]?.stringValue)
        rig.clock.advance(.seconds(10))
        let wait = "{\"op\": \"vm.wait_for\", \"params\": {\"conditions\": [{\"type\": \"file_exists\", \"path\": \"C:\\\\never\"}], \"timeout\": 1}, \"expect\": []}"
        let result = await run(rig, try script(steps([wait])), lease: token)
        XCTAssertFalse(result.passed)
        let text = await failureText(rig.handler)
        XCTAssertTrue(text.contains("leased by agent-a for another 50 s"), text)
    }

    private func failureText(_ handler: ControlHandler) async -> String {
        do { _ = try await handler.handle(op: "vm.type", params: ["name": "Win", "text": "a"]); return "" } catch { return "\(error)" }
    }

    // MARK: - lease lifecycle

    func testNoLeaseRemainsAfterRuns() async throws {
        let rig = try await rig()
        ScriptTiming.leaseRenewal = .milliseconds(1)
        let parsed = try script(steps([exec("one"), exec("two"), exec("three")]))
        for round in 0..<40 {
            let result = await run(rig, parsed)
            XCTAssertTrue(result.passed, result.error ?? "")
            let owner = try await leasedBy(rig)
            XCTAssertNil(owner, "round \(round)")
        }
    }

    func testLostLeaseStopsTheRun() async throws {
        let rig = try await rig()
        ScriptTiming.leaseRenewal = .milliseconds(20)
        let gate = "{\"op\": \"vm.wait_for\", \"params\": {\"conditions\": [{\"type\": \"file_exists\", \"path\": \"C:\\\\gate\"}], \"timeout\": 60}}"
        let parsed = try script(steps([gate, exec("after")]))
        let handler = rig.handler
        let task = Task { await ScriptRunner(handler: handler).run(parsed, vm: nil, variables: [:], owner: "script:test.json", progress: nil) }
        while try await leasedBy(rig) == nil { try await Task.sleep(for: .milliseconds(10)) }
        await handler.forget(vm: "Win")
        _ = try await handler.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "agent-b", "ttl": 60])
        rig.fs["C:\\gate"] = Data("x".utf8)
        let result = await task.value
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.stepsRun, 1)
        XCTAssertNil(result.failedStep)
        XCTAssertTrue(result.error?.contains("lease on 'Win' was lost") == true, result.error ?? "")
        XCTAssertEqual(execCommands(rig), [])
        let owner = try await leasedBy(rig)
        XCTAssertEqual(owner, "agent-b")
    }

    // MARK: - validation before step 1

    func testExpectationsAndConditionsValidatedBeforeAnyStep() async throws {
        let rig = try await rig()
        let badExpect = try script(steps([exec("one"), exec("two", expect: "[{\"type\": \"file_exists\", \"path\": \"C:\\\\ok\"}, {\"type\": \"text_visible\"}]")]))
        let first = await run(rig, badExpect)
        XCTAssertEqual(first.stepsRun, 0)
        let message = try XCTUnwrap(first.error)
        XCTAssertTrue(message.hasPrefix("step 2 expectation 2: "), message)
        XCTAssertTrue(message.contains("text_visible needs"), message)

        let badWait = "{\"op\": \"vm.wait_for\", \"params\": {\"conditions\": [{\"type\": \"nonsense\"}]}}"
        let second = await run(rig, try script(steps([exec("one"), badWait])))
        XCTAssertEqual(second.stepsRun, 0)
        XCTAssertTrue(second.error?.hasPrefix("step 2: ") == true, second.error ?? "")

        let substituted = try script(steps([exec("one", expect: "[{\"type\": \"${kind}\", \"path\": \"C:\\\\ok\"}]")]))
        let third = await run(rig, substituted, variables: ["kind": "bogus"])
        XCTAssertEqual(third.stepsRun, 0)
        XCTAssertTrue(third.error?.hasPrefix("step 1 expectation 1: ") == true, third.error ?? "")
        XCTAssertEqual(execCommands(rig), [])
        let owner = try await leasedBy(rig)
        XCTAssertNil(owner)
    }

    func testScriptBuiltInCodeGetsTheSameChecks() async throws {
        func step(_ params: [String: JSON] = [:], expect: [JSON] = [], timeout: Int = 5) -> Script.Step {
            Script.Step(label: nil, op: "vm.type", params: params, expect: expect, timeout: timeout)
        }
        let cases: [(Script.Step, String)] = [
            (step(["name": "Win"]), "step 1 passes 'name' in params"),
            (step(["lease": "x"]), "step 1 passes 'lease' in params"),
            (step(timeout: 0), "step 1 has a timeout outside 1 to 600 seconds"),
            (step(timeout: 601), "step 1 has a timeout outside 1 to 600 seconds"),
            (step(expect: [.string("x")]), "step 1 has an expectation that is not an object"),
        ]
        let rig = try await rig()
        for (bad, expected) in cases {
            let built = Script(vm: "Win", variables: [:], steps: [bad])
            XCTAssertThrowsError(try built.validate()) { XCTAssertTrue("\($0)".contains(expected), "\($0)") }
            let result = await run(rig, built)
            XCTAssertEqual(result.stepsRun, 0)
            XCTAssertTrue(result.error?.contains(expected) == true, result.error ?? "")
        }
    }

    func testVariableValueIsNotExpandedAgain() throws {
        let parsed = try script(steps([exec("echo ${a}")], variables: "{\"a\": \"${b}\", \"b\": \"B\"}"))
        let resolved = try parsed.resolved(with: [:])
        XCTAssertEqual(resolved.steps[0].params["command"], "echo ${b}")
    }

    // MARK: - bounded results

    func testStepResultsAreBounded() async throws {
        let rig = try await rig()
        let long = String(repeating: "a", count: 5000)
        let shot = "{\"op\": \"vm.screenshot\", \"params\": {}}"
        let result = await run(rig, try script(steps([exec(long), shot, "{\"op\": \"vm.status\", \"params\": {}}"])))
        XCTAssertTrue(result.passed, result.error ?? "")
        let output = try XCTUnwrap(result.stepResults[0]["result"]?["output"]?.stringValue)
        XCTAssertEqual(output, String(repeating: "a", count: 2048) + "… (2952 more characters)")
        let png = try XCTUnwrap(result.stepResults[1]["result"]?["png"]?.stringValue)
        XCTAssertTrue(png.hasPrefix("<omitted: ") && png.hasSuffix(" bytes>"), png)
        XCTAssertEqual(result.stepResults[1]["result"]?["width"]?.intValue, 800)
        XCTAssertEqual(result.stepResults[2]["result"]?["state"]?.stringValue, "running")
    }

    func testStepResultsPastTheCapKeepOnlyTheirOutcome() async throws {
        let rig = try await rig()
        let long = String(repeating: "b", count: 3000)
        var list = (0..<160).map { _ in exec(long, label: "L") }
        list.append("{\"op\": \"vm.mouse.click\", \"params\": {\"x\": 1}}")
        let result = await run(rig, try script(steps(list)))
        XCTAssertFalse(result.passed)
        XCTAssertNotNil(result.stepResults[0]["result"])
        let late = try XCTUnwrap(result.stepResults[150].objectValue)
        XCTAssertEqual(Set(late.keys), ["step", "op", "label", "ok", "seconds"])
        let failing = try XCTUnwrap(result.stepResults[160].objectValue)
        XCTAssertEqual(Set(failing.keys), ["step", "op", "ok", "seconds", "error"])
        XCTAssertEqual(failing["error"]?.stringValue, "missing or invalid parameter 'y'")
        let size = try JSON.array(result.stepResults).serialized().count
        XCTAssertLessThan(size, 300 * 1024)
        XCTAssertNotNil(result.failureImage)
    }

    // MARK: - script file

    func testScriptFileLimits() async throws {
        let rig = try await rig()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("script-big-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.json")
        try Data(repeating: 32, count: 4 * 1024 * 1024 + 1).write(to: big)
        do {
            _ = try await rig.handler.handle(op: "script.run", params: ["path": .string(big.path)])
            XCTFail("expected a refusal")
        } catch { XCTAssertEqual("\(error)", "the script is larger than 4 MiB; split it into several scripts") }
        do {
            _ = try await rig.handler.handle(op: "script.run", params: ["path": .string(dir.path)])
            XCTFail("expected a refusal")
        } catch { XCTAssertTrue("\(error)".contains("cannot read the script"), "\(error)") }
    }

    // MARK: - timing and cancellation

    func testExpectationClockStartsAfterTheOp() async throws {
        let rig = try await rig()
        let never = "[{\"type\": \"file_exists\", \"path\": \"C:\\\\never\"}]"
        let result = await run(rig, try script(steps([exec("slow", expect: never, timeout: 2)])))
        XCTAssertFalse(result.passed)
        let error = try XCTUnwrap(result.error)
        let match = try XCTUnwrap(error.range(of: "within [0-9]+\\.[0-9] s", options: .regularExpression), error)
        let waited = Double(error[match].dropFirst(7).dropLast(2))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(waited), 2.0, error)
    }

    func testCancelledStepIsReportedAsCancelled() async throws {
        let rig = try await rig()
        let stall = "{\"op\": \"vm.exec\", \"params\": {\"command\": \"stall\", \"timeout\": 2}, \"timeout\": 60}"
        let parsed = try script(steps([stall, exec("after")]))
        let handler = rig.handler
        let task = Task { await ScriptRunner(handler: handler).run(parsed, vm: nil, variables: [:], owner: "script:test.json", progress: nil) }
        while agentRequests(rig.agent, "exec.run").filter({ $0["cmd"]?.stringValue == "stall" }).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result.passed)
        XCTAssertNil(result.failedStep)
        XCTAssertNil(result.failureImage)
        XCTAssertTrue(result.error?.contains("cancelled") == true, result.error ?? "")
        XCTAssertFalse(result.error?.contains("failed") == true, result.error ?? "")
        let after = try await leasedBy(rig)
        XCTAssertNil(after)
    }

    func testScriptRunClassification() {
        XCTAssertTrue(ControlHandler.knownOps.contains("script.run"))
        XCTAssertTrue(ControlHandler.isConcurrent(op: "script.run"))
        XCTAssertFalse(ControlHandler.isReadOnly(op: "script.run"))
    }
}
