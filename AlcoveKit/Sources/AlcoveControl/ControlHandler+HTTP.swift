import Foundation
import CryptoKit
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP

/// How long one guest recipe may run.
public struct RecipeLimit: Sendable, Equatable {
    /// The time the guest gives the script.
    public var guestMilliseconds: Int
    /// The further time the host waits for the agent's answer.
    public var marginSeconds: Int

    public init(guestMilliseconds: Int, marginSeconds: Int) {
        self.guestMilliseconds = guestMilliseconds
        self.marginSeconds = marginSeconds
    }

    /// The longest the host waits for the recipe, in seconds.
    public var hostSeconds: Int { guestMilliseconds / 1000 + marginSeconds }
}

/// The time limits of HTTP captures.
public struct HTTPTiming: Sendable {
    /// Pause between two looks at the state of a capturing VM.
    public var vmPoll = Duration.seconds(2)
    /// Longest the guest tools get to connect for `vm.http.start` and for the `vm.http.stop` of a running capture.
    public var toolsWait = Duration.seconds(25)
    /// Longest the guest tools get to connect for a `vm.http.stop` without a running capture.
    public var staleToolsWait = Duration.seconds(5)
    /// Longest each agent request of the CA copy may take; the copy makes four, and a fifth after a failed one.
    public var pushStep = Duration.seconds(6)
    /// The limit of each recipe of `vm.http.start`, `vm.http.stop` and the cleanup after an earlier capture.
    public var recipe = RecipeLimit(guestMilliseconds: 25_000, marginSeconds: 5)
    /// The limit of each recipe that undoes a failed start or restores a guest whose VM stops or whose host shuts down.
    public var undo = RecipeLimit(guestMilliseconds: 12_000, marginSeconds: 3)

    public init() {}
}

/// The HTTP capture of one VM.
struct HTTPCapture {
    let id = UUID()
    /// The VM as the capture journal knows it.
    let owner: CaptureJournal.VM
    let proxy: ProxyControlling
    let port: Int
    /// The SHA-1 of the proxy's CA certificate as 40 upper-case hexadecimal digits.
    let thumbprint: String
    let os: VMConfig.GuestOS
    /// The engine process the capture belongs to.
    let instance: Int
    /// When the capture started, as ISO 8601 text.
    let since: String
    /// Whether the capture has an entry in the capture journal: its guest steps were begun.
    var guestChanged = false
    /// Where the CA certificate is in the guest; nil when it was not copied there.
    var guestCAPath: String?
    var caInstalled = false
    var systemProxySet = false
    /// The variables a launched app gets.
    var env: [String: String] = [:]
    /// Ends the capture when the VM is no longer the running engine process it started with.
    var watcher: Task<Void, Never>?

    /// The capture's entry in the capture journal.
    var journalEntry: CaptureJournal.Entry {
        CaptureJournal.Entry(vm: owner.name, port: port, thumbprint: thumbprint, systemProxy: systemProxySet, since: since, path: owner.path)
    }
}

/// `vm.http.*`: a capture is an `alcove-proxy` child process, its CA certificate in the guest and, on Windows, the
/// guest's system proxy pointing at it.
extension ControlHandler {
    /// The parameters each `vm.http.*` op reads besides `name` and `lease`.
    static let httpParameters: [String: [String]] = [
        "vm.http.start": ["hosts", "secrets", "bodies", "systemProxy"],
        "vm.http.stop": [],
        "vm.http.requests": ["since", "host", "path", "status", "limit"],
        "vm.http.request": ["exchange", "part", "offset", "length"],
        "vm.http.clear": [],
        "vm.http.rule.add": ["match", "action"],
        "vm.http.rule.list": [],
        "vm.http.rule.remove": ["rule"],
        "vm.http.rule.clear": [],
    ]

    static let httpOps = Set(httpParameters.keys)

    /// The fields of a request line and of its reply that belong to the control protocol itself.
    static let envelopeFields: Set<String> = ["id", "op", "ok", "error"]

    /// The header names whose values a trace never holds.
    static let secretHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key"]

    /// The warning of a capture on a Windows guest that intercepts only some hosts.
    static let hostsTrustWarning = "hosts is set: SSL_CERT_FILE and REQUESTS_CA_BUNDLE are not set, so programs that bring their own trust store "
        + "(Python requests, OpenSSL tools) reject the intercepted hosts; omit hosts to capture them"

