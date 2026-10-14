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
    /// The element the op was aimed at before it ran:
    /// `{window?, role, name, automationId?, rect?, password?, byAutomationId?, byName?}`.
    var target: JSON? = nil
    /// The kind of call a script run made this op as; nil for an op a client sent.
    var script: String? = nil
    /// Values replaced by `TraceSanitizer.mask` in the params, result, error and target of the line.
    var secrets: [String] = []

    /// The sanitized JSON object of the line.
    var json: JSON {
        var obj: [String: JSON] = [
            "seq": .int(Int64(seq)), "time": .string(TraceEntry.format(time)), "ms": .int(Int64(ms)), "op": .string(op),
            "params": TraceSanitizer.sanitize(TraceSanitizer.maskValues(params, secrets: secrets)), "durationMs": .int(Int64(durationMs)),
        ]
        switch outcome {
        case .success(let result):
            obj["ok"] = true
            obj["result"] = TraceSanitizer.sanitize(result: TraceSanitizer.maskValues(result, secrets: secrets), op: op)
        case .failure(let error):
            obj["ok"] = false
            obj["error"] = TraceSanitizer.sanitize(TraceSanitizer.maskValues(.string(ControlHandler.failureReason(error, fallback: "the op failed")), secrets: secrets))
        }
        if let before { obj["before"] = .string(before) }
        if let after { obj["after"] = .string(after) }
        if let target { obj["target"] = TraceSanitizer.sanitize(TraceSanitizer.maskValues(target, secrets: secrets)) }
        if let script { obj["script"] = .string(script) }
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
    /// What stands in place of a secret-looking env value.
    static let mask = "<masked>"
    /// What follows the key of a cut string in the key of its marker.
    static let cutMarkerSuffix = "Truncated"

    /// Removes `lease`, image payloads and long strings; masks secret-looking env values.
    static func sanitize(_ value: JSON) -> JSON {
        sanitize(value, inEnv: false)
    }

    /// The sanitized result of `op`. In a `vm.http.request` result the values of the `ControlHandler.secretHeaders`
    /// become `<masked>` unless the proxy stored them as `<redacted n chars>`, and a body longer than `maxStringLength`
    /// is cut and marked with `bodyCut`.
    static func sanitize(result: JSON, op: String) -> JSON {
        guard op == "vm.http.request", case .object(var fields) = result else { return sanitize(result) }
        for key in ["headers", "trailers"] {
            guard let pairs = fields[key]?.arrayValue else { continue }
            fields[key] = .array(pairs.map(maskedHeader))
        }
        let body = fields.removeValue(forKey: "body")
        guard case .object(var out) = sanitize(.object(fields)) else { return sanitize(result) }
        if case .string(let text)? = body {
            out["body"] = .string(cut(text))
            if text.count > maxStringLength { out["bodyCut"] = true }
        } else if let body {
            out["body"] = sanitize(body)
        }
        return .object(out)
    }

    /// A header pair whose first item is one of `ControlHandler.secretHeaders` as `[name, "<masked>"]`, whatever
    /// follows the name; a pair whose value the proxy stored as `<redacted n chars>` stays as it is.
    private static func maskedHeader(_ pair: JSON) -> JSON {
        guard let items = pair.arrayValue, let name = items.first?.stringValue,
              ControlHandler.secretHeaders.contains(name.lowercased()) else { return pair }
        if items.count == 2, let value = items[1].stringValue, isRedacted(value) { return pair }
        return [.string(name), "<masked>"]
    }

    /// Whether `value` is `<redacted n chars>` with a decimal number and nothing else.
    private static func isRedacted(_ value: String) -> Bool {
        guard value.hasPrefix("<redacted "), value.hasSuffix(" chars>") else { return false }
        let digits = value.dropFirst("<redacted ".count).dropLast(" chars>".count)
        return !digits.isEmpty && digits.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
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
                if inEnv, isSecret(key) { out[key] = .string(mask); continue }
                if case .string(let text) = field, text.count > maxStringLength {
                    out[key] = .string(cut(text))
                    out[key + cutMarkerSuffix] = true
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

    /// The shortest secret that is also replaced where it occurs inside a longer string.
    static let minSubstringSecret = 8

    /// `value` with each string that equals a secret replaced by `mask`, and each occurrence of a secret of at least
    /// `minSubstringSecret` characters inside a longer string.
    static func maskValues(_ value: JSON, secrets: [String], replacement: String = mask) -> JSON {
        let known = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        guard !known.isEmpty else { return value }
        func walk(_ item: JSON) -> JSON {
            switch item {
            case .string(let text):
                if known.contains(text) { return .string(replacement) }
                var out = text
                for secret in known where secret.count >= minSubstringSecret { out = out.replacingOccurrences(of: secret, with: replacement) }
                return .string(out)
            case .array(let items): return .array(items.map(walk))
            case .object(let fields): return .object(fields.mapValues(walk))
            default: return item
            }
        }
        return walk(value)
    }

    /// Whether `key` contains one of `secretMarkers`, whatever its case.
    static func isSecret(_ key: String) -> Bool {
        let upper = key.uppercased()
        return secretMarkers.contains { upper.contains($0) }
    }

    /// `text` with `<masked>` in place of the value of every `NAME=value` pair whose name `isSecret`. The name is the run
    /// of ASCII letters, digits, `_`, `.` and `-` right before the `=`; the value starts right after it and ends at the
    /// next white space, or at the closing quote when it starts with `"` or `'`.
    static func maskAssignments(_ text: String) -> String {
        var out = ""
        var name = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            out.append(character)
            guard character == "=" else {
                let inName = character.isASCII && (character.isLetter || character.isNumber || "_.-".contains(character))
                name = inName ? name + String(character) : ""
                continue
            }
            let secret = isSecret(name)
            name = ""
            guard secret else { continue }
            if index < text.endIndex, text[index] == "\"" || text[index] == "'" {
                let quote = text[index]
                let close = text[text.index(after: index)...].firstIndex(of: quote)
                index = close.map { text.index(after: $0) } ?? text.endIndex
            } else {
                while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            }
            out += "<masked>"
        }
        return out
    }
}

/// Reads a trace file one line at a time.
enum TraceReader {
    /// Calls `body` with each line of the file at `path` that is at most `limit` bytes long, in file order and without
    /// its line feed, and returns the number of longer lines. The file is read in pieces of `chunk` bytes; of a longer
    /// line nothing is kept. Throws when the file cannot be read, and what `body` throws.
    static func lines(at path: String, limit: Int, chunk: Int = 1 << 20, _ body: (Data) throws -> Void) throws -> Int {
        var longLines = 0
        try numberedLines(at: path, limit: limit, chunk: chunk, { line, _ in try body(line) }, tooLong: { _ in longLines += 1 })
        return longLines
    }

    /// Like `lines`, with the 1-based number of each line given to `body` and, for each line longer than `limit`, to `tooLong`.
    static func numberedLines(at path: String, limit: Int, chunk: Int = 1 << 20, _ body: (Data, Int) throws -> Void,
                              tooLong report: (Int) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var line = Data()
        var tooLong = false
        var number = 1
        while let piece = try handle.read(upToCount: chunk), !piece.isEmpty {
            var rest = piece[...]
            while let feed = rest.firstIndex(of: 0x0A) {
                let head = rest[rest.startIndex..<feed]
                if tooLong || line.count + head.count > limit {
                    report(number)
                } else {
                    line.append(head)
                    try body(line, number)
                }
                number += 1
                line = Data()
                tooLong = false
                rest = rest[rest.index(after: feed)...]
            }
            if tooLong { continue }
            if line.count + rest.count > limit {
                tooLong = true
                line = Data()
            } else {
                line.append(rest)
            }
        }
        if tooLong { report(number) } else if !line.isEmpty { try body(line, number) }
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

    /// Creates the directory and `frames/` with mode 0700 where they are missing, and an empty `trace.jsonl` with mode
    /// 0600; throws `WriterError.exists` when `trace.jsonl` is already there.
    init(directory: URL) throws {
        self.directory = directory
        let fm = FileManager.default
        let owned: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: owned)
        try fm.createDirectory(at: directory.appendingPathComponent(TraceWriter.framesName), withIntermediateDirectories: true, attributes: owned)
        let trace = directory.appendingPathComponent(TraceWriter.traceName)
        let descriptor = open(trace.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
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

    /// Writes `frame` as a half-size JPEG (quality 0.6) with mode 0600 to `frames/<name>`, replacing a file there in one
    /// rename, and returns its path relative to the directory.
    func writeFrame(_ frame: Frame, name: String) throws -> String {
        let data = frame.scaled(by: 0.5).encoded(.jpeg, quality: 0.6)
        guard !data.isEmpty else { throw WriterError.unencodable }
        let relative = "\(TraceWriter.framesName)/\(name)"
        _ = try ControlHandler.writeHostFile(data, to: directory.appendingPathComponent(relative), replacing: true)
        return relative
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}
