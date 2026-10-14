import Foundation
import CryptoKit
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP

enum HTTPTiming {
    /// Pause between two looks at the state of a capturing VM.
    nonisolated(unsafe) static var vmPoll = Duration.seconds(2)
    /// Longest the guest tools get to connect for `vm.http.start` and for the `vm.http.stop` of a running capture.
    nonisolated(unsafe) static var toolsWait = Duration.seconds(25)
    /// Longest the guest tools get to connect for a `vm.http.stop` without a running capture.
    nonisolated(unsafe) static var staleToolsWait = Duration.seconds(5)
    /// Longest one guest recipe may run when a VM stops or the host shuts down.
    static let partingRecipeMilliseconds = 15_000
    /// Longest the copy of the CA certificate into the guest may take.
    static let pushTimeout = Duration.seconds(60)
}

/// The HTTP capture of one VM.
struct HTTPCapture {
    let id = UUID()
    let proxy: ProxyControlling
    let port: Int
    /// The SHA-1 of the proxy's CA certificate as 40 upper-case hexadecimal digits.
    let thumbprint: String
    let os: VMConfig.GuestOS
    /// The engine process the capture belongs to.
    let instance: Int
    /// Where the CA certificate is in the guest; nil when it was not copied there.
    var guestCAPath: String?
    var caInstalled = false
    var systemProxySet = false
    /// The variables a launched app gets.
    var env: [String: String] = [:]
    /// Ends the capture when the VM is no longer the running engine process it started with.
    var watcher: Task<Void, Never>?
}

/// `vm.http.*`: a capture is an `alcove-proxy` child process, its CA certificate in the guest and, on Windows, the
/// guest's system proxy pointing at it.
extension ControlHandler {
    static let httpOps: Set<String> = [
        "vm.http.start", "vm.http.stop", "vm.http.requests", "vm.http.request", "vm.http.clear",
        "vm.http.rule.add", "vm.http.rule.list", "vm.http.rule.remove", "vm.http.rule.clear",
    ]

    /// The header names whose values a trace never holds.
    static let secretHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key"]

    private struct CaptureRequest: Sendable {
        var config: [String: JSON] = [:]
        var systemProxy = true
    }

    /// Whether the guest tools can run the capture's recipes, or why not and what changes that.
    private enum GuestAccess {
        case ready(AgentClient)
        case unavailable(reason: String, fix: String)
    }

    func http(op: String, params: JSON) async throws -> JSON {
        switch op {
        case "vm.http.start":
            let request = try captureRequest(params)
            let t = try await running(params)
            return try await captureGate.withLock(t.name) { try await self.startCapture(t, request) }
        case "vm.http.stop":
            let t = try await target(params)
            return try await captureGate.withLock(t.name) { try await self.stopCapture(t) }
        default:
            return try await proxyCall(op, params)
        }
    }

    // MARK: - vm.http.start

    private nonisolated func captureRequest(_ params: JSON) throws -> CaptureRequest {
        var request = CaptureRequest()
        if let value = params["hosts"], value != .null {
            guard let items = value.arrayValue, items.allSatisfy({ $0.stringValue?.isEmpty == false }) else {
                throw ControlError.failed("hosts must be an array of host globs such as [\"api.example.com\", \"*.corp.net\"]")
            }
            request.config["hosts"] = value
        }
        for key in ["secrets", "bodies"] {
            if let value = try optional(params, key, .boolean) { request.config[key] = value }
        }
        request.systemProxy = try optional(params, "systemProxy", .boolean)?.boolValue ?? true
        return request
    }

    private func guestAccess(_ t: VMTarget, wait: Duration) async -> GuestAccess {
        guard let agent = await t.agent(timeout: wait) else {
            return .unavailable(reason: "guest tools are not connected in '\(t.name)'", fix: "install alcove-agent in the guest")
        }
        guard let hello = await agent.hello, hello.rpcVersion >= 2 else {
            return .unavailable(reason: "guest tools in '\(t.name)' are too old to run commands", fix: "update alcove-agent in the guest")
        }
        guard hello.capabilities.contains("exec") else {
            return .unavailable(reason: "guest tools in '\(t.name)' do not allow running commands", fix: "start alcove-agent with --allow-exec")
        }
        return .ready(agent)
    }

