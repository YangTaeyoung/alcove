import Foundation
import AlcoveQMP

/// Unix-socket server for the control protocol: newline-delimited JSON
/// requests `{"id", "op", ...}` answered with `{"id", "ok", ...}`.
/// Multiple clients. Each connection has two lanes: operations for which
/// `ControlHandler.isConcurrent` is true start at once in their own task and
/// answer when they finish; all other operations run one after another in the
/// order they arrived. Closing a connection cancels every unfinished task of both
/// lanes. Replies wait in a per-connection outbox that is written as the client
/// reads; a connection whose outbox passes `maxOutboxBytes`, or that takes no
/// bytes of it for `writeStallLimit`, is closed. A request whose reply alone is
/// longer than `maxOutboxBytes` is answered with a failure that says so.
public final class ControlServer: @unchecked Sendable {
    public enum ServerError: Error, Equatable, CustomStringConvertible {
        case socket(errno: Int32), bind(path: String, errno: Int32), listen(errno: Int32), pathTooLong(String)

        public var description: String {
            switch self {
            case .socket(let e):
                return "a unix socket could not be created (\(String(cString: strerror(e)))); start the control server again"
            case .bind(let path, let e):
                return "the socket \(path) could not be bound (\(String(cString: strerror(e)))); make its folder writable or choose another path"
            case .listen(let e):
                return "the socket could not accept connections (\(String(cString: strerror(e)))); start the control server again"
            case .pathTooLong(let path):
                return "the socket path \(path) is \(path.utf8.count) bytes long, and a unix socket path on macOS holds at most "
                    + "\(ControlServer.maxSocketPathBytes) bytes (\(ControlServer.maxSocketPathBytes + 1) with the closing NUL byte); choose a shorter path"
            }
        }
    }

    /// The longest socket path in bytes that `sockaddr_un.sun_path` holds with its closing NUL byte.
    public static let maxSocketPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

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
    /// Longest a connection with unwritten replies may go without taking any of their bytes.
    private let writeStallLimit: Duration
    /// Most bytes of replies a connection may leave unread.
    private let maxOutboxBytes: Int

    private final class Client {
        /// Server-wide number of this connection; a later connection on the same descriptor has a different one.
        let id: Int
        let fd: Int32
        var source: DispatchSourceRead?
        var pending = Data()
        /// The newest task of the serial lane.
        var newestSerial: Task<Void, Never>?
        /// The unfinished tasks of the serial lane by server-wide task id.
        var serial: [Int: Task<Void, Never>] = [:]
        /// The running tasks of the concurrent lane by server-wide task id.
        var concurrent: [Int: Task<Void, Never>] = [:]
        /// Replies not yet written, oldest first; `written` bytes of the first one are written.
        var outbox: [Data] = []
        var written = 0
        var outboxBytes = 0
        /// Writes the outbox while the socket takes no more bytes at once.
        var writeSource: DispatchSourceWrite?
        /// Checks that the outbox keeps moving while `writeSource` waits.
        var stallTimer: DispatchSourceTimer?
        /// When the outbox last moved: a reply was queued into an empty outbox or bytes were written.
        var lastProgress = ContinuousClock.now
        init(id: Int, fd: Int32) { self.id = id; self.fd = fd }

        func cancelTasks() {
            for (_, t) in serial { t.cancel() }
            serial.removeAll()
            newestSerial = nil
            for (_, t) in concurrent { t.cancel() }
            concurrent.removeAll()
        }

        /// Stops writing and drops the replies not yet written.
        func dropOutbox() {
            writeSource?.cancel(); writeSource = nil
            stallTimer?.cancel(); stallTimer = nil
            outbox.removeAll()
            written = 0
            outboxBytes = 0
        }
    }

