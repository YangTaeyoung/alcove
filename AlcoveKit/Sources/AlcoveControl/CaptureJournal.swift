import Foundation
import AlcoveQMP

/// The record of HTTP captures whose guest is not restored: `captures.json` in the proxy's CA directory. It holds one
/// entry per VM whose guest a `vm.http.start` changed, and one note per snapshot created during such a capture.
///
/// Every control handler of this user shares the file. A change reads the file, edits it and replaces it in one step
/// while it holds an exclusive lock on `captures.json.lock`. A file that cannot be read as version 1 counts as
/// empty; the next change renames it to `captures.json.unreadable-<UTC time>` and writes a new one.
struct CaptureJournal: Sendable {
    /// What a capture changed in the guest of one VM.
    struct Entry: Equatable, Sendable {
        var vm: String
        /// The loopback port the capture's proxy listens on.
        var port: Int
        /// The SHA-1 of the CA certificate the capture installed, as 40 upper-case hexadecimal digits.
        var thumbprint: String
        /// Whether the capture set the guest's system proxy.
        var systemProxy: Bool
        /// When the capture started, as ISO 8601 text.
        var since: String

        fileprivate var json: [String: JSON] {
            ["vm": .string(vm), "port": .int(Int64(port)), "thumbprint": .string(thumbprint), "systemProxy": .bool(systemProxy),
             "since": .string(since)]
        }

        fileprivate init?(_ json: JSON) {
            guard let vm = json["vm"]?.stringValue, let port = json["port"]?.intValue, (1...65_535).contains(port),
                  let thumbprint = json["thumbprint"]?.stringValue, ControlHandler.isThumbprint(thumbprint),
                  let systemProxy = json["systemProxy"]?.boolValue, let since = json["since"]?.stringValue else { return nil }
            self.init(vm: vm, port: port, thumbprint: thumbprint.uppercased(), systemProxy: systemProxy, since: since)
        }

        init(vm: String, port: Int, thumbprint: String, systemProxy: Bool, since: String) {
            self.vm = vm
            self.port = port
            self.thumbprint = thumbprint
            self.systemProxy = systemProxy
            self.since = since
        }
    }

    enum JournalError: Error, CustomStringConvertible {
        case unusable(path: String, reason: String)

        var description: String {
            switch self {
            case .unusable(let path, let reason):
                return "the record of captures to restore at \(path) could not be written (\(reason)); make its folder writable and call vm.http.start again"
            }
        }
    }

    private struct Contents {
        var captures: [Entry] = []
        /// The capture a snapshot was created during, by VM and snapshot name.
        var snapshots: [(snapshot: String, entry: Entry)] = []
    }

    /// The path of `captures.json`.
    let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("captures.json")
    }

    /// The entry of `vm`; nil when the file holds none, is missing or cannot be read.
    func entry(for vm: String) -> Entry? {
        read()?.captures.first { $0.vm == vm }
    }

    /// The capture during which `snapshot` of `vm` was created; nil when none is noted.
    func snapshotEntry(_ snapshot: String, vm: String) -> Entry? {
        read()?.snapshots.first { $0.snapshot == snapshot && $0.entry.vm == vm }?.entry
    }

    /// Stores `entry` in place of the entry of its VM.
    func record(_ entry: Entry, now: Date) throws {
        try change(now: now) { contents in
            contents.captures.removeAll { $0.vm == entry.vm }
            contents.captures.append(entry)
        }
    }

    /// Removes the entry of `vm`.
    func remove(vm: String, now: Date) throws {
        guard entry(for: vm) != nil else { return }
        try change(now: now) { $0.captures.removeAll { $0.vm == vm } }
    }

    /// Notes that `snapshot` was created during the capture `entry` describes, in place of an earlier note for that
    /// snapshot name.
    func noteSnapshot(_ snapshot: String, during entry: Entry, now: Date) throws {
        try change(now: now) { contents in
            contents.snapshots.removeAll { $0.snapshot == snapshot && $0.entry.vm == entry.vm }
            contents.snapshots.append((snapshot, entry))
        }
    }

    /// Removes the note of `snapshot` of `vm`.
    func forgetSnapshot(_ snapshot: String, vm: String, now: Date) throws {
        guard snapshotEntry(snapshot, vm: vm) != nil else { return }
        try change(now: now) { $0.snapshots.removeAll { $0.snapshot == snapshot && $0.entry.vm == vm } }
    }

    /// Removes the entry and every snapshot note of `vm`.
    func forget(vm: String, now: Date) throws {
        guard let contents = read(), contents.captures.contains(where: { $0.vm == vm })
                || contents.snapshots.contains(where: { $0.entry.vm == vm }) else { return }
        try change(now: now) { contents in
            contents.captures.removeAll { $0.vm == vm }
            contents.snapshots.removeAll { $0.entry.vm == vm }
        }
    }

    // MARK: - the file

    /// What the file holds; nil when it is missing or cannot be read as version 1.
    private func read() -> Contents? {
        guard let data = try? Data(contentsOf: url), let json = try? JSON.parse(data), json["version"]?.intValue == 1,
              let captures = json["captures"]?.arrayValue, let snapshots = json["snapshots"]?.arrayValue else { return nil }
        var contents = Contents()
        for item in captures {
            guard let entry = Entry(item) else { return nil }
            contents.captures.append(entry)
        }
        for item in snapshots {
            guard let snapshot = item["snapshot"]?.stringValue, let entry = Entry(item) else { return nil }
            contents.snapshots.append((snapshot, entry))
        }
        return contents
    }

    /// Reads the file, applies `edit` and replaces the file with the result, all under the lock. A file that is there
    /// and cannot be read is renamed first.
    private func change(now: Date, _ edit: (inout Contents) -> Void) throws {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw JournalError.unusable(path: url.path, reason: error.localizedDescription)
        }
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw JournalError.unusable(path: url.path, reason: String(cString: strerror(errno))) }
        defer { close(lock) }
        while flock(lock, LOCK_EX) != 0 {
            guard errno == EINTR else { throw JournalError.unusable(path: url.path, reason: String(cString: strerror(errno))) }
        }
        defer { flock(lock, LOCK_UN) }

        let stored = read()
        var contents = stored ?? Contents()
        if stored == nil, FileManager.default.fileExists(atPath: url.path) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            let aside = URL(fileURLWithPath: url.path + ".unreadable-" + formatter.string(from: now))
            try? FileManager.default.removeItem(at: aside)
            do { try FileManager.default.moveItem(at: url, to: aside) } catch {
                throw JournalError.unusable(path: url.path, reason: error.localizedDescription)
            }
        }
        edit(&contents)
        let json: JSON = [
            "version": 1,
            "captures": .array(contents.captures.map { .object($0.json) }),
            "snapshots": .array(contents.snapshots.map { note in
                var fields = note.entry.json
                fields["snapshot"] = .string(note.snapshot)
                return .object(fields)
            }),
        ]
        do {
            var data = try json.serialized()
            data.append(10)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw JournalError.unusable(path: url.path, reason: error.localizedDescription)
        }
    }
}