    /// The warning of an op whose recipe changed the proxy settings without WinINET being told.
    static let notRefreshedWarning = "the proxy settings were written, but Windows was not told to reread them; restart the app under test"

    private struct CaptureRequest: Sendable {
        var config: [String: JSON] = [:]
        var systemProxy = true
        /// Whether the capture intercepts every host: `hosts` is absent or empty.
        var interceptsAll = true
    }

    /// Whether the guest tools can run the capture's recipes, or why not and what changes that.
    private enum GuestAccess {
        case ready(AgentClient)
        case unavailable(reason: String, fix: String)
    }

    /// What a restore of the guest did: whether it found anything of a capture, the sentences of the steps that
    /// failed, and a warning about a step that worked in part.
    struct GuestRestore: Sendable {
        var cleared = false
        var failure: String?
        var warning: String?
    }

    /// Whether a capture goes on while its VM is in `state`: the engine process runs. In the other states it has
    /// ended or is not started yet, so the capture belongs to an engine that is gone.
    static func keepsCapture(_ state: VMController.State) -> Bool {
        switch state {
        case .running, .paused, .suspending, .stopping: return true
        case .stopped, .starting, .failed: return false
        }
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
            request.interceptsAll = items.isEmpty
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
        return await guestAccess(agent, vm: t.name)
    }

    private func guestAccess(_ agent: AgentClient, vm: String) async -> GuestAccess {
        guard let hello = await agent.hello, hello.rpcVersion >= 2 else {
            return .unavailable(reason: "guest tools in '\(vm)' are too old to run commands", fix: "update alcove-agent in the guest")
        }
        guard hello.capabilities.contains("exec") else {
            return .unavailable(reason: "guest tools in '\(vm)' do not allow running commands", fix: "start alcove-agent with --allow-exec")
        }
        return .ready(agent)
    }

