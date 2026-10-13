import Foundation
import AlcoveQMP

/// `script.run`: replays a script file against a VM. `script.save`: writes a script file from the trace of a recording.
extension ControlHandler {
    /// Builds a script from a trace and writes it to the host file `path`.
    ///
    /// The trace is `trace.jsonl` in the recording directory `dir`, or the file `trace`. `name` is the script's VM;
    /// without it the script names the VM of the trace. `from` and `to` bound the `seq` of the lines used. A line that
    /// is not a JSON object with an integer `seq` and a string `op` is left out and counted in `skipped`.
    /// `path` is absolute and ends in `.json`; its folder is created when the folder above it exists. A file at `path`
    /// is replaced only with `overwrite: true`. The file is written through a temporary file beside it.
    /// The result holds `path`, the number of `steps`, `skipped` and, when there are any, the builder's `warnings`.
    nonisolated func scriptSave(_ params: JSON) async throws -> JSON {
        func given(_ key: String) -> JSON? { params[key].flatMap { $0 == .null ? nil : $0 } }
        let tracePath: String
        switch (given("dir"), given("trace")) {
        case (nil, nil):
            throw ControlError.oneOf("dir", "trace")
        case (.some, .some):
            throw ControlError.failed("pass dir or trace, not both")
        case (let dir?, nil):
            let folder = try absolutePath(dir, "dir")
            tracePath = URL(fileURLWithPath: folder).appendingPathComponent(TraceWriter.traceName).path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: tracePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ControlError.failed("'\(folder)' holds no recording (no \(TraceWriter.traceName) in it); pass the dir that vm.record.start returned")
            }
        case (nil, let trace?):
            tracePath = try absolutePath(trace, "trace")
            try requireHostFile(tracePath)
        }

        guard let pathValue = given("path") else { throw ControlError.missing("path") }
        let path = try absolutePath(pathValue, "path")
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "json" else { throw ControlError.failed("path must end in .json; a script is a JSON file") }
        let overwrite = try optional(params, "overwrite", .boolean)?.boolValue ?? false
        let exists = ControlError.failed("'\(path)' exists; pass overwrite: true or another path")
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { throw ControlError.failed("'\(path)' is a folder; pass the path of a file") }
            if !overwrite { throw exists }
        }
        let folder = url.deletingLastPathComponent()
        let createsFolder = !fm.fileExists(atPath: folder.path)
        if createsFolder {
            let above = folder.deletingLastPathComponent()
            guard fm.fileExists(atPath: above.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ControlError.failed("the folder '\(above.path)' does not exist; create it or choose another path")
            }
        }

        var vm: String?
        if let value = given("name") {
            guard let name = value.stringValue, !name.isEmpty else { throw ControlError.missing("name") }
            vm = name
        }
        func seq(_ key: String) throws -> Int? {
            guard let value = given(key) else { return nil }
            guard let number = value.intValue, number >= 1 else {
                throw ControlError.failed("\(key) must be an integer of 1 or more; pass a seq of the trace")
            }
            return number
        }
        let from = try seq("from"), to = try seq("to")
        if let from, let to, from > to { throw ControlError.failed("from (\(from)) must not exceed to (\(to))") }

        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: tracePath), options: .mappedIfSafe) else {
            throw ControlError.failed("cannot read the trace '\(tracePath)'; check that the file is readable")
        }
        var entries: [JSON] = []
        var skipped = 0
        for line in bytes.split(separator: 0x0A) where line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) {
            guard let entry = try? JSON.parse(Data(line)), entry.objectValue != nil, entry["seq"]?.intValue != nil,
                  entry["op"]?.stringValue != nil else {
                skipped += 1
                continue
            }
            entries.append(entry)
        }
        let recorded = entries.lazy.compactMap { $0["params"]?["name"]?.stringValue }.first { !$0.isEmpty }
        var draft = ScriptBuilder.draft(trace: entries, vm: vm ?? recorded ?? "", from: from, to: to)
        if draft.script.vm?.isEmpty == true { draft.script.vm = nil }
        guard !draft.script.steps.isEmpty else {
            guard from != nil || to != nil else {
                throw ControlError.failed("the trace holds no op to replay; record clicks, keys or other changing ops first")
            }
            let range = "between \(from.map { "seq \($0)" } ?? "its start") and \(to.map { "seq \($0)" } ?? "its end")"
            throw ControlError.failed("the trace holds no op to replay \(range); check from and to against the seq values of the trace")
        }
        let data: Data
        do {
            try draft.script.validate()
            data = try draft.script.encoded()
        } catch {
            throw ControlError.failed("the trace does not make a script that script.run accepts: \(ControlHandler.failureReason(error, fallback: "a step is not valid")); save another part of it with from and to")
        }
        guard data.count <= ScriptLimits.fileBytes else {
            throw ControlError.failed("the script would be larger than 4 MiB, the most script.run reads; save a part of the trace with from and to")
        }

        do {
            if createsFolder { try fm.createDirectory(at: folder, withIntermediateDirectories: false) }
            guard try ControlHandler.writeHostFile(data, to: url, replacing: overwrite) else { throw exists }
        } catch let error as ControlError {
            throw error
        } catch {
            throw ControlError.failed("cannot write '\(path)': \(ControlHandler.failureReason(error, fallback: "the file could not be written")); choose another path")
        }
        var out: [String: JSON] = ["path": .string(path), "steps": .int(Int64(draft.script.steps.count)), "skipped": .int(Int64(skipped))]
        if !draft.warnings.isEmpty { out["warnings"] = .array(draft.warnings.map(JSON.string)) }
        return .object(out)
    }

    /// Writes `data` to a temporary file beside `url` and renames it to `url`: `url` holds all of `data` or is as it
    /// was. Without `replacing`, a file that is at `url` at the moment of the rename stays and the result is false.
    nonisolated static func writeHostFile(_ data: Data, to url: URL, replacing: Bool) throws -> Bool {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if renamex_np(temporary.path, url.path, replacing ? 0 : UInt32(RENAME_EXCL)) == 0 { return true }
        var code = errno
        if code == ENOTSUP, !replacing {
            if FileManager.default.fileExists(atPath: url.path) { return false }
            if rename(temporary.path, url.path) == 0 { return true }
            code = errno
        }
        if code == EEXIST, !replacing { return false }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

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
