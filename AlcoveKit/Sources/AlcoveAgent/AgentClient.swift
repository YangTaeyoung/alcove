import Foundation
import Synchronization
import AlcoveQMP

/// Host side of the guest agent protocol (docs/agent-protocol.md): connects
/// to the forwarded agent port, validates the token, authenticates to the agent
/// with the VM's agent key, and exchanges messages.
public actor AgentClient {
    public enum AgentError: Error, Equatable, Sendable {
        case connect(String)
        case handshake(String)
        case tokenMismatch
        case disconnected
        case notConnected
        case timeout(String)
        case remote(String)
        case unsupported(String)
        /// The agent's `refused` line, or `agentWithoutAuth`: a sentence that names the next step.
        case refused(String)
    }

    public struct Hello: Sendable, Equatable {
        public let version: Int
        public let os: String
        public let agentVersion: String
        public let capabilities: [String]
        public let rpcVersion: Int
        /// Whether the connection authenticated to the agent with the VM's agent key.
        public let authenticated: Bool
    }

    /// The handshake reason when the agent asks for the VM's agent key and `connect` was given none.
    public static let noAgentKey = "the guest tools ask for the VM's agent key and none was given"
    /// The handshake reason when the agent asks for the VM's agent key and `connect` was given no token to sign.
    public static let noAgentToken = "the VM's config.json has no agentToken to sign; restore config.json from a backup"
    /// The refusal of a hello without `auth` by a `connect` that was given the VM's agent key.
    public static let agentWithoutAuth = "the guest tools do not ask the host for the VM's key, so the host does not use them; reinstall the guest tools from this version of Alcove (scripts/test/install-agent.py)"
    /// Whether `sentence`, the text of `.refused`, is a refusal by the host (`agentWithoutAuth`) rather than one the
    /// agent sent.
    public static func isHostRefusal(_ sentence: String) -> Bool { sentence == agentWithoutAuth }
    /// The handshake reason when the given agent key is not 64 hexadecimal digits.
    public static let badAgentKey = "the agentKey in the VM's config.json is not 64 hexadecimal digits; restore config.json from a backup"
    /// The handshake reason when the agent asks for a signature without a nonce of 64 hexadecimal digits.
    public static let badNonce = "the guest tools sent no usable nonce; reinstall alcove-agent in the guest"

    public enum Event: Sendable, Equatable {
        case clipboardChanged(text: String)
        case resolution(width: Int, height: Int)
        case agent(name: String, payload: JSON)
        case disconnected
    }

    /// What the transport delivers: a line, or the end of the connection.
    private enum Inbound: Sendable {
        case line(Data)
        case end(String)
    }

    /// The events of the connection. The stream keeps the newest `eventBacklog` events a reader has not taken and
    /// ends when the client is released; `.disconnected` is the last event of a connection.
    public nonisolated let events: AsyncStream<Event>
    public static let eventBacklog = 1000
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var transport: TCPLineTransport?
    /// Handles the transport's lines and its end one at a time in the order they arrived.
    private var readerTask: Task<Void, Never>?
    private var helloWaiter: CheckedContinuation<JSON, Error>?
    /// The caller of `connect` waiting for the agent's `authed`.
    private var authWaiter: CheckedContinuation<Void, Error>?
    /// Set when the time `connect` allows for the handshake has passed.
    private var handshakeExpired = false
    /// The sentence of the agent's `refused` line on this connection.
    private var refusal: String?
    private var pendingCalls: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var nextCallID = 1
    /// The callers of `request` by the message type they wait for, oldest first, each with its own number.
    private var waiters: [String: [(id: Int, continuation: CheckedContinuation<JSON, Error>)]] = [:]
    private var nextWaiterID = 1
    public private(set) var hello: Hello?
    public private(set) var isConnected = false

    /// Where the `ui.ping` of `startUIHelper` stands on this connection.
    private enum HelperStart: Sendable {
        case notSent
        case waiting(Task<Void, Never>)
        case ended(Task<Void, Never>)
    }
    private nonisolated let helperStart = Mutex(HelperStart.notSent)

    public init() {
        var c: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(AgentClient.eventBacklog)) { c = $0 }
        eventContinuation = c
    }

    deinit {
        readerTask?.cancel()
        eventContinuation.finish()
    }

    /// Connect to `127.0.0.1:port`, wait for `hello`, check the token (when
    /// `expectedToken` is non-nil), send an agent whose hello carries `auth: "key"` the signature by `agentKey` of
    /// `expectedToken` and the hello's nonce and wait for its `authed`, then answer `welcome` and mark the connection
    /// ready. With an `agentKey`, a hello without `auth: "key"` throws `.refused(agentWithoutAuth)` and nothing is
    /// sent. The whole handshake runs within `timeout`. An agent's `refused` line throws `.refused` with its sentence.
    public func connect(port: Int, expectedToken: String?, agentKey: String? = nil, timeout: Duration = .seconds(10)) async throws {
        guard transport == nil else { return }
        handshakeExpired = false
        refusal = nil
        let (inbound, feed) = AsyncStream<Inbound>.makeStream(bufferingPolicy: .unbounded)
        let t: TCPLineTransport
        do {
            t = try TCPLineTransport(host: "127.0.0.1", port: port,
                                     onLine: { feed.yield(.line($0)) },
                                     onEnd: { feed.yield(.end($0)); feed.finish() })
        } catch {
            throw AgentError.connect("\(error)")
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
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.expireHandshake()
        }
        let h: JSON
        do {
            h = try await withCheckedThrowingContinuation { helloWaiter = $0 }
        } catch {
            timeoutTask.cancel()
            disconnect()
            throw error
        }
        guard h["v"]?.intValue == 1 else { timeoutTask.cancel(); disconnect(); throw AgentError.handshake("unsupported version") }
        if let expectedToken, h["token"]?.stringValue != expectedToken {
            timeoutTask.cancel()
            disconnect()
            throw AgentError.tokenMismatch
        }
        let authenticates = h["auth"]?.stringValue == "key"
        if !authenticates, agentKey != nil {
            timeoutTask.cancel()
            disconnect()
            throw AgentError.refused(AgentClient.agentWithoutAuth)
        }
        if authenticates {
            do {
                try await authenticate(hello: h, token: expectedToken, agentKey: agentKey)
            } catch {
                timeoutTask.cancel()
                disconnect()
                throw error
            }
        }
        timeoutTask.cancel()
        hello = Hello(version: 1, os: h["os"]?.stringValue ?? "?", agentVersion: h["agent"]?.stringValue ?? "?",
                      capabilities: h["caps"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                      rpcVersion: h["proto"]?.intValue ?? 1, authenticated: authenticates)
        send(["t": "welcome", "v": 1])
        isConnected = true
    }

    /// Sends `auth` with the signature by `agentKey` of `token` and the hello's nonce (`AgentKey`), and waits for
    /// `authed`.
    private func authenticate(hello h: JSON, token: String?, agentKey: String?) async throws {
        guard let agentKey else { throw AgentError.handshake(AgentClient.noAgentKey) }
        guard AgentKey.publicKey(agentKey) != nil else { throw AgentError.handshake(AgentClient.badAgentKey) }
        guard let token, !token.isEmpty else { throw AgentError.handshake(AgentClient.noAgentToken) }
        guard let nonce = h["nonce"]?.stringValue.flatMap(AgentClient.hexBytes), nonce.count == 32 else {
            throw AgentError.handshake(AgentClient.badNonce)
        }
        guard let signature = AgentKey.signature(agentKey, token: token, nonce: nonce) else {
            throw AgentError.handshake(AgentClient.badAgentKey)
        }
        let message: JSON = ["t": "auth", "signature": .string(signature)]
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if let refusal {
                cont.resume(throwing: AgentError.refused(refusal))
            } else if transport == nil {
                cont.resume(throwing: AgentError.disconnected)
            } else if handshakeExpired {
                cont.resume(throwing: AgentError.timeout("authed"))
            } else {
                authWaiter = cont
                send(message)
            }
        }
    }

    /// The bytes an even number of hexadecimal digits encode, or nil.
    nonisolated static func hexBytes(_ text: String) -> Data? {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var out = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = hexValue(digits[index]), let low = hexValue(digits[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    private nonisolated static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    public func disconnect() {
        transport?.close()
        transport = nil
    }

    // MARK: - commands

    /// Set the guest clipboard text. Throws `.remote` without sending when the message would be longer than the agent reads.
    public func setClipboard(text: String) throws {
        guard AgentClient.clipboardMessageFits(text) else {
            throw AgentError.remote("the clipboard text is too large for one message to the guest tools (\(text.utf8.count) bytes of UTF-8; a message holds less than 1 MiB); set a shorter text")
        }
        send(["t": "clipboard.set", "text": .string(text)])
    }

    /// Whether the `clipboard.set` message for `text` stays below `maxRequestBytes`, the longest line the agent reads.
    public nonisolated static func clipboardMessageFits(_ text: String) -> Bool {
        guard let line = try? JSON.object(["t": "clipboard.set", "text": .string(text)]).serialized() else { return false }
        return line.count < maxRequestBytes
    }

    /// Read the guest clipboard text.
    public func getClipboard(timeout: Duration = .seconds(10)) async throws -> String {
        let r = try await request(["t": "clipboard.get"], waitFor: "clipboard.text", timeout: timeout)
        return r["text"]?.stringValue ?? ""
    }

    public func setResolution(width: Int, height: Int) {
        send(["t": "resolution.set", "w": .int(Int64(width)), "h": .int(Int64(height))])
    }

    public func shutdown() {
        send(["t": "shutdown"])
    }

    /// Run a shell command in the guest (agents started with --allow-exec only).
    /// Throws `.remote` without sending when the message would be longer than the agent reads.
    public func exec(_ command: String, timeout: Duration = .seconds(60)) async throws -> (code: Int, output: String) {
        let message: JSON = ["t": "exec", "cmd": .string(command)]
        guard fitsAgentLine(message) else {
            throw AgentError.remote("command is too long for this guest agent; write it to a file in the guest and run that")
        }
        let r = try await request(message, waitFor: "exec.result", timeout: timeout)
        return (r["code"]?.intValue ?? -1, r["out"]?.stringValue ?? "")
    }

    public enum Destination: String, Sendable { case desktop, downloads }

    /// Push a local file into the guest's Desktop or Downloads folder.
    /// Returns the path inside the guest.
    public func pushFile(_ url: URL, to destination: Destination = .desktop, timeout: Duration = .seconds(600)) async throws -> String {
        let data = try Data(contentsOf: url)
        let id = UUID().uuidString
        let digest = SHA256Digest.hex(of: data)
        send(["t": "file.begin", "id": .string(id), "name": .string(url.lastPathComponent),
              "size": .int(Int64(data.count)), "dest": .string(destination.rawValue)])
        let chunk = 256 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            send(["t": "file.chunk", "id": .string(id), "data": .string(data[offset..<end].base64EncodedString())])
            offset = end
        }
        let r = try await request(["t": "file.end", "id": .string(id), "sha256": .string(digest)], waitFor: "file.done", timeout: timeout, matchID: id)
        if let error = r["error"]?.stringValue { throw AgentError.remote(error) }
        return r["path"]?.stringValue ?? ""
    }

    /// What the calls waiting on a connection get when the agent sent a line longer than `TCPLineTransport.maxLineBytes`.
    public static let replyTooLong = "the guest tools sent an answer longer than 8 MiB, so the connection to them was closed; ask for less (a smaller max, depth or range) and retry"

    /// The longest request line the agent reads, newline included (`proto.MaxLine` in guest-tools).
    static let maxRequestBytes = 1 << 20

    /// Send `{"t":"req","id":n,"op":op, ...params}` and return the matching `res` object.
    /// Throws `.remote` on `ok:false` and for a request longer than `maxRequestBytes`, which is not sent,
    /// and `.unsupported` when the agent has no RPC layer. A cancelled task throws `CancellationError` at once; a
    /// request it has not sent yet is not sent, and the reply to one it has sent is ignored.
    public func call(_ op: String, _ params: [String: JSON] = [:], timeout: Duration = .seconds(30)) async throws -> JSON {
        try Task.checkCancellation()
        guard transport != nil else { throw AgentError.notConnected }
        guard (hello?.rpcVersion ?? 1) >= 2 else { throw AgentError.unsupported(op) }
        let id = nextCallID
        nextCallID += 1
        var message = params
        message["t"] = "req"
        message["id"] = .int(Int64(id))
        message["op"] = .string(op)
        guard var line = try? JSON.object(message).serialized(), line.count < AgentClient.maxRequestBytes else {
            throw AgentError.remote("request '\(op)' is longer than 1 MiB, the most alcove-agent reads in one message; put large input in a guest file and pass its path")
        }
        line.append(10)
        let timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.timeOutCall(id: id, op: op)
        }
        defer { timeoutTask.cancel() }
        let res = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSON, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                pendingCalls[id] = cont
                transport?.send(line)
            }
        } onCancel: {
            Task { await self.cancelCall(id: id) }
        }
        if res["ok"]?.boolValue == false {
            throw AgentError.remote(res["error"]?.stringValue ?? "request '\(op)' failed")
        }
        return res
    }

    /// Sends one `ui.ping` in a task of its own, which starts the agent's UI helper, and returns that task; a later call
    /// returns the task of the first and sends nothing. The ping ends when the agent answers it, when it fails or after
    /// `timeout`.
    @discardableResult
    public nonisolated func startUIHelper(timeout: Duration) -> Task<Void, Never> {
        helperStart.withLock { state in
            switch state {
            case .waiting(let task), .ended(let task):
                return task
            case .notSent:
                let task = Task {
                    _ = try? await self.call("ui.ping", [:], timeout: timeout)
                    self.helperStart.withLock { state in
                        if case .waiting(let task) = state { state = .ended(task) }
                    }
                }
                state = .waiting(task)
                return task
            }
        }
    }

    /// Whether the `ui.ping` of `startUIHelper` was sent and has not ended.
    public nonisolated var isStartingUIHelper: Bool {
        helperStart.withLock { state in
            if case .waiting = state { return true }
            return false
        }
    }

    /// Returns once the `ui.ping` of `startUIHelper` has ended; at once when none was sent.
    public nonisolated func uiHelperStarted() async {
        let task: Task<Void, Never>? = helperStart.withLock { state in
            switch state {
            case .waiting(let task), .ended(let task): return task
            case .notSent: return nil
            }
        }
        await task?.value
    }

    // MARK: - internals

    /// Whether `message` serialized stays below `maxRequestBytes`, the longest line the agent reads.
    private nonisolated func fitsAgentLine(_ message: JSON) -> Bool {
        guard let line = try? message.serialized() else { return false }
        return line.count < AgentClient.maxRequestBytes
    }

    private func send(_ message: JSON) {
        guard let transport, var data = try? message.serialized() else { return }
        data.append(10)
        transport.send(data)
    }

    private func request(_ message: JSON, waitFor type: String, timeout: Duration, matchID: String? = nil) async throws -> JSON {
        guard transport != nil else { throw AgentError.notConnected }
        let key = matchID.map { "\(type)#\($0)" } ?? type
        let waiter = nextWaiterID
        nextWaiterID += 1
        let timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.timeOut(key: key, waiter: waiter, type: type)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            waiters[key, default: []].append((waiter, cont))
            send(message)
        }
    }

    private func handle(line: Data) {
        guard let m = try? JSON.parse(line), let t = m["t"]?.stringValue else { return }
        switch t {
        case "hello":
            if let w = helloWaiter { helloWaiter = nil; w.resume(returning: m) }
        case "authed":
            if let w = authWaiter { authWaiter = nil; w.resume() }
        case "refused":
            let text = m["error"]?.stringValue ?? "the guest tools refused the connection"
            refusal = text
            if let w = helloWaiter { helloWaiter = nil; w.resume(throwing: AgentError.refused(text)) }
            if let w = authWaiter { authWaiter = nil; w.resume(throwing: AgentError.refused(text)) }
        case "ping":
            send(["t": "pong"])
        case "pong", "welcome":
            break
        case "caps":
            if let caps = m["caps"]?.arrayValue, let h = hello {
                hello = Hello(version: h.version, os: h.os, agentVersion: h.agentVersion, capabilities: caps.compactMap(\.stringValue),
                              rpcVersion: h.rpcVersion, authenticated: h.authenticated)
            }
        case "clipboard.changed":
            eventContinuation.yield(.clipboardChanged(text: m["text"]?.stringValue ?? ""))
        case "resolution":
            eventContinuation.yield(.resolution(width: m["w"]?.intValue ?? 0, height: m["h"]?.intValue ?? 0))
        case "res":
            if let id = m["id"]?.intValue, let c = pendingCalls.removeValue(forKey: id) { c.resume(returning: m) }
        case "ev":
            eventContinuation.yield(.agent(name: m["name"]?.stringValue ?? "", payload: m))
        default:
            let idKey = m["id"]?.stringValue.map { "\(t)#\($0)" }
            if let idKey, var list = waiters[idKey], !list.isEmpty {
                let c = list.removeFirst(); waiters[idKey] = list; c.continuation.resume(returning: m)
            } else if var list = waiters[t], !list.isEmpty {
                let c = list.removeFirst(); waiters[t] = list; c.continuation.resume(returning: m)
            }
        }
    }

    /// Fails every waiting caller: with `.refused` and its sentence when the agent sent a `refused` line, with
    /// `.remote(replyTooLong)` when the agent sent a line longer than the transport reads, otherwise with `.disconnected`.
    private func handleEnd(_ reason: String) {
        transport = nil
        isConnected = false
        let failure = refusal.map(AgentError.refused)
            ?? (reason == TCPLineTransport.lineTooLong ? AgentError.remote(AgentClient.replyTooLong) : AgentError.disconnected)
        if let w = helloWaiter { helloWaiter = nil; w.resume(throwing: failure) }
        if let w = authWaiter { authWaiter = nil; w.resume(throwing: failure) }
        for (_, list) in waiters { for c in list { c.continuation.resume(throwing: failure) } }
        waiters.removeAll()
        let calls = pendingCalls
        pendingCalls.removeAll()
        for (_, c) in calls { c.resume(throwing: failure) }
        eventContinuation.yield(.disconnected)
    }

    /// Ends the handshake time: the caller waiting for the hello or for `authed` fails with a timeout naming it.
    private func expireHandshake() {
        handshakeExpired = true
        if let w = helloWaiter { helloWaiter = nil; w.resume(throwing: AgentError.timeout("hello")) }
        if let w = authWaiter { authWaiter = nil; w.resume(throwing: AgentError.timeout("authed")) }
    }

    private func timeOutCall(id: Int, op: String) {
        if let c = pendingCalls.removeValue(forKey: id) { c.resume(throwing: AgentError.timeout(op)) }
    }

    private func cancelCall(id: Int) {
        if let c = pendingCalls.removeValue(forKey: id) { c.resume(throwing: CancellationError()) }
    }

    /// Fails the caller `waiter` of `request` with a timeout when it still waits for `key`.
    private func timeOut(key: String, waiter: Int, type: String) {
        guard var list = waiters[key], let index = list.firstIndex(where: { $0.id == waiter }) else { return }
        let c = list.remove(at: index)
        waiters[key] = list.isEmpty ? nil : list
        c.continuation.resume(throwing: AgentError.timeout(type))
    }
}

extension AgentClient.AgentError: LocalizedError {
    /// For `.refused`: its sentence after `the guest tools cannot be used: ` for a refusal by the host
    /// (`AgentClient.isHostRefusal`), after `the guest tools refused the connection: ` for one the agent sent; nil for
    /// the other cases.
    public var errorDescription: String? {
        refusal.map {
            AgentClient.isHostRefusal($0) ? "the guest tools cannot be used: \($0)" : "the guest tools refused the connection: \($0)"
        }
    }

    /// The sentence of the agent's `refused` line for `.refused`; nil for the other cases.
    public var refusal: String? {
        if case .refused(let text) = self { return text }
        return nil
    }
}
