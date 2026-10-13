import Foundation
import AlcoveQMP

/// Unix-socket server for the control protocol: newline-delimited JSON
/// requests `{"id", "op", ...}` answered with `{"id", "ok", ...}`.
/// Multiple clients. Each connection has two lanes: operations for which
/// `ControlHandler.isConcurrent` is true start at once in their own task and
/// answer when they finish; all other operations run one after another in the
/// order they arrived. Closing a connection cancels its tasks.
public final class ControlServer: @unchecked Sendable {
    public enum ServerError: Error, Equatable { case socket(errno: Int32), bind(path: String, errno: Int32), listen(errno: Int32), pathTooLong(String) }

    public static var defaultSocketPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Alcove/control.sock")
    }

    public let socketPath: String
    private let handler: ControlHandler
    private let queue = DispatchQueue(label: "alcove.control.server")
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var nextConnectionID = 0
    private var nextTaskID = 0
    private var discardedReplies = 0

    private final class Client {
        /// Server-wide number of this connection; a later connection on the same descriptor has a different one.
        let id: Int
        let fd: Int32
        var source: DispatchSourceRead?
        var pending = Data()
        /// The newest task of the serial lane.
        var task: Task<Void, Never>?
        /// The running tasks of the concurrent lane by server-wide task id.
        var concurrent: [Int: Task<Void, Never>] = [:]
        init(id: Int, fd: Int32) { self.id = id; self.fd = fd }

        func cancelTasks() {
            task?.cancel()
            for (_, t) in concurrent { t.cancel() }
            concurrent.removeAll()
        }
    }

    public init(handler: ControlHandler, socketPath: String = ControlServer.defaultSocketPath) {
        self.handler = handler
        self.socketPath = socketPath
    }

    /// Whether another server already answers on `path`.
    public static func isAlive(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in _ = path.withCString { strncpy(dst, $0, maxLen) } } }
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    }

    public func start() throws {
        var addr = sockaddr_un()
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard socketPath.utf8.count <= maxLen else { throw ServerError.pathTooLong(socketPath) }
        try? FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno: errno) }
        unlink(socketPath)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in _ = socketPath.withCString { strncpy(dst, $0, maxLen) } } }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { let e = errno; Darwin.close(fd); throw ServerError.bind(path: socketPath, errno: e) }
        chmod(socketPath, 0o600)
        guard listen(fd, 8) == 0 else { let e = errno; Darwin.close(fd); unlink(socketPath); throw ServerError.listen(errno: e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.resume()
        listenSource = source
    }

    public func stop() {
        queue.sync { shutDown() }
    }

    deinit { shutDown() }

    /// Closes the listener and every connection, cancels their tasks and removes the socket file.
    private func shutDown() {
        listenSource?.cancel(); listenSource = nil
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        for (_, c) in clients { c.source?.cancel(); c.cancelTasks(); Darwin.close(c.fd) }
        clients.removeAll()
        unlink(socketPath)
    }

    private func acceptClients() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let client = Client(id: nextConnectionID, fd: fd)
            nextConnectionID += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable(client) }
            source.resume()
            client.source = source
            clients[fd] = client
        }
    }

    private func readAvailable(_ client: Client) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(client.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                client.pending.append(contentsOf: buffer[0..<n])
                while let nl = client.pending.firstIndex(of: 10) {
                    let line = Data(client.pending[client.pending.startIndex..<nl])
                    client.pending.removeSubrange(client.pending.startIndex...nl)
                    if !line.isEmpty { enqueue(line, for: client) }
                }
                if client.pending.count > (8 << 20) { closeClient(client); return }
                if n < buffer.count { return }
                continue
            }
            if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { closeClient(client); return }
            return
        }
    }

    /// Starts a concurrent operation in its own tracked task; chains any other request behind the connection's previous serial task.
    private func enqueue(_ line: Data, for client: Client) {
        let fd = client.fd
        let connection = client.id
        let handler = self.handler
        if let op = (try? JSON.parse(line))?["op"]?.stringValue, ControlHandler.isConcurrent(op: op) {
            let id = nextTaskID
            nextTaskID += 1
            client.concurrent[id] = Task { [weak self] in
                let reply = await ControlServer.process(line, handler: handler)
                self?.write(reply, to: fd, connection: connection)
                self?.forgetConcurrentTask(id, of: fd)
            }
            return
        }
        let previous = client.task
        client.task = Task { [weak self] in
            await previous?.value
            let reply = await ControlServer.process(line, handler: handler)
            self?.write(reply, to: fd, connection: connection)
        }
    }

    private func forgetConcurrentTask(_ id: Int, of fd: Int32) {
        queue.async { [self] in clients[fd]?.concurrent[id] = nil }
    }

    /// The number of concurrent-lane tasks that are still tracked, over all connections.
    func concurrentTaskCount() -> Int {
        queue.sync { clients.values.reduce(0) { $0 + $1.concurrent.count } }
    }

    /// The number of open connections.
    func connectionCount() -> Int {
        queue.sync { clients.count }
    }

    /// The number of replies dropped because their connection had closed.
    func discardedReplyCount() -> Int {
        queue.sync { discardedReplies }
    }

    static func process(_ line: Data, handler: ControlHandler) async -> Data {
        var id: JSON = .null
        var result: [String: JSON]
        do {
            let req = try JSON.parse(line)
            id = req["id"] ?? .null
            guard let op = req["op"]?.stringValue else { throw ControlHandler.ControlError.missing("op") }
            let r = try await handler.handle(op: op, params: req)
            result = r.objectValue ?? [:]
            result["ok"] = true
        } catch let e as ControlHandler.ControlError {
            result = ["ok": false, "error": .string(e.description)]
        } catch {
            result = ["ok": false, "error": .string("\(error)")]
        }
        result["id"] = id
        var data = (try? JSON.object(result).serialized()) ?? Data("{\"ok\":false,\"error\":\"encode failed\"}".utf8)
        data.append(10)
        return data
    }

    /// Writes `data` to `fd` while connection `connection` still owns it; drops the reply otherwise.
    private func write(_ data: Data, to fd: Int32, connection: Int) {
        queue.async { [self] in
            guard let client = clients[fd], client.id == connection else { discardedReplies += 1; return }
            var offset = 0
            while offset < data.count {
                let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
                if n > 0 { offset += n; continue }
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 5000)
                    continue
                }
                if n < 0, errno == EINTR { continue }
                closeClient(client)
                return
            }
        }
    }

    private func closeClient(_ client: Client) {
        client.source?.cancel(); client.source = nil
        client.cancelTasks()
        Darwin.close(client.fd)
        clients[client.fd] = nil
    }
}
