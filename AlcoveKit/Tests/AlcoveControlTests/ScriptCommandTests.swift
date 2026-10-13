import XCTest
@testable import AlcoveControl
import AlcoveEngine
import AlcoveQMP
import AlcoveTestSupport

final class ScriptCommandTests: XCTestCase {
    private func parse(_ argv: [String]) throws -> RunScriptOptions { try RunScriptOptions.parse(argv) }

    private func usageError(_ argv: [String]) -> String {
        do { _ = try parse(argv); XCTFail("accepted \(argv)"); return "" } catch { return "\(error)" }
    }

    func testParsesFileAndOptions() throws {
        let options = try parse(["/tmp/flow.json", "--vm", "Win", "--snapshot", "clean", "--socket", "/tmp/a.sock", "--var", "a=1", "--var", "b=x=y", "--var", "c=--d", "--var", "e="])
        XCTAssertEqual(options.file, "/tmp/flow.json")
        XCTAssertEqual(options.vm, "Win")
        XCTAssertEqual(options.snapshot, "clean")
        XCTAssertEqual(options.socket, "/tmp/a.sock")
        XCTAssertEqual(options.variables, ["a": "1", "b": "x=y", "c": "--d", "e": ""])
    }

    func testOptionsMayPrecedeTheFileAndRelativePathsBecomeAbsolute() throws {
        let options = try parse(["--vm", "Win", "flow.json"])
        XCTAssertEqual(options.file, FileManager.default.currentDirectoryPath + "/flow.json")
    }

    func testRepeatedVariableKeepsTheLastValue() throws {
        XCTAssertEqual(try parse(["/f.json", "--var", "a=1", "--var", "a=2"]).variables, ["a": "2"])
    }

    func testRefusesBadArguments() {
        XCTAssertTrue(usageError([]).hasPrefix("run-script needs the script file"))
        XCTAssertEqual(usageError(["/a.json", "/b.json"]), "run-script takes one script file; got '/a.json' and '/b.json'")
        XCTAssertEqual(usageError(["/a.json", "--var", "no_such_env_variable_for_alcove"]), "--var no_such_env_variable_for_alcove needs a value: pass no_such_env_variable_for_alcove=VALUE or set the environment variable no_such_env_variable_for_alcove")
        XCTAssertEqual(usageError(["/a.json", "--var", "=1"]), "--var needs KEY=VALUE, for example --var message=hello; got '=1'")
        XCTAssertEqual(usageError(["/a.json", "--var"]), "--var needs a value; see alcovectl run-script --help")
        XCTAssertEqual(usageError(["/a.json", "--vm", ""]), "--vm needs a VM name; see alcovectl run-script --help")
        XCTAssertEqual(usageError(["/a.json", "--other"]), "unknown option '--other'; see alcovectl run-script --help, and put -- before a file name that starts with a dash")
        XCTAssertEqual(usageError(["-x", "/a.json"]), "unknown option '-x'; see alcovectl run-script --help, and put -- before a file name that starts with a dash")
    }

    func testVarWithoutValueReadsTheEnvironment() throws {
        let options = try RunScriptOptions.parse(["/f.json", "--var", "password", "--var", "plain=x"], environment: ["password": "from-env"])
        XCTAssertEqual(options.variables, ["password": "from-env", "plain": "x"])
        XCTAssertThrowsError(try RunScriptOptions.parse(["/f.json", "--var", "password"], environment: [:])) {
            XCTAssertEqual("\($0)", "--var password needs a value: pass password=VALUE or set the environment variable password")
        }
    }

    func testRepeatedVariablesAreListed() throws {
        let options = try parse(["/f.json", "--var", "a=1", "--var", "a=2", "--var", "a=3", "--var", "b=1"])
        XCTAssertEqual(options.repeatedVariables, ["a"])
        XCTAssertEqual(options.variables["a"], "3")
        XCTAssertEqual(try parse(["/f.json", "--var", "a=1"]).repeatedVariables, [])
    }

    func testDoubleDashEndsOptions() throws {
        let options = try parse(["--in-process", "--vm", "Win", "--", "-odd.json"])
        XCTAssertTrue(options.inProcess)
        XCTAssertEqual(options.file, FileManager.default.currentDirectoryPath + "/-odd.json")
        XCTAssertEqual(try parse(["/f.json"]).inProcess, false)
        XCTAssertEqual(try parse(["--", "--vm"]).file, FileManager.default.currentDirectoryPath + "/--vm")
    }