    /// A connection that takes none of its unwritten replies for `writeStallLimit`, or whose unwritten replies pass
    /// `maxOutboxBytes`, is closed.
    public init(handler: ControlHandler, socketPath: String = ControlServer.defaultSocketPath,
                writeStallLimit: Duration = .seconds(30), maxOutboxBytes: Int = 64 << 20) {
        self.handler = handler
        self.socketPath = socketPath
        self.writeStallLimit = writeStallLimit
        self.maxOutboxBytes = maxOutboxBytes
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

    /// Binds the socket and starts answering. With `loadingRecognizers`, the warm-up reading is in the recognition
    /// queue (`RecognitionQueue.warmUp`) before the first connection is accepted.
    public func start(loadingRecognizers: Bool = false) throws {
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
        if loadingRecognizers { RecognitionQueue.shared.warmUp() }
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
        for (_, c) in clients { c.source?.cancel(); c.dropOutbox(); c.cancelTasks(); Darwin.close(c.fd) }
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

    /// Starts a concurrent operation in its own tracked task; chains any other request behind the connection's previous
    /// serial task, in a tracked task that answers nothing once it is cancelled.
    private func enqueue(_ line: Data, for client: Client) {
        let fd = client.fd
        let connection = client.id
        let handler = self.handler
        let maxReply = maxOutboxBytes
        let parsed = Result { try JSON.parse(line) }
        let id = nextTaskID
        nextTaskID += 1
        if let op = (try? parsed.get())?["op"]?.stringValue, ControlHandler.isConcurrent(op: op) {
            client.concurrent[id] = Task { [weak self] in
                let reply = await ControlServer.process(line, parsed: parsed, handler: handler, maxReplyBytes: maxReply)
                self?.write(reply, to: fd, connection: connection)
                self?.forgetTask(id, of: fd, connection: connection)
            }
            return
        }
        let previous = client.newestSerial
        let task = Task { [weak self] in
            await previous?.value
            if !Task.isCancelled {
                let reply = await ControlServer.process(line, parsed: parsed, handler: handler, maxReplyBytes: maxReply)
                self?.write(reply, to: fd, connection: connection)
            }
            self?.forgetTask(id, of: fd, connection: connection)
        }
        client.serial[id] = task
        client.newestSerial = task
    }

    private func forgetTask(_ id: Int, of fd: Int32, connection: Int) {
        queue.async { [self] in
            guard let client = clients[fd], client.id == connection else { return }
            client.concurrent[id] = nil
            client.serial[id] = nil
        }
    }

    /// The number of concurrent-lane tasks that are still tracked, over all connections.
    func concurrentTaskCount() -> Int {
        queue.sync { clients.values.reduce(0) { $0 + $1.concurrent.count } }
    }

    /// The number of serial-lane tasks that are still tracked, over all connections.
    func serialTaskCount() -> Int {
        queue.sync { clients.values.reduce(0) { $0 + $1.serial.count } }
    }

    /// The bytes of replies not yet written, over all connections.
    func outboxByteCount() -> Int {
        queue.sync { clients.values.reduce(0) { $0 + $1.outboxBytes } }
    }

    /// The number of open connections.
    func connectionCount() -> Int {
        queue.sync { clients.count }
    }

    /// The number of replies dropped because their connection had closed.
    func discardedReplyCount() -> Int {
        queue.sync { discardedReplies }
    }

    static let unreadableRequest = "the request line is not JSON that can be read (broken syntax, or a \\u escape of half a surrogate pair); send one JSON object per line"

    /// The reply line to the request line `line`. A line that cannot be parsed is answered with `unreadableRequest`
    /// and the `id` that `requestID` reads from it.
    static func process(_ line: Data, handler: ControlHandler) async -> Data {
        await process(line, parsed: Result { try JSON.parse(line) }, handler: handler)
    }

    /// The reply line to the request line `line`, which `parsed` holds parsed. A reply line longer than `maxReplyBytes`
    /// is replaced by a failure that says so.
    static func process(_ line: Data, parsed: Result<JSON, Error>, handler: ControlHandler, maxReplyBytes: Int = .max) async -> Data {
        var id: JSON = .null
        var op = "the request"
        var result: [String: JSON]
        do {
            let req: JSON
            do {
                req = try parsed.get()
            } catch {
                id = requestID(in: line) ?? .null
                throw ControlHandler.ControlError.failed(unreadableRequest)
            }
            id = req["id"] ?? .null
            guard let name = req["op"]?.stringValue else { throw ControlHandler.ControlError.missing("op") }
            op = name
            let r = try await handler.handle(op: name, params: req)
            result = r.objectValue ?? [:]
            result["ok"] = true
        } catch let e as ControlHandler.ControlError {
            result = ["ok": false, "error": .string(e.description)]
        } catch {
            result = ["ok": false, "error": .string(ControlHandler.failureReason(error, fallback: "the request failed; check the request and vm.status"))]
        }
        result["id"] = id
        var data = (try? JSON.object(result).serialized()) ?? Data("{\"ok\":false,\"error\":\"encode failed\"}".utf8)
        data.append(10)
        if data.count > maxReplyBytes {
            let sentence = ControlServer.replyTooLarge(op: op, bytes: data.count, limit: maxReplyBytes)
            data = (try? JSON.object(["id": id, "ok": false, "error": .string(sentence)]).serialized()) ?? Data()
            data.append(10)
        }
        return data
    }

    /// The failure of a request whose reply line of `bytes` bytes is longer than `limit`.
    static func replyTooLarge(op: String, bytes: Int, limit: Int) -> String {
        "the reply to \(op) holds \(bytes) bytes, more than the \(limit) bytes one reply may hold; ask for less, such as a vm.screenshot with maxWidth, scale or region"
    }

    /// The value of the top-level `id` key of a request line that cannot be parsed as a whole: a number or a string.
    /// The line is scanned from its start, and every key and value before the key must be JSON syntax: UTF-8 strings
    /// with valid escapes (a `\u` escape needs four hex digits; whether it is half a surrogate pair is not checked),
    /// numbers, `true`, `false`, `null`, and objects and arrays of these nested at most 512 deep. Nil when the line does
    /// not begin as an object, when anything before the key is not JSON syntax, when the key is spelled other than
    /// `"id"`, when the value of the key is not a number or a string that parses, and when no `,` or `}` follows it.
    static func requestID(in line: Data) -> JSON? {
        let bytes = [UInt8](line)
        var at = 0
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        func skipSpace() { while at < bytes.count, [0x20, 0x09, 0x0D, 0x0A].contains(bytes[at]) { at += 1 } }
        func next(is byte: Character) -> Bool { at < bytes.count && bytes[at] == UInt8(ascii: byte.unicodeScalars.first!) }
        func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        func isHex(_ b: UInt8) -> Bool { isDigit(b) || ((b | 0x20) >= 0x61 && (b | 0x20) <= 0x66) }
        /// The bytes of the string that starts at `at`, quotes included; nil when it does not end or is not a JSON string.
        func string() -> ArraySlice<UInt8>? {
            guard next(is: "\"") else { return nil }
            let start = at
            at += 1
            while at < bytes.count {
                let b = bytes[at]
                if b == quote {
                    at += 1
                    return String(bytes: bytes[start..<at], encoding: .utf8) == nil ? nil : bytes[start..<at]
                }
                if b < 0x20 { return nil }
                if b == backslash {
                    guard at + 1 < bytes.count else { return nil }
                    if bytes[at + 1] == UInt8(ascii: "u") {
                        guard at + 5 < bytes.count, bytes[(at + 2)...(at + 5)].allSatisfy(isHex) else { return nil }
                        at += 6
                    } else {
                        guard Array("\"\\/bfnrt".utf8).contains(bytes[at + 1]) else { return nil }
                        at += 2
                    }
                    continue
                }
                at += 1
            }
            return nil
        }
        func digits() -> Bool {
            let start = at
            while at < bytes.count, isDigit(bytes[at]) { at += 1 }
            return at > start
        }
        func number() -> Bool {
            if next(is: "-") { at += 1 }
            if next(is: "0") { at += 1 } else { guard digits() else { return false } }
            if next(is: ".") { at += 1; guard digits() else { return false } }
            if next(is: "e") || next(is: "E") {
                at += 1
                if next(is: "+") || next(is: "-") { at += 1 }
                guard digits() else { return false }
            }
            return true
        }
        func literal(_ word: String) -> Bool {
            let w = Array(word.utf8)
            guard at + w.count <= bytes.count, Array(bytes[at..<(at + w.count)]) == w else { return false }
            at += w.count
            return true
        }
        /// Moves past `"key":` at `at`, spaces included; false when it is not there.
        func memberKey() -> Bool {
            skipSpace()
            guard string() != nil else { return false }
            skipSpace()
            guard next(is: ":") else { return false }
            at += 1
            return true
        }
        /// Moves past the JSON value that starts at `at`; false when it is not JSON syntax or does not end.
        func skipValue() -> Bool {
            var open: [UInt8] = []
            while true {
                skipSpace()
                guard at < bytes.count else { return false }
                switch bytes[at] {
                case quote:
                    guard string() != nil else { return false }
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    let opening = bytes[at]
                    at += 1
                    skipSpace()
                    if next(is: opening == UInt8(ascii: "{") ? "}" : "]") { at += 1; break }
                    guard open.count < 512 else { return false }
                    open.append(opening)
                    if opening == UInt8(ascii: "{") { guard memberKey() else { return false } }
                    continue
                case UInt8(ascii: "t"): guard literal("true") else { return false }
                case UInt8(ascii: "f"): guard literal("false") else { return false }
                case UInt8(ascii: "n"): guard literal("null") else { return false }
                default:
                    guard number() else { return false }
                }
                closing: while let top = open.last {
                    skipSpace()
                    if next(is: ",") {
                        at += 1
                        if top == UInt8(ascii: "{") { guard memberKey() else { return false } }
                        break closing
                    }
                    guard next(is: top == UInt8(ascii: "{") ? "}" : "]") else { return false }
                    at += 1
                    open.removeLast()
                }
                if open.isEmpty { return true }
            }
        }
        skipSpace()
        guard next(is: "{") else { return nil }
        at += 1
        while true {
            skipSpace()
            guard let key = string() else { return nil }
            skipSpace()
            guard next(is: ":") else { return nil }
            at += 1
            skipSpace()
            if Array(key) == Array("\"id\"".utf8) {
                let start = at
                guard skipValue(), let value = try? JSON.parse(Data(bytes[start..<at])) else { return nil }
                skipSpace()
                guard next(is: ",") || next(is: "}") else { return nil }
                return value.stringValue != nil || value.doubleValue != nil ? value : nil
            }
            guard skipValue() else { return nil }
            skipSpace()
            guard next(is: ",") else { return nil }
            at += 1
        }
    }

    /// Queues `data` in the outbox of connection `connection` while it still owns `fd` and writes what the socket takes;
    /// drops the reply when the connection is gone, and closes a connection whose outbox would pass `maxOutboxBytes`.
    private func write(_ data: Data, to fd: Int32, connection: Int) {
        queue.async { [self] in
            guard let client = clients[fd], client.id == connection else { discardedReplies += 1; return }
            guard client.outboxBytes + data.count <= maxOutboxBytes else {
                discardedReplies += 1
                closeClient(client)
                return
            }
            if client.outbox.isEmpty { client.lastProgress = .now }
            client.outbox.append(data)
            client.outboxBytes += data.count
            flush(client)
        }
    }

    /// Writes the outbox of `client` until it is empty or the socket takes no more; then a write source goes on when
    /// the socket has room and a timer closes the connection once it took nothing for `writeStallLimit`.
    private func flush(_ client: Client) {
        while let first = client.outbox.first {
            let offset = client.written
            let n = first.withUnsafeBytes { Darwin.write(client.fd, $0.baseAddress! + offset, first.count - offset) }
            if n > 0 {
                client.lastProgress = .now
                client.written += n
                client.outboxBytes -= n
                if client.written == first.count {
                    client.outbox.removeFirst()
                    client.written = 0
                }
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                waitForRoom(client)
                return
            }
            closeClient(client)
            return
        }
        client.writeSource?.cancel(); client.writeSource = nil
        client.stallTimer?.cancel(); client.stallTimer = nil
    }

    /// Starts the write source and the stall timer of `client` unless they run.
    private func waitForRoom(_ client: Client) {
        if client.writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
            source.setEventHandler { [weak self, weak client] in
                guard let self, let client, self.clients[client.fd] === client else { return }
                self.flush(client)
            }
            source.resume()
            client.writeSource = source
        }
        if client.stallTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let period = ControlServer.dispatchInterval(writeStallLimit / 4)
            timer.schedule(deadline: .now() + period, repeating: period)
            timer.setEventHandler { [weak self, weak client] in
                guard let self, let client, self.clients[client.fd] === client else { return }
                if !client.outbox.isEmpty, client.lastProgress.duration(to: .now) >= self.writeStallLimit { self.closeClient(client) }
            }
            timer.resume()
            client.stallTimer = timer
        }
    }

    /// `duration` in whole nanoseconds, at least one millisecond.
    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let nanoseconds = duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
        return .nanoseconds(Int(max(1_000_000, nanoseconds)))
    }

    private func closeClient(_ client: Client) {
        client.source?.cancel(); client.source = nil
        client.dropOutbox()
        client.cancelTasks()
        Darwin.close(client.fd)
        clients[client.fd] = nil
    }
}
