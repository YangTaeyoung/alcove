import Foundation
import AlcoveAgent
import AlcoveQMP

/// Shell commands, background jobs and processes in the guest, carried by the
/// agent's request/response operations (`exec.*`, `proc.*`).
extension ControlHandler {
    func shell(op: String, params: JSON) async throws -> JSON {
        let t = try await running(params)
        do {
            switch op {
            case "vm.exec":
                return try await exec(t, params)
            case "vm.exec.start":
                if let value = params["stdin"], value != .null {
                    throw ControlError.failed("vm.exec.start takes no stdin; start the job, then send the text with vm.exec.write (eof: true closes the job's stdin)")
                }
                if let value = params["timeout"], value != .null {
                    throw ControlError.failed("vm.exec.start takes no timeout; a job runs until it exits or vm.exec.kill ends it")
                }
                let request = try commandParams(params, stdin: false)
                let r = try await tools(t).call("exec.start", request)
                return pick(r, ["job", "pid"])
            case "vm.exec.read":
                var request: [String: JSON] = ["job": .string(try string(params, "job"))]
                try pass(params, "outOffset", to: &request, as: "out_offset", type: .integer)
                try pass(params, "errOffset", to: &request, as: "err_offset", type: .integer)
                try pass(params, "max", to: &request, type: .integer)
                let r = try await tools(t).call("exec.read", request)
                return pick(r, ["state", "code", "pid", "out", "err", "out_next", "err_next", "dropped"],
                            renamed: ["out_next": "outNext", "err_next": "errNext"])
            case "vm.exec.write":
                var request: [String: JSON] = ["job": .string(try string(params, "job")), "data": .string(try string(params, "data"))]
                try pass(params, "eof", to: &request, type: .boolean)
                _ = try await tools(t).call("exec.write", request)
                return [:]
            case "vm.exec.kill":
                let request: [String: JSON] = ["job": .string(try string(params, "job"))]
                return pick(try await tools(t).call("exec.kill", request), ["state"])
            case "vm.exec.list":
                let r = try await tools(t).call("exec.list")
                return ["jobs": r["jobs"] ?? []]
            case "vm.process.list":
                var request: [String: JSON] = [:]
                try pass(params, "filter", to: &request, as: "name", where: isString)
                let r = try await tools(t).call("proc.list", request)
                let rows = (r["procs"]?.arrayValue ?? []).map {
                    pick($0, ["pid", "ppid", "name", "path", "cmd", "mem_kb"], renamed: ["cmd": "command", "mem_kb": "memoryKB"])
                }
                return ["processes": .array(rows)]
            case "vm.process.kill":
                var request: [String: JSON] = [:]
                try pass(params, "pid", to: &request, type: .integer)
                try pass(params, "processName", to: &request, as: "name", where: isString)
                guard !request.isEmpty else { throw ControlError.oneOf("pid", "processName") }
                try pass(params, "tree", to: &request, type: .boolean)
                return pick(try await tools(t).call("proc.kill", request), ["killed"])
            default:
                throw ControlError.unknownOp(op)
            }
        } catch {
            throw agentFailure(error, vm: t.name, op: op)
        }
    }

    /// `exec.run` on agents with request/response support; the v1 `exec` message for a plain `command` otherwise.
    private func exec(_ t: VMTarget, _ params: JSON) async throws -> JSON {
        var request = try commandParams(params, stdin: true)
        let seconds = try commandTimeout(params)
        let agent = try await tools(t)
        if (await agent.hello?.rpcVersion ?? 1) >= 2 {
            request["timeout_ms"] = .int(Int64(seconds) * 1000)
            let r = try await agent.call("exec.run", request, timeout: .seconds(seconds + 15))
            let out = r["stdout"]?.stringValue ?? "", err = r["stderr"]?.stringValue ?? ""
            return ["code": r["code"] ?? -1, "output": .string(out + err), "stdout": .string(out), "stderr": .string(err),
                    "timedOut": .bool(r["timed_out"]?.boolValue ?? false), "truncated": .bool(r["truncated"]?.boolValue ?? false)]
        }
        guard Set(request.keys) == ["cmd"], let command = request["cmd"]?.stringValue else {
            throw ControlError.toolsTooOld(vm: t.name, op: "vm.exec")
        }
        let r = try await agent.exec(command, timeout: .seconds(seconds))
        return ["code": .int(Int64(r.code)), "output": .string(r.output)]
    }

    /// The `timeout` parameter in seconds: 120 when absent, otherwise an integer from 1 to 86400.
    private nonisolated func commandTimeout(_ params: JSON) throws -> Int {
        guard let value = params["timeout"], value != .null else { return 120 }
        guard let seconds = value.intValue, (1...86_400).contains(seconds) else {
            throw ControlError.failed("timeout must be between 1 and 86400 seconds")
        }
        return seconds
    }

    /// The agent parameters of `exec.run` / `exec.start` taken from `command`, `argv`, `cwd`, `env`, `shell` and, with `stdin`, `stdin`.
    private nonisolated func commandParams(_ params: JSON, stdin: Bool) throws -> [String: JSON] {
        var request: [String: JSON] = [:]
        try pass(params, "command", to: &request, as: "cmd", where: isString)
        try pass(params, "argv", to: &request) { $0.arrayValue.map { !$0.isEmpty && $0.allSatisfy(isString) } ?? false }
        guard !request.isEmpty else { throw ControlError.oneOf("command", "argv") }
        for key in stdin ? ["cwd", "shell", "stdin"] : ["cwd", "shell"] {
            try pass(params, key, to: &request, where: isString)
        }
        try pass(params, "env", to: &request) { $0.objectValue.map { $0.values.allSatisfy(isString) } ?? false }
        return request
    }

    /// Copies the optional parameter `key` into `request` under `name`; a value failing `valid` is an invalid parameter.
    nonisolated func pass(_ params: JSON, _ key: String, to request: inout [String: JSON], as name: String? = nil,
                          where valid: (JSON) -> Bool) throws {
        guard let value = params[key], value != .null else { return }
        guard valid(value) else { throw ControlError.missing(key) }
        request[name ?? key] = value
    }

    /// The optional parameter `key`: nil when absent or null, an error when present with a JSON type other than `type`.
    nonisolated func optional(_ params: JSON, _ key: String, _ type: ParamType) throws -> JSON? {
        guard let value = params[key], value != .null else { return nil }
        guard type.accepts(value) else { throw ControlError.wrongType(key, type) }
        return value
    }

    /// Copies the optional boolean or integer parameter `key` into `request` under `name`.
    nonisolated func pass(_ params: JSON, _ key: String, to request: inout [String: JSON], as name: String? = nil, type: ParamType) throws {
        if let value = try optional(params, key, type) { request[name ?? key] = value }
    }

    /// The fields `keys` of `source` that are present, stored under their `renamed` name when one is given.
    nonisolated func pick(_ source: JSON, _ keys: [String], renamed: [String: String] = [:]) -> JSON {
        var result: [String: JSON] = [:]
        for key in keys { if let value = source[key] { result[renamed[key] ?? key] = value } }
        return .object(result)
    }
}

func isString(_ value: JSON) -> Bool { value.stringValue != nil }
