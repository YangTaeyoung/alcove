import Foundation

/// A client for the QEMU Machine Protocol over a unix socket
/// (`-qmp unix:<path>,server=on,wait=off`).
///
/// Wire format: docs/interop/qmp-spec.rst in the QEMU tree. The server greets
/// with `{"QMP": {...}}`, the client must send `qmp_capabilities` before any
/// other command, commands carry an `id` that the reply echoes, and
/// asynchronous events arrive as `{"event": ..., "data": ..., "timestamp": ...}`.
///
/// A `QMPClient` is single-use: once its connection ends (`disconnect()`, the
/// peer closing, or a failed `connect`) `events` is finished and `connect`
/// refuses to run again; create a new instance to reconnect.
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

    /// Asynchronous events from QEMU, buffered until consumed and delivered in
    /// the order QEMU emitted them. Finishes when the connection ends.
    public nonisolated let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation

    /// What the transport hands us, in wire order.
    private enum Inbound: Sendable {
        case line(Data)
        case end(String)
    }

    private struct PendingCommand {
        let command: String
        let continuation: CheckedContinuation<JSON, Error>
    }

    private var transport: UnixLineTransport?
    /// Drains the transport's messages into the actor one at a time, so lines
    /// are handled in order and `.end` is handled after the last line.
    private var readerTask: Task<Void, Never>?
    private var ended = false
    private var nextID = 1
    private var pending: [Int: PendingCommand] = [:]
    private var greetingWaiter: CheckedContinuation<JSON, Error>?
    private var jobSignals: [String: AsyncStream<Void>.Continuation] = [:]
    public private(set) var greeting: JSON?
    public private(set) var isConnected = false

    public init() {
        var c: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        eventContinuation = c
    }

    deinit {
        readerTask?.cancel()
    }

    /// Connect, wait for the greeting and negotiate capabilities. On any
    /// failure the connection is torn down before the error is thrown. Throws
    /// `.connect` when already connected or when this instance was used before.
    public func connect(path: String, timeout: Duration = .seconds(15)) async throws {
        guard !ended else { throw QMPError.connect("QMPClient is single-use; create a new instance to reconnect") }
        guard transport == nil else { throw QMPError.connect("already connected") }
        let (inbound, feed) = AsyncStream<Inbound>.makeStream(bufferingPolicy: .unbounded)
        let t: UnixLineTransport
        do {
            // AsyncStream preserves yield order from a single thread (the transport queue),
            // and one reader task consumes it, so handling order == wire order.
            t = try UnixLineTransport(path: path,
                                      onLine: { feed.yield(.line($0)) },
                                      onEnd: { feed.yield(.end($0)); feed.finish() })
        } catch {
            throw QMPError.connect("\(error)")
        }
        transport = t
        readerTask = Task { [weak self] in
            for await message in inbound {
                guard let self else { return }
                switch message {
                case .line(let line): await self.handle(line: line)
                case .end(let reason): await self.handleEnd(reason)
                }
            }
        }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failGreeting(QMPError.timeout("greeting"))
        }
        defer { timeoutTask.cancel() }
        do {
            // The reader can only enter the actor once we suspend here, i.e. after the waiter is installed.
            greeting = try await withCheckedThrowingContinuation { greetingWaiter = $0 }
            timeoutTask.cancel()
            _ = try await execute("qmp_capabilities", timeout: timeout)
        } catch {
            disconnect()
            throw error
        }
        isConnected = true
    }

    /// Close the connection synchronously: when this returns `isConnected` is
    /// false, pending commands have failed with `.disconnected("closed")` and
    /// `events` is finished. Safe to call more than once.
    public func disconnect() {
        guard let t = transport else { return }
        t.close()
        teardown(reason: "closed")
    }

    /// Execute a command and return its `return` value. Honors task
    /// cancellation: a cancelled caller stops waiting immediately (the reply, if
    /// it arrives later, is dropped).
    public func execute(_ command: String, arguments: JSON? = nil, timeout: Duration = .seconds(30)) async throws -> JSON {
        guard let transport else { throw QMPError.notConnected }
        try Task.checkCancellation()
        let id = nextID
        nextID += 1
        var request: [String: JSON] = ["execute": .string(command), "id": .int(Int64(id))]
        if let arguments { request["arguments"] = arguments }
        let data = try JSON.object(request).serialized() + [10]
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.timeOut(id: id, command: command)
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // Runs synchronously on the actor, so `cancel(id:)` below (which must hop
                // onto the actor) cannot observe a missing entry even if we were already cancelled.
                pending[id] = PendingCommand(command: command, continuation: cont)
                transport.send(data)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    /// A stream that yields once when job `id` reaches `concluded`. Call this
    /// BEFORE starting the job so the status change cannot be missed.
    func jobConcludedSignal(id: String) -> AsyncStream<Void> {
        var c: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { c = $0 }
        jobSignals[id] = c
        return stream
    }

    func cancelJobSignal(id: String) {
        jobSignals.removeValue(forKey: id)?.finish()
    }

    private enum JobWait: Sendable { case concluded, signalFinished, timedOut, interrupted }

    /// Wait for a job signal. Throws `.timeout` only when `timeout` elapsed,
    /// `.disconnected` when the connection ended while waiting, and
    /// `CancellationError` when the caller was cancelled.
    func awaitJobConcluded(_ signal: AsyncStream<Void>, id: String, timeout: Duration) async throws {
        let outcome = await withTaskGroup(of: JobWait.self) { group in
            group.addTask { for await _ in signal { return .concluded }; return .signalFinished }
            group.addTask {
                do { try await Task.sleep(for: timeout); return .timedOut } catch { return .interrupted }
            }
            let first = await group.next() ?? .interrupted
            group.cancelAll()
            return first
        }
        jobSignals.removeValue(forKey: id)?.finish()
        switch outcome {
        case .concluded:
            return
        case .timedOut:
            throw QMPError.timeout("job \(id)")
        case .signalFinished, .interrupted:
            try Task.checkCancellation()
            if transport == nil { throw QMPError.disconnected("connection closed while waiting for job \(id)") }
            throw QMPError.protocolViolation("job \(id): signal ended before the job concluded")
        }
    }

    // MARK: - internals

    private func handle(line: Data) {
        guard transport != nil else { return }   // torn down by disconnect(); stale message
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
               event.data["status"]?.stringValue == "concluded", let c = jobSignals[id] {
                c.yield(())
                c.finish()
            }
            eventContinuation.yield(event)
            return
        }
        guard let id = msg["id"]?.intValue, let p = pending.removeValue(forKey: id) else { return }
        if let err = msg["error"] {
            p.continuation.resume(throwing: QMPError.command(name: p.command, class: err["class"]?.stringValue ?? "?",
                                                             desc: err["desc"]?.stringValue ?? "?"))
        } else if let ret = msg["return"] {
            p.continuation.resume(returning: ret)
        } else {
            p.continuation.resume(throwing: QMPError.protocolViolation("reply without return or error"))
        }
    }

    private func handleEnd(_ reason: String) {
        guard transport != nil else { return }   // already torn down by disconnect()
        teardown(reason: reason)
    }

    /// Fail everything that is waiting and finish `events`. Idempotent.
    private func teardown(reason: String) {
        transport = nil
        readerTask?.cancel()
        readerTask = nil
        ended = true
        isConnected = false
        let err = QMPError.disconnected(reason)
        if let w = greetingWaiter { greetingWaiter = nil; w.resume(throwing: err) }
        for (_, p) in pending { p.continuation.resume(throwing: err) }
        pending.removeAll()
        for (_, c) in jobSignals { c.finish() }
        jobSignals.removeAll()
        eventContinuation.finish()
    }

    private func failGreeting(_ error: QMPError) {
        if let w = greetingWaiter { greetingWaiter = nil; w.resume(throwing: error) }
    }

    private func timeOut(id: Int, command: String) {
        if let p = pending.removeValue(forKey: id) { p.continuation.resume(throwing: QMPError.timeout(command)) }
    }

    private func cancel(id: Int) {
        if let p = pending.removeValue(forKey: id) { p.continuation.resume(throwing: CancellationError()) }
    }
}
