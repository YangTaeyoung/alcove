import Foundation
import AlcoveEngine
import AlcoveControl
import AlcoveQMP

/// Ends `alcovectl run-script` with exit status 2: the script could not run.
private func couldNotRun(_ reason: String) -> Never {
    FileHandle.standardError.write(Data((reason + "\n").utf8))
    exit(2)
}

/// Prints the report of a `script.run` reply, stores or removes the failure screenshot and exits 0 (passed) or 1 (failed).
private func finishRun(_ reply: JSON, _ options: RunScriptOptions) -> Never {
    var lines = ScriptReport.variablesLine(options.variables).map { [$0] } ?? []
    lines += ScriptReport.lines(reply, variables: options.variables)
    print(lines.joined(separator: "\n"))
    if let problem = ScriptReport.storeFailureImage(reply, scriptFile: options.file) {
        FileHandle.standardError.write(Data((problem + "\n").utf8))
    }
    exit(reply["passed"]?.boolValue == true ? 0 : 1)
}

/// `alcovectl run-script`: through the control server at the socket, or in this process when none answers.
func runScriptCommand(_ argv: [String]) -> Never {
    let options: RunScriptOptions
    do {
        options = try RunScriptOptions.parse(argv)
    } catch let usage as RunScriptUsageError {
        if usage.isHelp { print(usage.description); exit(0) }
        couldNotRun(usage.description)
    } catch {
        couldNotRun("\(error)")
    }

    let socketPath = options.socket ?? ControlServer.defaultSocketPath
    if ControlServer.isAlive(at: socketPath) {
        do {
            finishRun(try ControlSocketClient.call(op: "script.run", params: options.params, socketPath: socketPath), options)
        } catch {
            couldNotRun("\(error)")
        }
    }

    let vmDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ALCOVE_VM_DIR"]
        ?? (NSHomeDirectory() + "/Library/Application Support/Alcove/VMs"))
    if let name = options.vm ?? ScriptReport.vmName(ofScriptAt: options.file),
       let bundle = VMBundle.list(in: vmDir).first(where: { $0.configName == name }), bundle.isRunning {
        couldNotRun("'\(name)' is running under another process and no control server answers at \(socketPath); start the Alcove app or alcovectl serve, or stop the VM, and run the script again")
    }
    let engine: EngineLocator.Engine
    do { engine = try EngineLocator.standard().locate() } catch { couldNotRun("engine not found: \(error); install the Alcove engine or start the Alcove app and run the script again") }

    let registry = HeadlessRegistry(directory: vmDir, engine: engine)
    let handler = ControlHandler(registry: registry, hostKind: "headless", engineDescription: engine.qemuSystem)
    Task.detached {
        let reply: JSON
        do {
            reply = try await handler.handle(op: "script.run", params: .object(options.params))
        } catch {
            await registry.stopAll()
            couldNotRun("\(error)")
        }
        await registry.stopAll()
        finishRun(reply, options)
    }
    dispatchMain()
}
