import Foundation

/// Splits a byte stream into newline-terminated lines, keeping a partial
/// trailing line between calls. Empty lines are dropped.
public struct LineSplitter: Sendable {
    /// Lines longer than this are rejected as a protocol violation.
    public let maxLineLength: Int
    private var pending = Data()

    public init(maxLineLength: Int = 1 << 20) {
        self.maxLineLength = maxLineLength
    }

    /// Feed a chunk; returns every complete line (without its newline).
    public mutating func feed(_ chunk: Data) throws -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<nl]
            if !line.isEmpty {
                lines.append(Data(line))
            }
            pending.removeSubrange(pending.startIndex...nl)
        }
        if pending.count > maxLineLength {
            let n = pending.count
            pending.removeAll()
            throw DisplayProtocolError.lineTooLong(n)
        }
        return lines
    }

    /// Bytes buffered that do not yet form a complete line.
    public var pendingCount: Int { pending.count }
}