    func testUnreadableScriptSentenceSaysWhatWasResolved() throws {
        let absolute = try parse(["/nonexistent/flow.json"])
        XCTAssertEqual(absolute.unreadableProblem, "cannot read the script '/nonexistent/flow.json'; check that the file exists and is readable")
        let relative = try parse(["nonexistent-flow.json"])
        let cwd = FileManager.default.currentDirectoryPath
        XCTAssertEqual(relative.unreadableProblem,
                       "cannot read the script '\(cwd)/nonexistent-flow.json' (resolved from 'nonexistent-flow.json' in '\(cwd)'); check that the file exists and is readable")
        XCTAssertNotNil(try parse([NSTemporaryDirectory()]).unreadableProblem)
        let file = NSTemporaryDirectory() + "readable-\(UUID().uuidString).json"
        FileManager.default.createFile(atPath: file, contents: Data("{}".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: file) }
        XCTAssertNil(try parse([file]).unreadableProblem)
    }

    func testHelpCarriesTheUsageText() {
        do { _ = try parse(["--help"]); XCTFail() } catch let error as RunScriptUsageError {
            XCTAssertTrue(error.isHelp)
            XCTAssertEqual(error.description, RunScriptOptions.usage)
        } catch { XCTFail("\(error)") }
    }

    func testParamsCarryOnlyWhatWasGiven() throws {
        XCTAssertEqual(try parse(["/f.json"]).params, ["path": "/f.json"])
        let full = try parse(["/f.json", "--vm", "Win", "--snapshot", "clean", "--var", "a=1"]).params
        XCTAssertEqual(full, ["path": "/f.json", "name": "Win", "snapshot": "clean", "variables": ["a": "1"]])
    }

    private func step(_ number: Int, label: String?, ok: Bool = true, seconds: Double = 0.25, error: String? = nil,
                      markers: [String] = []) -> JSON {
        var entry: [String: JSON] = ["step": .int(Int64(number)), "op": "vm.ui.click", "seconds": .double(seconds), "ok": .bool(ok)]
        if let label { entry["label"] = .string(label) }
        if let error { entry["error"] = .string(error) }
        for marker in markers { entry[marker] = true }
        return .object(entry)
    }

    func testPassedReport() {
        let reply: JSON = ["passed": true, "stepsRun": 2, "seconds": 1.5,
                           "steps": [step(1, label: "open", seconds: 0.34, markers: ["usedFallback", "usedAltSelector"]), step(2, label: nil, markers: ["positional"])]]
        XCTAssertEqual(ScriptReport.lines(reply, variables: [:]), [
            "ok   1 open 340 ms [fallback] [alt selector]",
            "ok   2 vm.ui.click 250 ms [positional]",
            "PASSED: 2 steps in 1.5 s",
        ])
    }

    func testFailedReportShowsTheErrorAndTheWarning() {
        let reply: JSON = ["passed": false, "stepsRun": 2, "failedStep": 2, "seconds": 3.0,
                           "error": "step 2 (send) failed: no element matches",
                           "warning": "the lease on 'Win' could not be released",
                           "steps": [step(1, label: "open"), step(2, label: "send", ok: false, seconds: 2, error: "no element matches")]]
        XCTAssertEqual(ScriptReport.lines(reply, variables: [:]), [
            "ok   1 open 250 ms",
            "FAIL 2 send 2000 ms",
            "     no element matches",
            "error: step 2 (send) failed: no element matches",
            "warning: the lease on 'Win' could not be released",
            "FAILED: step 2 failed after 3.0 s",
        ])
    }

    func testSecretVariablesAreHiddenInNamesAndOutput() {
        for name in ["password", "password2", "apiKey", "API_TOKEN", "clientSecret", "MyPassword"] {
            XCTAssertTrue(ScriptReport.isSecret(name), name)
        }
        for name in ["message", "user", "path"] { XCTAssertFalse(ScriptReport.isSecret(name), name) }
        let variables = ["message": "hello", "password": "hunter2"]
        XCTAssertEqual(ScriptReport.variablesLine(variables), "variables: message=hello, password=<hidden>")
        XCTAssertNil(ScriptReport.variablesLine([:]))
        let reply: JSON = ["passed": false, "stepsRun": 1, "failedStep": 1, "seconds": 1.0, "error": "step 1 failed: typed hunter2",
                           "steps": [step(1, label: "login hunter2", ok: false, error: "typed hunter2")]]
        let text = ScriptReport.lines(reply, variables: variables).joined(separator: "\n")
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertTrue(text.contains("typed <hidden>"))
    }

