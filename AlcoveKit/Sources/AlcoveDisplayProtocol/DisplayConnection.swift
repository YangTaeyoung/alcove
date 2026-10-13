import Foundation

/// The app side of the display protocol: owns a listening unix socket that
/// the QEMU `alcove` backend connects to, decodes inbound messages onto an
/// `AsyncStream`, and writes outbound messages.
///
/// Thread-safe: all socket state is confined to a private serial queue. Every
/// public member may be called from any thread, including from `onEnd` and
/// from the connection's own queue; no block queued on that queue ever holds
/// a strong reference to the connection, so releasing the last reference from
/// any thread is safe.
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
    /// Set on `queue` only, so `DispatchQueue.getSpecific` tells whether the
    /// caller is already on it (a `sync` from there would deadlock/abort).
    private let queueKey = DispatchSpecificKey<Bool>()
    private let continuation: AsyncStream<FromQEMU>.Continuation
    private var listenFD: Int32
    private var listenSource: DispatchSourceRead?
    private var clientFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var splitter = LineSplitter()
    private var outbox = Data()
    private var surface: FromQEMU.SurfaceSwitch?
    private var finished = false
    private var endReason: EndReason?
    private let onEnd: (@Sendable (EndReason) -> Void)?

    /// Create the socket at `socketPath` (a stale file is removed) and start listening.
    /// The first client to connect becomes the peer; later connections are refused.
    ///
    /// `onEnd` is called exactly once, on a global concurrent queue (never on
    /// the connection's own queue), after the stream has finished and the
    /// sockets are closed. It may call back into the connection.
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

        queue.setSpecific(key: queueKey, value: true)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        // Store before resuming: a client already queued on the socket makes
        // acceptClient() run on `queue` immediately, and it must see the source.
        listenSource = source
        source.resume()
    }

    deinit {
        // No other reference exists and every queued block captures `self`
        // weakly, so nothing can touch the state concurrently: tear down
        // directly. Hopping onto `queue` here would abort the process whenever
        // the last reference is dropped on the queue itself.
        finish(.closed)
    }

    /// Whether QEMU is currently connected.
    public var isConnected: Bool { onQueue { clientFD >= 0 } }

    /// The latest valid `switch` for console 0; nil before the first one and after the connection ends.
    public var currentSurface: FromQEMU.SurfaceSwitch? { onQueue { surface } }

    /// Queue a message for QEMU. Safe from any thread; drops silently once closed.
    public func send(_ message: ToQEMU) {
        let line = message.encodedLine
        // Weak: a queued send must never be the last owner of the connection.
        queue.async { [weak self] in
            guard let self, self.clientFD >= 0 else { return }
            self.outbox.append(contentsOf: line.utf8)
            self.flushOutbox()
        }
    }

    /// Stop listening, disconnect the peer and finish the stream. Idempotent;
    /// safe from any thread, including the connection's own queue and `onEnd`.
    public func close() {
        onQueue { finish(.closed) }
    }

    /// Run `body` on `queue`, synchronously, without deadlocking when the
    /// caller is already on it.
    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            return body()
        }
        return queue.sync(execute: body)
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
        readSource = source
        source.resume()
        // One peer only (QEMU connects exactly once): stop listening and give
        // up the path now, so a later listener bound to the same path is not
        // removed when this instance finishes.
        listenSource?.cancel()
        listenSource = nil
        Darwin.close(listenFD)
        listenFD = -1
        unlink(socketPath)
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
                        let message = try FromQEMU.decode(line)
                        if case .switchSurface(let s) = message, s.con == 0, s.isValid { surface = s }
                        continuation.yield(message)
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
                    writeSource = source
                    source.resume()
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

    /// Tear everything down once. Runs on `queue`, or from `deinit`.
    private func finish(_ reason: EndReason) {
        guard !finished else { return }
        finished = true
        endReason = reason
        surface = nil
        listenSource?.cancel(); listenSource = nil
        readSource?.cancel(); readSource = nil
        writeSource?.cancel(); writeSource = nil
        // The path belongs to this instance only while it is still listening
        // (acceptClient() unlinks it when the peer arrives).
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1; unlink(socketPath) }
        if clientFD >= 0 { Darwin.close(clientFD); clientFD = -1 }
        continuation.finish()
        // Deliver off the queue so the handler may call back into the
        // connection (isConnected/close/send) without re-entering `queue`.
        if let onEnd {
            DispatchQueue.global().async { onEnd(reason) }
        }
    }
}
