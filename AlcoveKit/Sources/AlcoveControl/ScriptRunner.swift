import Foundation
import AlcoveQMP

/// The outcome of one script run. Step numbers are 1-based.
struct ScriptResult: Sendable {
    var passed: Bool
    /// Steps that started, including the one that failed.
    var stepsRun: Int
    var failedStep: Int?
    /// Present only when `passed` is false.
    var error: String?
    /// A problem that did not change the outcome, such as a lease that could not be released.
    var warning: String?
    /// One entry per started step.
    var stepResults: [JSON]
    var seconds: Double
    /// PNG of the VM's screen after a failing step.
    var failureImage: Data?
    var failureWidth: Int?
    var failureHeight: Int?

    /// Whether the run ended before its first step began; `error` then says why.
    var couldNotStart: Bool { stepsRun == 0 }
}

/// What a script run calls an op for; a recording writes it to the trace line of the call as `script`.
enum ScriptCall: String, Sendable {
    /// The op of a step, its second run with `altSelector`, or the click at a step's fallback coordinates.
    case step
    /// The `vm.wait_for` of one expectation of a step.
    case expect
    /// Acquiring, renewing or releasing the run's lease.
    case lease
    /// Restoring the snapshot the run starts from.
    case snapshot
    /// The screenshot after a failing step.
    case failure
}

/// The timing of a script run's lease.
enum ScriptTiming {
    nonisolated(unsafe) static var leaseSeconds = 600
    nonisolated(unsafe) static var leaseRenewal = Duration.seconds(200)
}

/// The sizes a script run keeps and accepts.
enum ScriptLimits {
    static let fileBytes = 4 * 1024 * 1024
    /// The longest line of a trace that `script.save` reads.
    static let traceLineBytes = 8 * 1024 * 1024
    static let stringCharacters = 2048
    static let stepsBytes = 256 * 1024
    static let entryBytes = 64 * 1024
}

/// Runs a script against a handler without a model: each step is one control op, followed by its expectations.
struct ScriptRunner: Sendable {
    let handler: ControlHandler

    init(handler: ControlHandler) { self.handler = handler }

    /// Runs `op` through the handler as a call of kind `kind`.
    private func call(_ kind: ScriptCall, _ op: String, _ params: JSON) async throws -> JSON {
        try await ControlHandler.$scriptCall.withValue(kind) { try await handler.handle(op: op, params: params) }
    }

    /// Runs the steps of `script` in order and stops at the first failure.
    ///
    /// `vm` overrides the script's VM. A `lease` must be the VM's current token; it is used for every step and
    /// is neither renewed nor released. Without one the runner holds a lease of its own named `owner` for the run.
    /// A `snapshot` is restored first.
    func run(_ script: Script, vm: String?, variables: [String: String], lease: String? = nil, owner: String = "script",
             snapshot: String? = nil, failureMaxWidth: Int? = nil,
             progress: (@Sendable (Int, Script.Step, Result<JSON, Error>) -> Void)?) async -> ScriptResult {
        let secrets = script.variables.merging(variables) { _, override in override }
            .filter { ScriptReport.isSecret($0.key) }.map(\.value)
        return await ControlHandler.$scriptSecrets.withValue(secrets) {
            await runScript(script, vm: vm, variables: variables, lease: lease, owner: owner, snapshot: snapshot,
                            failureMaxWidth: failureMaxWidth, progress: progress)
        }
    }

