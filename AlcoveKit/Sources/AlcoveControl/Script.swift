import Foundation
import AlcoveQMP

/// A problem with a script; `step` is the 1-based number of the step it concerns.
struct ScriptError: Error, CustomStringConvertible, Equatable {
    let step: Int?
    let message: String
    var description: String { message }
}

/// A replayable list of control ops (script format version 1).
struct Script: Sendable, Equatable {
    struct Step: Sendable, Equatable {
        var label: String?
        var op: String
        var params: [String: JSON]
        var expect: [JSON]
        var timeout: Int
    }

    static let version = 1
    static let defaultTimeout = 10
    static let maxTimeout = 600

    var vm: String?
    var variables: [String: String]
    var steps: [Step]

    /// Ops a step may not use, by exact name or prefix ending in a dot.
    private static let refusedOps = ["vm.lease.", "vm.record.", "script.", "vm.clone", "vm.delete"]

    /// Whether a step may run `op`.
    static func allows(op: String) -> Bool {
        !refusedOps.contains { $0.hasSuffix(".") ? op.hasPrefix($0) : op == $0 }
    }

    // MARK: - parsing

    static func parse(_ data: Data) throws -> Script {
        let root: JSON
        do { root = try JSON.parse(data) } catch {
            throw ScriptError(step: nil, message: "the script is not valid JSON; fix its syntax")
        }
        guard let fields = root.objectValue else {
            throw ScriptError(step: nil, message: "the script must be a JSON object with version, steps and optionally vm and variables")
        }
        guard let version = fields["version"], version != .null else {
            throw ScriptError(step: nil, message: "the script has no version; add \"version\": \(Script.version)")
        }
        guard version.intValue == Script.version else {
            throw ScriptError(step: nil, message: "script version \(describe(version)) is not supported; this build reads version \(Script.version)")
        }
        var vm: String?
        if let value = fields["vm"], value != .null {
            guard let name = value.stringValue, !name.isEmpty else {
                throw ScriptError(step: nil, message: "'vm' must be a non-empty string naming the VM; fix it or remove it")
            }
            vm = name
        }
        var variables: [String: String] = [:]
        if let value = fields["variables"], value != .null {
            guard let object = value.objectValue else {
                throw ScriptError(step: nil, message: "'variables' must be an object of names to string values")
            }
            for (name, item) in object {
                guard let text = item.stringValue else {
                    throw ScriptError(step: nil, message: "variable '\(name)' must be a string; quote its value")
                }
                variables[name] = text
            }
        }
        guard let list = fields["steps"]?.arrayValue, !list.isEmpty else {
            throw ScriptError(step: nil, message: "the script has no steps; add a 'steps' array with at least one step")
        }
        var steps: [Step] = []
        for (offset, item) in list.enumerated() { steps.append(try parseStep(item, number: offset + 1)) }
        return Script(vm: vm, variables: variables, steps: steps)
    }

    private static func parseStep(_ item: JSON, number: Int) throws -> Step {
        func fail(_ message: String) -> ScriptError { ScriptError(step: number, message: "step \(number) \(message)") }
        guard let fields = item.objectValue else { throw fail("is not an object; write each step as {\"op\": ..., \"params\": ...}") }
        guard let op = fields["op"]?.stringValue, !op.isEmpty else {
            throw fail("has no op; every step needs an op such as vm.type")
        }
        try check(op: op, number: number)
        var label: String?
        if let value = fields["label"], value != .null {
            guard let text = value.stringValue else { throw fail("has a label that is not a string; quote it") }
            label = text
        }
        var params: [String: JSON] = [:]
        if let value = fields["params"], value != .null {
            guard let object = value.objectValue else { throw fail("has params that are not an object; write them as {\"key\": value}") }
            params = object
        }
        for key in ["name", "lease"] where params[key] != nil {
            throw fail("passes '\(key)' in params; remove it, the runner supplies the VM name and its own lease")
        }
        var expect: [JSON] = []
        if let value = fields["expect"], value != .null {
            guard let list = value.arrayValue else { throw fail("has an expect that is not an array; write it as a list of wait conditions") }
            for condition in list where condition.objectValue == nil {
                throw fail("has an expectation that is not an object; write each as {\"type\": ...}")
            }
            expect = list
        }
        var timeout = defaultTimeout
        if let value = fields["timeout"], value != .null {
            guard let seconds = value.intValue, (1...maxTimeout).contains(seconds) else {
                throw fail("has a timeout outside 1 to \(maxTimeout) seconds; use a whole number of seconds")
            }
            timeout = seconds
        }
        return Step(label: label, op: op, params: params, expect: expect, timeout: timeout)
    }

