import Foundation
import AlcoveQMP

/// The outcome of one script run. Step numbers are 1-based.
struct ScriptResult: Sendable {
    var passed: Bool
    /// Steps that started, including the one that failed.
    var stepsRun: Int
    var failedStep: Int?
    var error: String?
    /// One entry per started step.
    var stepResults: [JSON]
    var seconds: Double
    /// PNG of the VM's screen after a failing step.
    var failureImage: Data?
    var failureWidth: Int?
    var failureHeight: Int?
}

/// The timing of a script run's lease.
enum ScriptTiming {
    nonisolated(unsafe) static var leaseSeconds = 600
    nonisolated(unsafe) static var leaseRenewal = Duration.seconds(200)
}

/// Runs a script against a handler without a model: each step is one control op, followed by its expectations.
struct ScriptRunner: Sendable {
    let handler: ControlHandler

    init(handler: ControlHandler) { self.handler = handler }

    /// Runs the steps of `script` in order and stops at the first failure.
    ///
    /// `vm` overrides the script's VM. A `lease` that is the VM's current token is used for every step;
    /// without one the runner holds a lease of its own named `owner` for the run. A `snapshot` is restored first.
    func run(_ script: Script, vm: String?, variables: [String: String], lease: String? = nil, owner: String = "script",
             snapshot: String? = nil,
             progress: (@Sendable (Int, Script.Step, Result<JSON, Error>) -> Void)?) async -> ScriptResult {
        let clock = ContinuousClock()
        let started = clock.now
        var result = ScriptResult(passed: false, stepsRun: 0, failedStep: nil, error: nil, stepResults: [], seconds: 0)
        func finish(_ message: String?) -> ScriptResult {
            let elapsed = started.duration(to: clock.now)
            result.seconds = ((Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) * 10).rounded() / 10
            result.error = message
            result.passed = message == nil
            return result
        }

        let resolved: Script
        do {
            try script.validate()
            resolved = try script.resolved(with: variables)
        } catch {
            return finish("\(error)")
        }
        guard let name = vm ?? script.vm, !name.isEmpty else { return finish("the script names no VM; pass name") }

        var token = lease
        var acquired = false
        if let lease {
            if let refusal = await handler.leaseRefusal(vm: name, token: lease) { return finish(refusal) }
            token = lease
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

        var failure = await execute(resolved, vm: name, token: token, snapshot: snapshot, progress: progress, into: &result)
        if failure == nil, Task.isCancelled { failure = "the run was cancelled; start it again" }
        if failure != nil, !Task.isCancelled, result.failedStep != nil, let shot = await failureScreenshot(vm: name) {
            result.failureImage = shot.png
            result.failureWidth = shot.width
            result.failureHeight = shot.height
        }
        renewal?.cancel()
        if acquired, let token {
            _ = try? await handler.handle(op: "vm.lease.release", params: ["name": .string(name), "lease": .string(token)])
        }
        return finish(failure)
    }

    /// Renews the run's lease until cancelled.
    private func renewLease(vm: String, owner: String, token: String?) -> Task<Void, Never> {
        let handler = self.handler
        return Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: ScriptTiming.leaseRenewal) } catch { return }
                var params: [String: JSON] = ["name": .string(vm), "owner": .string(owner),
                                              "ttl": .int(Int64(ScriptTiming.leaseSeconds))]
                if let token { params["lease"] = .string(token) }
                _ = try? await handler.handle(op: "vm.lease.acquire", params: .object(params))
            }
        }
    }

    /// Restores the snapshot and runs the steps; returns the failure sentence, or nil when all passed.
    private func execute(_ script: Script, vm: String, token: String?, snapshot: String?,
                         progress: (@Sendable (Int, Script.Step, Result<JSON, Error>) -> Void)?,
                         into result: inout ScriptResult) async -> String? {
        if let snapshot {
            do { _ = try await handler.handle(op: "vm.snapshot.restore", params: base(vm, token, ["snapshot": .string(snapshot)])) }
            catch is CancellationError { return "the run was cancelled; start it again" }
            catch { return "restoring snapshot '\(snapshot)' failed: \(error)" }
        }
        for (offset, step) in script.steps.enumerated() {
            let number = offset + 1
            if Task.isCancelled { return "the run was cancelled before step \(number); start it again" }
            result.stepsRun = number
            let began = ContinuousClock.now
            let outcome = await perform(step, number: number, vm: vm, token: token)
            let elapsed = began.duration(to: ContinuousClock.now)
            let seconds = ((Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) * 10).rounded() / 10
            var entry: [String: JSON] = ["step": .int(Int64(number)), "op": .string(step.op), "seconds": .double(seconds)]
            if let label = step.label { entry["label"] = .string(label) }
            switch outcome {
            case .success(let value):
                entry["ok"] = true
                entry["result"] = value
            case .failure(let error):
                entry["ok"] = false
                entry["error"] = .string("\(error)")
            }
            result.stepResults.append(.object(entry))
            progress?(number, step, outcome)
            if case .failure(let error) = outcome {
                if error is CancellationError { return "the run was cancelled during step \(number); start it again" }
                result.failedStep = number
                let title = step.label.map { "step \(number) (\($0))" } ?? "step \(number)"
                return "\(title) failed: \(error)"
            }
        }
        return nil
    }

    private func base(_ vm: String, _ token: String?, _ extra: [String: JSON]) -> JSON {
        var params = extra
        params["name"] = .string(vm)
        if let token { params["lease"] = .string(token) }
        return .object(params)
    }

    /// Runs one step: its op, then each expectation with the time left of the step's timeout.
    private func perform(_ step: Script.Step, number: Int, vm: String, token: String?) async -> Result<JSON, Error> {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(step.timeout)
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
        for expectation in step.expect {
            let left = deadline - clock.now
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
                return .failure(ScriptError(step: number, message: "expectation \(text(of: expectation)) did not hold within \(step.timeout) s\(problems(wait)); check that the screen or guest reaches that state, or raise the step's timeout"))
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
