import Foundation
import AlcoveQMP

/// `script.run`: replays a script file against a VM.
extension ControlHandler {
    /// The refusal text when `token` does not hold the lease of `vm`; nil when the VM is free to it.
    func leaseRefusal(vm: String, token: String?) -> String? {
        leases.refusal(vm: vm, token: token, now: clock())
    }

    func scriptRun(_ params: JSON) async throws -> JSON {
        let path = try string(params, "path")
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) } catch {
            throw ControlError.failed("cannot read the script '\(path)'; check that the file exists on the host")
        }
        let script: Script
        do { script = try Script.parse(data) } catch { throw ControlError.failed("\(error)") }

        var variables: [String: String] = [:]
        if let value = params["variables"], value != .null {
            guard let object = value.objectValue else { throw ControlError.failed("'variables' must be an object of names to string values") }
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
        let owner = "script:" + URL(fileURLWithPath: path).lastPathComponent
        let result = await ScriptRunner(handler: self).run(script, vm: vm, variables: variables, lease: params["lease"]?.stringValue,
                                                           owner: owner, snapshot: snapshot, progress: nil)

        var out: [String: JSON] = ["passed": .bool(result.passed), "stepsRun": .int(Int64(result.stepsRun)),
                                   "steps": .array(result.stepResults), "seconds": .double(result.seconds)]
        if let failed = result.failedStep {
            out["failedStep"] = .int(Int64(failed))
            if script.steps.indices.contains(failed - 1), let label = script.steps[failed - 1].label { out["label"] = .string(label) }
        }
        if let error = result.error { out["error"] = .string(error) }
        if let png = result.failureImage {
            out["failure"] = ["png": .string(png.base64EncodedString()),
                              "width": .int(Int64(result.failureWidth ?? 0)), "height": .int(Int64(result.failureHeight ?? 0))]
        }
        return .object(out)
    }
}
