import Foundation
import AlcoveAgent
import AlcoveQMP
import AlcoveDisplayProtocol

/// Mouse and keyboard input, the screen observation that follows it, and batches of input steps.
/// Everything here runs with the VM's input gate already held by `handle`.
extension ControlHandler {
    /// The ops that send mouse or keyboard input and accept `observe`.
    static let actionOps: Set<String> = [
        "vm.mouse.move", "vm.mouse.click", "vm.mouse.drag", "vm.mouse.scroll", "vm.mouse.down", "vm.mouse.up",
        "vm.key.press", "vm.key.down", "vm.key.up", "vm.type",
    ]
    /// What a `vm.batch` step may name besides the action ops.
    static let batchOnlyStepOps: Set<String> = ["vm.wait_idle", "vm.wait_for", "sleep"]
    static let maxBatchSteps = 50

    struct ObserveOptions {
        var level = ObserveLevel.none
        var settleMs = 300
        var settleTimeoutMs = 2000
    }

    /// The `observe`, `settleMs` and `settleTimeoutMs` parameters.
    nonisolated func observeOptions(_ params: JSON) throws -> ObserveOptions {
        var options = ObserveOptions()
        if let value = params["observe"] {
            guard let level = value.stringValue.flatMap(ObserveLevel.init(rawValue:)) else {
                throw ControlError.failed("observe must be one of \(ObserveLevel.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            options.level = level
        }
        if let value = params["settleMs"] {
            guard let ms = value.intValue, (0...10000).contains(ms) else { throw ControlError.failed("settleMs must be between 0 and 10000") }
            options.settleMs = ms
        }
        if let value = params["settleTimeoutMs"] {
            guard let ms = value.intValue, (100...30000).contains(ms) else { throw ControlError.failed("settleTimeoutMs must be between 100 and 30000") }
            options.settleTimeoutMs = ms
        }
        guard options.settleMs <= options.settleTimeoutMs else {
            throw ControlError.failed("settleMs (\(options.settleMs)) must not exceed settleTimeoutMs (\(options.settleTimeoutMs)); lower settleMs or raise settleTimeoutMs")
        }
        return options
    }

    /// Runs one action op; unless the level is `none`, the result carries what the screen did afterwards,
    /// or `observationError` when the screen could not be read after the input was sent.
    func action(op: String, params: JSON) async throws -> JSON {
        let options = try observeOptions(params)
        let t = try await running(params)
        guard options.level != .none else {
            try await send(op, to: t, params)
            return [:]
        }
        let before = try await frame(of: t, before: op)
        try await send(op, to: t, params)
        var out: [String: JSON] = [:]
        try await addObservation(to: &out, t, after: op, before: before, options)
        return .object(out)
    }

    /// Runs the steps of a batch in order and stops at the first one that throws.
    func batch(_ params: JSON) async throws -> JSON {
        let options = try observeOptions(params)
        let steps = try batchSteps(params, vm: try string(params, "name"))
        let t = try await running(params)
        let before = options.level == .none ? nil : try await frame(of: t, before: "vm.batch")
        var results: [JSON] = []
        var failure: (step: Int, message: String)?
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation()
            do {
                results.append(try await run(step, vm: t.name))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = (index, ControlHandler.failureReason(error, fallback: "the step failed; check vm.status"))
                break
            }
        }
        var out: [String: JSON] = ["completed": .int(Int64(results.count)), "results": .array(results)]
        if let failure {
            out["failedStep"] = .int(Int64(failure.step))
            out["error"] = .string(failure.message)
        }
        if let before { try await addObservation(to: &out, t, after: "vm.batch", before: before, options) }
        return .object(out)
    }

    private struct BatchStep {
        let op: String
        let params: [String: JSON]
    }

    /// The validated `steps` parameter of a batch for `vm`; step numbers in errors count from 0.
    private nonisolated func batchSteps(_ params: JSON, vm: String) throws -> [BatchStep] {
        guard let list = params["steps"]?.arrayValue else { throw ControlError.missing("steps") }
        guard !list.isEmpty else { throw ControlError.failed("steps is empty; pass at least one step") }
        guard list.count <= ControlHandler.maxBatchSteps else {
            throw ControlError.failed("a batch runs at most \(ControlHandler.maxBatchSteps) steps, not \(list.count); split them over several vm.batch calls")
        }
        var steps: [BatchStep] = []
        for (index, value) in list.enumerated() {
            guard let fields = value.objectValue, let op = fields["op"]?.stringValue else {
                throw ControlError.failed("step \(index): a step is an object with a string 'op'")
            }
            guard ControlHandler.actionOps.contains(op) || ControlHandler.batchOnlyStepOps.contains(op) else {
                throw ControlError.failed("step \(index): '\(op)' cannot run in a batch")
            }
            if let name = fields["name"], name.stringValue != vm {
                throw ControlError.failed("step \(index): 'name' must not differ from the batch's VM")
            }
            if op == "sleep" {
                guard let ms = fields["ms"]?.intValue, (1...10000).contains(ms) else {
                    throw ControlError.failed("step \(index): sleep needs an integer 'ms' between 1 and 10000")
                }
            }
            steps.append(BatchStep(op: op, params: fields))
        }
        return steps
    }

    /// Runs one batch step against `vm` with its `observe` set to `none`; `sleep` waits for its `ms`.
    private func run(_ step: BatchStep, vm: String) async throws -> JSON {
        if step.op == "sleep" {
            try await Task.sleep(for: .milliseconds(step.params["ms"]?.intValue ?? 0))
            return [:]
        }
        var params = step.params
        params["name"] = .string(vm)
        params["observe"] = .string(ObserveLevel.none.rawValue)
        return try await perform(op: step.op, params: .object(params))
    }

    /// The current frame of `t`, read before `op` sends any input.
    private func frame(of t: VMTarget, before op: String) async throws -> Frame {
        let frame: Frame
        do {
            frame = try await t.frame()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ControlError.failed("the screen could not be read before \(op), so no input was sent: \(ControlHandler.failureReason(error, fallback: "the display gave no image; check vm.status"))")
        }
        lastSize[t.name] = (frame.width, frame.height)
        return frame
    }

    /// Waits for the screen to settle after `op` and sets `observation` in `out`, or `observationError`
    /// when a frame cannot be read. Cancellation is thrown.
    func addObservation(to out: inout [String: JSON], _ t: VMTarget, after op: String, before: Frame,
                                _ options: ObserveOptions) async throws {
        do {
            let result = try await observe(t, before: before, level: options.level, settleMs: options.settleMs,
                                           settleTimeoutMs: options.settleTimeoutMs)
            lastSize[t.name] = (result.width, result.height)
            out["observation"] = result.json()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            out["observationError"] = .string("the screen could not be read after \(op): \(ControlHandler.failureReason(error, fallback: "the display gave no image")); call vm.screenshot to see the result")
        }
    }

    /// Sends the display messages of one action op to `t`.
    private func send(_ op: String, to t: VMTarget, _ params: JSON) async throws {
        switch op {
        case "vm.mouse.move":
            try await move(t, x: try int(params, "x"), y: try int(params, "y"))
            await t.sendDisplay(.sync)
        case "vm.mouse.click":
            let button = try button(params["button"]?.stringValue)
            let count = max(1, min(3, params["count"]?.intValue ?? 1))
            let hold = params["hold"]?.intValue ?? 60
            try await move(t, x: try int(params, "x"), y: try int(params, "y"))
            for i in 0..<count {
                await t.sendDisplay(.btn(con: 0, button: button, down: true)); await t.sendDisplay(.sync)
                try await Task.sleep(for: .milliseconds(hold))
                await t.sendDisplay(.btn(con: 0, button: button, down: false)); await t.sendDisplay(.sync)
                if i < count - 1 { try await Task.sleep(for: .milliseconds(90)) }
            }
        case "vm.mouse.down", "vm.mouse.up":
            let button = try button(params["button"]?.stringValue)
            guard (params["x"] == nil) == (params["y"] == nil) else {
                throw ControlError.failed("\(op) takes 'x' and 'y' together; pass both or neither")
            }
            if params["x"] != nil { try await move(t, x: try int(params, "x"), y: try int(params, "y")) }
            guard await t.sendDisplay(.btn(con: 0, button: button, down: op == "vm.mouse.down")) else { throw ControlError.noDisplay(t.name) }
            await t.sendDisplay(.sync)
        case "vm.mouse.drag":
            let button = try button(params["button"]?.stringValue)
            let (fx, fy, tx, ty) = (try int(params, "fromX"), try int(params, "fromY"), try int(params, "toX"), try int(params, "toY"))
            try await move(t, x: fx, y: fy); await t.sendDisplay(.sync)
            await t.sendDisplay(.btn(con: 0, button: button, down: true)); await t.sendDisplay(.sync)
            try await Task.sleep(for: .milliseconds(80))
            for step in 1...10 {
                try await move(t, x: fx + (tx - fx) * step / 10, y: fy + (ty - fy) * step / 10)
                await t.sendDisplay(.sync)
                try await Task.sleep(for: .milliseconds(25))
            }
            await t.sendDisplay(.btn(con: 0, button: button, down: false)); await t.sendDisplay(.sync)
        case "vm.mouse.scroll":
            try await move(t, x: try int(params, "x"), y: try int(params, "y")); await t.sendDisplay(.sync)
            let dy = params["dy"]?.intValue ?? 0, dx = params["dx"]?.intValue ?? 0
            for _ in 0..<abs(dy) { await wheel(t, dy > 0 ? .wheelDown : .wheelUp) }
            for _ in 0..<abs(dx) { await wheel(t, dx > 0 ? .wheelRight : .wheelLeft) }
        case "vm.key.press":
            guard let spec = params["keys"]?.stringValue, !spec.isEmpty else { throw ControlError.missing("keys") }
            let seq: [(code: Int, down: Bool)]
            do { seq = try KeyNames.pressSequence(spec) } catch { throw ControlError.failed("bad key spec '\(spec)': \(ControlHandler.failureReason(error, fallback: "the keys could not be read"))") }
            let hold = params["hold"]?.intValue ?? 0
            try await sendKeys(t, seq, gap: 20, holdBeforeRelease: hold)
        case "vm.key.down", "vm.key.up":
            guard let name = params["key"]?.stringValue else { throw ControlError.missing("key") }
            let key: KeyNames.Key
            do { key = try KeyNames.key(named: name) } catch { throw ControlError.failed("unknown key '\(name)'") }
            await t.sendDisplay(.key(mac: key.code, q: nil, down: op == "vm.key.down"))
        case "vm.type":
            guard let text = params["text"]?.stringValue else { throw ControlError.missing("text") }
            let delay = params["delay"]?.intValue ?? 12
            if let seq = try? KeyNames.typeSequence(text) {
                try await sendKeys(t, seq, gap: delay, holdBeforeRelease: 0)
            } else {
                // non-US characters: go through the guest clipboard and paste
                guard let agent = await t.agent(timeout: .seconds(2)) else { throw ControlError.untypable("this text") }
                do { try await agent.setClipboard(text: text) } catch { throw agentFailure(error, vm: t.name, op: op) }
                try await Task.sleep(for: .milliseconds(150))
                try await sendKeys(t, try KeyNames.pressSequence("ctrl+v"), gap: 20, holdBeforeRelease: 0)
            }
        default:
            throw ControlError.unknownOp(op)
        }
    }

    private func button(_ name: String?) throws -> InputButton {
        switch (name ?? "left").lowercased() {
        case "left": return .left
        case "right": return .right
        case "middle": return .middle
        default: throw ControlError.missing("button")
        }
    }

    /// Moves the pointer to guest pixel (x, y), clamped to the frame.
    private func move(_ t: VMTarget, x: Int, y: Int) async throws {
        if lastSize[t.name] == nil { _ = try await screenshot(t) }
        guard let (w, h) = lastSize[t.name], w > 1, h > 1 else { throw ControlError.noDisplay(t.name) }
        let ax = Int((Double(max(0, min(x, w - 1))) / Double(w - 1) * Double(ToQEMU.absoluteMax)).rounded())
        let ay = Int((Double(max(0, min(y, h - 1))) / Double(h - 1) * Double(ToQEMU.absoluteMax)).rounded())
        guard await t.sendDisplay(.abs(con: 0, x: ax, y: ay)) else { throw ControlError.noDisplay(t.name) }
    }

    private func wheel(_ t: VMTarget, _ b: InputButton) async {
        await t.sendDisplay(.btn(con: 0, button: b, down: true)); await t.sendDisplay(.sync)
        await t.sendDisplay(.btn(con: 0, button: b, down: false)); await t.sendDisplay(.sync)
    }

    private func sendKeys(_ t: VMTarget, _ seq: [(code: Int, down: Bool)], gap: Int, holdBeforeRelease: Int) async throws {
        for (i, ev) in seq.enumerated() {
            if !ev.down, holdBeforeRelease > 0, i > 0, seq[i - 1].down, seq[i - 1].code == ev.code {
                try await Task.sleep(for: .milliseconds(holdBeforeRelease))
            }
            guard await t.sendDisplay(.key(mac: ev.code, q: nil, down: ev.down)) else { throw ControlError.noDisplay(t.name) }
            if gap > 0 { try await Task.sleep(for: .milliseconds(gap)) }
        }
    }
}