    private func startCapture(_ t: VMTarget, _ request: CaptureRequest) async throws -> JSON {
        let vm = t.name
        if let live = captures[vm] {
            throw ControlError.failed("'\(vm)' is already capturing on port \(live.port); call vm.http.stop first")
        }
        guard await t.state() == .running else { throw ControlError.failed("VM '\(vm)' is paused; call vm.resume first") }
        let os = await t.guestOS()
        let access = await guestAccess(t, wait: HTTPTiming.toolsWait)
        if case .unavailable(let reason, let fix) = access, request.systemProxy {
            throw ControlError.failed("\(reason), and vm.http.start needs them to install the CA certificate and set the system proxy; "
                                      + "\(fix), or pass systemProxy: false")
        }

        let proxy = makeProxy()
        let started: (port: Int, caPath: String)
        do {
            started = try await proxy.start()
        } catch {
            await proxy.stop()
            throw ControlError.failed(proxyReason(error))
        }
        do {
            do { _ = try await proxy.call("config", request.config) } catch { throw ControlError.failed(proxyReason(error)) }
            guard let pem = try? String(contentsOfFile: started.caPath, encoding: .utf8),
                  let thumbprint = ControlHandler.certificateThumbprint(pem: pem) else {
                throw ControlError.failed("the proxy's CA certificate at \(started.caPath) cannot be read; delete ca.pem and ca.key in its folder and call vm.http.start again")
            }
            var capture = HTTPCapture(proxy: proxy, port: started.port, thumbprint: thumbprint, os: os, instance: await t.engineInstance())
            var warnings: [String] = []
            var bundle: String?
            switch (access, GuestRecipes.proxyCAPath(os: os)) {
            case (.ready(let agent), let guestPath?):
                bundle = try await prepareGuest(&capture, &warnings, t, agent, hostCAPath: started.caPath, guestPath: guestPath,
                                                systemProxy: request.systemProxy)
            case (.ready, nil):
                warnings.append("the CA certificate is not installed in the guest (Alcove has no recipe for this guest OS): "
                                + "HTTPS through the proxy fails certificate checks until the guest trusts \(started.caPath) from the host; "
                                + "install that certificate in the guest and start the apps with the returned env")
            case (.unavailable(let reason, let fix), _):
                warnings.append("the CA certificate is not installed in the guest (\(reason)): "
                                + "HTTPS through the proxy fails certificate checks until the guest trusts \(started.caPath) from the host; "
                                + "\(fix) and call vm.http.start again, or install that certificate yourself and start the apps with the returned env")
            }
            capture.env = ControlHandler.proxyEnvironment(port: started.port, caFile: capture.guestCAPath, bundle: bundle)
            capture.watcher = watch(t, capture: capture.id, instance: capture.instance)
            captures[vm] = capture
            var out: [String: JSON] = [
                "proxy": .string("\(GuestRecipes.proxyHost):\(started.port)"),
                "env": .object(capture.env.mapValues(JSON.string)),
                "caInstalled": .bool(capture.caInstalled), "systemProxySet": .bool(capture.systemProxySet),
            ]
            if let path = capture.guestCAPath { out["guestCAPath"] = .string(path) }
            if !warnings.isEmpty { out["warning"] = .string(warnings.joined(separator: "; ")) }
            return .object(out)
        } catch {
            await proxy.stop()
            throw error
        }
    }

