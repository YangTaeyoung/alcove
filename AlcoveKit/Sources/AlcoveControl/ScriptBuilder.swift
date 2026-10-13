import Foundation
import AlcoveQMP

/// Turns the lines of a recording's trace into a script.
enum ScriptBuilder {
    /// A script built from a trace, and what its reader should know about the lines it could not turn into steps as they are.
    struct Draft: Sendable, Equatable {
        var script: Script
        /// One sentence per trace line that was left out or whose step needs a change by hand; each starts with `seq <n> (<op>)`.
        var warnings: [String]
        /// The `seq` of the trace line each step was made from, in step order.
        var sources: [Int] = []
        /// The variables the steps read and the script gives no value for, in the order the steps first read them.
        var required: [String] = []
    }

    /// The read-only ops that become steps.
    static let keptReadOnlyOps: Set<String> = ["vm.wait_for", "vm.wait_idle"]
    /// The most characters of typed text, a command or a path a label shows.
    static let labelTextLimit = 40
    /// The most characters of a label.
    static let labelLimit = 80

    /// Steps from trace entries `from...to` (inclusive `seq`, defaults: all).
    static func build(trace: [JSON], vm: String, from: Int?, to: Int?) -> Script {
        draft(trace: trace, vm: vm, from: from, to: to).script
    }

    /// The script of the trace entries with a `seq` in `from...to`, for the VM `vm`, and the warnings about them.
    ///
    /// An entry becomes a step when it succeeded, was sent by a client or made by a script run as a step (`script`
    /// absent or `step`), and its op is one a script may run that is not read-only, or `vm.wait_for` that matched a
    /// condition, or `vm.wait_idle`. The step's params are the entry's without `name`, also in the steps of a `vm.batch`,
    /// with `${` escaped in every string.
    /// - A `vm.mouse.click` whose `target` has a name or an automation id and that has no `hold` becomes `vm.ui.click`
    ///   with the selector of that target and `fallback: {x, y}`.
    /// - A `vm.ui.*` entry that named its element by ref uses the selector of the entry's `selector` in place of the ref;
    ///   without a name and an automation id there, a `vm.ui.click` becomes a `vm.mouse.click` at the point it clicked
    ///   and any other op is left out with a warning.
    /// - A `vm.window.action` on a window id names the window by the title in its result; without one it is left out
    ///   with a warning, as is a `vm.wait_for` with a condition that names its element by ref. A selector a client
    ///   passed to a `vm.ui.*` op loses a window id, with a warning.
    /// - A `vm.type` step directly after a `vm.type` step with the same other params and no expectation adds its text to that step.
    /// - A step whose entry shows a foreground window title other than the one the entries before it showed last
    ///   expects a window with that title.
    /// - An env value the trace masks becomes a variable named after its key; it, a string the trace cut and a step that
    ///   names a job id or a pid are reported in the warnings.
    /// Every step has the label `<op> <what it acts on>`; the label of a `vm.type` step that follows a click or UI op
    /// on a password field does not show the text.
    static func draft(trace: [JSON], vm: String, from: Int?, to: Int?) -> Draft {
        var assembly = Assembly(from: from, to: to)
        for entry in trace { assembly.add(entry) }
        return assembly.draft(vm: vm)
    }

    /// Builds a draft from trace entries given one at a time, in the order of the trace. Of an entry outside
    /// `from...to` it keeps the foreground window title it shows and nothing else.
    struct Assembly {
        private let from: Int?
        private let to: Int?
        private var pending: [Pending] = []
        private var warnings: [String] = []
        private var required: [String] = []
        private var foreground: String?
        private var intoPassword = false
        /// The VM the first entry with a VM name names.
        private(set) var recordedVM: String?

        /// An assembly of the entries with a `seq` in `from...to`; nil leaves that side open.
        init(from: Int?, to: Int?) {
            self.from = from
            self.to = to
        }

        /// The draft of the entries added so far, as a script for the VM `vm`.
        func draft(vm: String) -> Draft {
            let steps = pending.map { item -> Script.Step in
                var step = item.step
                if let text = item.text { step.params["text"] = .string(Script.escape(text)) }
                step.label = label(item)
                return step
            }
            return Draft(script: Script(vm: vm, variables: [:], steps: steps), warnings: warnings, sources: pending.map(\.seq), required: required)
        }

