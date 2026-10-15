import Foundation
import AlcoveQMP

/// The clock of `vm.wait_for`: one loop tick and how often each kind of condition is evaluated.
enum WaitTiming {
    nonisolated(unsafe) static var tick = Duration.milliseconds(250)
    nonisolated(unsafe) static var screenPeriod = Duration.milliseconds(250)
    nonisolated(unsafe) static var ocrPeriod = Duration.milliseconds(700)
    nonisolated(unsafe) static var agentPeriod = Duration.milliseconds(500)
    /// Longest an agent call of one evaluation may take.
    nonisolated(unsafe) static var agentCallTimeout = Duration.seconds(5)
    /// Longest a wait that reached its timeout waits for the text readings that have not ended, all of them together.
    nonisolated(unsafe) static var recognitionGrace = Duration.seconds(1)
    /// How long a wait's helper call must have gone without an answer, counted from the moment it began to wait for
    /// its turn, before the wait reports it; also how long a sent call must have been unanswered before the wait's
    /// observation leaves the UI facts out instead of waiting for the helper, and how long the guest agent must have
    /// left the calls of an agent condition unanswered before the wait reports that.
    nonisolated(unsafe) static var reportedSilence = Duration.milliseconds(500)
    /// Output bytes one evaluation of a job condition reads.
    nonisolated(unsafe) static var jobByteBudget = 4 * 1024 * 1024
    /// Text recognition on a frame.
    nonisolated(unsafe) static var recognizer: @Sendable (Frame, [String]) throws -> [TextMatch] = { try ScreenText.recognize($0, languages: $1) }
    /// The recognition languages a `languages` parameter may name.
    nonisolated(unsafe) static var supportedLanguages: @Sendable () throws -> [String] = { try ScreenText.supportedLanguages.get() }
}

/// How long the guest agent has left the calls of one agent condition of a wait without an answer.
struct AgentSilence {
    /// The op of the latest call that ran out of time, and the start of the first of the evaluations in a row that
    /// ended with such a call. Nil when the latest evaluation that ended got its answers.
    private(set) var unanswered: (op: String, since: ContinuousClock.Instant)?

    /// Takes in an evaluation that began at `started` and has ended. `openCall` is the op of its call that ran out
    /// of time; nil when every call it made was answered.
    mutating func ended(openCall: String?, started: ContinuousClock.Instant) {
        unanswered = openCall.map { ($0, unanswered?.since ?? started) }
    }

    /// The sentence for a wait that ends at `now`, or nil. `inFlight` is the evaluation that has not ended: the op
    /// of its call without an answer so far (nil when it has none) and its start; while it has none, there is no
    /// sentence. The silence counts from the start of the first evaluation in the row of unanswered ones that reaches
    /// up to `now`, and is reported from `WaitTiming.reportedSilence` on.
    func sentence(inFlight: (openCall: String?, started: ContinuousClock.Instant)?, now: ContinuousClock.Instant) -> String? {
        if let inFlight, inFlight.openCall == nil { return nil }
        guard let op = inFlight?.openCall ?? unanswered?.op, let since = unanswered?.since ?? inFlight?.started else { return nil }
        let silent = now - since
        guard silent >= WaitTiming.reportedSilence else { return nil }
        let seconds = (Double(silent.components.seconds) + Double(silent.components.attoseconds) / 1e18).rounded()
        return "the guest agent has not answered \(op) for \(Int(seconds)) s"
    }
}

/// The text a `text_visible` or `text_gone` condition looks for.
struct WaitText: Sendable {
    let query: String
    let expression: NSRegularExpression?
    let region: Frame.Rect?
    /// The recognition languages the condition names; nil for the reading without `languages`.
    let languages: [String]?

    /// Identifies the reading this text needs; conditions with the same key share one.
    var recognitionKey: String {
        let area = region.map { "\($0.x),\($0.y),\($0.w),\($0.h)" } ?? "frame"
        return area + "|" + (languages?.joined(separator: ",") ?? "merged")
    }
}

/// One condition of `vm.wait_for`.
enum WaitCondition: Sendable {
    case screenIdle(seconds: Double)
    case regionChanged(Frame.Rect)
    case textVisible(WaitText)
    case textGone(WaitText)
    case processStarted(name: String)
    case processExited(pid: Int?, name: String?)
    case fileExists(path: String)
    case portListening(Int)
    case logMatches(path: String, pattern: NSRegularExpression)
    case jobOutputMatches(job: String, pattern: NSRegularExpression)
    /// An element exists; `element` holds the agent fields that select it.
    case uiExists(element: [String: JSON])
    case uiGone(element: [String: JSON])
    /// An element exists without the `disabled` flag.
    case uiEnabled(element: [String: JSON])
    /// A top-level window has a title containing `contains` (case ignored) or matching `pattern`.
    case windowTitle(contains: String?, pattern: NSRegularExpression?)
    /// The text of an element stayed the same for `quietMs`.
    case uiTextStable(element: [String: JSON], quietMs: Int)
    /// A guest event named `name` arrived, with a window title containing `titleContains` when given. With `since` the
    /// events after that sequence number count; without it those after the VM's event baseline.
    case event(name: String, titleContains: String?, since: Int?)