    private func runScript(_ script: Script, vm: String?, variables: [String: String], lease: String?, owner: String, snapshot: String?,
                           failureMaxWidth: Int?, progress: (@Sendable (Int, Script.Step, Result<JSON, Error>) -> Void)?) async -> ScriptResult {
        let clock = ContinuousClock()
        let started = clock.now
        var result = ScriptResult(passed: false, stepsRun: 0, failedStep: nil, error: nil, stepResults: [], seconds: 0)
        func finish(_ message: String?, warning: String? = nil) -> ScriptResult {
            result.seconds = ScriptRunner.seconds(started.duration(to: clock.now))
            result.passed = message == nil
            result.error = message
            result.warning = warning
            return result
        }

        let resolved: Script
        do { resolved = try checked(script, variables: variables) } catch { return finish("\(error)") }
        guard let name = vm ?? script.vm, !name.isEmpty else {
            return finish("the script names no VM; pass name or add \"vm\" to the script")
        }

        var token = lease
        var acquired = false
        if let lease {
            if let refusal = await handler.leaseRefusal(vm: name, token: lease) { return finish(refusal) }
        } else {
            do {
                let granted = try await call(.lease, "vm.lease.acquire", [
                    "name": .string(name), "owner": .string(owner), "ttl": .int(Int64(ScriptTiming.leaseSeconds)),
                ])
                token = granted["lease"]?.stringValue
                acquired = true
            } catch {
                return finish("\(error)")
            }
        }
        let renewal = acquired ? renewLease(vm: name, owner: owner, token: token) : nil

        var leaseLost = false
        let failure = await execute(resolved, vm: name, token: token, holdsOwnLease: acquired, snapshot: snapshot,
                                    progress: progress, leaseLost: &leaseLost, into: &result)
        if failure != nil, !Task.isCancelled, result.failedStep != nil, let shot = await failureScreenshot(vm: name, maxWidth: failureMaxWidth) {
            result.failureImage = shot.png
            result.failureWidth = shot.width
            result.failureHeight = shot.height
        }
        renewal?.cancel()
        await renewal?.value
        var warning: String?
        if acquired, !leaseLost, let token {
            do {
                _ = try await call(.lease, "vm.lease.release", ["name": .string(name), "lease": .string(token)])
            } catch {
                if await handler.holdsLease(vm: name, token: token) {
                    warning = "the lease on '\(name)' could not be released (\(error)); it expires by itself within \(ScriptTiming.leaseSeconds) s"
                } else {
                    warning = "the lease on '\(name)' was lost during the last step (it expired or another client took it), so it was not released"
                }
            }
        }
        return finish(failure, warning: warning)
    }

    /// `script` with `variables` in place of `${name}`, after the checks a run makes before its first step: the steps
    /// themselves, the variables they read, their wait conditions and their observe options.
    func checked(_ script: Script, variables: [String: String]) throws -> Script {
        try script.validate()
        let resolved = try script.resolved(with: variables)
        try resolved.validateConditions()
        try validateObserveOptions(resolved)
        return resolved
    }

