import Foundation
import AlcoveQMP

/// One line of `trace.jsonl`.
struct TraceEntry {
    let seq: Int
    let time: Date
    let ms: Int
    let op: String
    let params: JSON
    let outcome: Result<JSON, Error>
    let durationMs: Int
    let before: String?
    let after: String?

    /// The sanitized JSON object of the line.
    var json: JSON {
        var obj: [String: JSON] = [
            "seq": .int(Int64(seq)), "time": .string(TraceEntry.format(time)), "ms": .int(Int64(ms)), "op": .string(op),
            "params": TraceSanitizer.sanitize(params), "durationMs": .int(Int64(durationMs)),
        ]
        switch outcome {
        case .success(let result):
            obj["ok"] = true
            obj["result"] = TraceSanitizer.sanitize(result)
        case .failure(let error):
            obj["ok"] = false
            obj["error"] = TraceSanitizer.sanitize(.string("\(error)"))
        }
        if let before { obj["before"] = .string(before) }
        if let after { obj["after"] = .string(after) }
        return .object(obj)
    }

    /// ISO 8601 with milliseconds.
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Cleans request and result objects before they are written to a trace.
enum TraceSanitizer {
    static let maxStringLength = 2000
    static let imageKeys: Set<String> = ["png", "jpeg"]
    static let secretMarkers = ["KEY", "TOKEN", "SECRET", "PASSWORD"]

    /// Removes `lease`, image payloads and long strings; masks secret-looking env values.
    static func sanitize(_ value: JSON) -> JSON {
        sanitize(value, inEnv: false)
    }

    private static func sanitize(_ value: JSON, inEnv: Bool) -> JSON {
        switch value {
        case .array(let items):
            return .array(items.map { sanitize($0, inEnv: false) })
        case .string(let text):
            return .string(cut(text))
        case .object(let fields):
            var out: [String: JSON] = [:]
            for (key, field) in fields {
                if key == "lease" { continue }
                if imageKeys.contains(key) { out[key] = "<image omitted>"; continue }
                if inEnv, isSecret(key) { out[key] = "<masked>"; continue }
                if case .string(let text) = field, text.count > maxStringLength {
                    out[key] = .string(cut(text))
                    out["\(key)Truncated"] = true
                    continue
                }
                out[key] = sanitize(field, inEnv: key == "env")
            }
            return .object(out)
        default:
            return value
        }
    }

    private static func cut(_ text: String) -> String {
        text.count > maxStringLength ? String(text.prefix(maxStringLength)) + "…" : text
    }

    private static func isSecret(_ key: String) -> Bool {
        let upper = key.uppercased()
        return secretMarkers.contains { upper.contains($0) }
    }
}

/// Where a recording writes its trace lines and frame files.
protocol TraceStore: Sendable {
    func append(_ entry: TraceEntry) throws
    /// Writes `frame` as a frame file named `name` and returns its path relative to the recording directory.
    func writeFrame(_ frame: Frame, name: String) throws -> String
    func close()
}

/// Appends trace lines and frame files below one recording directory.
final class TraceWriter: TraceStore, @unchecked Sendable {
    enum WriterError: Error, CustomStringConvertible {
        case closed, unencodable, exists
        var description: String {
            switch self {
            case .closed: return "the trace is closed"
            case .unencodable: return "the frame could not be encoded"
            case .exists: return "the directory already holds a recording"
            }
        }
    }

    static let traceName = "trace.jsonl"
    static let framesName = "frames"

    let directory: URL
    private let lock = NSLock()
    private var handle: FileHandle?

    /// Creates the directory, `frames/` and an empty `trace.jsonl`; throws `WriterError.exists` when `trace.jsonl` is already there.
    init(directory: URL) throws {
        self.directory = directory
        let fm = FileManager.default
        try fm.createDirectory(at: directory.appendingPathComponent(TraceWriter.framesName), withIntermediateDirectories: true)
        let trace = directory.appendingPathComponent(TraceWriter.traceName)
        let descriptor = open(trace.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw WriterError.exists }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: trace.path])
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit { try? handle?.close() }

    /// Writes one line with a single write call.
    func append(_ entry: TraceEntry) throws {
        var line = try entry.json.serialized()
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw WriterError.closed }
        try handle.write(contentsOf: line)
    }

    /// Writes `frame` as a half-size JPEG (quality 0.6) to `frames/<name>` and returns its path relative to the directory.
    func writeFrame(_ frame: Frame, name: String) throws -> String {
        let data = frame.scaled(by: 0.5).encoded(.jpeg, quality: 0.6)
        guard !data.isEmpty else { throw WriterError.unencodable }
        let relative = "\(TraceWriter.framesName)/\(name)"
        try data.write(to: directory.appendingPathComponent(relative), options: .atomic)
        return relative
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}