    /// Copies the CA certificate into the guest, installs it and, with `systemProxy`, points the guest's system proxy
    /// at the capture; without `systemProxy` it first puts back what an earlier capture left. A step that fails
    /// undoes the steps before it. Returns the CA bundle the guest reports, when it reports one.
    private func prepareGuest(_ capture: inout HTTPCapture, _ warnings: inout [String], _ t: VMTarget, _ agent: AgentClient,
                              hostCAPath: String, guestPath: String, systemProxy: Bool) async throws -> String? {
        let op = "vm.http.start"
        let os = capture.os
        if !systemProxy, let script = GuestRecipes.clearSystemProxy(os: os) {
            let cleared = await runRecipe(agent, script, vm: t.name, op: op)
            guard cleared.ok else { throw ControlError.failed(cleared.detail) }
            if let old = ControlHandler.lastJSONObject(cleared.stdout)?["thumbprint"]?.stringValue,
               ControlHandler.isThumbprint(old), old.uppercased() != capture.thumbprint,
               let remove = GuestRecipes.removeProxyCA(thumbprint: old.uppercased(), os: os) {
                _ = await runRecipe(agent, remove, vm: t.name, op: op)
            }
        }
        do {
            _ = try await agent.pushFile(URL(fileURLWithPath: hostCAPath), toGuestPath: guestPath, overwrite: true, timeout: HTTPTiming.pushTimeout)
        } catch {
            throw ControlError.failed("could not copy the proxy CA into the guest: \(agentFailure(error, vm: t.name, op: op))")
        }
        capture.guestCAPath = guestPath
        var bundle: String?
        do {
            guard let script = GuestRecipes.installProxyCA(thumbprint: capture.thumbprint, os: os) else { return nil }
            let installed = await runRecipe(agent, script, vm: t.name, op: op)
            guard installed.ok else { throw ControlError.failed(installed.detail) }
            let reply = ControlHandler.lastJSONObject(installed.stdout)
            capture.caInstalled = reply?["installed"]?.boolValue ?? true
            bundle = reply?["bundle"]?.stringValue
            if !capture.caInstalled {
                warnings.append("the guest has no update-ca-certificates, so the CA certificate is not in its system store; "
                                + "apps started with the returned env trust it, others need \(guestPath) added to their trust store")
            }
            if systemProxy, let script = GuestRecipes.setSystemProxy(port: capture.port, thumbprint: capture.thumbprint, os: os) {
                let set = await runRecipe(agent, script, vm: t.name, op: op)
                guard set.ok else {
                    if let undo = GuestRecipes.clearSystemProxy(os: os) { _ = await runRecipe(agent, undo, vm: t.name, op: op) }
                    throw ControlError.failed(set.detail)
                }
                capture.systemProxySet = true
                let reply = ControlHandler.lastJSONObject(set.stdout)
                if reply?["winhttp"]?.boolValue == false {
                    warnings.append("netsh could not set the WinHTTP proxy, so services and apps that use WinHTTP are not captured; "
                                    + "run 'netsh winhttp show proxy' with vm.exec to see why")
                }
                if reply?["refreshed"]?.boolValue == false {
                    warnings.append("running apps were not told about the new proxy; restart the apps you want to capture")
                }
            }
        } catch {
            if let undo = GuestRecipes.removeProxyCA(thumbprint: capture.thumbprint, os: os) { _ = await runRecipe(agent, undo, vm: t.name, op: op) }
            throw error
        }
        return bundle
    }