    /// Refuses a step whose `observe`, `settleMs` or `settleTimeoutMs` the op would refuse.
    private func validateObserveOptions(_ script: Script) throws {
        for (offset, step) in script.steps.enumerated() where ControlHandler.observingOps.contains(step.op) {
            do { _ = try handler.observeOptions(.object(step.params)) } catch {
                throw ScriptError(step: offset + 1, message: "step \(offset + 1): \(error)")
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        ((Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 10).rounded() / 10
    }

    /// Renews the run's lease until cancelled or until the lease is no longer the run's own.
    private func renewLease(vm: String, owner: String, token: String?) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: ScriptTiming.leaseRenewal) } catch { return }
                guard let token else { return }
                let params: JSON = ["name": .string(vm), "owner": .string(owner),
                                    "ttl": .int(Int64(ScriptTiming.leaseSeconds)), "lease": .string(token)]
                do {
                    let granted = try await call(.lease, "vm.lease.acquire", params)
                    if let other = granted["lease"]?.stringValue, other != token {
                        _ = try? await call(.lease, "vm.lease.release", ["name": .string(vm), "lease": .string(other)])
                        return
                    }
                } catch {
                    return
                }
            }
        }
    }

    /// Restores the snapshot and runs the steps; returns the failure sentence, or nil when all passed.
    private func execute(_ script: Script, vm: String, token: String?, holdsOwnLease: Bool, snapshot: String?,
                         progress: (@Sendable (Int, Script.Step, Result<JSON, Error>) -> Void)?,
                         leaseLost: inout Bool, into result: inout ScriptResult) async -> String? {
        if let snapshot {
            do { _ = try await call(.snapshot, "vm.snapshot.restore", base(vm, token, ["snapshot": .string(snapshot)])) }
            catch {
                if Task.isCancelled || error is CancellationError { return "the run was cancelled before step 1; start it again" }
                return "restoring snapshot '\(snapshot)' failed: \(error); check the snapshot name with vm.snapshot.list"
            }
        }
        var stepsBytes = 0
        for (offset, step) in script.steps.enumerated() {
            let number = offset + 1
            if Task.isCancelled { return "the run was cancelled before step \(number); start it again" }
            if let token, !(await handler.holdsLease(vm: vm, token: token)) {
                leaseLost = true
                if holdsOwnLease {
                    return "the lease on '\(vm)' was lost before step \(number) (it expired or another client took it); start the run again"
                }
                return "the lease on '\(vm)' is no longer the one passed to script.run (expired, released or taken over) before step \(number); renew the lease and run the script again"
            }
            result.stepsRun = number
            let began = ContinuousClock.now
            let run = await perform(step, number: number, vm: vm, token: token)
            let outcome = run.outcome
            let seconds = ScriptRunner.seconds(began.duration(to: ContinuousClock.now))
            var entry: [String: JSON] = ["step": .int(Int64(number)), "op": .string(step.op), "seconds": .double(seconds)]
            if let label = step.label { entry["label"] = .string(label) }
            if run.usedAltSelector { entry["usedAltSelector"] = true }
            if run.usedFallback { entry["usedFallback"] = true }
            if run.positional { entry["positional"] = true }
            switch outcome {
            case .success: entry["ok"] = true
            case .failure(let error):
                entry["ok"] = false
                entry["error"] = .string("\(error)")
            }
            if case .success(let value) = outcome, stepsBytes <= ScriptLimits.stepsBytes {
                var withResult = entry
                withResult["result"] = ScriptRunner.bounded(value)
                let size = (try? JSON.object(withResult).serialized().count) ?? 0
                if size > ScriptLimits.entryBytes {
                    entry["resultOmitted"] = .string("\(size) bytes")
                } else {
                    entry = withResult
                }
            }
            stepsBytes += (try? JSON.object(entry).serialized().count) ?? 0
            result.stepResults.append(.object(entry))
            progress?(number, step, outcome)
            if case .failure(let error) = outcome {
                if Task.isCancelled || error is CancellationError { return "the run was cancelled during step \(number); start it again" }
                result.failedStep = number
                let title = step.label.map { "step \(number) (\($0))" } ?? "step \(number)"
                return "\(title) failed: \(error)"
            }
        }
        return nil
    }

    /// A copy of `value` with every `png` string replaced by its size and every other long string shortened.
    static func bounded(_ value: JSON, key: String? = nil) -> JSON {
        switch value {
        case .string(let text):
            if key == "png" { return .string("<omitted: \(text.utf8.count) bytes>") }
            guard text.count > ScriptLimits.stringCharacters else { return value }
            return .string(String(text.prefix(ScriptLimits.stringCharacters)) + "… (\(text.count - ScriptLimits.stringCharacters) more characters)")
        case .array(let items): return .array(items.map { bounded($0) })
        case .object(let fields): return .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, bounded($0.value, key: $0.key)) }))
        default: return value
        }
    }

    private func base(_ vm: String, _ token: String?, _ extra: [String: JSON]) -> JSON {
        var params = extra
        params["name"] = .string(vm)
        if let token { params["lease"] = .string(token) }
        return .object(params)
    }

    /// Whether `error` is the UI helper saying that the element `params` names is not there: no element matches the
    /// selector, its window is gone, or the ref no longer exists.
    static func foundNothing(_ error: Error, params: [String: JSON]) -> Bool {
        guard case ControlHandler.ControlError.failed(let message) = error else { return false }
        return HelperSentence(message).saysAbsent(ref: params["ref"]?.stringValue, orNoMatch: true)
    }

    /// Whether `error` is the UI helper saying that no element matches a selector.
    static func matchedNothing(_ error: Error) -> Bool {
        guard case ControlHandler.ControlError.failed(let message) = error else { return false }
        return HelperSentence(message) == .noMatch
    }

    /// What running one step brought.
    private struct StepRun {
        var outcome: Result<JSON, Error>
        /// Whether the step's op ran a second time with `altSelector` as its selector.
        var usedAltSelector = false
        /// Whether the step went on to the click at its `fallback` coordinates.
        var usedFallback = false
        /// Whether a selector the step ran with carries an `index`.
        var positional = false
    }

    /// Runs one step: its op, then each expectation with the time left of the step's timeout, counted from the op's end.
    /// A step with a `selector` and an `altSelector` whose selector matches no element runs its op once more with
    /// `altSelector` as the selector. A `vm.ui.click` step with a `fallback` whose element is still not there clicks
    /// the fallback's coordinates with the step's button, count and observe options.
    private func perform(_ step: Script.Step, number: Int, vm: String, token: String?) async -> StepRun {
        var run = StepRun(outcome: .failure(CancellationError()))
        var params = step.params
        if step.op == "vm.wait_for", params["timeout"] == nil { params["timeout"] = .int(Int64(step.timeout)) }
        var fallback: JSON?
        if step.op == "vm.ui.click", let point = params.removeValue(forKey: "fallback"), point != .null { fallback = point }
        var alt: JSON?
        if let other = params.removeValue(forKey: "altSelector"), other != .null, (params["selector"] ?? .null) != .null { alt = other }
        func hasIndex(_ selector: JSON?) -> Bool { (selector?["index"] ?? .null) != .null }
        run.positional = hasIndex(params["selector"])
        var acted: Result<JSON, Error>
        do { acted = .success(try await call(.step, step.op, base(vm, token, params))) } catch { acted = .failure(error) }
        if case .failure(let first) = acted, let alt, ScriptRunner.matchedNothing(first) {
            run.usedAltSelector = true
            params["selector"] = alt
            run.positional = hasIndex(alt)
            do {
                acted = .success(try await call(.step, step.op, base(vm, token, params)))
            } catch is CancellationError {
                return run
            } catch let second {
                guard fallback != nil, ScriptRunner.foundNothing(second, params: params) else {
                    run.outcome = .failure(ScriptError(step: number, message: "the selector matched no element (\(first)) and the retry with altSelector failed: \(second)"))
                    return run
                }
                acted = .failure(second)
            }
        }
        if case .failure(let missing) = acted, let fallback, ScriptRunner.foundNothing(missing, params: params) {
            var click = params
            click["ref"] = nil
            click["selector"] = nil
            click["x"] = fallback["x"]
            click["y"] = fallback["y"]
            run.usedFallback = true
            run.positional = false
            do {
                acted = .success(try await call(.step, "vm.mouse.click", base(vm, token, click)))
            } catch is CancellationError {
                return run
            } catch let second {
                let point = "(\(fallback["x"]?.intValue ?? 0), \(fallback["y"]?.intValue ?? 0))"
                run.outcome = .failure(ScriptError(step: number, message: "the element was not found (\(missing)) and the click at the fallback point \(point) failed: \(second)"))
                return run
            }
        }
        switch acted {
        case .success(let value): run.outcome = await expectations(of: step, number: number, vm: vm, token: token, after: value)
        case .failure(let error): run.outcome = .failure(error)
        }
        return run
    }

    /// Checks the result of a `vm.wait_for` step and waits for each expectation of `step`; `value` on success.
    private func expectations(of step: Script.Step, number: Int, vm: String, token: String?, after value: JSON) async -> Result<JSON, Error> {
        if step.op == "vm.wait_for", value["matched"]?.intValue == -1 {
            return .failure(ScriptError(step: number, message: "vm.wait_for matched none of its conditions\(problems(value)); check the conditions or raise the timeout"))
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(step.timeout)
        for expectation in step.expect {
            let left = clock.now.duration(to: deadline)
            let remaining = max(1.0, Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
            let wait: JSON
            do {
                wait = try await call(.expect, "vm.wait_for", base(vm, token, [
                    "conditions": .array([expectation]), "timeout": .double(remaining),
                ]))
            } catch is CancellationError {
                return .failure(CancellationError())
            } catch {
                return .failure(ScriptError(step: number, message: "expectation \(text(of: expectation)) could not be checked: \(error)"))
            }
            if wait["matched"]?.intValue != 0 {
                let waited = wait["waited"]?.doubleValue ?? remaining
                return .failure(ScriptError(step: number, message: "expectation \(text(of: expectation)) did not hold within \(String(format: "%.1f", waited)) s\(problems(wait)); check that the screen or guest reaches that state, or raise the step's timeout"))
            }
        }
        return .success(value)
    }

    private func text(of value: JSON) -> String {
        (try? value.serialized()).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }

    /// The ` (...)` suffix naming the conditions of a wait that failed to evaluate.
    private func problems(_ wait: JSON) -> String {
        guard let list = wait["problems"]?.arrayValue, !list.isEmpty else { return "" }
        let lines = list.compactMap { $0["error"]?.stringValue }
        return lines.isEmpty ? "" : " (" + lines.joined(separator: "; ") + ")"
    }

    private func failureScreenshot(vm: String, maxWidth: Int?) async -> (png: Data, width: Int, height: Int)? {
        var params: JSON = ["name": .string(vm)]
        if let maxWidth { params = ["name": .string(vm), "maxWidth": .int(Int64(maxWidth))] }
        guard let shot = try? await call(.failure, "vm.screenshot", params),
              let png = shot["png"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
              let width = shot["sentWidth"]?.intValue, let height = shot["sentHeight"]?.intValue else { return nil }
        return (png, width, height)
    }
}