    private func startCapture(_ t: VMTarget, _ request: CaptureRequest) async throws -> JSON {
        let vm = t.name
        if let live = captures[vm] {
            throw ControlError.failed("'\(vm)' is already capturing on port \(live.port); call vm.http.stop first")
        }
        let state = await t.state()
        guard state == .running else {
            throw state == .paused ? ControlError.failed("VM '\(vm)' is paused; call vm.resume first") : ControlError.notRunning(vm, state)
        }
        let os = await t.guestOS()
        let access = await guestAccess(t, wait: httpTiming.toolsWait)
        if case .unavailable(let reason, let fix) = access, request.systemProxy {
            throw ControlError.failed("\(reason), and vm.http.start needs them to install the CA certificate and set the system proxy; "
                                      + "\(fix), or pass systemProxy: false")
        }

        let proxy = makeProxy()
        let started: (port: Int, caPath: String)
        do {
            started = try await proxyStartGate.withLock("start") { try await proxy.start() }
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
            var capture = HTTPCapture(owner: await journalVM(t), proxy: proxy, port: started.port, thumbprint: thumbprint, os: os,
                                      instance: await t.engineInstance(), since: ISO8601DateFormatter().string(from: wallClock()))
            var warnings: [String] = []
            var bundle: String?
            switch (access, GuestRecipes.proxyCAPath(os: os)) {
            case (.ready(let agent), let guestPath?):
                capture.systemProxySet = request.systemProxy && os == .windows
                do {
                    try captureJournal.record(capture.journalEntry, now: wallClock())
                } catch {
                    throw ControlError.failed(ControlHandler.failureReason(error, fallback: "the record of captures to restore could not be written; "
                        + "make \(captureJournal.url.deletingLastPathComponent().path) writable and call vm.http.start again"))
                }
                capture.guestChanged = true
                do {
                    bundle = try await prepareGuest(&capture, &warnings, t, agent, hostCAPath: started.caPath, guestPath: guestPath,
                                                    systemProxy: request.systemProxy)
                } catch {
                    let undone = await restoreGuest(t, agent, os: os, thumbprint: thumbprint, op: "vm.http.start", limit: httpTiming.undo)
                    guard undone.failure != nil else {
                        try? captureJournal.remove(vm: capture.owner, now: wallClock())
                        throw error
                    }
                    if ControlHandler.failureReason(error, fallback: "") == GuestRecipes.unreadableProxyState { throw error }
                    throw ControlError.failed("\(ControlHandler.failureReason(error, fallback: "vm.http.start failed in the guest")); the guest keeps what this "
                        + "attempt changed, and Alcove restores it when its guest tools next connect; call vm.http.stop to restore it now")
                }
            case (.ready, nil):
                warnings.append("the CA certificate is not installed in the guest (Alcove has no recipe for this guest OS): "
                                + "HTTPS through the proxy fails certificate checks until the guest trusts \(started.caPath) from the host; "
                                + "install that certificate in the guest and start the apps with the returned env")
            case (.unavailable(let reason, let fix), _):
                warnings.append("the CA certificate is not installed in the guest (\(reason)): "
                                + "HTTPS through the proxy fails certificate checks until the guest trusts \(started.caPath) from the host; "
                                + "\(fix) and call vm.http.start again, or install that certificate yourself and start the apps with the returned env")
            }
            let replacesTrustStore = os != .windows || request.interceptsAll
            capture.env = ControlHandler.proxyEnvironment(port: started.port, caFile: capture.guestCAPath, bundle: bundle,
                                                          trustStoreVariables: replacesTrustStore)
            if capture.guestCAPath != nil, !replacesTrustStore { warnings.append(ControlHandler.hostsTrustWarning) }
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

    /// Copies the CA certificate into the guest, installs it and runs the system proxy recipe: with `systemProxy` it
    /// points the guest's system proxy at the capture, without it it records the capture and puts back what an earlier
    /// capture left. Returns the CA bundle the guest reports, when it reports one.
    private func prepareGuest(_ capture: inout HTTPCapture, _ warnings: inout [String], _ t: VMTarget, _ agent: AgentClient,
                              hostCAPath: String, guestPath: String, systemProxy: Bool) async throws -> String? {
        let op = "vm.http.start"
        let os = capture.os
        let limit = httpTiming.recipe
        do {
            _ = try await agent.pushFile(URL(fileURLWithPath: hostCAPath), toGuestPath: guestPath, overwrite: true, timeout: httpTiming.pushStep)
        } catch {
            throw ControlError.failed("could not copy the proxy CA into the guest: \(agentFailure(error, vm: t.name, op: op))")
        }
        capture.guestCAPath = guestPath
        guard let install = GuestRecipes.installProxyCA(thumbprint: capture.thumbprint, os: os) else { return nil }
        let installed = await runRecipeOutput(agent, install, vm: t.name, op: op, limit: limit)
        guard installed.ok else { throw ControlError.failed(recipeFailure(installed, doing: "install the proxy CA", limit: limit, retry: op)) }
        let reply = ControlHandler.lastJSONObject(installed.stdout)
        capture.caInstalled = reply?["installed"]?.boolValue ?? true
        if !capture.caInstalled {
            warnings.append("the guest has no update-ca-certificates, so the CA certificate is not in its system store; "
                            + "apps started with the returned env trust it, others need \(guestPath) added to their trust store")
        }
        if let script = GuestRecipes.setSystemProxy(port: capture.port, thumbprint: capture.thumbprint, apply: systemProxy, os: os) {
            let set = await runRecipeOutput(agent, script, vm: t.name, op: op, limit: limit)
            guard set.ok else {
                throw ControlError.failed(recipeFailure(set, doing: systemProxy ? "set the system proxy" : "record the capture", limit: limit, retry: op))
            }
            let reply = ControlHandler.lastJSONObject(set.stdout)
            if systemProxy, reply?["winhttp"]?.boolValue == false {
                warnings.append("netsh could not set the WinHTTP proxy, so services and apps that use WinHTTP are not captured; "
                                + "run 'netsh winhttp show proxy' with vm.exec to see why")
            }
            if systemProxy || reply?["restored"]?.boolValue == true, reply?["refreshed"]?.boolValue == false {
                warnings.append(ControlHandler.notRefreshedWarning)
            }
        }
        return reply?["bundle"]?.stringValue
    }

    /// The sentence for a recipe that did not succeed: its own sentence, the agent's failure, or, when the guest gave
    /// no text, what it was doing, how it ended and that `retry` is the op to call again.
    private nonisolated func recipeFailure(_ result: RecipeOutput, doing step: String, limit: RecipeLimit, retry: String) -> String {
        if result.timedOut {
            return "the guest took more than \(limit.guestMilliseconds / 1000) s to \(step); check that it responds with vm.exec, then call \(retry) again"
        }
        guard result.answered, !result.hasText else { return result.detail }
        return "the guest could not \(step) and gave no reason (\(result.detail)); run vm.doctor to check its shell, then call \(retry) again"
    }

    /// The variables that send an app's requests through the proxy on `port`, in upper and lower case. With a CA file
    /// in the guest, `NODE_EXTRA_CA_CERTS` names it, and with `trustStoreVariables` also `SSL_CERT_FILE` and
    /// `REQUESTS_CA_BUNDLE` name `bundle`, or the CA file when there is no bundle.
    static func proxyEnvironment(port: Int, caFile: String?, bundle: String?, trustStoreVariables: Bool) -> [String: String] {
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
            if trustStoreVariables {
                env["SSL_CERT_FILE"] = bundle ?? caFile
                env["REQUESTS_CA_BUNDLE"] = bundle ?? caFile
            }
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
        var warnings: [String] = []
        if capture.guestChanged {
            if await t.state() == .running, case .ready(let agent) = await guestAccess(t, wait: httpTiming.toolsWait) {
                let restored = await restoreGuest(t, agent, os: capture.os, thumbprint: capture.thumbprint, op: "vm.http.stop", limit: httpTiming.recipe)
                if let failure = restored.failure { warnings.append(failure) } else { try? captureJournal.remove(vm: capture.owner, now: wallClock()) }
                if let warning = restored.warning { warnings.append(warning) }
            } else {
                warnings.append("the guest keeps the capture's proxy settings and CA certificate because its guest tools are not reachable; "
                                + "call vm.http.stop again once vm.status shows tools")
            }
        }
        await endCapture(vm, id: capture.id)
        var out: [String: JSON] = ["exchanges": .int(Int64(exchanges))]
        if !warnings.isEmpty { out["warning"] = .string(warnings.joined(separator: "; ")) }
        return .object(out)
    }

    /// `vm.http.stop` for a VM without a capture: clears what an earlier capture left in the guest.
    private func stopStaleCapture(_ t: VMTarget) async throws -> JSON {
        let vm = t.name
        let owner = await journalVM(t)
        let recorded = captureJournal.entry(for: owner)
        guard await t.state() == .running, case .ready(let agent) = await guestAccess(t, wait: httpTiming.staleToolsWait) else {
            guard recorded != nil else { throw ControlError.failed("'\(vm)' is not capturing; call vm.http.start first") }
            throw ControlError.failed("'\(vm)' is not capturing, and what an earlier capture left in its guest cannot be restored while its guest "
                                      + "tools are not reachable; call vm.http.stop again once vm.status shows tools")
        }
        let stale = await restoreGuest(t, agent, os: await t.guestOS(), thumbprint: recorded?.thumbprint, op: "vm.http.stop", limit: httpTiming.recipe)
        if let failure = stale.failure { throw ControlError.failed(failure) }
        try? captureJournal.remove(vm: owner, now: wallClock())
        guard stale.cleared else { throw ControlError.failed("'\(vm)' is not capturing; call vm.http.start first") }
        var out: [String: JSON] = ["exchanges": 0, "staleCleared": true]
        if let warning = stale.warning { out["warning"] = .string(warning) }
        return .object(out)
    }

    /// Puts back the proxy settings a capture left in the guest, deletes its state file, and removes the CA
    /// certificate with `thumbprint` and the one the state file names; without either, the certificate of the CA file.
    /// The CA certificate stays when the guest gave no answer about the proxy settings.
    func restoreGuest(_ t: VMTarget, _ agent: AgentClient, os: VMConfig.GuestOS, thumbprint: String?, op: String,
                      limit: RecipeLimit) async -> GuestRestore {
        var out = GuestRestore()
        var failures: [String] = []
        var thumbprints: [String] = thumbprint.map { [$0.uppercased()] } ?? []
        if let script = GuestRecipes.clearSystemProxy(os: os) {
            let result = await runRecipeOutput(agent, script, vm: t.name, op: op, limit: limit)
            if result.ok {
                let reply = ControlHandler.lastJSONObject(result.stdout)
                let restored = reply?["restored"]?.boolValue == true
                if restored || reply?["state"]?.boolValue == true { out.cleared = true }
                if restored, reply?["refreshed"]?.boolValue == false { out.warning = ControlHandler.notRefreshedWarning }
                if let stored = reply?["thumbprint"]?.stringValue, ControlHandler.isThumbprint(stored), !thumbprints.contains(stored.uppercased()) {
                    thumbprints.append(stored.uppercased())
                }
            } else {
                failures.append(recipeFailure(result, doing: "restore the proxy settings", limit: limit, retry: "vm.http.stop"))
                guard result.answered, !result.timedOut else {
                    out.failure = failures.joined(separator: "; ")
                    return out
                }
            }
        }
        let removals: [String?] = thumbprints.isEmpty ? [nil] : thumbprints
        for (index, thumbprint) in removals.enumerated() {
            guard let script = GuestRecipes.removeProxyCA(thumbprint: thumbprint, os: os), os == .windows || index == 0 else { break }
            let result = await runRecipeOutput(agent, script, vm: t.name, op: op, limit: limit)
            guard result.ok else {
                failures.append(recipeFailure(result, doing: "remove the proxy CA", limit: limit, retry: "vm.http.stop"))
                break
            }
            let reply = ControlHandler.lastJSONObject(result.stdout)
            if reply?["removed"]?.boolValue == true || reply?["fileRemoved"]?.boolValue == true { out.cleared = true }
        }
        if !failures.isEmpty { out.failure = failures.joined(separator: "; ") }
        return out
    }

    // MARK: - what an earlier capture left

    /// Called when a connection to the guest tools of `vm` that the control target does not hold, such as the app
    /// window's, is made. When the capture journal holds an entry for the VM and no capture of it is live, the control
    /// target connects its own tools, and that connection starts the cleanup as every connection it adopts does; a
    /// connection the target holds already starts it at once. Without an entry nothing is connected.
    public func guestToolsSeen(vm: String) async {
        guard captures[vm] == nil, let t = await lookUp(vm), captureJournal.entry(for: await journalVM(t)) != nil, captures[vm] == nil else { return }
        if case .connected(let agent) = await t.agentLink() { await toolsConnected(t, agent) }
    }

    /// The VM `t` as the capture journal knows it.
    func journalVM(_ t: VMTarget) async -> CaptureJournal.VM {
        CaptureJournal.VM(name: t.name, path: await t.bundlePath())
    }

    /// Called for every agent connection a VM adopts: starts the cleanup of `t` when the capture journal holds an
    /// entry for it and no capture of it is live.
    func toolsConnected(_ t: VMTarget, _ agent: AgentClient) async {
        let owner = await journalVM(t)
        guard captures[t.name] == nil, captureJournal.entry(for: owner) != nil else { return }
        _ = staleCleanup(t, agent)
    }

    /// The cleanup of `t` that is running, or a new one: under the capture gate of the VM it restores the guest from
    /// the VM's journal entry, with `HTTPTiming.recipe` for each recipe, and removes the entry when every step worked. Its value tells whether it removed
    /// anything of a capture from the guest.
    func staleCleanup(_ t: VMTarget, _ agent: AgentClient) -> Task<Bool, Never> {
        let vm = t.name
        if let running = staleCleanups[vm] { return running.task }
        let id = UUID()
        let gate = captureGate
        let task = Task { [weak self] () -> Bool in
            guard let handler = self else { return false }
            let cleaned = await gate.withLock(vm) { await handler.cleanStale(t, agent) }
            await handler.cleanupEnded(vm, id, cleaned: cleaned)
            return cleaned
        }
        staleCleanups[vm] = (id, task)
        return task
    }

    /// The cleanup of `vm` that is running; nil when none is.
    func runningCleanup(of vm: String) -> Task<Bool, Never>? { staleCleanups[vm]?.task }

    /// The cleanups of a VM at one moment: the one running and the latest that ended.
    struct CleanupMark: Sendable {
        var running: UUID?
        var ended: UUID?
    }

    /// The cleanups of `vm` as they are now, for `cleanup(since:_:_:)`.
    func cleanupMark(_ vm: String) -> CleanupMark {
        CleanupMark(running: staleCleanups[vm]?.id, ended: endedCleanups[vm]?.id)
    }

    /// Whether a cleanup of `t` begun after `mark` removed anything of a capture from the guest: the one running, the
    /// one that ended since, or else a new one over `agent`, which waits for a cleanup that was running at `mark`.
    func cleanup(since mark: CleanupMark, _ t: VMTarget, _ agent: AgentClient) -> Task<Bool, Never> {
        let vm = t.name
        if let running = staleCleanups[vm], running.id != mark.running { return running.task }
        if let ended = endedCleanups[vm], ended.id != mark.ended, ended.id != mark.running {
            let cleaned = ended.cleaned
            return Task { cleaned }
        }
        guard let earlier = staleCleanups[vm]?.task else { return staleCleanup(t, agent) }
        return Task {
            _ = await earlier.value
            return await self.staleCleanup(t, agent).value
        }
    }

    private func cleanupEnded(_ vm: String, _ id: UUID, cleaned: Bool) {
        endedCleanups[vm] = (id, cleaned)
        if staleCleanups[vm]?.id == id { staleCleanups[vm] = nil }
    }

    private func cleanStale(_ t: VMTarget, _ agent: AgentClient) async -> Bool {
        let vm = t.name
        let owner = await journalVM(t)
        guard captures[vm] == nil, let entry = captureJournal.entry(for: owner), await t.state() == .running,
              case .ready(let ready) = await guestAccess(agent, vm: vm) else { return false }
        let restored = await restoreGuest(t, ready, os: await t.guestOS(), thumbprint: entry.thumbprint, op: "vm.http.stop", limit: httpTiming.recipe)
        guard restored.failure == nil else { return false }
        try? captureJournal.remove(vm: owner, now: wallClock())
        return restored.cleared
    }

    // MARK: - the capture's life

    /// Removes the capture of `vm` (the one with `id`, when given) and ends its proxy.
    func endCapture(_ vm: String, id: UUID? = nil) async {
        guard let capture = captures[vm], id == nil || capture.id == id else { return }
        captures[vm] = nil
        capture.watcher?.cancel()
        await capture.proxy.stop()
    }

    /// Restores the guest of the capture of `t` before its VM goes away, with `HTTPTiming.undo` for each recipe, when
    /// its guest tools are connected right now. Returns nil when the guest holds nothing of the capture afterwards,
    /// otherwise why it still does.
    func restoreCaptureGuest(_ t: VMTarget) async -> String? {
        guard let capture = captures[t.name], capture.guestChanged else { return nil }
        let state = await t.state()
        guard state == .running, case .ready(let agent) = await guestAccess(t, wait: .zero) else {
            return state == .paused ? "the VM was paused" : "its guest tools were not connected"
        }
        let restored = await restoreGuest(t, agent, os: capture.os, thumbprint: capture.thumbprint, op: "vm.stop", limit: httpTiming.undo)
        if let failure = restored.failure { return failure }
        try? captureJournal.remove(vm: capture.owner, now: wallClock())
        return nil
    }

    /// The warning of an op that ended a capture whose guest was not restored for `reason`.
    static func unrestoredWarning(_ reason: String) -> String {
        "the guest keeps the proxy settings and the CA certificate of the capture (\(reason)); Alcove restores them when its guest tools next connect"
    }

    /// Ends every capture: restores the guests whose guest tools are connected, and stops the proxies.
    public func shutdown() async {
        for vm in Array(captures.keys) {
            if let t = await lookUp(vm) { _ = await restoreCaptureGuest(t) }
            await endCapture(vm)
        }
    }

    /// Runs `shutdown()` and returns when it has finished or after `limit`, whichever comes first.
    public nonisolated func shutdown(within limit: Duration) async {
        let finished = OneShotLatch()
        let timer = Task {
            try? await Task.sleep(for: limit)
            finished.open()
        }
        Task {
            await self.shutdown()
            timer.cancel()
            finished.open()
        }
        await finished.wait()
    }

    /// Looks at the VM every `HTTPTiming.vmPoll` and ends capture `id` once the VM is in a state that does not keep a
    /// capture (`keepsCapture`), or runs in another engine process than `instance`.
    private func watch(_ t: VMTarget, capture id: UUID, instance: Int) -> Task<Void, Never> {
        let poll = httpTiming.vmPoll
        return Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                guard !Task.isCancelled, let handler = self else { return }
                if ControlHandler.keepsCapture(await t.state()), await t.engineInstance() == instance { continue }
                await handler.endCapture(t.name, id: id)
                return
            }
        }
    }

