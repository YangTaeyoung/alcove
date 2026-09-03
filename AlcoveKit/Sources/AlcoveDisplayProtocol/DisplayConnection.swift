import Foundation

/// The app side of the display protocol: owns a listening unix socket that
/// the QEMU `alcove` backend connects to, decodes inbound messages onto an
/// `AsyncStream`, and writes outbound messages.
///
/// Thread-safe: all socket state is confined to a private serial queue.
public final class DisplayConnection: @unchecked Sendable {
    public enum ConnectionError: Error, Equatable {
        case socket(errno: Int32)
        case bind(path: String, errno: Int32)
        case listen(errno: Int32)
        case pathTooLong(String)
    }

    /// Why the inbound stream ended.
    public enum EndReason: Sendable, Equatable {
        case peerClosed
        case protocolError(String)
        case closed
    }

    public let socketPath: String
    /// Inbound messages from QEMU. Finishes when the peer disconnects or `close()` is called.
    public let messages: AsyncStream<FromQEMU>

    private let queue = DispatchQueue(label: "alcove.display.connection")
    private let continuation: AsyncStream<FromQEMU>.Continuation
    private var listenFD: Int32
    private var listenSource: DispatchSourceRead?
    private var clientFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var splitter = LineSplitter()
    private var outbox = Data()
    private var finished = false
    private var endReason: EndReason?
    private let onEnd: (@Sendable (EndReason) -> Void)?

    /// Create the socket at `socketPath` (a stale file is removed) and start listening.
    /// The first client to connect becomes the peer; later connections are refused.
    public init(socketPath: String, onEnd: (@Sendable (EndReason) -> Void)? = nil) throws {
        var addr = sockaddr_un()
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard socketPath.utf8.count <= maxLen else { throw ConnectionError.pathTooLong(socketPath) }
        self.socketPath = socketPath
        self.onEnd = onEnd

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectionError.socket(errno: errno) }
        unlink(socketPath)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in
                _ = socketPath.withCString { strncpy(dst, $0, maxLen) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else {
            let e = errno; Darwin.close(fd)
            throw ConnectionError.bind(path: socketPath, errno: e)
        }
        chmod(socketPath, 0o600)
        guard listen(fd, 1) == 0 else {
            let e = errno; Darwin.close(fd); unlink(socketPath)
            throw ConnectionError.listen(errno: e)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        var cont: AsyncStream<FromQEMU>.Continuation!
        messages = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        listenSource = source
    }

    deinit {
        close()
    }

    /// Whether QEMU is currently connected.
    public var isConnected: Bool { queue.sync { clientFD >= 0 } }

    /// Queue a message for QEMU. Safe from any thread; drops silently once closed.
    public func send(_ message: ToQEMU) {
        let line = message.encodedLine
        queue.async { [self] in
            guard clientFD >= 0 else { return }
            outbox.append(contentsOf: line.utf8)
            flushOutbox()
        }
    }

    /// Stop listening, disconnect the peer and finish the stream.
    public func close() {
        queue.sync { finish(.closed) }
    }

    // MARK: - queue-confined

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        guard clientFD < 0 else { Darwin.close(fd); return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        clientFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source
        // one peer only
        listenSource?.cancel()
        listenSource = nil
        Darwin.close(listenFD)
        listenFD = -1
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while clientFD >= 0 {
            let n = buffer.withUnsafeMutableBytes { read(clientFD, $0.baseAddress, $0.count) }
            if n > 0 {
                let lines: [Data]
                do {
                    lines = try splitter.feed(Data(buffer[0..<n]))
                } catch {
                    finish(.protocolError("\(error)"))
                    return
                }
                for line in lines {
                    do {
                        continuation.yield(try FromQEMU.decode(line))
                    } catch {
                        // tolerate garbage on a single line; keep the connection
                        continue
                    }
                }
                if n < buffer.count { return }
                continue
            }
            if n == 0 { finish(.peerClosed); return }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            finish(.protocolError(String(cString: strerror(errno))))
            return
        }
    }

    private func flushOutbox() {
        while clientFD >= 0, !outbox.isEmpty {
            let n = outbox.withUnsafeBytes { write(clientFD, $0.baseAddress, $0.count) }
            if n > 0 {
                outbox.removeFirst(n)
                continue
            }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: clientFD, queue: queue)
                    source.setEventHandler { [weak self] in self?.flushOutbox() }
                    source.resume()
                    writeSource = source
                }
                return
            }
            if n < 0, errno == EINTR { continue }
            finish(.peerClosed)
            return
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func finish(_ reason: EndReason) {
        guard !finished else { return }
        finished = true
        endReason = reason
        listenSource?.cancel(); listenSource = nil
        readSource?.cancel(); readSource = nil
        writeSource?.cancel(); writeSource = nil
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        if clientFD >= 0 { Darwin.close(clientFD); clientFD = -1 }
        unlink(socketPath)
        continuation.finish()
        onEnd?(reason)
    }
}