    /// The variables that send an app's requests through the proxy on `port`, in upper and lower case, and, with a CA
    /// file in the guest, the variables that make Node.js, OpenSSL and Python requests trust it.
    static func proxyEnvironment(port: Int, caFile: String?, bundle: String?) -> [String: String] {
        let url = "http://\(GuestRecipes.proxyHost):\(port)"
        var env: [String: String] = [:]
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
            env[name] = url
            env[name.lowercased()] = url
        }
        env["NO_PROXY"] = "localhost,127.0.0.1,::1"
        env["no_proxy"] = "localhost,127.0.0.1,::1"
        if let caFile {
            env["NODE_EXTRA_CA_CERTS"] = caFile
            env["SSL_CERT_FILE"] = bundle ?? caFile
            env["REQUESTS_CA_BUNDLE"] = bundle ?? caFile
        }
        return env
    }

    /// Adds the proxy variables of the VM's capture to the `env` of a launch request. A name the request already
    /// holds, in any letter case, keeps the request's value and gets no second spelling.
    func addProxyEnvironment(to request: inout [String: JSON], vm: String) {
        guard let capture = captures[vm] else { return }
        var env = request["env"]?.objectValue ?? [:]
        let given = Set(env.keys.map { $0.lowercased() })
        for (name, value) in capture.env where !given.contains(name.lowercased()) { env[name] = .string(value) }
        request["env"] = .object(env)
    }

    /// The SHA-1 of the first certificate in `pem` as 40 upper-case hexadecimal digits; nil when it holds none.
    static func certificateThumbprint(pem: String) -> String? {
        guard let begin = pem.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = pem.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<pem.endIndex) else { return nil }
        let body = String(pem[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace })
        guard let der = Data(base64Encoded: body), !der.isEmpty else { return nil }
        return Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    static func isThumbprint(_ text: String) -> Bool {
        text.unicodeScalars.count == 40 && text.unicodeScalars.allSatisfy { $0.isASCII && $0.properties.isASCIIHexDigit }
    }

    private nonisolated func proxyReason(_ error: Error) -> String {
        ControlHandler.failureReason(error, fallback: "alcove-proxy failed in a way Alcove cannot describe; call vm.http.stop, then vm.http.start")
    }

    // MARK: - vm.http.stop

    private func stopCapture(_ t: VMTarget) async throws -> JSON {
        let vm = t.name
        guard let capture = captures[vm] else { return try await stopStaleCapture(t) }
        var exchanges = 0
        if let newest = try? await capture.proxy.call("list", ["limit": 1]) { exchanges = newest["next"]?.intValue ?? 0 }
        var warning: String?
        if capture.guestCAPath != nil || capture.systemProxySet {
            if await t.state() == .running, case .ready(let agent) = await guestAccess(t, wait: HTTPTiming.toolsWait) {
                warning = await restoreGuest(capture, t, agent, op: "vm.http.stop")
            } else {
                warning = "the guest keeps the capture's proxy settings and CA certificate because its guest tools are not reachable; "
                    + "call vm.http.stop again once vm.status shows tools"
            }
        }
        await endCapture(vm, id: capture.id)
        var out: [String: JSON] = ["exchanges": .int(Int64(exchanges))]
        if let warning { out["warning"] = .string(warning) }
        return .object(out)
    }

    /// Puts the guest's proxy settings back and removes the CA certificate of `capture`. Returns nil when both worked,
    /// otherwise the sentences of the steps that failed. With `timeoutMilliseconds` each recipe gets that long and the
    /// CA certificate stays when the settings could not be put back.
    private func restoreGuest(_ capture: HTTPCapture, _ t: VMTarget, _ agent: AgentClient, op: String,
                              timeoutMilliseconds: Int? = nil) async -> String? {
        var failures: [String] = []
        if capture.systemProxySet, let script = GuestRecipes.clearSystemProxy(os: capture.os) {
            let cleared = await runRecipe(agent, script, vm: t.name, op: op, timeoutMilliseconds: timeoutMilliseconds)
            if !cleared.ok { failures.append(cleared.detail) }
        }
        if capture.guestCAPath != nil, failures.isEmpty || timeoutMilliseconds == nil,
           let script = GuestRecipes.removeProxyCA(thumbprint: capture.thumbprint, os: capture.os) {
            let removed = await runRecipe(agent, script, vm: t.name, op: op, timeoutMilliseconds: timeoutMilliseconds)
            if !removed.ok { failures.append(removed.detail) }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    /// `vm.http.stop` for a VM without a capture: clears what an earlier capture left in the guest.
    private func stopStaleCapture(_ t: VMTarget) async throws -> JSON {
        let notCapturing = ControlError.failed("'\(t.name)' is not capturing; call vm.http.start first")
        guard await t.state() == .running, case .ready(let agent) = await guestAccess(t, wait: HTTPTiming.staleToolsWait) else { throw notCapturing }
        let stale = await clearStaleGuest(t, agent, op: "vm.http.stop")
        if let failure = stale.failure { throw ControlError.failed(failure) }
        guard stale.cleared else { throw notCapturing }
        return ["exchanges": 0, "staleCleared": true]
    }

    /// Restores the proxy settings an earlier capture left in the guest and removes its CA certificate. `cleared` tells
    /// whether there was anything to clear; `failure` is the sentence of a step that failed.
    func clearStaleGuest(_ t: VMTarget, _ agent: AgentClient, op: String) async -> (cleared: Bool, failure: String?) {
        let os = await t.guestOS()
        var cleared = false
        var thumbprint: String?
        if let script = GuestRecipes.clearSystemProxy(os: os) {
            let result = await runRecipe(agent, script, vm: t.name, op: op)
            guard result.ok else { return (false, result.detail) }
            let reply = ControlHandler.lastJSONObject(result.stdout)
            cleared = reply?["restored"]?.boolValue == true || reply?["cleared"]?.boolValue == true
            if let stored = reply?["thumbprint"]?.stringValue, ControlHandler.isThumbprint(stored) { thumbprint = stored.uppercased() }
        }
        if let script = GuestRecipes.removeProxyCA(thumbprint: thumbprint, os: os) {
            let result = await runRecipe(agent, script, vm: t.name, op: op)
            guard result.ok else { return (cleared, result.detail) }
            let reply = ControlHandler.lastJSONObject(result.stdout)
            if reply?["removed"]?.boolValue == true || reply?["fileRemoved"]?.boolValue == true { cleared = true }
        }
        return (cleared, nil)
    }

    /// After a restore to a snapshot that was created during a capture: clears what that capture left in the restored
    /// guest. False when the guest tools cannot run the recipes, a recipe failed or there was nothing to clear.
    func clearStaleAfterRestore(_ t: VMTarget, _ agent: AgentClient?) async -> Bool {
        guard agent != nil, case .ready(let ready) = await guestAccess(t, wait: .zero) else { return false }
        let stale = await clearStaleGuest(t, ready, op: "vm.snapshot.restore")
        return stale.failure == nil && stale.cleared
    }

    // MARK: - the capture's life

    /// Removes the capture of `vm` (the one with `id`, when given) and ends its proxy.
    func endCapture(_ vm: String, id: UUID? = nil) async {
        guard let capture = captures[vm], id == nil || capture.id == id else { return }
        captures[vm] = nil
        capture.watcher?.cancel()
        await capture.proxy.stop()
    }

    /// Puts the guest's proxy settings back before the VM of a capture goes away, when its guest tools are connected
    /// right now; each recipe gets `HTTPTiming.partingRecipeMilliseconds`.
    func restoreCaptureGuest(_ t: VMTarget) async {
        guard let capture = captures[t.name], capture.guestCAPath != nil || capture.systemProxySet,
              await t.state() == .running, case .ready(let agent) = await guestAccess(t, wait: .zero) else { return }
        _ = await restoreGuest(capture, t, agent, op: "vm.stop", timeoutMilliseconds: HTTPTiming.partingRecipeMilliseconds)
    }

    /// Ends every capture: puts the proxy settings of the guests back where their guest tools are connected, and
    /// stops the proxies.
    public func shutdown() async {
        for vm in Array(captures.keys) {
            if let t = await registry.target(named: vm) { await restoreCaptureGuest(t) }
            await endCapture(vm)
        }
    }

    /// Looks at the VM every `HTTPTiming.vmPoll` and ends capture `id` once the VM is not running or paused, or runs
    /// in another engine process than `instance`.
    private func watch(_ t: VMTarget, capture id: UUID, instance: Int) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: HTTPTiming.vmPoll)
                guard !Task.isCancelled, let handler = self else { return }
                let state = await t.state()
                if (state == .running || state == .paused), await t.engineInstance() == instance { continue }
                await handler.endCapture(t.name, id: id)
                return
            }
        }
    }

    // MARK: - requests, rules

    private func proxyCall(_ op: String, _ params: JSON) async throws -> JSON {
        var request: [String: JSON] = [:]
        func copy(_ keys: [String]) {
            for key in keys { if let value = params[key], value != .null { request[key] = value } }
        }
        let proxyOp: String
        switch op {
        case "vm.http.requests":
            proxyOp = "list"
            copy(["since", "host", "path", "status", "limit"])
        case "vm.http.request":
            proxyOp = "get"
            guard let id = params["id"], id.intValue != nil else { throw ControlError.missing("id") }
            request["exchange"] = id
            copy(["part", "offset", "length"])
        case "vm.http.clear":
            proxyOp = "clear"
        case "vm.http.rule.add":
            proxyOp = "rule.add"
            copy(["match", "action"])
        case "vm.http.rule.list":
            proxyOp = "rule.list"
        case "vm.http.rule.remove":
            proxyOp = "rule.remove"
            guard let rule = params["rule"], rule.intValue != nil else { throw ControlError.missing("rule") }
            request["rule"] = rule
        case "vm.http.rule.clear":
            proxyOp = "rule.clear"
        default:
            throw ControlError.unknownOp(op)
        }
        let t = try await running(params)
        guard let capture = captures[t.name] else {
            throw ControlError.failed("'\(t.name)' is not capturing; call vm.http.start first")
        }
        do { return try await capture.proxy.call(proxyOp, request) } catch { throw ControlError.failed(proxyReason(error)) }
    }

    // MARK: - vm.doctor

    /// The `proxy` row: what `readSystemProxy` finds in the guest, held against the VM's capture.
    func proxyCheck(_ t: VMTarget, agent: AgentClient, os: VMConfig.GuestOS) async -> JSON {
        guard let script = GuestRecipes.readSystemProxy(os: os) else { return check("proxy", true, "not checked on this guest") }
        let result = await runRecipe(agent, script, vm: t.name, op: "vm.doctor")
        guard result.ok, let read = ControlHandler.lastJSONObject(result.stdout) else {
            return check("proxy", false, result.ok ? "the guest printed no proxy settings" : result.detail,
                         hint: "check that the guest shell works with vm.exec")
        }
        let host = GuestRecipes.proxyHost
        let server = (read["wininetServer"]?.stringValue).flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let enabled = read["wininetEnabled"]?.boolValue ?? false
        var ports: [Int] = []
        if enabled, let port = ControlHandler.capturePort(in: server) { ports.append(port) }
        if let port = read["winhttpPort"]?.intValue, port > 0 { ports.append(port) }
        if let live = captures[t.name] {
            if let other = ports.first(where: { $0 != live.port }) {
                return check("proxy", false, "the system proxy points at \(host):\(other), but the capture listens on port \(live.port)",
                             hint: "call vm.http.stop, then vm.http.start")
            }
            return check("proxy", true, "capturing through \(host):\(live.port), system proxy \(ports.isEmpty ? "not set" : "set")")
        }
        var left: [String] = []
        if let port = ports.first { left.append("the system proxy points at \(host):\(port)") }
        if read["previous"]?.boolValue == true { left.append("the settings from before a capture are still stored") }
        if read["caFile"]?.boolValue == true || read["caInStore"]?.boolValue == true { left.append("the proxy CA is still installed") }
        if !left.isEmpty {
            return check("proxy", false, "no capture is running, but " + left.joined(separator: " and "),
                         hint: "vm.http.stop clears stale proxy settings")
        }
        return check("proxy", true, enabled ? "system proxy \(server)" : "no system proxy")
    }

    /// The port of the first `10.0.2.2:<port>` in `text`; nil when it holds none.
    static func capturePort(in text: String) -> Int? {
        guard let address = text.range(of: GuestRecipes.proxyHost + ":") else { return nil }
        let digits = text[address.upperBound...].prefix { $0.isASCII && $0.isNumber }
        guard let port = Int(digits), (1...65_535).contains(port) else { return nil }
        return port
    }
}
