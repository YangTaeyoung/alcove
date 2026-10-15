import Foundation
import CryptoKit
import AlcoveQMP

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A scripted stand-in for the Go agent: TCP server sending hello and replying per handler.
public final class FakeAgent: @unchecked Sendable {
    public let port: Int
    private let listenFD: Int32
    private var clientFD: Int32 = -1
    private let lock = NSLock()
    public private(set) var received: [JSON] = []
    public var token = "tok"
    public var proto: Int? = 2
    public var caps: [String] = ["clipboard", "files", "exec"]
    public var handler: (@Sendable (JSON, FakeAgent) -> [JSON])?
    /// Fields added to the hello.
    public var helloExtra: [String: JSON] = [:]
    /// Whether the hello is sent on connect.
    public var sendsHello = true
    /// Runs on connect after the hello was sent (or would have been).
    public var onConnect: (@Sendable (FakeAgent) -> Void)?

    public init() {
        let lfd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(lfd, $0, &len) } }
        listenFD = lfd
        port = Int(UInt16(bigEndian: addr.sin_port))
        Darwin.listen(lfd, 1)
    }

    public func start() -> FakeAgent { Thread { [self] in serve() }.start(); return self }

    private func serve() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        lock.lock(); clientFD = fd; lock.unlock()
        var hello: JSON = ["t": "hello", "v": 1, "os": "windows", "agent": "0.1.0", "token": .string(token), "caps": .array(caps.map(JSON.string))]
        if let proto, case .object(var o) = hello { o["proto"] = .int(Int64(proto)); hello = .object(o) }
        if case .object(var o) = hello { for (k, v) in helloExtra { o[k] = v }; hello = .object(o) }
        if sendsHello { sendLine(hello) }
        onConnect?(self)
        var pending = Data(); var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 10) {
                let line = Data(pending[pending.startIndex..<nl]); pending.removeSubrange(pending.startIndex...nl)
                guard let m = try? JSON.parse(line) else { continue }
                lock.lock(); received.append(m); let h = handler; lock.unlock()
                for r in h?(m, self) ?? [] { sendLine(r) }
            }
        }
    }

    public func sendLine(_ j: JSON) {
        lock.lock(); defer { lock.unlock() }
        guard clientFD >= 0, var d = try? j.serialized() else { return }
        d.append(10)
        _ = d.withUnsafeBytes { write(clientFD, $0.baseAddress, $0.count) }
    }

    public func receivedCount() -> Int { lock.lock(); defer { lock.unlock() }; return received.count }
    public func drop() { lock.lock(); if clientFD >= 0 { Darwin.close(clientFD); clientFD = -1 }; lock.unlock() }
    public func stop() { drop(); Darwin.close(listenFD) }
}

/// A value guarded by a lock, shared between test code and the fake agent thread.
public final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    public init(_ value: T) { stored = value }
    public var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// In-memory guest file system answering the `fs.*` requests of the agent contract.
