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
    /// with `${` escaped in every string and without the `since` of an `event` wait condition.
    /// - A `vm.mouse.click` without `hold` whose `target` passes `replaysAtCentre` and has `selectors` becomes
    ///   `vm.ui.click` with `selector`, with `altSelector` when there is one, and with `fallback: {x, y}`.
    /// - A `vm.ui.*` entry that named its element by ref uses the `selectors` of its `target` in place of the ref;
    ///   without them a `vm.ui.click` becomes a `vm.mouse.click` at the point it clicked and any other op is left out.
    /// - A `vm.window.action` on a window id names the window by the title in its result; without one it is left out.
    ///   Left out as well are a `vm.wait_for` with a condition that names its element by ref, a `vm.batch` with a step
    ///   that holds a ref, and an entry with a param the trace cut. A selector a client passed to a `vm.ui.*` op loses
    ///   a window id.
    /// - A `vm.type` step directly after a `vm.type` step with the same other params and no expectation adds its text
    ///   to that step, unless an entry between the two was left out.
    /// - A step whose entry shows a foreground window title with another stable part than the entries before it
    ///   showed last expects a window with that part in its title.
    /// - An env value the trace masks becomes a variable named after its key.
    /// - The `text` of a `vm.ui.type` and the `value` of a `vm.ui.action` whose `target` or result node is a password
    ///   element, and the `text` of a `vm.type` when the latest entry that says what it was aimed at was aimed at a
    ///   password element, become a variable each: `password`, `password2`, and so on. Such a `vm.type` step is not merged.
    /// A `vm.key.press`, `vm.key.down` or `vm.key.up` whose keys the trace masks is left out.
    /// No variable has a default. The warnings hold a sentence for every entry left out, every selector that lost its
    /// window, every variable, every step that names a job id or a pid, every step whose selector carries an `index`, and
    /// every window part that stands for a longer title.
    /// A window title is replaced by its stable part only when no other title in the entries `from...to` show contains that
    /// part; this holds for `selector.window`, `altSelector.window`, the foreground expectation and the title that replaces
    /// a window id in `vm.window.action`.
    /// Every step has the label `<op> <what it acts on>`; the label of a `vm.type` step whose text is a variable does
    /// not show it.
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
        /// What the trace shows of each window title it holds.
        private var titles: [String: Sighting] = [:]
        /// Whether the latest entry that says what it was aimed at was aimed at a password element.
        private var passwordAimed = false
        /// The variable each masked env key is read from.
        private var envVariables: [String: String] = [:]
        /// Whether an entry was left out with a warning since the latest step was added.
        private var leftOut = false
        /// Whether the warning about the run of key steps left out since the latest step was added has been given.
        private var keysWarned = false
        /// The VM the first entry with a VM name names.
        private(set) var recordedVM: String?

        /// An assembly of the entries with a `seq` in `from...to`; nil leaves that side open.
        init(from: Int?, to: Int?) {
            self.from = from
            self.to = to
        }

        /// The draft of the entries added so far, as a script for the VM `vm`.
        func draft(vm: String) -> Draft {
            var warnings = self.warnings
            var namedParts: Set<String> = []
            var namedShared: Set<String> = []
            var steps: [Script.Step] = []
            for (offset, item) in pending.enumerated() {
                var step = item.step
                if let text = item.text { step.params["text"] = .string(Script.escape(text)) }
                if let secret = item.secret { step.params[secret.param] = .string("${\(secret.variable)}") }
                for use in item.windows {
                    let name = windowName(use.title, onlyTitleParts: use.place != .expectation)
                    let escaped = JSON.string(Script.escape(name))
                    switch use.place {
                    case .selector, .altSelector:
                        let key = use.place == .selector ? "selector" : "altSelector"
                        if var fields = step.params[key]?.objectValue {
                            fields["window"] = escaped
                            step.params[key] = .object(fields)
                        }
                    case .expectation:
                        step.expect = [["type": "window_title", "contains": escaped]]
                    case .windowParam:
                        step.params["window"] = escaped
                    }
                    if isShared(use.title), namedShared.insert(use.title).inserted {
                        warnings.append("steps name the window \"\(use.title)\"; more than one window had that title while recording, the first one found is used")
                    }
                    if name != use.title, namedParts.insert(name).inserted {
                        warnings.append("steps name the window \"\(name)\" by a part of its title \"\(use.title)\"; another window whose title contains \"\(name)\" would be used instead")
                    }
                }
                step.label = label(item)
                if let position = item.positions.first {
                    warnings.append("step \(offset + 1) (\(step.label ?? step.op)) selects number \(position.index + 1) of \(position.matches) elements that look the same; it replays whatever is at that position")
                }
                steps.append(step)
            }
            return Draft(script: Script(vm: vm, variables: [:], steps: steps), warnings: warnings, sources: pending.map(\.seq), required: required)
        }

        /// What a script names the window titled `title` by: the stable part of the title when no other title the
        /// trace shows contains that part (compared as the agent compares, ignoring case), the whole title otherwise.
        /// A title shown only by windows that also showed `title` is not another window's. `onlyTitleParts` makes a part
        /// that does not read as a title part give way to the whole title.
        private func windowName(_ title: String, onlyTitleParts: Bool) -> String {
            let part = ScriptBuilder.stablePart(ofTitle: title)
            guard part != title, !onlyTitleParts || ScriptBuilder.isTitlePart(part) else { return title }
            let own = titles[title]?.ids ?? []
            let other = titles.contains { entry in
                guard entry.key != title, entry.key.range(of: part, options: .caseInsensitive) != nil else { return false }
                return entry.value.hasNoID || own.isEmpty || !entry.value.ids.isSubset(of: own)
            }
            return other ? title : part
        }

        /// Whether more than one window id showed `title`.
        private func isShared(_ title: String) -> Bool { (titles[title]?.ids.count ?? 0) > 1 }

        /// Notes the window titles `entry` shows, with the window ids the trace gives for them.
        private mutating func collectTitles(_ entry: JSON) {
            func note(_ title: String?, id: String? = nil) {
                guard let title, !title.isEmpty else { return }
                var sighting = titles[title] ?? Sighting()
                if let id, !id.isEmpty { sighting.ids.insert(id) } else { sighting.hasNoID = true }
                titles[title] = sighting
            }
            func note(window: JSON?) { note(window?["title"]?.stringValue, id: window?["id"]?.stringValue) }
            note(entry["target"]?["window"]?.stringValue)
            let result = entry["result"]
            note(result?["observation"]?["foreground"]?.stringValue)
            for event in result?["observation"]?["events"]?.arrayValue ?? [] {
                if let text = event.stringValue, let title = ScriptBuilder.windowTitle(ofEvent: text) { note(title) }
            }
            note(window: result?["window"])
            for window in result?["windows"]?.arrayValue ?? [] { note(window: window) }
        }

        /// A variable no step reads yet, which becomes one of `required`: `preferred`, or `preferred` followed by the
        /// lowest number from 2 that no variable has.
        private mutating func newVariable(_ preferred: String) -> String {
            var name = preferred
            var number = 1
            while required.contains(name) {
                number += 1
                name = "\(preferred)\(number)"
            }
            required.append(name)
            return name
        }

        /// `fields` as a step holds them: every string with `${` escaped, and the variable of its key in place of an
        /// env value the trace masks, with a warning for each.
        private mutating func prepared(_ fields: [String: JSON], inEnv: Bool, line: String) -> [String: JSON] {
            var out: [String: JSON] = [:]
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                if inEnv, value == .string(TraceSanitizer.mask), TraceSanitizer.isSecret(key), !key.contains("}") {
                    let variable = envVariables[key] ?? newVariable(key)
                    envVariables[key] = variable
                    out[key] = .string("${\(variable)}")
                    warnings.append("\(line): the trace masks the env value '\(key)'; the step reads it from the variable '\(variable)', pass it in variables when running the script")
                    continue
                }
                switch value {
                case .string(let text): out[key] = .string(Script.escape(text))
                case .object(let inner): out[key] = .object(prepared(inner, inEnv: key == "env", line: line))
                case .array(let items): out[key] = .array(items.map { prepared(item: $0, line: line) })
                default: out[key] = value
                }
            }
            return out
        }

        private mutating func prepared(item: JSON, line: String) -> JSON {
            switch item {
            case .string(let text): return .string(Script.escape(text))
            case .object(let inner): return .object(prepared(inner, inEnv: false, line: line))
            case .array(let items): return .array(items.map { prepared(item: $0, line: line) })
            default: return item
            }
        }

        /// Adds the warning that the entry `line` names is left out, for `reason`.
        private mutating func leaveOut(_ line: String, _ reason: String) {
            warnings.append("\(line) is left out: \(reason)")
            leftOut = true
        }

        /// Takes one trace entry into account; `draft(trace:vm:from:to:)` says what becomes of it.
        mutating func add(_ entry: JSON) {
            guard let seq = entry["seq"]?.intValue, let op = entry["op"]?.stringValue else { return }
            if recordedVM == nil, let name = entry["params"]?["name"]?.stringValue, !name.isEmpty { recordedVM = name }
            collectTitles(entry)
            guard entry["ok"]?.boolValue == true else { return }
            if let to, seq > to { return }
            let shown = shownForeground(entry)
            defer { if let shown { foreground = ScriptBuilder.stablePart(ofTitle: shown) } }
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
                    guard !steps.contains(where: holdsRef) else {
                        leaveOut(line, "one of its steps names an element by ref; add the steps by hand with selector fields")
                        return
                    }
                    item.step.params["steps"] = .array(steps.map { step in
                        guard var fields = step.objectValue else { return step }
                        fields["name"] = nil
                        if fields["op"] == "vm.wait_for", let conditions = fields["conditions"] { fields["conditions"] = withoutCursors(conditions) }
                        return .object(fields)
                    })
                }
            case "vm.wait_for":
                guard entry["result"]?["matched"]?.intValue != -1 else { return }
                if (params["conditions"]?.arrayValue ?? []).contains(where: { ($0["ref"] ?? .null) != .null }) {
                    leaveOut(line, "a condition names its element by ref; add the step by hand with selector fields")
                    return
                }
                if let conditions = params["conditions"] { item.step.params["conditions"] = withoutCursors(conditions) }
            case "vm.mouse.click", "vm.mouse.drag":
                let facts = entry["target"]
                passwordAimed = facts?["password"]?.boolValue == true
                item.element = describe(target: facts)
                if op == "vm.mouse.click", params["hold"] == nil, let x = params["x"]?.intValue, let y = params["y"]?.intValue,
                   replaysAtCentre(facts, x: x, y: y), let found = selectors(for: facts) {
                    item.step.op = "vm.ui.click"
                    item.step.params["x"] = nil
                    item.step.params["y"] = nil
                    item.step.params["selector"] = .object(found.selector)
                    if let other = found.alt { item.step.params["altSelector"] = .object(other) }
                    item.useSelectors(found)
                    item.step.params["fallback"] = ["x": .int(Int64(x)), "y": .int(Int64(y))]
                }
            case "vm.ui.click", "vm.ui.type", "vm.ui.action":
                guard let ref = params["ref"], ref != .null else {
                    passwordAimed = ControlHandler.isPasswordNode(entry["result"]?["node"])
                    if var given = params["selector"]?.objectValue, let window = given["window"]?.stringValue, isWindowID(window) {
                        given["window"] = nil
                        item.step.params["selector"] = .object(given)
                        warnings.append("\(line): its selector named the window by id; the step looks in the foreground window, add a title part by hand")
                    }
                    break
                }
                let facts = entry["target"]
                passwordAimed = facts?["password"]?.boolValue == true
                item.element = describe(target: facts)
                item.step.params["ref"] = nil
                if let found = selectors(for: facts) {
                    item.step.params["selector"] = .object(found.selector)
                    if let other = found.alt { item.step.params["altSelector"] = .object(other) }
                    item.useSelectors(found)
                } else if op == "vm.ui.click", let x = entry["result"]?["x"]?.intValue, let y = entry["result"]?["y"]?.intValue {
                    item.step.op = "vm.mouse.click"
                    item.step.params["x"] = .int(Int64(x))
                    item.step.params["y"] = .int(Int64(y))
                } else {
                    leaveOut(line, "its element was named by ref and the trace holds no selector that finds it again; add the step by hand with a selector")
                    return
                }
            case "vm.window.action":
                if let window = params["window"]?.stringValue, isWindowID(window) {
                    guard let title = entry["result"]?["window"]?["title"]?.stringValue, !title.isEmpty, isTitlePart(title) else {
                        leaveOut(line, "its window was named by id and the trace holds no title for it; add the step by hand with a title part")
                        return
                    }
                    item.step.params["window"] = .string(title)
                    item.windows.append(WindowUse(place: .windowParam, title: title))
                }
            case "vm.key.press", "vm.key.down", "vm.key.up":
                if let param = ControlHandler.keyParam(op: op), params[param] == .string(TraceSanitizer.mask) {
                    if !keysWarned {
                        warnings.append("step \(pending.count + 1) pressed keys in a password field; type the password with vm.type and a variable instead")
                        keysWarned = true
                    }
                    leftOut = true
                    return
                }
            case "vm.type":
                if let facts = entry["target"] { passwordAimed = facts["password"]?.boolValue == true }
                item.text = params["text"]?.stringValue
            default:
                break
            }

            if let cut = cutParam(params) {
                leaveOut(line, "the trace holds only the first \(TraceSanitizer.maxStringLength) characters of '\(cut)'; add the step by hand with the full value")
                return
            }
            if let id = sessionID(op: op, params: params) {
                warnings.append("\(line): its \(id) belongs to the recorded session and a replay gets another one; change the step by hand")
            }
            if let param = ControlHandler.writtenTextParam(op: op), item.step.params[param]?.stringValue != nil,
               item.step.params[param]?.stringValue == TraceSanitizer.mask
                || (op == "vm.type" ? passwordAimed : entry["target"]?["password"]?.boolValue == true || ControlHandler.isPasswordNode(entry["result"]?["node"])) {
                let variable = newVariable("password")
                item.secret = (param, variable)
                item.text = nil
                warnings.append("\(line): its \(param) goes into a password field and is not written to the script; the step reads it from the variable '\(variable)', pass it in variables when running the script")
            }
            item.subject = subject(of: item.step, element: item.element)
            item.step.params = prepared(item.step.params, inEnv: false, line: line)
            if let shown, let previous = foreground, ScriptBuilder.stablePart(ofTitle: shown) != previous {
                item.step.expect = [["type": "window_title", "contains": .string(Script.escape(ScriptBuilder.stablePart(ofTitle: shown)))]]
                item.windows.append(WindowUse(place: .expectation, title: shown))
            }
            if !leftOut, let text = item.text, let last = pending.last, let before = last.text, last.step.op == "vm.type", last.step.expect.isEmpty,
               last.step.params.filter({ $0.key != "text" }) == item.step.params.filter({ $0.key != "text" }) {
                pending[pending.count - 1].text = before + text
                pending[pending.count - 1].step.expect = item.step.expect
                pending[pending.count - 1].windows += item.windows
                keysWarned = false
                return
            }
            leftOut = false
            keysWarned = false
            pending.append(item)
        }
    }

    /// The roles of elements that a click at any of their points acts on as a click at their centre does.
    static let wholeElementRoles: Set<String> = ["Button", "CheckBox", "RadioButton", "MenuItem", "TabItem", "ListItem", "TreeItem", "Hyperlink"]
    /// The roles of elements that only a click near their centre acts on as a click at their centre does.
    static let centreRoles: Set<String> = ["Edit", "ComboBox", "SplitButton", "Spinner", "HeaderItem", "DataItem", "Text"]
    /// The least distance from the centre, in pixels, that counts as near it.
    static let centreMargin = 6.0

    /// Whether a click at (`x`, `y`) on the element a trace line describes as `target` may be replayed as a click at
    /// the element's centre: always for a role of `wholeElementRoles`; for a role of `centreRoles` when the point lies
    /// within `max(centreMargin, w / 4)` horizontally and `max(centreMargin, h / 4)` vertically of the centre of
    /// `rect`; never for another role or without the facts this needs.
    static func replaysAtCentre(_ facts: JSON?, x: Int, y: Int) -> Bool {
        guard let role = facts?["role"]?.stringValue else { return false }
        if wholeElementRoles.contains(role) { return true }
        guard centreRoles.contains(role), let rect = facts?["rect"], let left = rect["x"]?.intValue, let top = rect["y"]?.intValue,
              let w = rect["w"]?.intValue, let h = rect["h"]?.intValue else { return false }
        let dx = abs(Double(x) - (Double(left) + Double(w) / 2))
        let dy = abs(Double(y) - (Double(top) + Double(h) / 2))
        return dx <= max(centreMargin, Double(w) / 4) && dy <= max(centreMargin, Double(h) / 4)
    }

    /// The string `key` of `facts` when the trace holds it in full and not empty.
    private static func whole(_ facts: JSON, _ key: String) -> String? {
        guard let text = facts[key]?.stringValue, !text.isEmpty, facts[key + TraceSanitizer.cutMarkerSuffix]?.boolValue != true else { return nil }
        return text
    }

    /// The selectors that find the element a trace line describes as `target` again.
    ///
    /// Each holds `window` (the stable part of the title) and `role`, and `index` when more than one element matched.
    /// `selector` holds `automationId` when the line has one and `byAutomationId` counted its matches; otherwise
    /// `name` when the line has one and `byName` counted its matches. `alt` is the selector by `name` when `selector`
    /// is the one by `automationId` and both exist. Nil without a role, without a window title that reads as a
    /// title part, and when neither selector exists.
    static func selectors(for facts: JSON?) -> Selectors? {
        guard let facts, let role = whole(facts, "role"), let title = whole(facts, "window") else { return nil }
        let window = [stablePart(ofTitle: title), title].first(where: isTitlePart)
        guard let window else { return nil }
        func selector(_ field: String, countedBy count: String) -> (fields: [String: JSON], position: Position?)? {
            guard let value = whole(facts, field), let matches = facts[count]?["matches"]?.intValue, let index = facts[count]?["index"]?.intValue,
                  matches >= 1, (0..<matches).contains(index) else { return nil }
            var fields: [String: JSON] = ["window": .string(window), "role": .string(role), field: .string(value)]
            if matches > 1 { fields["index"] = .int(Int64(index)) }
            return (fields, matches > 1 ? Position(index: index, matches: matches) : nil)
        }
        let byID = selector("automationId", countedBy: "byAutomationId")
        let byName = selector("name", countedBy: "byName")
        guard let first = byID ?? byName else { return nil }
        let alt = byID == nil ? nil : byName
        return Selectors(selector: first.fields, alt: alt?.fields, title: title, positions: [first.position, alt?.position].compactMap { $0 })
    }

    /// The place of an element among the `matches` elements that look the same.
    struct Position: Equatable {
        var index: Int
        var matches: Int
    }

    /// What `selectors(for:)` finds: the selector, the alternative selector, the full title of the window the selectors
    /// name by a part of it, and the position of the element for each selector that carries an `index`.
    struct Selectors {
        var selector: [String: JSON]
        var alt: [String: JSON]?
        var title: String
        var positions: [Position]
    }

    // MARK: - parts of a step

    /// The window ids that showed a window title in the trace, and whether it was shown without an id.
    private struct Sighting {
        var ids: Set<String> = []
        var hasNoID = false
    }

    /// The events whose line in an observation names a window title.
    private static let windowEvents = ["window.opened", "window.created", "window.title", "window.foreground", "window.closed", "dialog.opened"]

    /// The title in the observation event line `line` (`<event> "<title>"`) of a window event; nil for another line.
    static func windowTitle(ofEvent line: String) -> String? {
        guard let name = windowEvents.first(where: { line.hasPrefix($0 + " \"") }) else { return nil }
        var title = ""
        var characters = line.dropFirst(name.count + 2).makeIterator()
        while let character = characters.next() {
            switch character {
            case "\"": return title
            case "\\":
                guard let escaped = characters.next() else { return nil }
                switch escaped {
                case "n": title.append("\n")
                case "r": title.append("\r")
                case "t": title.append("\t")
                case "u":
                    guard characters.next() == "{" else { return nil }
                    var digits = ""
                    while let digit = characters.next(), digit != "}" { digits.append(digit) }
                    guard let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
                    title.unicodeScalars.append(scalar)
                default: title.append(escaped)
                }
            default: title.append(character)
            }
        }
        return nil
    }

    /// A step being built.
    private struct Pending {
        /// The `seq` of the trace line the step is made from.
        var seq: Int
        var step: Script.Step
        /// The typed text of a `vm.type` step, unescaped; nil when the step reads it from a variable.
        var text: String?
        /// The param that goes into a password field, and the variable the step reads it from.
        var secret: (param: String, variable: String)?
        /// How the label names the element of the entry's `target`.
        var element: String?
        /// What the label names after the op.
        var subject: String?
        /// The window titles the step names, which `draft(vm:)` replaces by the name each gets.
        var windows: [WindowUse] = []
        /// The positions of the element among equal ones, for the selectors that carry an `index`.
        var positions: [Position] = []

        mutating func useSelectors(_ found: Selectors) {
            windows.append(WindowUse(place: .selector, title: found.title))
            if found.alt != nil { windows.append(WindowUse(place: .altSelector, title: found.title)) }
            positions += found.positions
        }
    }

    /// A place in a step that names a window by its title.
    private struct WindowUse {
        enum Place { case selector, altSelector, expectation, windowParam }
        var place: Place
        var title: String
    }

    /// Whether the agent reads `window` as a window id.
    private static func isWindowID(_ window: String) -> Bool { window.lowercased().hasPrefix("0x") }

    /// Whether the agent reads `window` as a part of a title: it is neither a window id nor the word `foreground`.
    static func isTitlePart(_ window: String) -> Bool { !isWindowID(window) && window != "foreground" }

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

    /// The foreground window title in the observation of `entry`; nil without a title, for an empty one and for one
    /// the trace cut.
    private static func shownForeground(_ entry: JSON) -> String? {
        guard let observation = entry["result"]?["observation"], let title = observation["foreground"]?.stringValue, !title.isEmpty,
              observation["foregroundTruncated"]?.boolValue != true else { return nil }
        return title
    }

    /// What separates the parts of a window title.
    static let titleSeparators = [" - ", " – ", " — "]
    /// The fewest characters of a title part that names a window.
    static let titlePartLength = 3

    /// The part of `title` a script names the window by: what follows the last of `titleSeparators` when that has at
    /// least `titlePartLength` characters, the whole title otherwise.
    static func stablePart(ofTitle title: String) -> String {
        let ends = titleSeparators.compactMap { title.range(of: $0, options: .backwards)?.upperBound }
        guard let last = ends.max() else { return title }
        let part = title[last...]
        return part.count >= titlePartLength ? String(part) : title
    }

    /// Whether `value` holds a `ref` at any depth.
    private static func holdsRef(_ value: JSON) -> Bool {
        switch value {
        case .object(let fields): return (fields["ref"] ?? .null) != .null || fields.values.contains(where: holdsRef)
        case .array(let items): return items.contains(where: holdsRef)
        default: return false
        }
    }

    /// The wait conditions `conditions` without the `since` of each `event` condition.
    private static func withoutCursors(_ conditions: JSON) -> JSON {
        guard let list = conditions.arrayValue else { return conditions }
        return .array(list.map { condition in
            guard var fields = condition.objectValue, fields["type"] == "event" else { return condition }
            fields["since"] = nil
            return .object(fields)
        })
    }

    /// Whether `text` has the length and the ending of a string the trace cut.
    private static func isCut(_ text: String) -> Bool {
        text.count == TraceSanitizer.maxStringLength + 1 && text.hasSuffix("…")
    }

    /// The first param of `fields`, in key order and at any depth, that the trace holds cut: a string with its cut
    /// marker beside it, or a string of an array that `isCut`. Nil when every param is whole.
    private static func cutParam(_ fields: [String: JSON]) -> String? {
        func cut(in items: [JSON]) -> Bool {
            items.contains { item in
                switch item {
                case .string(let text): return isCut(text)
                case .object(let inner): return cutParam(inner) != nil
                case .array(let nested): return cut(in: nested)
                default: return false
                }
            }
        }
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            switch value {
            case .string(let text): if fields[key + TraceSanitizer.cutMarkerSuffix] == true, isCut(text) { return key }
            case .object(let inner): if let found = cutParam(inner) { return "\(key).\(found)" }
            case .array(let items): if cut(in: items) { return key }
            default: break
            }
        }
        return nil
    }

    // MARK: - labels

    /// `<op> <subject>`, cut at `labelLimit` characters; the op alone without a subject. The subject of a `vm.type`
    /// step is its text in quotes, or `into a password field`.
    private static func label(_ item: Pending) -> String {
        var subject = item.subject
        if item.step.op == "vm.type" {
            subject = item.secret != nil ? "into a password field" : item.text.map { UITreeText.quoted(short($0)) }
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

    /// The element of a `target` as a label names it; nil without a target and for one that has neither a name nor an
    /// automation id in full.
    private static func describe(target facts: JSON?) -> String? {
        guard let facts else { return nil }
        var fields: [String: JSON] = [:]
        for key in ["role", "name", "automationId"] { fields[key] = whole(facts, key).map(JSON.string) }
        guard fields["name"] != nil || fields["automationId"] != nil else { return nil }
        return describe(fields)
    }

    /// What the label of `step` names after the op, read from its unescaped params; nil when the op has nothing to name.
    /// `element` names the element the step acts on; without it the step's selector does.
    private static func subject(of step: Script.Step, element: String?) -> String? {
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
        if let element, step.op == "vm.mouse.click" || step.op == "vm.mouse.drag" { return element }
        let element = element ?? params["selector"]?.objectValue.map(describe)
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
