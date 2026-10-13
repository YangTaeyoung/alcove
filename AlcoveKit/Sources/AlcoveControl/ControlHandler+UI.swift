import Foundation
import AlcoveAgent
import AlcoveQMP

/// The clocks of the UI ops.
enum UITiming {
    /// Longest the host waits for the agent's answer to one window or element op, counted from the moment it is sent.
    /// It covers what the agent may spend on one call: 60 s in its queue for the helper, 120 s for a helper start and
    /// 30 s for the call itself, and leaves 5 s for the answer's way back.
    nonisolated(unsafe) static var callTimeout = Duration.seconds(215)
    /// Longest a window or element op waits for its turn at the UI helper.
    nonisolated(unsafe) static var queueTimeout = Duration.seconds(60)
    /// Longest an observation spends on the foreground window and the focused element, the wait for the helper's turn included.
    nonisolated(unsafe) static var factBudget = Duration.seconds(3)
    /// Longest an observation at level `ui` spends on the foreground window, the focused element and the tree together.
    nonisolated(unsafe) static var treeFactBudget = Duration.seconds(20)
    /// Longest a recorded action waits for the answer about the element it is aimed at, counted from the moment the
    /// question is sent.
    nonisolated(unsafe) static var targetBudget = Duration.milliseconds(300)
    /// The time limit a question about the element an action is aimed at gives the UI helper, in milliseconds.
    static let targetHelperBudgetMs = 200
    /// Returns when a budget for UI facts, which ends at the given moment, has run out.
    nonisolated(unsafe) static var factBudgetEnd: @Sendable (ContinuousClock.Instant) async -> Void = {
        try? await Task.sleep(until: $0, clock: .continuous)
    }
    /// Pause between the click of `vm.ui.type` and its first key.
    nonisolated(unsafe) static var focusDelay = Duration.milliseconds(120)
    /// Pause between two reads of the process list while `vm.deploy` waits for stopped processes to exit.
    nonisolated(unsafe) static var processPoll = Duration.milliseconds(200)
    /// Longest `vm.deploy` waits for stopped processes to exit.
    nonisolated(unsafe) static var processExitTimeout = Duration.seconds(5)
}

/// A helper call that was not sent: other calls kept the VM's UI helper until the call's turn deadline.
struct HelperBusy: Error {}