        /// Takes one trace entry into account; `draft(trace:vm:from:to:)` says what becomes of it.
        mutating func add(_ entry: JSON) {
            guard let seq = entry["seq"]?.intValue, let op = entry["op"]?.stringValue else { return }
            if recordedVM == nil, let name = entry["params"]?["name"]?.stringValue, !name.isEmpty { recordedVM = name }
            guard entry["ok"]?.boolValue == true else { return }
            if let to, seq > to { return }
            let shown = shownForeground(entry)
            defer { if let shown { foreground = shown } }
            if let from, seq < from { return }
            if let role = entry["script"], role != .null, role.stringValue != ScriptCall.step.rawValue { return }
            guard Script.allows(op: op), ControlHandler.knownOps.contains(op),
                  !ControlHandler.isReadOnly(op: op) || keptReadOnlyOps.contains(op) else { return }
            var params = entry["params"]?.objectValue ?? [:]
            params["name"] = nil
            params["lease"] = nil
            let line = "seq \(seq) (\(op))"
            var item = Pending(seq: seq, step: Script.Step(label: nil, op: op, params: params, expect: [], timeout: Script.defaultTimeout))

            switch op {
            case "vm.batch":
                if let steps = params["steps"]?.arrayValue {
                    item.step.params["steps"] = .array(steps.map { step in
                        guard var fields = step.objectValue else { return step }
                        fields["name"] = nil
                        return .object(fields)
                    })
                }
            case "vm.wait_for":
                guard entry["result"]?["matched"]?.intValue != -1 else { return }
                if (params["conditions"]?.arrayValue ?? []).contains(where: { ($0["ref"] ?? .null) != .null }) {
                    warnings.append("\(line) is left out: a condition names its element by ref; add the step by hand with selector fields")
                    return
                }
            case "vm.mouse.click", "vm.mouse.drag":
                let facts = entry["target"]
                intoPassword = facts?["password"]?.boolValue == true
                if let selector = selector(from: facts) {
                    item.subject = describe(selector)
                    if op == "vm.mouse.click", params["hold"] == nil, let x = params["x"]?.intValue, let y = params["y"]?.intValue {
                        item.step.op = "vm.ui.click"
                        item.step.params["x"] = nil
                        item.step.params["y"] = nil
                        item.step.params["selector"] = .object(selector)
                        item.step.params["fallback"] = ["x": .int(Int64(x)), "y": .int(Int64(y))]
                    }
                }
            case "vm.ui.click", "vm.ui.type", "vm.ui.action":
                guard let ref = params["ref"], ref != .null else {
                    intoPassword = false
                    if var given = params["selector"]?.objectValue, let window = given["window"]?.stringValue, isWindowID(window) {
                        given["window"] = nil
                        item.step.params["selector"] = .object(given)
                        warnings.append("\(line): its selector named the window by id; the step looks in the foreground window, add a title part by hand")
                    }
                    break
                }
                let facts = entry["selector"]
                intoPassword = facts?["password"]?.boolValue == true
                item.step.params["ref"] = nil
                if let selector = selector(from: facts) {
                    item.step.params["selector"] = .object(selector)
                } else if op == "vm.ui.click", let x = entry["result"]?["x"]?.intValue, let y = entry["result"]?["y"]?.intValue {
                    item.step.op = "vm.mouse.click"
                    item.step.params["x"] = .int(Int64(x))
                    item.step.params["y"] = .int(Int64(y))
                } else {
                    warnings.append("\(line) is left out: its element was named by ref and has neither a name nor an automation id; add the step by hand with a selector")
                    return
                }
            case "vm.window.action":
                if let window = params["window"]?.stringValue, isWindowID(window) {
                    guard let title = entry["result"]?["window"]?["title"]?.stringValue, !title.isEmpty, isTitlePart(title) else {
                        warnings.append("\(line) is left out: its window was named by id and the trace holds no title for it; add the step by hand with a title part")
                        return
                    }
                    item.step.params["window"] = .string(title)
                }
            case "vm.type":
                item.hidesText = intoPassword
                item.text = params["text"]?.stringValue
            default:
                break
            }

            if let id = sessionID(op: op, params: params) {
                warnings.append("\(line): its \(id) belongs to the recorded session and a replay gets another one; change the step by hand")
            }
            if item.subject == nil { item.subject = subject(of: item.step) }
            item.step.params = prepared(item.step.params, inEnv: false, line: line, warnings: &warnings, required: &required)
            if let shown, let previous = foreground, shown != previous {
                item.step.expect = [["type": "window_title", "contains": .string(Script.escape(shown))]]
            }
            if let text = item.text, let last = pending.last, let before = last.text, last.step.op == "vm.type", last.step.expect.isEmpty,
               last.hidesText == item.hidesText, last.step.params.filter({ $0.key != "text" }) == item.step.params.filter({ $0.key != "text" }) {
                pending[pending.count - 1].text = before + text
                pending[pending.count - 1].step.expect = item.step.expect
                return
            }
            pending.append(item)
        }
    }

