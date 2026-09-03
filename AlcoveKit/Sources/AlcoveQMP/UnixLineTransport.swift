import Foundation

/// A client connection to a unix stream socket delivering newline-terminated
/// lines (a trailing CR is stripped, QEMU terminates QMP lines with CRLF).
/// All socket state lives on a private serial queue; callbacks are invoked on
/// that queue, in wire order, and `onEnd` is invoked exactly once after the
/// last `onLine`.
final class UnixLineTransport: @unchecked Sendable {
    enum TransportError: Error, Equatable {
        case pathTooLong(String)
        case socket(errno: Int32)
        case connect(path: String, errno: Int32)
    }

    private let queue = DispatchQueue(label: "alcove.qmp.transport")
    private let queueKey = DispatchSpecificKey<Int>()
    private var fd: Int32
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var pending = Data()
    private var outbox = Data()
    private var closed = false
    private let onLine: @Sendable (Data) -> Void
    private let onEnd: @Sendable (String) -> Void

    init(path: String, onLine: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable (String) -> Void) throws {
        var addr = sockaddr_un()
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else { throw TransportError.pathTooLong(path) }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw TransportError.socket(errno: errno) }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in _ = path.withCString { strncpy(dst, $0, maxLen) } }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { let e = errno; Darwin.close(s); throw TransportError.connect(path: path, errno: e) }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        self.onLine = onLine
        self.onEnd = onEnd
        queue.setSpecific(key: queueKey, value: 1)
        let source = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        // The descriptor is closed only from the cancellation handler: libdispatch
        // documents that closing it earlier races with a still-running event handler
        // if the descriptor number gets reused (man dispatch_source_set_cancel_handler).
        source.setCancelHandler { Darwin.close(s) }
        source.resume()
        readSource = source
    }

    /// Never dispatch_sync from here: the last reference can be dropped inside a
    /// block running on `queue` (e.g. the owner releases us from `onEnd`), and a
    /// sync hop onto the current serial queue traps. Cancelling is asynchronous;
    /// the read source's cancel handler closes the descriptor once no handler runs.
    deinit {
        writeSource?.cancel()
        readSource?.cancel()
    }

    func send(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            outbox.append(data)
            flush()
        }
    }

    /// Close the socket. `onEnd("closed")` is invoked (once) before this returns
    /// unless the transport already ended.
    func close() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            finish("closed")            // already on our queue: a sync hop would deadlock/trap
        } else {
            queue.sync { finish("closed") }
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !closed {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                pending.append(contentsOf: buffer[0..<n])
                while let nl = pending.firstIndex(of: 10) {
                    var line = pending[pending.startIndex..<nl]
                    if line.last == 13 { line = line.dropLast() }   // CRLF framing (monitor/monitor.c monitor_puts_locked)
                    let out = Data(line)
                    pending.removeSubrange(pending.startIndex...nl)
                    if !out.isEmpty { onLine(out) }
                }
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
        // Write source first: once cancelled its handler cannot fire again, so the
        // read source's cancel handler (which closes the fd) cannot race with it.
        writeSource?.cancel(); writeSource = nil
        readSource?.cancel(); readSource = nil
        fd = -1
        onEnd(reason)
    }
}
