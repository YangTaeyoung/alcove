import Foundation
import CryptoKit
import AlcoveQMP

public struct TransferResult: Sendable, Equatable {
    public let guestPath: String
    public let bytes: Int
    public let sha256: String
}

public struct SyncResult: Sendable, Equatable {
    public let sent: [String]
    public let skipped: Int
    public let deleted: [String]
    public let bytes: Int
}

/// A guest entry that is not a folder at a path where a synced directory has one.
public struct SyncObstacle: Error, Equatable, Sendable {
    /// The entry's path in the guest.
    public let guestPath: String
    /// Whether the agent listed the entry as a link.
    public let isLink: Bool
}

/// A guest file that holds more bytes than a pull was allowed to take: `bytes` is the size the guest reported, or the
/// bytes received when the limit was passed.
public struct TransferTooLarge: Error, Equatable, Sendable {
    public let guestPath: String
    public let bytes: Int
    public let limit: Int

    public init(guestPath: String, bytes: Int, limit: Int) {
        self.guestPath = guestPath
        self.bytes = bytes
        self.limit = limit
    }
}

private let transferPiece = 256 * 1024

private func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

/// `relative`, whose parts are separated by `/`, below the guest folder `base`, with `\\` as the separator when `base`
/// holds one and `/` otherwise, and one separator between `base` and `relative`.
func joinGuestPath(_ base: String, _ relative: String) -> String {
    let separator = base.contains("\\") ? "\\" : "/"
    var root = base
    while root.hasSuffix("/") || root.hasSuffix("\\") { root.removeLast() }
    let tail = relative.replacingOccurrences(of: "/", with: separator)
    return root + separator + tail
}

/// The last component of the guest path `path`, split at `/` and `\\`.
private func guestFileName(_ path: String) -> String {
    path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "file"
}

private func foldedName(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

func windowsCaseConflict(in names: [String]) -> (String, String)? {
    var seen: [String: String] = [:]
    for name in names {
        let folded = foldedName(name)
        if let first = seen[folded] { return (first, name) }
        seen[folded] = name
    }
    return nil
}

/// Whether the host file at `url` has an execute bit for its owner, its group or others.
private func isExecutable(_ url: URL) -> Bool {
    guard let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber else { return false }
    return mode.intValue & 0o111 != 0
}

private func localDigest(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let piece = try handle.read(upToCount: transferPiece), !piece.isEmpty { hasher.update(data: piece) }
    return hex(hasher.finalize())
}

private func localFiles(in directory: URL) throws -> [(name: String, url: URL)] {
    var result: [(name: String, url: URL)] = []
    func walk(_ dir: URL, prefix: String) throws {
        for entry in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let url = dir.appendingPathComponent(entry)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            if values.isSymbolicLink == true { continue }
            let name = prefix + entry.precomposedStringWithCanonicalMapping
            if values.isDirectory == true { try walk(url, prefix: name + "/") }
            else if values.isRegularFile == true { result.append((name, url)) }
        }
    }
    try walk(directory, prefix: "")
    return result.sorted { $0.name < $1.name }
}

/// Lists the files of a host folder for a sync: each regular file below it, symbolic links left out, by its path below
/// the folder with `/` separators, sorted by that path.
nonisolated(unsafe) var listSyncFiles: @Sendable (URL) throws -> [(name: String, url: URL)] = { try localFiles(in: $0) }

/// The files of `directory` that a sync to the guest path `path` compares and uploads, without those whose path below
/// the directory is in `preserving`. Throws when two of them differ only by case and `path` is a Windows path.
private func syncSource(_ directory: URL, toGuestPath path: String, preserving: Set<String>) throws -> [(name: String, url: URL)] {
    let windows = path.contains("\\")
    let kept = Set(preserving.map { windows ? foldedName($0) : $0 })
    let local = try listSyncFiles(directory).filter { !kept.contains(windows ? foldedName($0.name) : $0.name) }
    if windows, let (a, b) = windowsCaseConflict(in: local.map(\.name)) {
        throw AgentClient.AgentError.remote("'\(a)' and '\(b)' differ only by case and cannot both exist in a Windows guest folder")
    }
    return local
}

extension AgentClient {
    /// The end of the agent's sentence for an `fs.rename` without `overwrite` whose target exists.
    static let renameTargetExists = "' exists; pass overwrite to replace it"

    /// The sentence of a pull of `guestPath` whose received bytes do not match the digest the guest reported.
    public static func downloadMismatch(_ guestPath: String) -> String {
        "'\(guestPath)' changed in the guest while it was pulled, so the copy does not match; pull the file again"
    }

    /// Throws what `syncDirectory` with the same arguments refuses from the files of `directory` alone, without a
    /// request to the guest.
    public static func checkSyncSource(_ directory: URL, toGuestPath path: String, preserving: Set<String> = []) throws {
        _ = try syncSource(directory, toGuestPath: path, preserving: preserving)
    }