    /// The selector fields for an element a trace line describes as `{window?, role, name, aid?}`: `name` and
    /// `automationId` when the line holds them in full and not empty, with `role`, and with `window` when the title
    /// reads as a title part. Nil when the line holds neither a name nor an automation id.
    static func selector(from facts: JSON?) -> [String: JSON]? {
        guard let facts else { return nil }
        func whole(_ key: String) -> String? {
            guard let text = facts[key]?.stringValue, !text.isEmpty, facts["\(key)Truncated"]?.boolValue != true else { return nil }
            return text
        }
        var selector: [String: JSON] = [:]
        if let name = whole("name") { selector["name"] = .string(name) }
        if let aid = whole("aid") { selector["automationId"] = .string(aid) }
        guard !selector.isEmpty else { return nil }
        if let role = whole("role") { selector["role"] = .string(role) }
        if let title = whole("window"), isTitlePart(title) { selector["window"] = .string(title) }
        return selector
    }

    // MARK: - parts of a step

    /// A step being built.
    private struct Pending {
        /// The `seq` of the trace line the step is made from.
        var seq: Int
        var step: Script.Step
        /// The typed text of a `vm.type` step, unescaped.
        var text: String?
        /// Whether the label leaves the typed text out.
        var hidesText = false
        /// What the label names after the op.
        var subject: String?
    }

    /// Whether the agent reads `window` as a window id.
    private static func isWindowID(_ window: String) -> Bool { window.lowercased().hasPrefix("0x") }

    /// Whether the agent reads `window` as a part of a title: it is neither a window id nor the word `foreground`.
    private static func isTitlePart(_ window: String) -> Bool { !isWindowID(window) && window != "foreground" }

    /// What `params` of `op` name that only the recorded session has: the `job id` of `vm.exec.write`, `vm.exec.kill`
    /// or a wait condition, the `pid` of `vm.process.kill` or a wait condition; nil without one.
    private static func sessionID(op: String, params: [String: JSON]) -> String? {
        func has(_ key: String, in fields: JSON) -> Bool { (fields[key] ?? .null) != .null }
        switch op {
        case "vm.exec.write", "vm.exec.kill": return has("job", in: .object(params)) ? "job id" : nil
        case "vm.process.kill": return has("pid", in: .object(params)) ? "pid" : nil
        case "vm.wait_for":
            let conditions = params["conditions"]?.arrayValue ?? []
            if conditions.contains(where: { has("job", in: $0) }) { return "job id" }
            return conditions.contains(where: { has("pid", in: $0) }) ? "pid" : nil
        default: return nil
        }
    }

    /// The foreground window title in the observation of `entry`; nil without one, for an empty one and for one the trace cut.
    private static func shownForeground(_ entry: JSON) -> String? {
        guard let observation = entry["result"]?["observation"], let title = observation["foreground"]?.stringValue, !title.isEmpty,
              observation["foregroundTruncated"]?.boolValue != true else { return nil }
        return title
    }

