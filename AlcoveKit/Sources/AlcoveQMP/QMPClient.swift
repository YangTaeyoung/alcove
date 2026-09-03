import Foundation

/// A client for the QEMU Machine Protocol over a unix socket
/// (`-qmp unix:<path>,server=on,wait=off`).
///
/// Wire format: docs/interop/qmp-spec.rst in the QEMU tree. The server greets
/// with `{"QMP": {...}}`, the client must send `qmp_capabilities` before any
/// other command, commands carry an `id` that the reply echoes, and
/// asynchronous events arrive as `{"event": ..., "data": ..., "timestamp": ...}`.
public actor QMPClient {
    public struct Event: Sendable, Equatable {
        public let name: String
        public let data: JSON
        public let seconds: Int64
        public let microseconds: Int64
    }

    public enum QMPError: Error, Equatable, Sendable {
        case notConnected
        case connect(String)
        case disconnected(String)
        /// The server answered with an error object.
        case command(name: String, class: String, desc: String)
        case protocolViolation(String)
        case timeout(String)
        /// A background job (snapshot, etc.) finished with an error.
        case job(id: String, error: String)
        case unexpectedReturn(command: String, value: JSON)
    }

    /// Asynchronous events from QEMU, buffered until consumed. Finishes on disconnect.
    public nonisolated let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation

    private var transport: UnixLineTransport?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var greetingWaiter: CheckedContinuation<JSON, Error>?
    private var jobWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var concludedJobs: Set<String> = []
    public private(set) var greeting: JSON?
    public private(set) var isConnected = false

    public init() {
        var c: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        eventContinuation = c
    }

    /// Connect, wait for the greeting and negotiate capabilities.
    public func connect(path: String, timeout: Duration = .seconds(15)) async throws {
        guard transport == nil else { return }
        let t: UnixLineTransport
        do {
            t = try UnixLineTransport(path: path, onLine: { [weak self] line in
                guard let self else { return }
                Task { await self.handle(line: line) }
            }, onEnd: { [weak self] reason in
                guard let self else { return }
                Task { await self.handleEnd(reason) }
            })
        } catch {
            throw QMPError.connect("\(error)")
        }
        transport = t
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failGreeting(QMPError.timeout("greeting"))
        }
        do {
            greeting = try await withCheckedThrowingContinuation { greetingWaiter = $0 }
        } catch {
            timeoutTask.cancel()
            disconnect()
            throw error
        }
        timeoutTask.cancel()
        _ = try await execute("qmp_capabilities", timeout: timeout)
        isConnected = true
    }

    /// Close the connection. Pending commands fail with `.disconnected`.
    public func disconnect() {
        transport?.close()
        transport = nil
    }

    /// Execute a command and return its `return` value.
    public func execute(_ command: String, arguments: JSON? = nil, timeout: Duration = .seconds(30)) async throws -> JSON {
        guard let transport else { throw QMPError.notConnected }
        let id = nextID
        nextID += 1
        var request: [String: JSON] = ["execute": .string(command), "id": .int(Int64(id))]
        if let arguments { request["arguments"] = arguments }
        var data = try JSON.object(request).serialized()
        data.append(10)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.timeOut(id: id, command: command)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            transport.send(data)
        }
    }

    /// Wait until the job with `id` reaches the `concluded` state.
    /// Registered before the job is started so no status change is missed.
    func awaitJobConcluded(id: String, timeout: Duration) async throws {
        if concludedJobs.remove(id) != nil { return }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.timeOutJob(id: id)
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            jobWaiters[id] = cont
        }
    }

    // MARK: - internals

    private func handle(line: Data) {
        let msg: JSON
        do { msg = try JSON.parse(line) } catch {
            // ignore unparsable lines; QEMU only sends valid JSON
            return
        }
        if let g = msg["QMP"] {
            if let w = greetingWaiter { greetingWaiter = nil; w.resume(returning: g) }
            return
        }
        if let name = msg["event"]?.stringValue {
            let ts = msg["timestamp"]
            let event = Event(name: name, data: msg["data"] ?? .null,
                              seconds: Int64(ts?["seconds"]?.intValue ?? 0),
                              microseconds: Int64(ts?["microseconds"]?.intValue ?? 0))
            if name == "JOB_STATUS_CHANGE", let id = event.data["id"]?.stringValue,
               event.data["status"]?.stringValue == "concluded" {
                if let w = jobWaiters.removeValue(forKey: id) { w.resume() } else { concludedJobs.insert(id) }
            }
            eventContinuation.yield(event)
            return
        }
        guard let id = msg["id"]?.intValue, let cont = pending.removeValue(forKey: id) else { return }
        if let err = msg["error"] {
            cont.resume(throwing: QMPError.command(name: "id \(id)", class: err["class"]?.stringValue ?? "?",
                                                   desc: err["desc"]?.stringValue ?? "?"))
        } else if let ret = msg["return"] {
            cont.resume(returning: ret)
        } else {
            cont.resume(throwing: QMPError.protocolViolation("reply without return or error"))
        }
    }

    private func handleEnd(_ reason: String) {
        transport = nil
        isConnected = false
        let err = QMPError.disconnected(reason)
        if let w = greetingWaiter { greetingWaiter = nil; w.resume(throwing: err) }
        for (_, c) in pending { c.resume(throwing: err) }
        pending.removeAll()
        for (_, c) in jobWaiters { c.resume(throwing: err) }
        jobWaiters.removeAll()
        eventContinuation.finish()
    }

    private func failGreeting(_ error: QMPError) {
        if let w = greetingWaiter { greetingWaiter = nil; w.resume(throwing: error) }
    }

    private func timeOut(id: Int, command: String) {
        if let c = pending.removeValue(forKey: id) { c.resume(throwing: QMPError.timeout(command)) }
    }

    private func timeOutJob(id: String) {
        if let c = jobWaiters.removeValue(forKey: id) { c.resume(throwing: QMPError.timeout("job \(id)")) }
    }
}