/// Where work running in a task of its own stands, for a caller that does not wait for it.
actor CallAnswer<Value: Sendable> {
    enum Phase: Sendable {
        /// Running and not marked as sent: a helper call is waiting for its turn at the helper; other work stays in
        /// this phase until it ends.
        case queued
        /// A helper call that was sent to the agent at the given time.
        case sent(ContinuousClock.Instant)
        /// Ended at the given time with its result.
        case done(Value, ContinuousClock.Instant)
    }

    private(set) var phase = Phase.queued
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0

    func markSent() {
        if case .queued = phase { phase = .sent(.now) }
    }

    /// Ends the work with `result`; a second call changes nothing.
    func finish(_ result: Value) {
        if case .done = phase { return }
        phase = .done(result, .now)
        let waiting = waiters
        waiters = [:]
        for continuation in waiting.values { continuation.resume() }
    }

    /// The result of the work and the time it ended, once it ended; waits for that until `deadline` at most and
    /// returns nil when the work has not ended by then or the waiting task was cancelled. A deadline that has passed
    /// makes this a look without waiting. With `expiry`, the wait ends when `expiry` returns instead of at `deadline`.
    func outcome(until deadline: ContinuousClock.Instant,
                 expiry: (@Sendable () async -> Void)? = nil) async -> (result: Value, at: ContinuousClock.Instant)? {
        if case .done(let result, let at) = phase { return (result, at) }
        guard ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
        nextID += 1
        let id = nextID
        let timer = Task {
            if let expiry {
                await expiry()
            } else {
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            }
            self.wake(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.wake(id) }
        }
        timer.cancel()
        if case .done(let result, let at) = phase { return (result, at) }
        return nil
    }

    private func wake(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

/// Where one helper call stands: its result is the agent's reply or an error.
typealias HelperAnswer = CallAnswer<Result<JSON, Error>>

/// One helper call running in its own task.
struct HelperProbe: Sendable {
    /// The agent op of the call.
    let op: String
    /// When the call began to wait for its turn.
    let started: ContinuousClock.Instant
    let answer: HelperAnswer
    let task: Task<Void, Never>

    /// Gives the call up: a call still waiting for its turn is not sent; a sent call keeps the helper until the agent answered.
    func abandon() { task.cancel() }
}

/// How a control op or a wait condition names one element: a ref, or selector fields.
enum UISelector {
    static let fieldNames = ["window", "role", "name", "nameContains", "automationId", "index"]
    static let criteria = ["role", "name", "nameContains", "automationId"]

    enum Invalid: Error {
        case neither
        case both
        case noCriteria
        case field(String)
    }

    /// The agent fields that select one element: `ref` alone, or the fields of the `selector` object. Null counts as absent.
    static func agentFields(ref: JSON?, selector: JSON?) throws -> [String: JSON] {
        let ref = ref.flatMap { $0 == .null ? nil : $0 }
        let selector = selector.flatMap { $0 == .null ? nil : $0 }
        if ref != nil, selector != nil { throw Invalid.both }
        if let ref {
            guard let text = ref.stringValue, isRef(text) else {
                throw Invalid.field("ref must be an element ref such as e12; take one from vm.ui.tree or vm.ui.find")
            }
            return ["ref": .string(text)]
        }
        guard let selector else { throw Invalid.neither }
        guard let fields = selector.objectValue else {
            throw Invalid.field("selector must be an object with window, role, name, nameContains, automationId or index")
        }
        var out: [String: JSON] = [:]
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) where value != .null {
            guard fieldNames.contains(key) else {
                throw Invalid.field("selector has no field '\(key)'; valid fields: \(fieldNames.joined(separator: ", "))")
            }
            if key == "index" {
                guard let index = value.intValue, index >= 0 else { throw Invalid.field("selector field 'index' must be an integer of 0 or more") }
            } else {
                guard value.stringValue != nil else { throw Invalid.field("selector field '\(key)' must be a string") }
            }
            out[key] = value
        }
        guard criteria.contains(where: { out[$0] != nil }) else { throw Invalid.noCriteria }
        return out
    }

    /// Whether `text` is `e` followed by digits.
    static func isRef(_ text: String) -> Bool {
        text.hasPrefix("e") && text.count > 1 && text.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

}

/// What an error sentence of the guest agent's `ui.*` and `win.*` operations says, told by a part of the sentence that
/// stays the same. Every place that reads such a sentence goes through this type.
enum HelperSentence: Equatable {
    /// `element <ref> no longer exists; …`
    case staleRef(String)
    /// `no element matches <selector>; …`
    case noMatch
    /// `no window has "…" in its title; …` or `window 0x… no longer exists; …`, the `0x` in either case
    case windowGone
    /// `the element is a password field; …`
    case passwordField
    /// `window 0x… "…" is not responding; …`
    case notResponding
    /// `the UI helper is shut down; …`
    case shutDown
    /// `… the UI helper folder <dir> could not be locked (…); fix its owner and access list, then retry`
    case cannotStart
    /// `the request was cancelled`
    case cancelled
    /// `unknown op '<op>'; …`
    case unknownOp
    /// Any other sentence.
    case other

    init(_ message: String) {
        let words = message.split(separator: " ", maxSplits: 2)
        if words.count == 3, words[0] == "element", UISelector.isRef(String(words[1])), words[2].hasPrefix("no longer exists") {
            self = .staleRef(String(words[1]))
        } else if message.hasPrefix("no element matches ") {
            self = .noMatch
        } else if message.hasPrefix("no window has \"") {
            self = .windowGone
        } else if words.count == 3, words[0] == "window", words[1].lowercased().hasPrefix("0x"), words[2].hasPrefix("no longer exists") {
            self = .windowGone
        } else if message.hasPrefix("the element is a password field") {
            self = .passwordField
        } else if message.hasPrefix("window 0x"), message.contains(" is not responding; ") {
            self = .notResponding
        } else if message.hasPrefix("the UI helper is shut down") {
            self = .shutDown
        } else if message.hasPrefix("the request was cancelled") {
            self = .cancelled
        } else if message.hasPrefix("unknown op '") {
            self = .unknownOp
        } else if message.contains("the UI helper folder "), message.contains(" could not be locked ("),
                  message.hasSuffix("; fix its owner and access list, then retry") {
            self = .cannotStart
        } else {
            self = .other
        }
    }

    /// Whether asking the helper again cannot bring another answer: it is shut down or cannot start.
    var isPermanent: Bool { self == .shutDown || self == .cannotStart }

    /// Whether the sentence says that an element is not there: for `ref` the stale-ref sentence of that ref, for
    /// selector fields a sentence about their window being gone, or with `orNoMatch` the no-match sentence.
    func saysAbsent(ref: String?, orNoMatch: Bool = false) -> Bool {
        if let ref { return self == .staleRef(ref) }
        return self == .windowGone || (orNoMatch && self == .noMatch)
    }
}

/// One numbered element of a marked screenshot.
struct UIMark {
    let number: Int
    let node: JSON
    /// The element's rectangle in guest pixels of the full frame.
    let rect: Frame.Rect

    /// `{n, ref, role, name, x, y, w, h}`.
    var json: JSON {
        ["n": .int(Int64(number)), "ref": node["ref"] ?? .null, "role": node["role"] ?? .null, "name": node["name"] ?? "",
         "x": .int(Int64(rect.x)), "y": .int(Int64(rect.y)), "w": .int(Int64(rect.w)), "h": .int(Int64(rect.h))]
    }
}

/// What a screenshot asks of the guest's UI: the window to crop to and the elements to mark.
struct ScreenshotView {
    var window: JSON?
    var nodes: [JSON]?
    /// Whether the agent left elements out of `nodes`.
    var nodesTruncated = false
}

extension Frame.Rect {
    func offset(x dx: Int, y dy: Int) -> Frame.Rect { Frame.Rect(x: x + dx, y: y + dy, w: w, h: h) }

    func intersects(_ other: Frame.Rect) -> Bool {
        x < other.x + other.w && other.x < x + w && y < other.y + other.h && other.y < y + h
    }
}

/// Windows, UI Automation elements, app launch and guest events of Windows guests, carried by the agent's
/// `win.*`, `ui.*` and `app.launch` operations. Clicks and keys go through the display like `vm.mouse.click` and `vm.type`.
extension ControlHandler {
    static let windowActions = ["focus", "minimize", "maximize", "restore", "close", "move", "resize"]
    static let elementActions = ["invoke", "toggle", "expand", "collapse", "select", "set_value", "focus", "scroll_into_view"]
    static let textModes = ["auto", "pattern", "descendants"]
    /// The control types a marked screenshot numbers, in lower case.
    static let markRoles: Set<String> = [
        "button", "checkbox", "combobox", "edit", "headeritem", "hyperlink", "listitem", "menuitem", "radiobutton", "slider", "spinner",
        "splitbutton", "tabitem", "treeitem", "dataitem", "document",
    ]
    static let maxMarks = 100
    static let maxObservedEvents = 20
    static let observedTreeNodes = 150
    static let defaultLaunchWaitSeconds = 15.0
    static let maxWaitWindowSeconds = 300.0

    func ui(op: String, params: JSON) async throws -> JSON {
        switch op {
        case "vm.window.list":
            let t = try await running(params)
            let agent = try await uiAgent(t, op: op)
            let r = try await uiCall(agent, "win.list", [:], vm: t.name, op: op)
            return ["windows": r["windows"] ?? []]
        case "vm.window.action": return try await windowAction(params)
        case "vm.ui.tree": return try await uiTree(params)
        case "vm.ui.find": return try await uiFind(params)
        case "vm.ui.text": return try await uiText(params)
        case "vm.ui.click": return try await uiClick(params)
        case "vm.ui.type": return try await uiType(params)
        case "vm.ui.action": return try await uiAction(params)
        case "vm.app.launch": return try await launchApp(params)
        case "vm.events": return try await guestEvents(params)
        default: throw ControlError.unknownOp(op)
        }
    }

    // MARK: - shared helpers

    /// The agent of `t`, checked for request/response support and the `ui` capability.
    func uiAgent(_ t: VMTarget, op: String) async throws -> AgentClient {
        let agent = try await tools(t)
        guard let hello = await agent.hello, hello.rpcVersion >= 2 else { throw ControlError.toolsTooOld(vm: t.name, op: op) }
        guard hello.capabilities.contains("ui") else { throw ControlError.noUI(t.name) }
        return agent
    }

    /// One `ui.*` or `win.*` agent call as the only helper call of `vm` in flight: waits for its turn until `turnBy`, sends,
    /// and keeps the turn until the agent answered, failed, timed out after `UITiming.callTimeout` or disconnected.
    /// `sent` runs once the turn is taken, `answered` with the outcome of a turn that was taken, before the turn is
    /// given to the next caller. Throws `HelperBusy` when the turn did not come by `turnBy`, and `CancellationError`
    /// without sending when the task was cancelled before the call went out.
    nonisolated func helperTurn(_ agent: AgentClient, _ agentOp: String, _ fields: [String: JSON], vm: String,
                                turnBy: ContinuousClock.Instant, sent: (@Sendable () async -> Void)? = nil,
                                answered: (@Sendable (Result<JSON, Error>) async -> Void)? = nil) async throws -> JSON {
        guard try await helperGate.acquire(vm, until: turnBy) else { throw HelperBusy() }
        return try await takenTurn(agent, agentOp, fields, vm: vm, sent: sent, answered: answered)
    }

    /// The part of `helperTurn` that follows the taking of the turn: sends the call and keeps the turn until the agent
    /// answered, failed, timed out after `UITiming.callTimeout` or disconnected, then gives it to the next caller.
    private nonisolated func takenTurn(_ agent: AgentClient, _ agentOp: String, _ fields: [String: JSON], vm: String,
                                       sent: (@Sendable () async -> Void)? = nil,
                                       answered: (@Sendable (Result<JSON, Error>) async -> Void)? = nil) async throws -> JSON {
        let result: Result<JSON, Error>
        do {
            await sent?()
            try Task.checkCancellation()
            result = .success(try await agent.call(agentOp, fields, timeout: UITiming.callTimeout))
        } catch {
            result = .failure(error)
        }
        await answered?(result)
        await helperGate.release(vm)
        return try result.get()
    }

    /// Starts `helperTurn` in a task of its own and returns at once. The answer of the call is in the probe before
    /// the helper is given to the next caller.
    nonisolated func startHelperCall(_ agent: AgentClient, _ agentOp: String, _ fields: [String: JSON], vm: String,
                                     turnBy: ContinuousClock.Instant) -> HelperProbe {
        let answer = HelperAnswer()
        let started = ContinuousClock.now
        let task = Task {
            do {
                _ = try await self.helperTurn(agent, agentOp, fields, vm: vm, turnBy: turnBy, sent: { await answer.markSent() },
                                              answered: { await answer.finish($0) })
            } catch {
                await answer.finish(.failure(error))
            }
        }
        return HelperProbe(op: agentOp, started: started, answer: answer, task: task)
    }

    /// One helper call on behalf of the control op `op`, which waits `UITiming.queueTimeout` for its turn; failures become control errors.
    func uiCall(_ agent: AgentClient, _ agentOp: String, _ fields: [String: JSON], vm: String, op: String) async throws -> JSON {
        do {
            return try await helperTurn(agent, agentOp, fields, vm: vm, turnBy: .now + UITiming.queueTimeout)
        } catch is HelperBusy {
            throw ControlError.failed("the UI helper is busy with other requests; retry")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw agentFailure(error, vm: vm, op: op)
        }
    }

    /// The agent fields that select the element of a control op: its `ref`, or the fields of its `selector` object.
    nonisolated func elementFields(_ params: JSON) throws -> [String: JSON] {
        do {
            return try UISelector.agentFields(ref: params["ref"], selector: params["selector"])
        } catch UISelector.Invalid.neither {
            throw ControlError.failed("pass ref or selector")
        } catch UISelector.Invalid.both {
            throw ControlError.failed("pass ref or selector, not both")
        } catch UISelector.Invalid.noCriteria {
            throw ControlError.failed("selector needs at least one of \(UISelector.criteria.joined(separator: ", "))")
        } catch UISelector.Invalid.field(let message) {
            throw ControlError.failed(message)
        }
    }

    /// Runs `body`; unless the level is `none`, its result also carries what the screen did afterwards,
    /// or `observationError` when the screen could not be read after `body` finished.
    private func observed(_ t: VMTarget, op: String, _ options: ObserveOptions,
                          _ body: () async throws -> [String: JSON]) async throws -> JSON {
        let before = options.level == .none ? nil : try await frame(of: t, before: op)
        var out = try await body()
        if let before { try await addObservation(to: &out, t, after: op, before: before, options) }
        return .object(out)
    }

    /// Scrolls the element into view and returns it with its clickable point in guest pixels of the full frame.
    private func clickPoint(_ agent: AgentClient, _ element: [String: JSON], vm: String, op: String) async throws -> (node: JSON, x: Int, y: Int) {
        var request = element
        request["scroll"] = true
        let r = try await uiCall(agent, "ui.rect", request, vm: vm, op: op)
        let node = r["node"] ?? .null
        guard r["clickable"]?.boolValue == true, let x = r["cx"]?.intValue, let y = r["cy"]?.intValue else {
            let ref = node["ref"]?.stringValue ?? element["ref"]?.stringValue ?? "of this selector"
            guard let blocked = r["blocked"]?.stringValue, !blocked.isEmpty else {
                throw ControlError.failed("element \(ref) has no clickable point (off screen or covered); use vm.ui.action or scroll it into view")
            }
            throw ControlError.failed("element \(ref) has no clickable point: \(blocked); or act on it with vm.ui.action")
        }
        return (node, x, y)
    }

    // MARK: - windows

    private func windowAction(_ params: JSON) async throws -> JSON {
        let op = "vm.window.action"
        let options = try observeOptions(params)
        guard let window = params["window"]?.stringValue, !window.isEmpty else { throw ControlError.missing("window") }
        guard let action = params["action"]?.stringValue, ControlHandler.windowActions.contains(action) else {
            throw ControlError.failed("action must be one of \(ControlHandler.windowActions.joined(separator: ", "))")
        }
        var request: [String: JSON] = ["window": .string(window), "action": .string(action)]
        if action == "move" {
            guard let x = params["x"]?.intValue, let y = params["y"]?.intValue else {
                throw ControlError.failed("move needs integer 'x' and 'y' in guest pixels")
            }
            request["x"] = .int(Int64(x)); request["y"] = .int(Int64(y))
        }
        if action == "resize" {
            guard let w = params["width"]?.intValue, let h = params["height"]?.intValue, w > 0, h > 0 else {
                throw ControlError.failed("resize needs integer 'width' and 'height' above 0 in guest pixels")
            }
            request["w"] = .int(Int64(w)); request["h"] = .int(Int64(h))
        }
        let t = try await running(params)
        let agent = try await uiAgent(t, op: op)
        let fields = request
        return try await observed(t, op: op, options) {
            let r = try await self.uiCall(agent, "win.action", fields, vm: t.name, op: op)
            var out: [String: JSON] = ["window": r["window"] ?? .null]
            if let closed = r["closed"] { out["closed"] = closed }
            return out
        }
    }

    // MARK: - tree, find, text

    private func uiTree(_ params: JSON) async throws -> JSON {
        let op = "vm.ui.tree"
        var request: [String: JSON] = [:]
        try pass(params, "window", to: &request, where: isString)
        try pass(params, "root", to: &request, where: isString)
        try pass(params, "depth", to: &request, type: .integer)
        try pass(params, "max", to: &request, type: .integer)
        try pass(params, "filter", to: &request, where: isString)
        if let depth = request["depth"]?.intValue, depth < 0 { throw ControlError.failed("depth must be 0 or more") }
        if let max = request["max"]?.intValue, !(1...2000).contains(max) { throw ControlError.failed("max must be between 1 and 2000") }
        if let filter = request["filter"]?.stringValue, filter != "interactive", filter != "all" {
            throw ControlError.failed("filter must be 'interactive' or 'all'")
        }
        let t = try await running(params)
        let agent = try await uiAgent(t, op: op)
        let r = try await uiCall(agent, "ui.tree", request, vm: t.name, op: op)
        let nodes = r["nodes"]?.arrayValue ?? []
        var out: [String: JSON] = ["tree": .string(UITreeText.render(nodes)), "count": .int(Int64(nodes.count)),
                                   "truncated": .bool(r["truncated"]?.boolValue ?? false)]
        if let window = r["window"] { out["window"] = window }
        return .object(out)
    }

    private func uiFind(_ params: JSON) async throws -> JSON {
        let op = "vm.ui.find"
        var request = try elementFields(params)
        let byRef = request["ref"] != nil
        if let limit = try optional(params, "limit", .integer) {
            guard let n = limit.intValue, n >= 1 else { throw ControlError.failed("limit must be 1 or more") }
            if !byRef { request["limit"] = limit }
        }
        let t = try await running(params)
        let agent = try await uiAgent(t, op: op)
        if byRef {
            let nodes = [try await uiCall(agent, "ui.rect", request, vm: t.name, op: op)["node"]].compactMap { $0 }
            return ["nodes": .array(nodes), "text": .string(UITreeText.render(nodes))]
        }
        let r = try await uiCall(agent, "ui.find", request, vm: t.name, op: op)
        let nodes = r["nodes"]?.arrayValue ?? []
        guard r["truncated"]?.boolValue == true else {
            return ["nodes": .array(nodes), "text": .string(UITreeText.render(nodes))]
        }
        let note = "… the search ran out of time after these matches; add window or role to the selector, or read a part with vm.ui.tree and root"
        return ["nodes": .array(nodes), "text": .string(UITreeText.render(nodes) + "\n" + note), "truncated": true]
    }

    private func uiText(_ params: JSON) async throws -> JSON {
        let op = "vm.ui.text"
        var request = try elementFields(params)
        try pass(params, "mode", to: &request, where: isString)
        try pass(params, "offset", to: &request, type: .integer)
        try pass(params, "length", to: &request, type: .integer)
        if let mode = request["mode"]?.stringValue, !ControlHandler.textModes.contains(mode) {
            throw ControlError.failed("mode must be one of \(ControlHandler.textModes.joined(separator: ", "))")
        }
        if let offset = request["offset"]?.intValue, offset < 0 { throw ControlError.failed("offset must be 0 or more") }
        if let length = request["length"]?.intValue, !(1...200_000).contains(length) {
            throw ControlError.failed("length must be between 1 and 200000")
        }
        let t = try await running(params)
        let agent = try await uiAgent(t, op: op)
        return pick(try await uiCall(agent, "ui.text", request, vm: t.name, op: op), ["text", "total", "source"])
    }

    // MARK: - click, type, action

    private func uiClick(_ params: JSON) async throws -> JSON {
        let op = "vm.ui.click"
        let options = try observeOptions(params)
        let element = try elementFields(params)
        _ = try button(params["button"]?.stringValue)
        var click: [String: JSON] = [:]
        try pass(params, "button", to: &click, where: isString)
        try pass(params, "count", to: &click, type: .integer)
        let t = try await running(params)
        let agent = try await uiAgent(t, op: op)
        let extra = click
        return try await observed(t, op: op, options) {
            let target = try await self.clickPoint(agent, element, vm: t.name, op: op)
            var input = extra
            input["x"] = .int(Int64(target.x)); input["y"] = .int(Int64(target.y))
            try await self.send("vm.mouse.click", to: t, .object(input))
            return ["x": .int(Int64(target.x)), "y": .int(Int64(target.y)), "node": target.node]
        }
    }

    private func uiType(_ params: JSON) async throws -> JSON {
        let op = "vm.ui.type"
        let options = try observeOptions(params)
        let element = try elementFields(params)
        let text = try string(params, "text")
        let clear = try optional(params, "clear", .boolean)?.boolValue ?? false
        let submit = try optional(params, "submit", .boolean)?.boolValue ?? false
        let t = try await running(params)
        let agent = try await uiAgent(t, op: op)
        return try await observed(t, op: op, options) {
            let target = try await self.clickPoint(agent, element, vm: t.name, op: op)
            try await self.send("vm.mouse.click", to: t, ["x": .int(Int64(target.x)), "y": .int(Int64(target.y))])
            try await Task.sleep(for: UITiming.focusDelay)
            if clear { try await self.send("vm.key.press", to: t, ["keys": "ctrl+a"]) }
            if !text.isEmpty {
                try await self.send("vm.type", to: t, ["text": .string(text)])
            } else if clear {
                try await self.send("vm.key.press", to: t, ["keys": "backspace"])
            }
            if submit { try await self.send("vm.key.press", to: t, ["keys": "enter"]) }
            return ["node": target.node]
        }
    }

    private func uiAction(_ params: JSON) async throws -> JSON {
        let op = "vm.ui.action"
        let options = try observeOptions(params)
        var request = try elementFields(params)
        guard let action = params["action"]?.stringValue, ControlHandler.elementActions.contains(action) else {
            throw ControlError.failed("action must be one of \(ControlHandler.elementActions.joined(separator: ", "))")
        }
        request["action"] = .string(action)
        try pass(params, "value", to: &request, where: isString)
        if action == "set_value", request["value"] == nil { throw ControlError.failed("set_value needs a string 'value'; pass the new text") }
        let t = try await running(params)
        let agent = try await uiAgent(t, op: op)
        let fields = request
        return try await observed(t, op: op, options) {
            let r = try await self.uiCall(agent, "ui.act", fields, vm: t.name, op: op)
            var out: [String: JSON] = ["node": r["node"] ?? .null]
            for key in ["unresponsive", "gone", "pending"] { if let flag = r[key] { out[key] = flag } }
            return out
        }
    }

    // MARK: - launch

    /// The `waitWindow` parameter in milliseconds: `fallback` seconds when absent, otherwise 0 to 300 seconds.
    nonisolated func waitWindowMilliseconds(_ params: JSON, default fallback: Double) throws -> Int {
        guard let value = params["waitWindow"], value != .null else { return Int((fallback * 1000).rounded()) }
        guard let seconds = value.doubleValue, (0...ControlHandler.maxWaitWindowSeconds).contains(seconds) else {
            throw ControlError.failed("waitWindow must be between 0 and \(Int(ControlHandler.maxWaitWindowSeconds)) seconds")
        }
        return Int((seconds * 1000).rounded())
    }

    /// `app.launch` with `request` and a window wait of `waitMs`; the agent call outlasts the wait by 30 s.
    /// The result holds `pid`, the `window` that appeared, or `windowTimedOut` when one was waited for and none appeared.
    func launch(_ agent: AgentClient, _ request: [String: JSON], waitMs: Int) async throws -> JSON {
        var fields = request
        fields["wait_window_ms"] = .int(Int64(waitMs))
        let r = try await agent.call("app.launch", fields, timeout: .milliseconds(waitMs + 30_000))
        var out: [String: JSON] = [:]
        if let pid = r["pid"] { out["pid"] = pid }
        if let window = r["window"], window != .null {
            out["window"] = window
        } else if waitMs > 0 {
            out["windowTimedOut"] = true
        }
        return .object(out)
    }

    private func launchApp(_ params: JSON) async throws -> JSON {
        let op = "vm.app.launch"
        guard let path = params["path"]?.stringValue, !path.isEmpty else { throw ControlError.missing("path") }
        var request: [String: JSON] = ["path": .string(path)]
        try pass(params, "args", to: &request) { $0.arrayValue.map { $0.allSatisfy(isString) } ?? false }
        try pass(params, "cwd", to: &request, where: isString)
        try pass(params, "env", to: &request) { $0.objectValue.map { $0.values.allSatisfy(isString) } ?? false }
        let waitMs = try waitWindowMilliseconds(params, default: ControlHandler.defaultLaunchWaitSeconds)
        let t = try await running(params)
        let agent = try await tools(t)
        do { return try await launch(agent, request, waitMs: waitMs) } catch { throw agentFailure(error, vm: t.name, op: op) }
    }

    // MARK: - events

    func guestEvents(_ params: JSON) async throws -> JSON {
        var since = 0
        if let value = params["since"], value != .null {
            guard let n = value.intValue, n >= 0 else {
                throw ControlError.failed("since must be an integer of 0 or more; pass the next value of an earlier vm.events reply")
            }
            since = n
        }
        let t = try await target(params)
        _ = await t.agent(timeout: .zero)
        var batch = await t.events(since: since)
        if since > batch.next { batch = await t.events(since: 0) }
        return ["events": .array(batch.events.map(\.json)), "next": .int(Int64(batch.next)), "first": .int(Int64(batch.first))]
    }

    /// The observation lines of `events`: the newest `maxObservedEvents`, preceded by a count of the ones left out.
    static func eventLines(_ events: [GuestEvent]) -> [String] {
        let shown = events.suffix(maxObservedEvents)
        var lines = shown.map(eventLine)
        if events.count > shown.count { lines.insert("\(events.count - shown.count) earlier events; call vm.events", at: 0) }
        return lines
    }

    /// The event name followed by its window title in quotes (the window's process when the title is empty), or by the
    /// file name of its `path` or its `job`, and by `code <n>` when it has a code; `events.dropped (<count>)` for the
    /// event that counts the events a connection lost.
    static func eventLine(_ event: GuestEvent) -> String {
        if event.name == "events.dropped", let count = event.payload["count"]?.intValue { return "\(event.name) (\(count))" }
        var line = event.name
        if let title = event.windowTitle {
            let process = title.isEmpty ? event.payload["window"]?["process"]?.stringValue : nil
            line += " " + (process ?? UITreeText.quoted(title))
        } else if let path = event.payload["path"]?.stringValue, let file = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last {
            line += " " + file
        } else if let job = event.payload["job"]?.stringValue {
            line += " " + job
        }
        if let code = event.payload["code"]?.intValue { line += " code \(code)" }
        return line
    }

    // MARK: - observation

    static let busyHelperFacts = "the UI helper is busy with another request; call vm.ui.tree when you need the tree"

    /// What one helper call with a budget brought.
    enum Fact {
        case answer(JSON)
        /// The call did not end within the budget.
        case late
        case failed(Error)
    }

    /// One helper call in a task of its own. `end` is the latest moment its turn at the helper may come and the
    /// moment the caller stops waiting for it.
    nonisolated func fact(_ agent: AgentClient, _ agentOp: String, _ fields: [String: JSON], vm: String,
                                  by end: ContinuousClock.Instant) async -> Fact {
        let probe = startHelperCall(agent, agentOp, fields, vm: vm, turnBy: end)
        guard let outcome = await probe.answer.outcome(until: end, expiry: { await UITiming.factBudgetEnd(end) }) else {
            probe.abandon()
            return .late
        }
        switch outcome.result {
        case .success(let reply): return .answer(reply)
        case .failure(let error): return error is HelperBusy ? .late : .failed(error)
        }
    }

    /// One helper call that is made only when the UI helper of `vm` is free at this moment: `.late`, with nothing
    /// sent, when another call has the helper or the task is cancelled. The call runs in a task of its own and keeps
    /// the helper until the agent answered; `answered` runs with its outcome before the helper is given to the next
    /// caller. The caller stops waiting `patience` after the helper was taken.
    nonisolated func factAtOnce(_ agent: AgentClient, _ agentOp: String, _ fields: [String: JSON], vm: String, patience: Duration,
                                answered: (@Sendable (Result<JSON, Error>) async -> Void)? = nil) async -> Fact {
        guard (try? await helperGate.acquire(vm, until: .now)) == true else { return .late }
        guard !Task.isCancelled else {
            await helperGate.release(vm)
            return .late
        }
        let end = ContinuousClock.now + patience
        let answer = HelperAnswer()
        Task {
            _ = try? await self.takenTurn(agent, agentOp, fields, vm: vm, answered: { result in
                await answered?(result)
                await answer.finish(result)
            })
        }
        guard let outcome = await answer.outcome(until: end, expiry: { await UITiming.factBudgetEnd(end) }) else { return .late }
        switch outcome.result {
        case .success(let reply): return .answer(reply)
        case .failure(let error): return .failed(error)
        }
    }

    static let agentNotConnectedYet = "the guest tools are not connected yet; the next observation will carry the UI facts"
    static let agentNotConnected = "the guest tools are not connected; UI facts need alcove-agent running in the guest"

    /// Adds the foreground window title, the focused element, the events since the VM's previous observation and,
    /// at level `ui`, the tree of the foreground window. Needs a connected agent with the `ui` capability; without one
    /// only level `ui` says so in `uiError`: the agent is being connected, is not connected, or has no UI Automation.
    /// The agent and that sentence come from one reading of the VM's agent connection.
    /// The helper calls share one budget counted from the start: `UITiming.factBudget`, or `UITiming.treeFactBudget`
    /// at level `ui`; what did not arrive within it is left out and `uiError` says the helper is busy. With
    /// `helperTaken` no helper call is made and `uiError` says the same at once.
    func addUIFacts(to observation: inout ScreenObservation, _ t: VMTarget, level: ObserveLevel, helperTaken: Bool = false) async {
        let end = ContinuousClock.now + (level == .ui ? UITiming.treeFactBudget : UITiming.factBudget)
        let agent: AgentClient
        switch await t.agentLink() {
        case .connected(let client):
            agent = client
        case .connecting:
            if level == .ui { observation.uiError = ControlHandler.agentNotConnectedYet }
            return
        case .notConnected:
            if level == .ui { observation.uiError = ControlHandler.agentNotConnected }
            return
        }
        guard let hello = await agent.hello, hello.rpcVersion >= 2, hello.capabilities.contains("ui") else {
            if level == .ui { observation.uiError = ControlError.noUI(t.name).description }
            return
        }
        switch helperTaken ? Fact.late : await fact(agent, "ui.focused", [:], vm: t.name, by: end) {
        case .answer(let r):
            observation.foreground = r["window"]?["title"]?.stringValue
            observation.focused = r["node"].map(UITreeText.label)
        case .late:
            observation.uiError = ControlHandler.busyHelperFacts
        case .failed(let error):
            let reason = agentFailure(error, vm: t.name, op: "the observation").description
            observation.uiError = "the foreground window and focused element could not be read: \(reason)"
        }
        if level == .ui, observation.uiError == nil {
            let request: [String: JSON] = ["window": "foreground", "max": .int(Int64(ControlHandler.observedTreeNodes))]
            switch await fact(agent, "ui.tree", request, vm: t.name, by: end) {
            case .answer(let r):
                var text = UITreeText.render(r["nodes"]?.arrayValue ?? [])
                if r["truncated"]?.boolValue == true { text += "\n… more elements; call vm.ui.tree to read the whole window" }
                observation.tree = text
                if observation.foreground == nil { observation.foreground = r["window"]?["title"]?.stringValue }
            case .late:
                observation.uiError = ControlHandler.busyHelperFacts
            case .failed(let error):
                let reason = agentFailure(error, vm: t.name, op: "the observation").description
                observation.uiError = "the UI tree could not be read: \(reason)"
            }
        }
        let known = observedEvents[t.name] != nil || eventBaseline[t.name] != nil
        let cursor = position(in: observedEvents, of: t) ?? position(in: eventBaseline, of: t) ?? (known ? 0 : .max)
        let batch = await t.events(since: cursor)
        advanceObservedEvents(of: t, to: batch.next)
        observation.events = ControlHandler.eventLines(batch.events)
    }

    // MARK: - screenshot

    /// The window and elements `vm.screenshot` asked for with `window` and `marks`; empty without either.
    /// `window` together with an explicit region is refused.
    func screenshotView(_ t: VMTarget, _ params: JSON, hasRegion: Bool) async throws -> ScreenshotView {
        let op = "vm.screenshot"
        var spec: String?
        if let value = params["window"], value != .null {
            guard let text = value.stringValue, !text.isEmpty else { throw ControlError.missing("window") }
            spec = text
        }
        let marks = try optional(params, "marks", .boolean)?.boolValue ?? false
        guard spec != nil || marks else { return ScreenshotView() }
        if spec != nil, hasRegion {
            throw ControlError.failed("pass region or window, not both; region is a rectangle of the frame, window crops to a window's rectangle")
        }
        let agent = try await uiAgent(t, op: op)
        var view = ScreenshotView()
        if let spec {
            let windows = try await uiCall(agent, "win.list", [:], vm: t.name, op: op)["windows"]?.arrayValue ?? []
            guard let window = ControlHandler.window(matching: spec, in: windows) else {
                throw ControlError.failed("no window matches '\(spec)'; call vm.window.list")
            }
            view.window = window
        }
        if marks {
            let request: [String: JSON] = ["window": view.window?["id"] ?? "foreground", "filter": "interactive", "max": 300]
            let tree = try await uiCall(agent, "ui.tree", request, vm: t.name, op: op)
            view.nodes = tree["nodes"]?.arrayValue ?? []
            view.nodesTruncated = tree["truncated"]?.boolValue ?? false
        }
        return view
    }

    /// The window `spec` names: `foreground`, a window id, or a part of a title (the foreground window first among several).
    /// Ids and titles compare without regard to case.
    static func window(matching spec: String, in windows: [JSON]) -> JSON? {
        let wanted = spec.lowercased()
        if wanted == "foreground" { return windows.first { $0["foreground"]?.boolValue == true } }
        if let byID = windows.first(where: { $0["id"]?.stringValue?.lowercased() == wanted }) { return byID }
        let titled = windows.filter { $0["title"]?.stringValue?.range(of: spec, options: .caseInsensitive) != nil }
        return titled.first { $0["foreground"]?.boolValue == true } ?? titled.first
    }

    /// The part of `frame` that `window` covers.
    nonisolated func windowArea(_ window: JSON, in frame: Frame) throws -> Frame.Rect {
        guard window["state"]?.stringValue != "minimized",
              let x = window["x"]?.intValue, let y = window["y"]?.intValue, let w = window["w"]?.intValue, let h = window["h"]?.intValue,
              let area = frame.clamp(Frame.Rect(x: x, y: y, w: w, h: h)) else {
            let title = window["title"]?.stringValue ?? window["id"]?.stringValue ?? ""
            throw ControlError.failed("window '\(title)' is minimized or has no area on the \(frame.width)x\(frame.height) frame; call vm.window.action restore first")
        }
        return area
    }

    /// The elements of `nodes` to number: those with a control type in `markRoles`, a rectangle that is not empty and
    /// reaches into `area`, and without the `offscreen` flag; at most `maxMarks`, numbered from 1 in tree order.
    /// `more` says whether further such elements were left without a number.
    static func marks(for nodes: [JSON], in area: Frame.Rect) -> (marks: [UIMark], more: Bool) {
        var marks: [UIMark] = []
        for node in nodes {
            guard let role = node["role"]?.stringValue, markRoles.contains(role.lowercased()),
                  let x = node["x"]?.intValue, let y = node["y"]?.intValue, let w = node["w"]?.intValue, let h = node["h"]?.intValue,
                  w > 0, h > 0, !(node["flags"]?.arrayValue ?? []).contains("offscreen") else { continue }
            let rect = Frame.Rect(x: x, y: y, w: w, h: h)
            guard rect.intersects(area) else { continue }
            guard marks.count < maxMarks else { return (marks, true) }
            marks.append(UIMark(number: marks.count + 1, node: node, rect: rect))
        }
        return (marks, false)
    }
}