    /// `fields` as a step holds them: every string with `${` escaped, without the marker of a string the trace cut,
    /// and with `${<key>}` in place of an env value the trace masks. `warnings` gains a sentence per cut string and
    /// per masked value, in key order; `required` gains the key of each masked value it does not hold yet.
    private static func prepared(_ fields: [String: JSON], inEnv: Bool, line: String, warnings: inout [String],
                                 required: inout [String]) -> [String: JSON] {
        var out: [String: JSON] = [:]
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            if key.hasSuffix(TraceSanitizer.cutMarkerSuffix), value == true,
               let cut = fields[String(key.dropLast(TraceSanitizer.cutMarkerSuffix.count))]?.stringValue,
               cut.count == TraceSanitizer.maxStringLength + 1, cut.hasSuffix("…") {
                let name = key.dropLast(TraceSanitizer.cutMarkerSuffix.count)
                warnings.append("\(line): the trace holds only the first \(TraceSanitizer.maxStringLength) characters of '\(name)'; write the full value into the step by hand")
                continue
            }
            if inEnv, value == .string(TraceSanitizer.mask), TraceSanitizer.isSecret(key), !key.contains("}") {
                out[key] = .string("${\(key)}")
                if !required.contains(key) { required.append(key) }
                warnings.append("\(line): the trace masks the env value '\(key)'; the step reads it from the variable '\(key)', pass it in variables when running the script")
                continue
            }
            switch value {
            case .string(let text): out[key] = .string(Script.escape(text))
            case .object(let inner): out[key] = .object(prepared(inner, inEnv: key == "env", line: line, warnings: &warnings, required: &required))
            case .array(let items): out[key] = .array(items.map { prepared(item: $0, line: line, warnings: &warnings, required: &required) })
            default: out[key] = value
            }
        }
        return out
    }

    private static func prepared(item: JSON, line: String, warnings: inout [String], required: inout [String]) -> JSON {
        switch item {
        case .string(let text): return .string(Script.escape(text))
        case .object(let inner): return .object(prepared(inner, inEnv: false, line: line, warnings: &warnings, required: &required))
        case .array(let items): return .array(items.map { prepared(item: $0, line: line, warnings: &warnings, required: &required) })
        default: return item
        }
    }

    // MARK: - labels

    /// `<op> <subject>`, cut at `labelLimit` characters; the op alone without a subject. The subject of a `vm.type`
    /// step is its text in quotes, or `into a password field`.
    private static func label(_ item: Pending) -> String {
        var subject = item.subject
        if item.step.op == "vm.type" {
            subject = item.hidesText ? "into a password field" : item.text.map { UITreeText.quoted(short($0)) }
        }
        let full = [item.step.op, subject ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return full.count > labelLimit ? String(full.prefix(labelLimit)) + "…" : full
    }

    /// `text`, or its first `labelTextLimit` characters followed by `…` when it is longer.
    private static func short(_ text: String) -> String {
        text.count > labelTextLimit ? String(text.prefix(labelTextLimit)) + "…" : text
    }

    /// An element as a label names it: the role, then the name (or the name part) in quotes, or `#` and the automation id.
    private static func describe(_ selector: [String: JSON]) -> String {
        var parts: [String] = []
        if let role = selector["role"]?.stringValue { parts.append(role) }
        if let name = selector["name"]?.stringValue ?? selector["nameContains"]?.stringValue {
            parts.append(UITreeText.quoted(short(name)))
        } else if let aid = selector["automationId"]?.stringValue {
            parts.append("#" + short(aid))
        }
        return parts.joined(separator: " ")
    }

    /// What the label of `step` names after the op, read from its unescaped params; nil when the op has nothing to name.
    private static func subject(of step: Script.Step) -> String? {
        let params = step.params
        func text(_ key: String) -> String? { params[key]?.stringValue.map { short($0.split(whereSeparator: \.isNewline).first.map(String.init) ?? "") } }
        func point(_ x: String, _ y: String) -> String? {
            guard let px = params[x]?.intValue, let py = params[y]?.intValue else { return nil }
            return "(\(px), \(py))"
        }
        func words(_ parts: [String?]) -> String? {
            let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
            return present.isEmpty ? nil : present.joined(separator: " ")
        }
        let element = params["selector"]?.objectValue.map(describe)
        switch step.op {
        case "vm.ui.click", "vm.ui.type": return element
        case "vm.ui.action": return words([text("action"), element])
        case "vm.mouse.drag": return words([point("fromX", "fromY"), point("toX", "toY").map { "to " + $0 }])
        case "vm.key.press": return text("keys")
        case "vm.key.down", "vm.key.up": return text("key")
        case "vm.window.action": return words([text("action"), params["window"]?.stringValue.map { UITreeText.quoted(short($0)) }])
        case "vm.wait_for": return words([(params["conditions"]?.arrayValue ?? []).compactMap { $0["type"]?.stringValue }.joined(separator: ", ")])
        case "vm.exec", "vm.exec.start": return text("command") ?? params["argv"]?[0]?.stringValue.map(short)
        case "vm.app.launch", "vm.deploy", "vm.push_file", "vm.sync_dir":
            return params["path"]?.stringValue.flatMap { $0.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last }.map { short(String($0)) }
        default:
            if step.op.hasPrefix("vm.mouse.") { return point("x", "y") }
            return text("snapshot") ?? text("guestPath") ?? text("path") ?? text("job")
        }
    }
}