    static let typeNames = ["screen_idle", "region_changed", "text_visible", "text_gone", "process_started", "process_exited",
                            "file_exists", "port_listening", "log_matches", "job_output_matches",
                            "ui_exists", "ui_gone", "ui_enabled", "window_title", "ui_text_stable", "event"]
    static let maxQuietMs = 600_000

    var typeName: String {
        switch self {
        case .screenIdle: return "screen_idle"
        case .regionChanged: return "region_changed"
        case .textVisible: return "text_visible"
        case .textGone: return "text_gone"
        case .processStarted: return "process_started"
        case .processExited: return "process_exited"
        case .fileExists: return "file_exists"
        case .portListening: return "port_listening"
        case .logMatches: return "log_matches"
        case .jobOutputMatches: return "job_output_matches"
        case .uiExists: return "ui_exists"
        case .uiGone: return "ui_gone"
        case .uiEnabled: return "ui_enabled"
        case .windowTitle: return "window_title"
        case .uiTextStable: return "ui_text_stable"
        case .event: return "event"
        }
    }

    /// What a condition reads: frames, recognized text, agent calls, agent calls that need the `ui` capability,
    /// or the guest events of the VM.
    enum Kind { case screen, text, agent, ui, event }

    var kind: Kind {
        switch self {
        case .screenIdle, .regionChanged: return .screen
        case .textVisible, .textGone: return .text
        case .uiExists, .uiGone, .uiEnabled, .windowTitle, .uiTextStable: return .ui
        case .event: return .event
        default: return .agent
        }
    }

    /// The text a `text_visible` or `text_gone` condition looks for.
    var text: WaitText? {
        switch self {
        case .textVisible(let text), .textGone(let text): return text
        default: return nil
        }
    }

    /// The guest agent ops an agent condition calls, as a phrase; nil for the other kinds.
    var guestCalls: String? {
        switch self {
        case .processStarted, .processExited: return "proc.list"
        case .fileExists: return "fs.stat"
        case .portListening: return "exec.run"
        case .logMatches: return "fs.tail and fs.stat"
        case .jobOutputMatches: return "exec.read"
        default: return nil
        }
    }

    var needsFrame: Bool { kind == .screen || kind == .text }
    var needsAgent: Bool { !needsFrame }
    var needsUI: Bool { kind == .ui }

    var period: Duration {
        switch kind {
        case .screen: return WaitTiming.screenPeriod
        case .text: return WaitTiming.ocrPeriod
        case .agent, .ui: return WaitTiming.agentPeriod
        case .event: return WaitTiming.tick
        }
    }

    static let maxConditions = 8
    static let maxSeconds = 600

    /// The validated `conditions` parameter.
    static func parseList(_ params: JSON) throws -> [WaitCondition] {
        guard let list = params["conditions"]?.arrayValue else { throw ControlHandler.ControlError.missing("conditions") }
        guard (1...maxConditions).contains(list.count) else {
            throw ControlHandler.ControlError.failed("conditions must hold 1 to \(maxConditions) conditions, not \(list.count)")
        }
        return try list.enumerated().map { try parse($1, index: $0) }
    }

    /// The validated `timeout` parameter in seconds; 30 when absent.
    static func parseTimeout(_ params: JSON) throws -> Double {
        guard let value = params["timeout"], value != .null else { return 30 }
        guard let seconds = value.doubleValue, seconds >= 1, seconds <= Double(maxSeconds) else {
            throw ControlHandler.ControlError.failed("timeout must be between 1 and \(maxSeconds) seconds")
        }
        return seconds
    }

