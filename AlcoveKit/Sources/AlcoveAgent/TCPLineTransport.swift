import Foundation
import CryptoKit

/// A client TCP connection delivering newline-terminated lines (loopback only).
final class TCPLineTransport: @unchecked Sendable {
    enum TransportError: Error, Equatable { case socket(errno: Int32), connect(errno: Int32) }

    /// The most bytes buffered while waiting for a newline; a longer line ends the connection with `lineTooLong`.
    static let maxLineBytes = 8 << 20
    /// The reason `onEnd` receives when a line passed `maxLineBytes`.
    static let lineTooLong = "line too long"

    private let queue = DispatchQueue(label: "alcove.agent.transport")
    private var fd: Int32
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var pending = Data()
    private var outbox = Data()
    private var closed = false
    private let onLine: @Sendable (Data) -> Void
    private let onEnd: @Sendable (String) -> Void

    init(host: String, port: Int, onLine: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable (String) -> Void) throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw TransportError.socket(errno: errno) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr(host)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { let e = errno; Darwin.close(s); throw TransportError.connect(errno: e) }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        self.onLine = onLine
        self.onEnd = onEnd
        let source = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source
    }

    deinit { finish("closed") }

    func send(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            outbox.append(data)
            flush()
        }
    }

    func close() { queue.sync { finish("closed") } }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !closed {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                pending.append(contentsOf: buffer[0..<n])
                while let nl = pending.firstIndex(of: 10) {
                    let line = Data(pending[pending.startIndex..<nl])
                    pending.removeSubrange(pending.startIndex...nl)
                    if !line.isEmpty { onLine(line) }
                }
                if pending.count > TCPLineTransport.maxLineBytes { finish(TCPLineTransport.lineTooLong); return }
                if n < buffer.count { return }
                continue
            }
            if n == 0 { finish("peer closed"); return }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            finish(String(cString: strerror(errno))); return
        }
    }

    private func flush() {
        while !closed, !outbox.isEmpty {
            let n = outbox.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { outbox.removeFirst(n); continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if writeSource == nil {
                    let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    w.setEventHandler { [weak self] in self?.flush() }
                    w.resume()
                    writeSource = w
                }
                return
            }
            if n < 0, errno == EINTR { continue }
            finish("write failed"); return
        }
        writeSource?.cancel(); writeSource = nil
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        readSource?.cancel(); readSource = nil
        writeSource?.cancel(); writeSource = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        onEnd(reason)
    }
}

enum SHA256Digest {
    static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
