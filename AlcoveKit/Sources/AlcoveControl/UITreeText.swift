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

    /// `Role "name"` of a node.
    static func label(_ node: JSON) -> String {
        "\(node["role"]?.stringValue ?? "?") \(quoted(node["name"]?.stringValue ?? ""))"
    }

    /// `text` in double quotes on one line: backslash, double quote, newline, carriage return and tab are backslash-escaped.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(character)
            }
        }
        return out + "\""
    }
}
