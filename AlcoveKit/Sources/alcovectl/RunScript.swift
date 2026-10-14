import Foundation
import AlcoveEngine
import AlcoveControl
import AlcoveQMP

/// The variables of the current `run-script` command, the script's own defaults included; secret values are removed from every sentence it prints.
nonisolated(unsafe) private var printedVariables: [String: String] = [:]

/// The directory of the VM bundles: `option`, else `ALCOVE_VM_DIR`, else the app's folder.
func resolvedVMDirectory(_ option: String?) -> URL {
    URL(fileURLWithPath: option ?? ProcessInfo.processInfo.environment["ALCOVE_VM_DIR"]
        ?? (NSHomeDirectory() + "/Library/Application Support/Alcove/VMs"))
}

/// Ends `alcovectl run-script` with exit status 2: the script could not run.
private func couldNotRun(_ reason: String) -> Never {
    FileHandle.standardError.write(Data((ScriptReport.masked(reason, variables: printedVariables) + "\n").utf8))
    exit(RunScriptExit.couldNotRun)
}

/// Prints `lines` and, for a run a signal stopped, ends with the status of that signal.
private func finishInterrupted(_ lines: [String], signal: Int32) -> Never {
    print(lines.joined(separator: "\n"))
    exit(RunScriptExit.status(forSignal: signal) ?? RunScriptExit.failed)
}

/// Prints the report of a `script.run` reply, stores or removes the failure screenshot and exits 0 (passed) or 1 (failed).
private func finishRun(_ reply: JSON, _ options: RunScriptOptions, stopFailed: Bool = false) -> Never {
    var lines = ScriptReport.variablesLine(options.variables).map { [$0] } ?? []
    lines += ScriptReport.lines(reply, variables: printedVariables)
    print(lines.joined(separator: "\n"))
    if let problem = ScriptReport.storeFailureImage(reply, scriptFile: options.file) {
        FileHandle.standardError.write(Data((problem + "\n").utf8))
    }
    exit(RunScriptExit.status(passed: reply["passed"]?.boolValue == true, stopFailed: stopFailed))
}

/// The signal that interrupted a run, once there was one.
private final class InterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var number: Int32?
    var signal: Int32? { lock.lock(); defer { lock.unlock() }; return number }
    func set(_ signal: Int32) { lock.lock(); if number == nil { number = signal }; lock.unlock() }
}

/// Dispatch sources that call `body` with the signal number of SIGINT, SIGTERM and SIGHUP, which are otherwise ignored.
private func onTerminationSignals(queue: DispatchQueue, _ body: @escaping @Sendable (Int32) -> Void) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM, SIGHUP].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
        source.setEventHandler { body(number) }
        source.resume()
        return source
    }
}

/// `alcovectl run-script`: through the control server at the socket, or with `--in-process` in this process.
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
    printedVariables = ScriptReport.variables(ofScriptAt: options.file).merging(options.variables) { _, passed in passed }
    for name in options.repeatedVariables {
        FileHandle.standardError.write(Data("--var \(name) was given more than once; the last value is used\n".utf8))
    }
    if let problem = options.unreadableProblem { couldNotRun(problem) }
    ScriptReport.removeFailureImage(forScript: options.file)

    let socketPath = options.socket ?? ControlServer.defaultSocketPath
    let serverAnswers = ControlServer.isAlive(at: socketPath)
    if serverAnswers && options.inProcess {
        couldNotRun("a control server answers at \(socketPath); run the script without --in-process, or stop that server first")
    }
    if !serverAnswers && !options.inProcess {
        couldNotRun("no control server answers at \(socketPath); start one with alcovectl serve, or pass --in-process to run the script without a server")
    }
    if serverAnswers { runThroughServer(options, socketPath: socketPath) }
    runInProcess(options, socketPath: socketPath)
}

private func runThroughServer(_ options: RunScriptOptions, socketPath: String) -> Never {
    let cancellation = ControlCallCancellation()
    let sources = onTerminationSignals(queue: .global()) { cancellation.cancel(signal: $0) }
    defer { withExtendedLifetime(sources) {} }
    do {
        finishRun(try ControlSocketClient.call(op: "script.run", params: options.params, socketPath: socketPath, cancellation: cancellation), options)
    } catch let interrupted as ControlSocketClient.Interrupted {
        finishInterrupted(["INTERRUPTED"], signal: interrupted.signal)
    } catch {
        couldNotRun("\(error)")
    }
}

private func runInProcess(_ options: RunScriptOptions, socketPath: String) -> Never {
    let vmDir = resolvedVMDirectory(nil)
    var lock: ScriptRunLock?
    if let name = options.vm ?? ScriptReport.vmName(ofScriptAt: options.file),
       let bundle = VMBundle.list(in: vmDir).first(where: { $0.configName == name }) {
        do {
            guard let held = try ScriptRunLock.acquire(in: bundle.url) else {
                couldNotRun("another run-script --in-process is using '\(name)'; wait for it or use a control server")
            }
            lock = held
        } catch {
            couldNotRun("\(error)")
        }
        if bundle.isRunning {
            couldNotRun("'\(name)' is running under another process and no control server answers at \(socketPath); start the Alcove app or alcovectl serve, or stop the VM, and run the script again")
        }
    }
    let engine: EngineLocator.Engine
    do { engine = try EngineLocator.standard().locate() } catch { couldNotRun("engine not found: \(error); install the Alcove engine or start the Alcove app and run the script again") }

    let registry = HeadlessRegistry(directory: vmDir, engine: engine)
    let handler = ControlHandler(registry: registry, hostKind: "headless", captureDirectory: ProxyProcess.defaultCADirectory,
                                 engineDescription: engine.qemuSystem,
                                 log: ControlHandler.standardErrorAndSystemLog())
    let flag = InterruptFlag()
    let run = Task.detached { try await handler.handle(op: "script.run", params: .object(options.params)) }
    let vmName = options.vm ?? ScriptReport.vmName(ofScriptAt: options.file) ?? "the VM"
    let sources = onTerminationSignals(queue: .main) { number in
        if let first = flag.signal {
            FileHandle.standardError.write(Data((ScriptReport.interruptedAgainSentence(vm: vmName) + "\n").utf8))
            exit(RunScriptExit.status(forSignal: first) ?? RunScriptExit.failed)
        }
        flag.set(number)
        run.cancel()
    }
    Task.detached {
        let outcome = await run.result
        await handler.shutdown()
        let stopFailures = await registry.stopAll()
        lock?.release()
        withExtendedLifetime(sources) {}
        for (name, reason) in stopFailures.sorted(by: { $0.key < $1.key }) {
            FileHandle.standardError.write(Data((ScriptReport.stopFailureSentence(vm: name, reason: reason) + "\n").utf8))
        }
        if let number = flag.signal {
            var lines = ScriptReport.variablesLine(options.variables).map { [$0] } ?? []
            if case .success(let reply) = outcome { lines += ScriptReport.lines(reply, variables: printedVariables, interrupted: true) } else { lines.append("INTERRUPTED") }
            finishInterrupted(lines, signal: number)
        }
        switch outcome {
        case .success(let reply): finishRun(reply, options, stopFailed: !stopFailures.isEmpty)
        case .failure(let error): couldNotRun("\(error)")
        }
    }
    dispatchMain()
}