    func testFailureImageIsWrittenNextToTheScriptAndRemovedWhenTheRunHasNone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("script-cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("flow.json").path
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        let failed: JSON = ["passed": false, "failure": ["png": .string(image.base64EncodedString()), "width": 1, "height": 1]]
        XCTAssertNil(ScriptReport.storeFailureImage(failed, scriptFile: script))
        XCTAssertEqual(ScriptReport.failureImagePath(forScript: script), script + ".failure.png")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: script + ".failure.png")), image)

        XCTAssertNil(ScriptReport.storeFailureImage(["passed": false], scriptFile: script))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script + ".failure.png"))

        XCTAssertNil(ScriptReport.storeFailureImage(failed, scriptFile: script))
        ScriptReport.removeFailureImage(forScript: script)
        XCTAssertFalse(FileManager.default.fileExists(atPath: script + ".failure.png"))
        XCTAssertNil(ScriptReport.storeFailureImage(failed, scriptFile: script))

        XCTAssertNil(ScriptReport.storeFailureImage(["passed": true], scriptFile: script))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script + ".failure.png"))
    }

    func testFailureImageThatCannotBeWrittenIsReported() {
        let failed: JSON = ["passed": false, "failure": ["png": .string(Data([1]).base64EncodedString())]]
        let problem = ScriptReport.storeFailureImage(failed, scriptFile: "/nonexistent-folder/flow.json")
        XCTAssertEqual(problem, "cannot write the failure screenshot '/nonexistent-folder/flow.json.failure.png'; check that the folder of the script is writable")
    }

    func testClientReturnsTheReplyAndTheServersSentence() throws {
        let path = "/tmp/alcove-cmd-\(UUID().uuidString.prefix(8)).sock"
        let target = FakeTarget(name: "Win", state: .running, png: makePNG(width: 320, height: 200))
        let server = ControlServer(handler: ControlHandler(registry: FakeRegistry(targets: ["Win": target]), hostKind: "test"), socketPath: path)
        try server.start()
        defer { server.stop() }
        let hello = try ControlSocketClient.call(op: "hello", params: [:], socketPath: path)
        XCTAssertEqual(hello["host"]?.stringValue, "test")
        XCTAssertThrowsError(try ControlSocketClient.call(op: "script.run", params: ["path": "/nonexistent/flow.json"], socketPath: path)) {
            XCTAssertEqual("\($0)", "cannot read the script '/nonexistent/flow.json'; check that it is a file on the host and use an absolute path")
        }
        XCTAssertThrowsError(try ControlSocketClient.call(op: "hello", params: [:], socketPath: "/tmp/alcove-cmd-none.sock")) {
            XCTAssertEqual("\($0)", "no control server answers at '/tmp/alcove-cmd-none.sock'")
        }
    }

    func testInterruptedReportEndsWithInterrupted() {
        let reply: JSON = ["passed": false, "stepsRun": 1, "seconds": 1.0, "error": "the run was cancelled during step 1; start it again",
                           "steps": [step(1, label: "open")]]
        XCTAssertEqual(ScriptReport.lines(reply, variables: [:], interrupted: true), ["ok   1 open 250 ms", "INTERRUPTED"])
    }

    func testSignalsMapToShellExitStatuses() {
        XCTAssertEqual(RunScriptExit.status(forSignal: SIGINT), 130)
        XCTAssertEqual(RunScriptExit.status(forSignal: SIGTERM), 143)
        XCTAssertNil(RunScriptExit.status(forSignal: SIGHUP))
    }

    func testRunLockIsExclusiveUntilReleased() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("run-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: bundle) }
        let first = try XCTUnwrap(try ScriptRunLock.acquire(in: bundle))
        XCTAssertNil(try ScriptRunLock.acquire(in: bundle))
        first.release()
        let second = try XCTUnwrap(try ScriptRunLock.acquire(in: bundle))
        XCTAssertNil(try ScriptRunLock.acquire(in: bundle))
        second.release()
        XCTAssertThrowsError(try ScriptRunLock.acquire(in: bundle.appendingPathComponent("missing"))) {
            XCTAssertTrue("\($0)".hasPrefix("cannot open the lock file "), "\($0)")
        }
    }

    func testCancellationEndsACallThatWaitsForItsReply() throws {
        let path = "/tmp/alcove-cancel-\(UUID().uuidString.prefix(8)).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in _ = path.withCString { strncpy(dst, $0, 103) } } }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        addTeardownBlock { close(listener); unlink(path) }
        let cancellation = ControlCallCancellation()
        let outcome = LockedBox<Error?>(nil)
        let done = expectation(description: "call returned")
        Thread {
            do { _ = try ControlSocketClient.call(op: "script.run", params: ["path": "/f.json"], socketPath: path, cancellation: cancellation) }
            catch { outcome.value = error }
            done.fulfill()
        }.start()
        let accepted = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        addTeardownBlock { close(accepted) }
        var request = [UInt8](repeating: 0, count: 1)
        XCTAssertEqual(read(accepted, &request, 1), 1)
        cancellation.cancel(signal: SIGINT)
        wait(for: [done], timeout: 20)
        XCTAssertEqual(outcome.value as? ControlSocketClient.Interrupted, ControlSocketClient.Interrupted(signal: SIGINT))
        XCTAssertEqual(cancellation.signal, SIGINT)
    }
}
