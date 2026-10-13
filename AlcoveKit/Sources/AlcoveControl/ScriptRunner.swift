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

/// The timing of a script run's lease.
enum ScriptTiming {
    nonisolated(unsafe) static var leaseSeconds = 600
    nonisolated(unsafe) static var leaseRenewal = Duration.seconds(200)
}

/// The sizes a script run keeps and accepts.
enum ScriptLimits {
    static let fileBytes = 4 * 1024 * 1024
    static let stringCharacters = 2048
    static let stepsBytes = 256 * 1024
    static let entryBytes = 64 * 1024
}

/// Runs a script against a handler without a model: each step is one control op, followed by its expectations.
struct ScriptRunner: Sendable {
    let handler: ControlHandler

    init(handler: ControlHandler) { self.handler = handler }

    /// Runs the steps of `script` in order and stops at the first failure.
    ///
    /// `vm` overrides the script's VM. A `lease` must be the VM's current token; it is used for every step and
    /// is neither renewed nor released. Without one the runner holds a lease of its own named `owner` for the run.
    /// A `snapshot` is restored first.
    func run(_ script: Script, vm: String?, variables: [String: String], lease: String? = nil, owner: String = "script",
             snapshot: String? = nil,
             progress: (@Sendable (Int, Script.Step, Result<JSON, Error>) -> Void)?) async -> ScriptResult {
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
        do {
            try script.validate()
            resolved = try script.resolved(with: variables)
            try resolved.validateConditions()
            try validateObserveOptions(resolved)
        } catch {
            return finish("\(error)")
        }
        guard let name = vm ?? script.vm, !name.isEmpty else {
            return finish("the script names no VM; pass name or add \"vm\" to the script")
        }

        var token = lease
        var acquired = false
        if let lease {
            if let refusal = await handler.leaseRefusal(vm: name, token: lease) { return finish(refusal) }
        } else {
            do {
                let granted = try await handler.handle(op: "vm.lease.acquire", params: [
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
        if failure != nil, !Task.isCancelled, result.failedStep != nil, let shot = await failureScreenshot(vm: name) {
            result.failureImage = shot.png
            result.failureWidth = shot.width
            result.failureHeight = shot.height
        }
        renewal?.cancel()
        await renewal?.value
        var warning: String?
        if acquired, !leaseLost, let token {
            do {
                _ = try await handler.handle(op: "vm.lease.release", params: ["name": .string(name), "lease": .string(token)])
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
        let handler = self.handler
        return Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: ScriptTiming.leaseRenewal) } catch { return }
                guard let token else { return }
                let params: JSON = ["name": .string(vm), "owner": .string(owner),
                                    "ttl": .int(Int64(ScriptTiming.leaseSeconds)), "lease": .string(token)]
                do {
                    let granted = try await handler.handle(op: "vm.lease.acquire", params: params)
                    if let other = granted["lease"]?.stringValue, other != token {
                        _ = try? await handler.handle(op: "vm.lease.release", params: ["name": .string(vm), "lease": .string(other)])
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
            do { _ = try await handler.handle(op: "vm.snapshot.restore", params: base(vm, token, ["snapshot": .string(snapshot)])) }
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
            let outcome = await perform(step, number: number, vm: vm, token: token)
            let seconds = ScriptRunner.seconds(began.duration(to: ContinuousClock.now))
            var entry: [String: JSON] = ["step": .int(Int64(number)), "op": .string(step.op), "seconds": .double(seconds)]
            if let label = step.label { entry["label"] = .string(label) }
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

    /// Runs one step: its op, then each expectation with the time left of the step's timeout, counted from the op's end.
    private func perform(_ step: Script.Step, number: Int, vm: String, token: String?) async -> Result<JSON, Error> {
        let clock = ContinuousClock()
        var params = step.params
        if step.op == "vm.wait_for", params["timeout"] == nil { params["timeout"] = .int(Int64(step.timeout)) }
        let value: JSON
        do {
            value = try await handler.handle(op: step.op, params: base(vm, token, params))
        } catch {
            return .failure(error)
        }
        if step.op == "vm.wait_for", value["matched"]?.intValue == -1 {
            return .failure(ScriptError(step: number, message: "vm.wait_for matched none of its conditions\(problems(value)); check the conditions or raise the timeout"))
        }
        let deadline = clock.now + .seconds(step.timeout)
        for expectation in step.expect {
            let left = clock.now.duration(to: deadline)
            let remaining = max(1.0, Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
            let wait: JSON
            do {
                wait = try await handler.handle(op: "vm.wait_for", params: base(vm, token, [
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

    private func failureScreenshot(vm: String) async -> (png: Data, width: Int, height: Int)? {
        guard let shot = try? await handler.handle(op: "vm.screenshot", params: ["name": .string(vm)]),
              let png = shot["png"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
              let width = shot["sentWidth"]?.intValue, let height = shot["sentHeight"]?.intValue else { return nil }
        return (png, width, height)
    }
}
