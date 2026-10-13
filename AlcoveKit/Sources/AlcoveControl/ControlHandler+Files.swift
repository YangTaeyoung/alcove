import Foundation
import AlcoveAgent
import AlcoveQMP

/// The largest number of bytes one `fs.read` or `fs.write` request carries.
private let filePiece = 262_144

/// File transfer between host and guest and text access to guest files,
/// carried by the agent's `fs.*` operations.
extension ControlHandler {
    func files(op: String, params: JSON) async throws -> JSON {
        let t = try await running(params)
        do {
            switch op {
            case "vm.push_file":
                let path = try string(params, "path")
                var target: [String: JSON] = [:]
                try pass(params, "guestPath", to: &target, where: isString)
                let overwrite = try optional(params, "overwrite", .boolean)?.boolValue ?? false
                let agent = try await tools(t)
                try requireHostFile(path)
                let url = URL(fileURLWithPath: path)
                guard let guestPath = target["guestPath"]?.stringValue else {
                    let dest: AgentClient.Destination = params["dest"]?.stringValue == "downloads" ? .downloads : .desktop
                    return ["guestPath": .string(try await agent.pushFile(url, to: dest))]
                }
                let r = try await agent.pushFile(url, toGuestPath: guestPath, overwrite: overwrite)
                return ["guestPath": .string(r.guestPath), "bytes": .int(Int64(r.bytes)), "sha256": .string(r.sha256)]
            case "vm.pull_file":
                let guestPath = try string(params, "guestPath")
                let path = try string(params, "path")
                return try await pull(t, guestPath: guestPath, to: path)
            case "vm.crash_dumps.pull":
                guard await t.guestOS() == .windows else { throw ControlError.failed(ControlHandler.windowsOnlyDumps) }
                let file = try string(params, "file")
                guard ControlHandler.isWindowsFileName(file, suffix: ".dmp") else {
                    throw ControlError.failed("file must be the name of a .dmp file listed by vm.crash_dumps.list, without a folder")
                }
                return try await pull(t, guestPath: GuestRecipes.dumpFolder + "\\" + file, to: try string(params, "path"))
            case "vm.sync_dir":
                let path = try string(params, "path")
                let guestPath = try string(params, "guestPath")
                let deleteExtras = try optional(params, "delete", .boolean)?.boolValue ?? false
                let agent = try await tools(t)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw ControlError.failed("'\(path)' is not a directory on the host; check the path")
                }
                let r = try await agent.syncDirectory(URL(fileURLWithPath: path), toGuestPath: guestPath,
                                                      deleteExtras: deleteExtras)
                return ["sent": .array(r.sent.map(JSON.string)), "skipped": .int(Int64(r.skipped)),
                        "deleted": .array(r.deleted.map(JSON.string)), "bytes": .int(Int64(r.bytes))]
            case "vm.fs.list":
                var request: [String: JSON] = ["path": .string(try string(params, "path"))]
                try pass(params, "recursive", to: &request, type: .boolean)
                let r = try await tools(t).call("fs.list", request)
                let entries = (r["entries"]?.arrayValue ?? []).map { pick($0, ["name", "dir", "size", "mtime"]) }
                return ["entries": .array(entries), "truncated": .bool(r["truncated"]?.boolValue ?? false)]
            case "vm.fs.read":
                return try await readText(t, params)
            case "vm.fs.write":
                return try await writeText(t, params)
            case "vm.fs.delete":
                var request: [String: JSON] = ["path": .string(try string(params, "path"))]
                try pass(params, "recursive", to: &request, type: .boolean)
                return pick(try await tools(t).call("fs.delete", request), ["deleted"])
            default:
                throw ControlError.unknownOp(op)
            }
        } catch {
            throw agentFailure(error, vm: t.name, op: op)
        }
    }

    /// The last `tail` lines through `fs.tail`, or up to `length` bytes from `offset` through `fs.read`, decoded as text;
    /// as UTF-16LE when the agent reports that encoding for the file.
    private func readText(_ t: VMTarget, _ params: JSON) async throws -> JSON {
        let path = try string(params, "path")
        var range: [String: JSON] = [:]
        try pass(params, "tail", to: &range, as: "lines", type: .integer)
        try pass(params, "offset", to: &range, type: .integer)
        try pass(params, "length", to: &range, type: .integer)
        let agent = try await tools(t)
        let r: JSON
        if let lines = range["lines"] {
            r = try await agent.call("fs.tail", ["path": .string(path), "lines": lines])
        } else {
            let length = min(max(range["length"]?.intValue ?? filePiece, 0), filePiece)
            r = try await agent.call("fs.read", ["path": .string(path), "offset": range["offset"] ?? 0, "length": .int(Int64(length))])
        }
        let data = Data(base64Encoded: r["data"]?.stringValue ?? "") ?? Data()
        return ["text": .string(GuestText.decode(data, utf16: r["encoding"]?.stringValue == "utf-16le")), "size": r["size"] ?? 0,
                "eof": .bool(range["lines"] != nil || r["eof"]?.boolValue == true)]
    }

    /// Writes `text` as UTF-8 in pieces of at most `filePiece` bytes: the first piece replaces the file unless `append` is set, the rest append.
    private func writeText(_ t: VMTarget, _ params: JSON) async throws -> JSON {
        let path = try string(params, "path")
        let data = Data(try string(params, "text").utf8)
        let append = try optional(params, "append", .boolean)?.boolValue ?? false
        let agent = try await tools(t)
        var size: JSON = 0
        var offset = 0
        repeat {
            let piece = data.subdata(in: offset..<min(offset + filePiece, data.count))
            var request: [String: JSON] = ["path": .string(path), "data": .string(piece.base64EncodedString()), "mkdirs": true]
            if append || offset > 0 { request["append"] = true } else { request["truncate"] = true }
            let r = try await agent.call("fs.write", request)
            size = r["size"] ?? size
            offset += piece.count
        } while offset < data.count
        return ["size": size]
    }

    /// Copies the guest file `guestPath` to the host path `path` and reports its size and SHA-256.
    private func pull(_ t: VMTarget, guestPath: String, to path: String) async throws -> JSON {
        let r = try await tools(t).pullFile(guestPath: guestPath, to: URL(fileURLWithPath: path))
        return ["path": .string(path), "bytes": .int(Int64(r.bytes)), "sha256": .string(r.sha256)]
    }

    private nonisolated func requireHostFile(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ControlError.failed("'\(path)' is not a file on the host; check the path")
        }
    }
}