public final class FakeFS: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]
    private var writtenPaths: [String] = []
    public var corruptWrites = false
    public var caseInsensitive = false
    /// Paths that are links to folders elsewhere: `fs.stat` answers for them as for a folder, `fs.list` lists one as a
    /// single entry that is not a folder and lists nothing below it.
    public var links: Set<String> = []
    /// Whether `fs.stat` and `fs.list` mark a link with `link`.
    public var reportsLinks = true

    public init() {}

    private func fold(_ path: String) -> String { caseInsensitive ? path.lowercased() : path }

    private func key(for path: String) -> String {
        guard caseInsensitive else { return path }
        let folded = fold(path)
        return store.keys.first { fold($0) == folded } ?? path
    }

    public subscript(path: String) -> Data? {
        get { lock.lock(); defer { lock.unlock() }; return store[key(for: path)] }
        set { lock.lock(); defer { lock.unlock() }; store[key(for: path)] = newValue }
    }

    public func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return store.keys.sorted() }
    public func written() -> [String] { lock.lock(); defer { lock.unlock() }; return writtenPaths }

    public func install(on agent: FakeAgent) {
        agent.handler = { [self] m, _ in
            guard m["t"]?.stringValue == "req" else { return [] }
            return [handle(m)]
        }
    }

    private static func separator(for path: String) -> String { path.contains("\\") ? "\\" : "/" }

    private func isLink(_ path: String) -> Bool { links.contains { fold($0) == fold(path) } }

    /// The fields that say an entry is a link, when links are reported.
    private var linkFields: [String: JSON] { reportsLinks ? ["link": true] : [:] }

    private func reply(_ m: JSON, _ fields: [String: JSON]) -> JSON {
        var o = fields; o["t"] = "res"; o["id"] = m["id"] ?? .null; o["ok"] = true
        return .object(o)
    }

    private func fail(_ m: JSON, _ text: String) -> JSON { ["t": "res", "id": m["id"] ?? .null, "ok": false, "error": .string(text)] }

    private func handle(_ m: JSON) -> JSON {
        lock.lock(); defer { lock.unlock() }
        let path = m["path"]?.stringValue ?? ""
        switch m["op"]?.stringValue {
        case "fs.stat":
            let sep = Self.separator(for: path)
            if isLink(path) {
                var f: [String: JSON] = ["exists": true, "dir": true, "size": 0, "path": .string(path)]
                for (k, v) in linkFields { f[k] = v }
                return reply(m, f)
            }
            if let data = store[key(for: path)] {
                var f: [String: JSON] = ["exists": true, "dir": false, "size": .int(Int64(data.count)), "path": .string(path)]
                if m["sha256"]?.boolValue == true { f["sha256"] = .string(sha256Hex(data)) }
                return reply(m, f)
            }
            if store.keys.contains(where: { fold($0).hasPrefix(fold(path + sep)) }) || links.contains(where: { fold($0).hasPrefix(fold(path + sep)) }) {
                return reply(m, ["exists": true, "dir": true, "size": 0, "path": .string(path)])
            }
            return reply(m, ["exists": false])
        case "fs.list":
            let sep = Self.separator(for: path)
            let prefix = path + sep
            if isLink(path) { return reply(m, ["entries": [], "truncated": false]) }
            let below = links.filter { fold($0).hasPrefix(fold(prefix)) }
            let found = store.filter { entry in
                fold(entry.key).hasPrefix(fold(prefix)) && !below.contains { fold(entry.key).hasPrefix(fold($0 + sep)) }
            }
            if found.isEmpty && below.isEmpty { return fail(m, "'\(path)' does not exist") }
            var entries: [JSON] = found.keys.sorted().map { key in
                let name = String(key.dropFirst(prefix.count)).replacingOccurrences(of: sep, with: "/")
                let data = found[key]!
                return ["name": .string(name), "dir": false, "size": .int(Int64(data.count)), "mtime": "2026-01-01T00:00:00Z", "sha256": .string(sha256Hex(data))]
            }
            for link in below.sorted() {
                let name = String(link.dropFirst(prefix.count)).replacingOccurrences(of: sep, with: "/")
                var row: [String: JSON] = ["name": .string(name), "dir": false, "size": 0, "mtime": "2026-01-01T00:00:00Z"]
                for (k, v) in linkFields { row[k] = v }
                entries.append(.object(row))
            }
            return reply(m, ["entries": .array(entries), "truncated": false])
        case "fs.read":
            guard let data = store[key(for: path)] else { return fail(m, "'\(path)' does not exist") }
            let offset = min(m["offset"]?.intValue ?? 0, data.count)
            let end = min(offset + (m["length"]?.intValue ?? 262144), data.count)
            return reply(m, ["data": .string(data[offset..<end].base64EncodedString()), "size": .int(Int64(data.count)), "eof": .bool(end >= data.count)])
        case "fs.write":
            var piece = Data(base64Encoded: m["data"]?.stringValue ?? "") ?? Data()
            if corruptWrites, !piece.isEmpty { piece[piece.startIndex] ^= 0xFF }
            let target = key(for: path)
            var data = m["truncate"]?.boolValue == true ? Data() : (store[target] ?? Data())
            let offset = m["append"]?.boolValue == true ? data.count : (m["offset"]?.intValue ?? 0)
            if data.count < offset { data.append(Data(count: offset - data.count)) }
            data.replaceSubrange(offset..<min(offset + piece.count, data.count), with: piece)
            store[target] = data
            writtenPaths.append(path)
            return reply(m, ["size": .int(Int64(data.count))])
        case "fs.rename":
            let from = m["from"]?.stringValue ?? "", to = m["to"]?.stringValue ?? ""
            guard let data = store[key(for: from)] else { return fail(m, "'\(from)' does not exist") }
            let existing = key(for: to)
            if store[existing] != nil, m["overwrite"]?.boolValue != true { return fail(m, "'\(to)' exists; pass overwrite to replace it") }
            store[existing] = nil; store[key(for: from)] = nil
            store[to] = data
            return reply(m, ["path": .string(to)])
        case "fs.delete":
            let existed = store.removeValue(forKey: key(for: path)) != nil
            return reply(m, ["deleted": .bool(existed)])
        default:
            return fail(m, "unknown op '\(m["op"]?.stringValue ?? "")'; update alcove-agent")
        }
    }
}
