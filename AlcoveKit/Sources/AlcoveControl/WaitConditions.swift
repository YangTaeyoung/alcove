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
}

/// The text a `text_visible` or `text_gone` condition looks for.
struct WaitText: Sendable {
    let query: String
    let regex: Bool
    let region: Frame.Rect?
    let languages: [String]

    /// Identifies the recognition this text needs; conditions with the same key share one.
    var recognitionKey: String {
        let area = region.map { "\($0.x),\($0.y),\($0.w),\($0.h)" } ?? "frame"
        return area + "|" + languages.joined(separator: ",")
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

    static let typeNames = ["screen_idle", "region_changed", "text_visible", "text_gone", "process_started", "process_exited",
                            "file_exists", "port_listening", "log_matches", "job_output_matches"]

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
        }
    }

    enum Kind { case screen, text, agent }

    var kind: Kind {
        switch self {
        case .screenIdle, .regionChanged: return .screen
        case .textVisible, .textGone: return .text
        default: return .agent
        }
    }

    var needsFrame: Bool { kind != .agent }
    var needsAgent: Bool { kind == .agent }

    var period: Duration {
        switch kind {
        case .screen: return WaitTiming.screenPeriod
        case .text: return WaitTiming.ocrPeriod
        case .agent: return WaitTiming.agentPeriod
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
            guard let x = v["x"]?.intValue, let y = v["y"]?.intValue, let w = v["w"]?.intValue, let h = v["h"]?.intValue, w > 0, h > 0 else {
                throw fail("region needs integer x, y, w, h with w and h above 0")
            }
            return Frame.Rect(x: x, y: y, w: w, h: h)
        }
        func screenText() throws -> WaitText {
            let query = try text("text")!
            var regex = false
            if let v = fields["regex"], v != .null {
                guard let flag = v.boolValue else { throw fail("'regex' must be a boolean") }
                regex = flag
            }
            if regex { _ = try compile(query, regexOptions: [.caseInsensitive], index: index) }
            var languages = ScreenText.defaultLanguages
            if let v = fields["languages"], v != .null {
                guard let items = v.arrayValue, !items.isEmpty, items.allSatisfy({ $0.stringValue != nil }) else {
                    throw fail("'languages' must be a non-empty array of strings")
                }
                languages = items.compactMap(\.stringValue)
            }
            return WaitText(query: query, regex: regex, region: try region(), languages: languages)
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
        default:
            throw fail("unknown type '\(type)'; valid types: \(typeNames.joined(separator: ", "))")
        }
    }

    private static func compile(_ source: String, regexOptions: NSRegularExpression.Options, index: Int) throws -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: source, options: regexOptions) }
        catch { throw ControlHandler.ControlError.failed("condition \(index): '\(source)' is not a valid regular expression") }
    }
}