    /// Upload a local file to `path` in the guest through `<path>.alcove-part`, verifying the SHA-256. A push that fails
    /// or is cancelled before the rename deletes `<path>.alcove-part` in the guest while the connection lasts; a
    /// cancellation does not stop that delete.
    public func pushFile(_ url: URL, toGuestPath path: String, overwrite: Bool, timeout: Duration = .seconds(1800)) async throws -> TransferResult {
        let existing = try await call("fs.stat", ["path": .string(path)], timeout: timeout)
        if existing["exists"]?.boolValue == true, !overwrite {
            throw AgentError.remote("'\(path)' exists in the guest; pass overwrite")
        }
        let part = path + ".alcove-part"
        let executable = isExecutable(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let renamed: JSON
        var offset = 0
        var digest = ""
        do {
            var hasher = SHA256()
            while true {
                let piece = try handle.read(upToCount: transferPiece) ?? Data()
                if piece.isEmpty && offset > 0 { break }
                hasher.update(data: piece)
                var request: [String: JSON] = [
                    "path": .string(part), "data": .string(piece.base64EncodedString()),
                    "offset": .int(Int64(offset)), "truncate": .bool(offset == 0), "mkdirs": .bool(true),
                ]
                if executable, offset == 0 { request["executable"] = true }
                _ = try await call("fs.write", request, timeout: timeout)
                offset += piece.count
                if piece.isEmpty { break }
            }
            digest = hex(hasher.finalize())
            let uploaded = try await call("fs.stat", ["path": .string(part), "sha256": .bool(true)], timeout: timeout)
            guard uploaded["sha256"]?.stringValue?.lowercased() == digest else {
                throw AgentError.remote("the copy of '\(path)' in the guest does not match the host file after the upload; push the file again")
            }
            do {
                renamed = try await call("fs.rename", ["from": .string(part), "to": .string(path), "overwrite": .bool(overwrite)], timeout: timeout)
            } catch AgentError.remote(let text) where !overwrite && text.hasSuffix(AgentClient.renameTargetExists) {
                throw AgentError.remote("'\(path)' exists in the guest; pass overwrite")
            }
        } catch {
            if let agentError = error as? AgentError, agentError == .disconnected || agentError == .notConnected { throw error }
            _ = try? await Task { try await self.call("fs.delete", ["path": .string(part)], timeout: timeout) }.value
            throw error
        }
        return TransferResult(guestPath: renamed["path"]?.stringValue ?? path, bytes: offset, sha256: digest)
    }

    /// Download a guest file to `url` through `<url>.alcove-part`, verifying the SHA-256, and replace a file at `url` with
    /// it in one `rename(2)`. A folder at `url` is refused before any request and kept as it is, also when it appears
    /// there during the pull; a folder at `<url>.alcove-part` is refused and kept as it is.
    ///
    /// With `deadline`, each request waits `timeout` or the time left until `deadline`, whichever is shorter, and a request
    /// due after `deadline` throws `AgentError.timeout` without being sent. With `maxBytes`, a file that holds more bytes
    /// throws `TransferTooLarge`: before any piece is read when `fs.stat` reports the size, otherwise once more bytes
    /// arrived. A task cancelled before the file is moved to `url` throws `CancellationError` and leaves no
    /// `<url>.alcove-part`; a file already at `url` stays as it is.
    public func pullFile(guestPath: String, to url: URL, timeout: Duration = .seconds(1800),
                         deadline: ContinuousClock.Instant? = nil, maxBytes: Int? = nil) async throws -> TransferResult {
        try await pullFile(guestPath: guestPath, to: url, timeout: timeout, deadline: deadline, maxBytes: maxBytes, now: { .now })
    }

    /// `pullFile(guestPath:to:timeout:deadline:maxBytes:)` with `now` as the clock `deadline` is read on.
    func pullFile(guestPath: String, to url: URL, timeout: Duration = .seconds(1800),
                  deadline: ContinuousClock.Instant? = nil, maxBytes: Int? = nil,
                  now: @Sendable () -> ContinuousClock.Instant) async throws -> TransferResult {
        func wait(for op: String) throws -> Duration {
            guard let deadline else { return timeout }
            let left = now().duration(to: deadline)
            guard left > .zero else { throw AgentError.timeout(op) }
            return min(timeout, left)
        }
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            throw AgentError.remote("'\(url.path)' is a folder on the host; pass the path of the file to create, such as \(url.path)/\(guestFileName(guestPath))")
        }
        let info = try await call("fs.stat", ["path": .string(guestPath), "sha256": .bool(true)], timeout: try wait(for: "fs.stat"))
        guard info["exists"]?.boolValue == true, info["dir"]?.boolValue != true else {
            throw AgentError.remote("'\(guestPath)' is not a file in the guest; check the path")
        }
        if let maxBytes, let size = info["size"]?.intValue, size > maxBytes {
            throw TransferTooLarge(guestPath: guestPath, bytes: size, limit: maxBytes)
        }
        try Task.checkCancellation()
        let expected = info["sha256"]?.stringValue?.lowercased() ?? ""
        let part = URL(fileURLWithPath: url.path + ".alcove-part")
        let fm = FileManager.default
        var partIsFolder: ObjCBool = false
        if fm.fileExists(atPath: part.path, isDirectory: &partIsFolder), partIsFolder.boolValue {
            throw AgentError.remote("'\(part.path)' is a folder on the host, and the pull writes its partial copy there; move that folder away or pull to another path")
        }
        unlink(part.path)
        guard fm.createFile(atPath: part.path, contents: nil) else {
            throw AgentError.remote("cannot create '\(part.path)'; check the destination folder")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: part)
        } catch {
            unlink(part.path)
            throw error
        }
        var hasher = SHA256()
        var offset = 0
        do {
            while true {
                try Task.checkCancellation()
                let r = try await call("fs.read", [
                    "path": .string(guestPath), "offset": .int(Int64(offset)), "length": .int(Int64(transferPiece)),
                ], timeout: try wait(for: "fs.read"))
                let piece = Data(base64Encoded: r["data"]?.stringValue ?? "") ?? Data()
                try handle.write(contentsOf: piece)
                hasher.update(data: piece)
                offset += piece.count
                if let maxBytes, offset > maxBytes { throw TransferTooLarge(guestPath: guestPath, bytes: offset, limit: maxBytes) }
                if r["eof"]?.boolValue == true || piece.isEmpty { break }
            }
            try handle.close()
            try Task.checkCancellation()
        } catch {
            try? handle.close()
            unlink(part.path)
            throw error
        }
        let digest = hex(hasher.finalize())
        guard digest == expected else {
            unlink(part.path)
            throw AgentError.remote(AgentClient.downloadMismatch(guestPath))
        }
        guard rename(part.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(part.path)
            throw AgentError.remote("'\(url.path)' could not be replaced: \(reason); pass the path of a file that is not a folder")
        }
        return TransferResult(guestPath: info["path"]?.stringValue ?? guestPath, bytes: offset, sha256: digest)
    }

    /// Upload the files of `directory` whose size or digest differ from the guest copy; optionally delete guest files without a local counterpart.
    /// A file whose path below the directory is in `preserving` is neither uploaded nor deleted. With `refusingObstacles`,
    /// a guest entry that is not a folder where `directory` has one throws `SyncObstacle` before any file is sent.
    public func syncDirectory(_ directory: URL, toGuestPath path: String, deleteExtras: Bool, preserving: Set<String> = [],
                              refusingObstacles: Bool = false, timeout: Duration = .seconds(3600)) async throws -> SyncResult {
        let windows = path.contains("\\")
        let key: (String) -> String = { windows ? foldedName($0) : $0 }
        let kept = Set(preserving.map(key))
        let local = try syncSource(directory, toGuestPath: path, preserving: preserving)
        var remote: [String: (name: String, size: Int, sha256: String)] = [:]
        let root = try await call("fs.stat", ["path": .string(path)], timeout: timeout)
        if root["exists"]?.boolValue == true {
            let listing = try await call("fs.list", ["path": .string(path), "recursive": .bool(true), "sha256": .bool(true)], timeout: timeout)
            if listing["truncated"]?.boolValue == true {
                throw AgentError.remote("'\(path)' has more than 5000 entries in the guest; sync a smaller directory")
            }
            var folders: Set<String> = []
            for file in local {
                var parts = file.name.split(separator: "/").dropLast()
                while !parts.isEmpty, folders.insert(key(parts.joined(separator: "/"))).inserted { parts.removeLast() }
            }
            for entry in listing["entries"]?.arrayValue ?? [] where entry["dir"]?.boolValue != true {
                guard let name = entry["name"]?.stringValue, !kept.contains(key(name)) else { continue }
                if refusingObstacles, folders.contains(key(name)) {
                    throw SyncObstacle(guestPath: joinGuestPath(path, name), isLink: entry["link"]?.boolValue == true)
                }
                remote[key(name)] = (name, entry["size"]?.intValue ?? -1, entry["sha256"]?.stringValue?.lowercased() ?? "")
            }
        }
        var sent: [String] = []
        var skipped = 0
        var bytes = 0
        for file in local {
            let size = (try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int) ?? -1
            if let guest = remote[key(file.name)], guest.size == size, guest.sha256 == (try localDigest(of: file.url)) {
                skipped += 1
                continue
            }
            let result = try await pushFile(file.url, toGuestPath: joinGuestPath(path, file.name), overwrite: true, timeout: timeout)
            sent.append(file.name)
            bytes += result.bytes
        }
        var deleted: [String] = []
        if deleteExtras {
            let names = Set(local.map { key($0.name) })
            for (folded, entry) in remote.sorted(by: { $0.value.name < $1.value.name }) where !names.contains(folded) {
                let name = entry.name
                _ = try await call("fs.delete", ["path": .string(joinGuestPath(path, name)), "recursive": .bool(false)], timeout: timeout)
                deleted.append(name)
            }
        }
        return SyncResult(sent: sent, skipped: skipped, deleted: deleted, bytes: bytes)
    }
}
