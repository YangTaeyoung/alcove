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

private let transferPiece = 256 * 1024

private func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

private func joinGuestPath(_ base: String, _ relative: String) -> String {
    let separator = base.contains("\\") ? "\\" : "/"
    var root = base
    while root.count > 1, root.hasSuffix("/") || root.hasSuffix("\\") { root.removeLast() }
    let tail = relative.replacingOccurrences(of: "/", with: separator)
    return root + separator + tail
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

/// The files of `directory` that a sync to the guest path `path` compares and uploads, without those whose path below
/// the directory is in `preserving`. Throws when two of them differ only by case and `path` is a Windows path.
private func syncSource(_ directory: URL, toGuestPath path: String, preserving: Set<String>) throws -> [(name: String, url: URL)] {
    let windows = path.contains("\\")
    let kept = Set(preserving.map { windows ? foldedName($0) : $0 })
    let local = try localFiles(in: directory).filter { !kept.contains(windows ? foldedName($0.name) : $0.name) }
    if windows, let (a, b) = windowsCaseConflict(in: local.map(\.name)) {
        throw AgentClient.AgentError.remote("'\(a)' and '\(b)' differ only by case and cannot both exist in a Windows guest folder")
    }
    return local
}

extension AgentClient {
    /// Throws what `syncDirectory` with the same arguments refuses from the files of `directory` alone, without a
    /// request to the guest.
    public static func checkSyncSource(_ directory: URL, toGuestPath path: String, preserving: Set<String> = []) throws {
        _ = try syncSource(directory, toGuestPath: path, preserving: preserving)
    }

    /// Upload a local file to `path` in the guest through `<path>.alcove-part`, verifying the SHA-256.
    public func pushFile(_ url: URL, toGuestPath path: String, overwrite: Bool, timeout: Duration = .seconds(1800)) async throws -> TransferResult {
        let existing = try await call("fs.stat", ["path": .string(path)], timeout: timeout)
        if existing["exists"]?.boolValue == true, !overwrite {
            throw AgentError.remote("'\(path)' exists in the guest; pass overwrite")
        }
        let part = path + ".alcove-part"
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
                _ = try await call("fs.write", [
                    "path": .string(part), "data": .string(piece.base64EncodedString()),
                    "offset": .int(Int64(offset)), "truncate": .bool(offset == 0), "mkdirs": .bool(true),
                ], timeout: timeout)
                offset += piece.count
                if piece.isEmpty { break }
            }
            digest = hex(hasher.finalize())
            let uploaded = try await call("fs.stat", ["path": .string(part), "sha256": .bool(true)], timeout: timeout)
            guard uploaded["sha256"]?.stringValue?.lowercased() == digest else {
                throw AgentError.remote("digest mismatch after upload")
            }
            do {
                renamed = try await call("fs.rename", ["from": .string(part), "to": .string(path), "overwrite": .bool(overwrite)], timeout: timeout)
            } catch AgentError.remote(let text) where !overwrite && text.contains("exists") {
                throw AgentError.remote("'\(path)' exists in the guest; pass overwrite")
            }
        } catch {
            if let agentError = error as? AgentError, agentError == .disconnected || agentError == .notConnected { throw error }
            _ = try? await call("fs.delete", ["path": .string(part)], timeout: timeout)
            throw error
        }
        return TransferResult(guestPath: renamed["path"]?.stringValue ?? path, bytes: offset, sha256: digest)
    }

    /// Download a guest file to `url` through `<url>.alcove-part`, verifying the SHA-256.
    public func pullFile(guestPath: String, to url: URL, timeout: Duration = .seconds(1800)) async throws -> TransferResult {
        let info = try await call("fs.stat", ["path": .string(guestPath), "sha256": .bool(true)], timeout: timeout)
        guard info["exists"]?.boolValue == true, info["dir"]?.boolValue != true else {
            throw AgentError.remote("'\(guestPath)' is not a file in the guest; check the path")
        }
        let expected = info["sha256"]?.stringValue?.lowercased() ?? ""
        let part = URL(fileURLWithPath: url.path + ".alcove-part")
        let fm = FileManager.default
        try? fm.removeItem(at: part)
        guard fm.createFile(atPath: part.path, contents: nil) else {
            throw AgentError.remote("cannot create '\(part.path)'; check the destination folder")
        }
        let handle = try FileHandle(forWritingTo: part)
        var hasher = SHA256()
        var offset = 0
        do {
            while true {
                try Task.checkCancellation()
                let r = try await call("fs.read", [
                    "path": .string(guestPath), "offset": .int(Int64(offset)), "length": .int(Int64(transferPiece)),
                ], timeout: timeout)
                let piece = Data(base64Encoded: r["data"]?.stringValue ?? "") ?? Data()
                try handle.write(contentsOf: piece)
                hasher.update(data: piece)
                offset += piece.count
                if r["eof"]?.boolValue == true || piece.isEmpty { break }
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: part)
            throw error
        }
        let digest = hex(hasher.finalize())
        guard digest == expected else {
            try? fm.removeItem(at: part)
            throw AgentError.remote("digest mismatch after download")
        }
        try? fm.removeItem(at: url)
        try fm.moveItem(at: part, to: url)
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
