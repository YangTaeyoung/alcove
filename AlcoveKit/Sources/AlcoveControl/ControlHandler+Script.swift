import Foundation
import AlcoveQMP

/// `script.run`: replays a script file against a VM.
extension ControlHandler {
    /// The refusal text when `token` is not the current lease of `vm`; nil when it is.
    func leaseRefusal(vm: String, token: String) -> String? {
        if let refusal = leases.refusal(vm: vm, token: token, now: clock()) { return refusal }
        guard leases.active(vm: vm, now: clock())?.token == token else {
            return "lease token is not the current lease of '\(vm)' (expired, released or unknown); acquire a new lease or omit lease"
        }
        return nil
    }

    /// Whether `token` is the unexpired lease of `vm`.
    func holdsLease(vm: String, token: String) -> Bool {
        leases.active(vm: vm, now: clock())?.token == token
    }

    func scriptRun(_ params: JSON) async throws -> JSON {
        let path = try string(params, "path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let unreadable = ControlError.failed("cannot read the script '\(path)'; check that it is a file on the host and use an absolute path")
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
              let size = values.fileSize else { throw unreadable }
        guard size <= ScriptLimits.fileBytes else {
            throw ControlError.failed("the script is larger than 4 MiB; split it into several scripts")
        }
        guard let data = try? Data(contentsOf: url) else { throw unreadable }
        let script: Script
        do { script = try Script.parse(data) } catch { throw ControlError.failed("\(error)") }

        var variables: [String: String] = [:]
        if let value = params["variables"], value != .null {
            guard let object = value.objectValue else { throw ControlError.failed("'variables' must be an object of names to string values, for example {\"message\": \"hello\"}") }
            for (name, item) in object {
                guard let text = item.stringValue else { throw ControlError.failed("variable '\(name)' must be a string; quote its value") }
                variables[name] = text
            }
        }
        var vm: String?
        if let value = params["name"], value != .null {
            guard let name = value.stringValue, !name.isEmpty else { throw ControlError.missing("name") }
            vm = name
        }
        var snapshot: String?
        if let value = params["snapshot"], value != .null {
            guard let name = value.stringValue, !name.isEmpty else { throw ControlError.missing("snapshot") }
            snapshot = name
        }
        var lease: String?
        if let value = params["lease"], value != .null {
            guard let token = value.stringValue else {
                throw ControlError.failed("'lease' must be the lease token string returned by vm.lease.acquire")
            }
            lease = token
        }
        let owner = "script:" + URL(fileURLWithPath: path).lastPathComponent
        let result = await ScriptRunner(handler: self).run(script, vm: vm, variables: variables, lease: lease,
                                                           owner: owner, snapshot: snapshot, progress: nil)
        if result.couldNotStart { throw ControlError.failed(result.error ?? "the run could not start") }

        var out: [String: JSON] = ["passed": .bool(result.passed), "stepsRun": .int(Int64(result.stepsRun)),
                                   "steps": .array(result.stepResults), "seconds": .double(result.seconds)]
        if let failed = result.failedStep {
            out["failedStep"] = .int(Int64(failed))
            if script.steps.indices.contains(failed - 1), let label = script.steps[failed - 1].label { out["label"] = .string(label) }
        }
        if let error = result.error { out["error"] = .string(error) }
        if let warning = result.warning { out["warning"] = .string(warning) }
        if let png = result.failureImage {
            out["failure"] = ["png": .string(png.base64EncodedString()),
                              "width": .int(Int64(result.failureWidth ?? 0)), "height": .int(Int64(result.failureHeight ?? 0))]
        }
        return .object(out)
    }
}