    static func parse(_ value: JSON, index: Int) throws -> WaitCondition {
        func fail(_ message: String) -> ControlHandler.ControlError { .failed("condition \(index): \(message)") }
        guard let fields = value.objectValue, let type = fields["type"]?.stringValue else {
            throw fail("a condition is an object with a string 'type'")
        }

        func text(_ key: String, required: Bool = true) throws -> String? {
            guard let v = fields[key], v != .null else {
                if required { throw fail("\(type) needs a non-empty string '\(key)'") }
                return nil
            }
            guard let s = v.stringValue, !s.isEmpty else { throw fail("\(type) needs a non-empty string '\(key)'") }
            return s
        }
        func pattern(_ options: NSRegularExpression.Options = []) throws -> NSRegularExpression {
            guard let source = fields["pattern"]?.stringValue else { throw fail("\(type) needs a string 'pattern'") }
            return try compile(source, regexOptions: options, index: index)
        }
        func region() throws -> Frame.Rect? {
            guard let v = fields["region"], v != .null else { return nil }
            guard let rect = ControlHandler.requestedRect(v) else { throw fail(ControlHandler.regionSentence) }
            return rect
        }
        func screenText() throws -> WaitText {
            let query = try text("text")!
            var expression: NSRegularExpression?
            if let v = fields["regex"], v != .null {
                guard let flag = v.boolValue else { throw fail("'regex' must be a boolean") }
                if flag { expression = try compile(query, regexOptions: [.caseInsensitive], index: index) }
            }
            var languages: [String]?
            if let v = fields["languages"], v != .null {
                guard let items = v.arrayValue, !items.isEmpty, items.allSatisfy({ $0.stringValue != nil }) else {
                    throw fail("'languages' must be a non-empty array of strings")
                }
                languages = items.compactMap(\.stringValue)
            }
            do { try ScreenText.validate(languages: languages ?? ScreenText.defaultLanguages + ScreenText.latinLanguages, op: "vm.wait_for") }
            catch { throw fail(ControlHandler.failureReason(error, fallback: "the recognition languages cannot be checked")) }
            return WaitText(query: query, expression: expression, region: try region(), languages: languages)
        }

        func element() throws -> [String: JSON] {
            let selector = fields.filter { UISelector.fieldNames.contains($0.key) && $0.value != .null }
            do {
                return try UISelector.agentFields(ref: fields["ref"], selector: selector.isEmpty ? nil : .object(selector))
            } catch UISelector.Invalid.neither, UISelector.Invalid.noCriteria {
                throw fail("\(type) needs 'ref' or at least one of \(UISelector.criteria.joined(separator: ", "))")
            } catch UISelector.Invalid.both {
                throw fail("\(type) takes 'ref' or selector fields, not both")
            } catch UISelector.Invalid.field(let message) {
                throw fail(message)
            }
        }

        switch type {
        case "screen_idle":
            var seconds = 2.0
            if let v = fields["seconds"], v != .null {
                guard let s = v.doubleValue, s >= 0, s <= Double(maxSeconds) else { throw fail("'seconds' must be a number between 0 and \(maxSeconds)") }
                seconds = s
            }
            return .screenIdle(seconds: seconds)
        case "region_changed":
            guard let area = try region() else { throw fail("region_changed needs a 'region'") }
            return .regionChanged(area)
        case "text_visible":
            return .textVisible(try screenText())
        case "text_gone":
            return .textGone(try screenText())
        case "process_started":
            return .processStarted(name: try text("processName")!)
        case "process_exited":
            var pid: Int?
            if let v = fields["pid"], v != .null {
                guard let p = v.intValue else { throw fail("'pid' must be an integer") }
                pid = p
            }
            let name = try text("processName", required: false)
            guard pid != nil || name != nil else { throw fail("process_exited needs 'pid' or 'processName'") }
            return .processExited(pid: pid, name: name)
        case "file_exists":
            return .fileExists(path: try text("path")!)
        case "port_listening":
            guard let port = fields["port"]?.intValue, (1...65535).contains(port) else {
                throw fail("port_listening needs an integer 'port' between 1 and 65535")
            }
            return .portListening(port)
        case "log_matches":
            let path = try text("path")!
            return .logMatches(path: path, pattern: try pattern())
        case "job_output_matches":
            let job = try text("job")!
            return .jobOutputMatches(job: job, pattern: try pattern(.anchorsMatchLines))
        case "ui_exists":
            return .uiExists(element: try element())
        case "ui_gone":
            return .uiGone(element: try element())
        case "ui_enabled":
            return .uiEnabled(element: try element())
        case "ui_text_stable":
            var quietMs = 1500
            if let v = fields["quietMs"], v != .null {
                guard let ms = v.intValue, (0...maxQuietMs).contains(ms) else { throw fail("'quietMs' must be an integer between 0 and \(maxQuietMs)") }
                quietMs = ms
            }
            return .uiTextStable(element: try element(), quietMs: quietMs)
        case "window_title":
            let contains = try text("contains", required: false)
            let source = try text("regex", required: false)
            guard (contains == nil) != (source == nil) else { throw fail("window_title needs exactly one of 'contains' and 'regex'") }
            return .windowTitle(contains: contains, pattern: try source.map { try compile($0, regexOptions: [], index: index) })
        case "event":
            var since: Int?
            if let v = fields["since"], v != .null {
                guard let seq = v.intValue, seq >= 0 else { throw fail("'since' must be an integer of 0 or more; pass the eventSeq of an earlier reply") }
                since = seq
            }
            return .event(name: try text("event")!, titleContains: try text("titleContains", required: false), since: since)
        default:
            throw fail("unknown type '\(type)'; valid types: \(typeNames.joined(separator: ", "))")
        }
    }

    private static func compile(_ source: String, regexOptions: NSRegularExpression.Options, index: Int) throws -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: source, options: regexOptions) }
        catch { throw ControlHandler.ControlError.failed("condition \(index): '\(source)' is not a valid regular expression") }
    }
}