    // MARK: - requests, rules

    private func proxyCall(_ op: String, _ params: JSON) async throws -> JSON {
        let proxyOp: String
        var required: [String] = []
        switch op {
        case "vm.http.requests": proxyOp = "list"
        case "vm.http.request": (proxyOp, required) = ("get", ["exchange"])
        case "vm.http.clear": proxyOp = "clear"
        case "vm.http.rule.add": proxyOp = "rule.add"
        case "vm.http.rule.list": proxyOp = "rule.list"
        case "vm.http.rule.remove": (proxyOp, required) = ("rule.remove", ["rule"])
        case "vm.http.rule.clear": proxyOp = "rule.clear"
        default: throw ControlError.unknownOp(op)
        }
        var request: [String: JSON] = [:]
        for key in ControlHandler.httpParameters[op] ?? [] {
            if let value = params[key], value != .null { request[key] = value }
        }
        for key in required where request[key]?.intValue == nil { throw ControlError.missing(key) }
        let t = try await running(params)
        guard let capture = captures[t.name] else {
            throw ControlError.failed("'\(t.name)' is not capturing; call vm.http.start first")
        }
        do { return try await capture.proxy.call(proxyOp, request) } catch { throw ControlError.failed(proxyReason(error)) }
    }

    // MARK: - vm.doctor

