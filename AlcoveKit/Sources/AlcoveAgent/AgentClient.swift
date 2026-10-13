import Foundation
import AlcoveQMP   // JSON value type and the unix/tcp line transport helpers live there

/// Host side of the guest agent protocol (docs/agent-protocol.md): connects
/// to the forwarded agent port, validates the token, and exchanges messages.
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
    }

    public struct Hello: Sendable, Equatable {
        public let version: Int
        public let os: String
        public let agentVersion: String
        public let capabilities: [String]
        public let rpcVersion: Int
    }

    public enum Event: Sendable, Equatable {
        case clipboardChanged(text: String)
        case resolution(width: Int, height: Int)
        case agent(name: String, payload: JSON)
        case disconnected
    }

    public nonisolated let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var transport: TCPLineTransport?
    private var helloWaiter: CheckedContinuation<JSON, Error>?
    private var pendingCalls: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var nextCallID = 1
    private var waiters: [String: [CheckedContinuation<JSON, Error>]] = [:]
    public private(set) var hello: Hello?
    public private(set) var isConnected = false

    public init() {
        var c: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        eventContinuation = c
    }

    /// Connect to `127.0.0.1:port`, wait for `hello`, check the token (when
    /// `expectedToken` is non-nil) and answer `welcome`.
    public func connect(port: Int, expectedToken: String?, timeout: Duration = .seconds(10)) async throws {
        guard transport == nil else { return }
        let t: TCPLineTransport
        do {
            t = try TCPLineTransport(host: "127.0.0.1", port: port, onLine: { [weak self] line in
                guard let self else { return }
                Task { await self.handle(line: line) }
            }, onEnd: { [weak self] reason in
                guard let self else { return }
                Task { await self.handleEnd(reason) }
            })
        } catch {
            throw AgentError.connect("\(error)")
        }
        transport = t
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failHello(AgentError.timeout("hello"))
        }
        let h: JSON
        do {
            h = try await withCheckedThrowingContinuation { helloWaiter = $0 }
        } catch {
            timeoutTask.cancel()
            disconnect()
            throw error
        }
        timeoutTask.cancel()
        guard h["v"]?.intValue == 1 else { disconnect(); throw AgentError.handshake("unsupported version") }
        if let expectedToken, h["token"]?.stringValue != expectedToken {
            disconnect()
            throw AgentError.tokenMismatch
        }
        hello = Hello(version: 1, os: h["os"]?.stringValue ?? "?", agentVersion: h["agent"]?.stringValue ?? "?",
                      capabilities: h["caps"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                      rpcVersion: h["proto"]?.intValue ?? 1)
        send(["t": "welcome", "v": 1])
        isConnected = true
    }

    public func disconnect() {
        transport?.close()
        transport = nil
    }

    // MARK: - commands

    public func setClipboard(text: String) {
        send(["t": "clipboard.set", "text": .string(text)])
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
    public func exec(_ command: String, timeout: Duration = .seconds(60)) async throws -> (code: Int, output: String) {
        let r = try await request(["t": "exec", "cmd": .string(command)], waitFor: "exec.result", timeout: timeout)
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

    /// Send `{"t":"req","id":n,"op":op, ...params}` and return the matching `res` object.
    /// Throws `.remote` on `ok:false` and `.unsupported` when the agent has no RPC layer.
    public func call(_ op: String, _ params: [String: JSON] = [:], timeout: Duration = .seconds(30)) async throws -> JSON {
        guard transport != nil else { throw AgentError.notConnected }
        guard (hello?.rpcVersion ?? 1) >= 2 else { throw AgentError.unsupported(op) }
        let id = nextCallID
        nextCallID += 1
        let timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.timeOutCall(id: id, op: op)
        }
        defer { timeoutTask.cancel() }
        let res = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSON, Error>) in
            pendingCalls[id] = cont
            var message = params
            message["t"] = "req"
            message["id"] = .int(Int64(id))
            message["op"] = .string(op)
            send(.object(message))
        }
        if res["ok"]?.boolValue == false {
            throw AgentError.remote(res["error"]?.stringValue ?? "request '\(op)' failed")
        }
        return res
    }

    // MARK: - internals

    private func send(_ message: JSON) {
        guard let transport, var data = try? message.serialized() else { return }
        data.append(10)
        transport.send(data)
    }

    private func request(_ message: JSON, waitFor type: String, timeout: Duration, matchID: String? = nil) async throws -> JSON {
        guard transport != nil else { throw AgentError.notConnected }
        let key = matchID.map { "\(type)#\($0)" } ?? type
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.timeOut(key: key, type: type)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            waiters[key, default: []].append(cont)
            send(message)
        }
    }

    private func handle(line: Data) {
        guard let m = try? JSON.parse(line), let t = m["t"]?.stringValue else { return }
        switch t {
        case "hello":
            if let w = helloWaiter { helloWaiter = nil; w.resume(returning: m) }
        case "ping":
            send(["t": "pong"])
        case "pong", "welcome":
            break
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
                let c = list.removeFirst(); waiters[idKey] = list; c.resume(returning: m)
            } else if var list = waiters[t], !list.isEmpty {
                let c = list.removeFirst(); waiters[t] = list; c.resume(returning: m)
            }
        }
    }

    private func handleEnd(_ reason: String) {
        transport = nil
        isConnected = false
        if let w = helloWaiter { helloWaiter = nil; w.resume(throwing: AgentError.disconnected) }
        for (_, list) in waiters { for c in list { c.resume(throwing: AgentError.disconnected) } }
        waiters.removeAll()
        let calls = pendingCalls
        pendingCalls.removeAll()
        for (_, c) in calls { c.resume(throwing: AgentError.disconnected) }
        eventContinuation.yield(.disconnected)
    }

    private func failHello(_ error: AgentError) {
        if let w = helloWaiter { helloWaiter = nil; w.resume(throwing: error) }
    }

    private func timeOutCall(id: Int, op: String) {
        if let c = pendingCalls.removeValue(forKey: id) { c.resume(throwing: AgentError.timeout(op)) }
    }

    private func timeOut(key: String, type: String) {
        if var list = waiters[key], !list.isEmpty {
            let c = list.removeFirst(); waiters[key] = list
            c.resume(throwing: AgentError.timeout(type))
        }
    }
}
