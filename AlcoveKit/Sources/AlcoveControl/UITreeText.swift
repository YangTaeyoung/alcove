import Foundation
import AlcoveQMP

/// Text form of UI Automation nodes (`{ref, depth, role, name, value?, x, y, w, h, flags}`).
enum UITreeText {
    /// One line per node: indentation by depth, `[ref] Role "name" (x,y WxH) flags`, value as `value="..."`.
    static func render(_ nodes: [JSON]) -> String {
        nodes.map(line).joined(separator: "\n")
    }

    /// The line of one node, indented by two spaces per depth level. A node without a rectangle has no `(x,y WxH)` part.
    static func line(_ node: JSON) -> String {
        var parts = ["[\(node["ref"]?.stringValue ?? "?")]", label(node)]
        if let x = node["x"]?.intValue, let y = node["y"]?.intValue, let w = node["w"]?.intValue, let h = node["h"]?.intValue {
            parts.append("(\(x),\(y) \(w)x\(h))")
        }
        parts += (node["flags"]?.arrayValue ?? []).compactMap(\.stringValue)
        if let value = node["value"]?.stringValue { parts.append("value=\(quoted(value))") }
        return String(repeating: "  ", count: max(0, node["depth"]?.intValue ?? 0)) + parts.joined(separator: " ")
    }

    /// The most characters of a name a line shows.
    static let nameLimit = 200

    /// `Role "name"` of a node; a name longer than `nameLimit` characters is cut there and ends with `…`.
    static func label(_ node: JSON) -> String {
        var name = node["name"]?.stringValue ?? ""
        if name.count > nameLimit { name = String(name.prefix(nameLimit)) + "…" }
        return "\(node["role"]?.stringValue ?? "?") \(quoted(name))"
    }

    /// `text` in double quotes on one line: backslash, double quote, newline, carriage return and tab are backslash-escaped;
    /// every other scalar below U+0020 or from U+007F to U+009F, and the line and paragraph separators U+2028 and U+2029,
    /// are written as `\u{hex}`.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