    private static func check(op: String, number: Int) throws {
        guard allows(op: op) else {
            throw ScriptError(step: number, message: "step \(number) uses op '\(op)', which scripts may not run; remove the step or use another op")
        }
        guard ControlHandler.knownOps.contains(op) else {
            throw ScriptError(step: number, message: "step \(number) uses unknown op '\(op)'; use one of the control ops such as vm.type")
        }
    }

    /// Fails with the first step whose op a script may not run.
    func validate() throws {
        if steps.isEmpty {
            throw ScriptError(step: nil, message: "the script has no steps; add a 'steps' array with at least one step")
        }
        for (offset, step) in steps.enumerated() { try Script.check(op: step.op, number: offset + 1) }
    }

    private static func describe(_ value: JSON) -> String {
        (try? value.serialized()).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }

    // MARK: - encoding

    /// Pretty-printed JSON with sorted keys.
    func encoded() throws -> Data {
        var root: [String: JSON] = ["version": .int(Int64(Script.version)),
                                    "variables": .object(variables.mapValues(JSON.string)),
                                    "steps": .array(steps.map(\.json))]
        if let vm { root["vm"] = .string(vm) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSON.object(root))
    }

    // MARK: - variables

    /// Turns a literal into text that substitution leaves unchanged: `${` becomes `$${`.
    static func escape(_ literal: String) -> String {
        literal.replacingOccurrences(of: "${", with: "$${")
    }

    /// The script with `${name}` replaced in every string of the params and expectations.
    /// `overrides` win over the script's own variables; the result holds the merged variables.
    func resolved(with overrides: [String: String]) throws -> Script {
        let values = variables.merging(overrides) { _, override in override }
        var result = self
        result.variables = values
        for index in result.steps.indices {
            let number = index + 1
            result.steps[index].params = try result.steps[index].params.mapValues { try Script.substitute($0, values, step: number) }
            result.steps[index].expect = try result.steps[index].expect.map { try Script.substitute($0, values, step: number) }
        }
        return result
    }

    private static func substitute(_ value: JSON, _ values: [String: String], step: Int) throws -> JSON {
        switch value {
        case .string(let text): return .string(try substitute(text, values, step: step))
        case .array(let items): return .array(try items.map { try substitute($0, values, step: step) })
        case .object(let fields): return .object(try fields.mapValues { try substitute($0, values, step: step) })
        default: return value
        }
    }

    private static func substitute(_ text: String, _ values: [String: String], step: Int) throws -> String {
        guard text.contains("${") else { return text }
        var out = ""
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.hasPrefix("$${") {
                out += "${"
                rest = rest.dropFirst(3)
            } else if rest.hasPrefix("${") {
                let afterOpen = rest.dropFirst(2)
                guard let close = afterOpen.firstIndex(of: "}") else {
                    throw ScriptError(step: step, message: "step \(step) has '${' without a closing '}'; close the variable or write $${ for a literal ${")
                }
                let name = String(afterOpen[afterOpen.startIndex..<close])
                guard let replacement = values[name] else {
                    throw ScriptError(step: step, message: "variable '\(name)' is not defined; pass it or add a default")
                }
                out += replacement
                rest = afterOpen[afterOpen.index(after: close)...]
            } else {
                out.append(rest.removeFirst())
            }
        }
        return out
    }
}

extension Script.Step {
    var json: JSON {
        var object: [String: JSON] = ["op": .string(op), "params": .object(params), "expect": .array(expect),
                                      "timeout": .int(Int64(timeout))]
        if let label { object["label"] = .string(label) }
        return .object(object)
    }
}