    /// The `proxy` row: what `readSystemProxy` finds in the guest, held against the VM's capture. Proxy settings
    /// count as left by a capture only when the guest's state file says it set them and they are exactly
    /// `10.0.2.2:<port of the state file>`.
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
            if live.systemProxySet, let other = ports.first(where: { $0 != live.port }) {
                return check("proxy", false, "the system proxy points at \(host):\(other), but the capture listens on port \(live.port)",
                             hint: "call vm.http.stop, then vm.http.start")
            }
            let set = live.systemProxySet && !ports.isEmpty
            return check("proxy", true, "capturing through \(host):\(live.port), system proxy \(set ? "set" : "not set")")
        }
        if read["previousUnreadable"]?.boolValue == true {
            return check("proxy", false, "no capture is running, but \(GuestRecipes.unreadableProxyState)",
                         hint: "vm.http.stop clears stale proxy settings")
        }
        let recorded = read["previous"]?.boolValue == true
        var left: [String] = []
        if recorded, read["previousSystemProxy"]?.boolValue == true, let port = read["previousPort"]?.intValue, ports.contains(port) {
            left.append("the system proxy points at \(host):\(port)")
        }
        if recorded { left.append("the settings from before a capture are still stored") }
        if read["caFile"]?.boolValue == true || read["caInStore"]?.boolValue == true { left.append("the proxy CA is still installed") }
        if !left.isEmpty {
            return check("proxy", false, "no capture is running, but " + left.joined(separator: " and "),
                         hint: "vm.http.stop clears stale proxy settings")
        }
        guard enabled else { return check("proxy", true, "no system proxy") }
        let foreign = ControlHandler.capturePort(in: server) != nil ? " (not set by Alcove; if a capture left it, change it by hand)" : ""
        return check("proxy", true, "system proxy \(server)\(foreign)")
    }

    /// The port of `text` when the whole text is `10.0.2.2:<port>`; nil for any other text.
    static func capturePort(in text: String) -> Int? {
        let prefix = GuestRecipes.proxyHost + ":"
        guard text.hasPrefix(prefix) else { return nil }
        let digits = text.dropFirst(prefix.count)
        guard (1...5).contains(digits.count), digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let port = Int(digits), (1...65_535).contains(port) else { return nil }
        return port
    }
}

/// Lets tasks wait until it is opened; opening it more than once changes nothing.
final class OneShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in resumed { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let opened = lock.withLock { () -> Bool in
                if !isOpen { waiters.append(waiter) }
                return isOpen
            }
            if opened { waiter.resume() }
        }
    }
}
