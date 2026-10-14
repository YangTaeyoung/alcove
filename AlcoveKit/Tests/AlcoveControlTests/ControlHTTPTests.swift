import XCTest
import CryptoKit
@testable import AlcoveControl
@testable import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

/// What the fake proxy and the fake agent were asked to do, in the order it happened.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func clear() { lock.lock(); items.removeAll(); lock.unlock() }
}

/// A scripted proxy: records its calls in a log and answers from `answers`.
final class FakeProxy: ProxyControlling, @unchecked Sendable {
    let log: CallLog
    let port: Int
    let caPath: String
    private let lock = NSLock()
    private var recorded: [(op: String, params: [String: JSON])] = []
    private var answers: [String: JSON] = [:]
    private var errors: [String: Error] = [:]
    private var startFailure: Error?
    private var stops = 0
    private var ended: String?

    init(log: CallLog, port: Int, caPath: String) {
        self.log = log
        self.port = port
        self.caPath = caPath
    }

    func reply(_ op: String, _ answer: JSON) { lock.lock(); answers[op] = answer; lock.unlock() }
    func fail(_ op: String, _ error: Error) { lock.lock(); errors[op] = error; lock.unlock() }
    func failStart(_ error: Error) { lock.lock(); startFailure = error; lock.unlock() }
    var calls: [(op: String, params: [String: JSON])] { lock.lock(); defer { lock.unlock() }; return recorded }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    func params(of op: String) -> [String: JSON]? { calls.last { $0.op == op }?.params }

    func start() async throws -> (port: Int, caPath: String) {
        log.add("proxy.start")
        if let failure = lock.withLock({ startFailure }) { throw failure }
        return (port, caPath)
    }

    func call(_ op: String, _ params: [String: JSON]) async throws -> JSON {
        log.add("proxy.\(op)")
        let (failure, answer) = lock.withLock { () -> (Error?, JSON) in
            recorded.append((op, params))
            return (errors[op], answers[op] ?? [:])
        }
        if let failure { throw failure }
        return answer
    }

    func stop() async {
        log.add("proxy.stop")
        lock.withLock { stops += 1 }
    }

    /// Makes `exitReason` answer `reason`, as a proxy that ended on its own does.
    func end(_ reason: String) { lock.withLock { ended = reason } }

    func exitReason() async -> String? { lock.withLock { ended } }

    /// Whether `stop` is called within 20 s; records a failure when it is not.
    func stopped(file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        await eventually("the capture's proxy is stopped", file: file, line: line) { self.stopCount > 0 }
    }
}

/// A proxy whose `start` counts itself in `starts` and then waits until `hold` is opened.
final class HeldProxy: ProxyControlling, @unchecked Sendable {
    let hold: OneShotLatch
    let starts: LockedBox<Int>
    let caPath: String

    init(hold: OneShotLatch, starts: LockedBox<Int>, caPath: String) {
        self.hold = hold
        self.starts = starts
        self.caPath = caPath
    }

    func start() async throws -> (port: Int, caPath: String) {
        starts.value += 1
        await hold.wait()
        return (49152, caPath)
    }

    func call(_ op: String, _ params: [String: JSON]) async throws -> JSON { [:] }
    func stop() async {}
    func exitReason() async -> String? { nil }
}

/// Hands out one new `FakeProxy` per capture, with ports counting up from 49152.
final class FakeProxyFactory: @unchecked Sendable {
    let log: CallLog
    let caPath: String
    private let lock = NSLock()
    private var proxies: [FakeProxy] = []

    init(log: CallLog, caPath: String) {
        self.log = log
        self.caPath = caPath
    }

    var made: [FakeProxy] { lock.lock(); defer { lock.unlock() }; return proxies }
    var latest: FakeProxy { made[made.count - 1] }

    func make() -> FakeProxy {
        lock.lock(); defer { lock.unlock() }
        let proxy = FakeProxy(log: log, port: 49152 + proxies.count, caPath: caPath)
        proxies.append(proxy)
        return proxy
    }
}

private let caBody = Data("alcove test certificate authority".utf8)
private let caPEM = "-----BEGIN CERTIFICATE-----\n\(caBody.base64EncodedString())\n-----END CERTIFICATE-----\n"
private let caThumbprint = Insecure.SHA1.hash(data: caBody).map { String(format: "%02X", $0) }.joined()
private let otherThumbprint = String(repeating: "AB", count: 20)
private let noState = "{\"state\":false,\"restored\":false,\"thumbprint\":\"\",\"refreshed\":false}"

private func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

/// What `readSystemProxy` prints for a guest with these findings.
private func guestProxy(previous: Bool = false, unreadable: Bool = false, port: Int = 0, system: Bool = false, ca: Bool = false,
                        enabled: Bool = false, server: String = "", winhttp: Int = 0) -> String {
    "{\"previous\":\(previous),\"previousUnreadable\":\(unreadable),\"previousPort\":\(port),\"previousSystemProxy\":\(system),"
        + "\"caFile\":\(ca),\"caInStore\":\(ca),\"wininetEnabled\":\(enabled),\"wininetServer\":\"\(base64(server))\",\"winhttpPort\":\(winhttp)}"
}

/// What `clearSystemProxy` prints after it restored the settings a state file with `thumbprint` remembered.
private func restoredState(_ thumbprint: String, refreshed: Bool = true) -> String {
    "{\"state\":true,\"restored\":true,\"thumbprint\":\"\(thumbprint)\",\"refreshed\":\(refreshed)}"
}

/// The journal calls of the tests, by VM name alone: they find the entries of every bundle of that name.
extension CaptureJournal {
    func entry(for name: String) -> Entry? { entry(for: VM(name: name, path: nil)) }
    func snapshotEntry(_ snapshot: String, vm name: String) -> Entry? { snapshotEntry(snapshot, vm: VM(name: name, path: nil)) }
    func remove(vm name: String, now: Date) throws { try remove(vm: VM(name: name, path: nil), now: now) }
    func forgetSnapshot(_ snapshot: String, vm name: String, now: Date) throws { try forgetSnapshot(snapshot, vm: VM(name: name, path: nil), now: now) }
    func forget(vm name: String, now: Date) throws { try forget(vm: VM(name: name, path: nil), now: now) }
}

/// A handler over the running VM "Win", its fake agent and the proxies the handler makes.
private struct Capture: Sendable {
    let h: ControlHandler
    let t: FakeTarget
    let agent: FakeAgent
    let fs: FakeFS
    let factory: FakeProxyFactory
    let log: CallLog
    /// What a recipe prints, by log name; a recipe without an entry prints its default.
    let outputs: LockedBox<[String: String]>
    /// The recipes that exit with 2 and this sentence on stderr, by log name.
    let failures: LockedBox<[String: String]>
    /// The fields of the `exec.run` answer of a recipe, by log name, in place of any other answer.
    let answers: LockedBox<[String: [String: JSON]]>
    /// The recipes whose requests get no answer until `release` sends one, by log name.
    let held: LockedBox<Set<String>>
    /// The requests of held recipes that wait for their answer.
    let waiting: LockedBox<[(name: String, request: JSON, agent: FakeAgent)]>
    /// Runs on the agent's thread before each guest step is answered, with the step's log name.
    let onStep: LockedBox<(@Sendable (String) -> Void)?>
    /// The `timeout_ms` of the recipes the guest was asked to run, in order.
    let limits: LockedBox<[Int]>
    let launches: LockedBox<[JSON]>
    /// The capture directory of the handler: the CA certificate and the capture journal.
    let directory: URL
    /// Builds another handler over the same VM, capture directory and proxies.
    let makeHandler: @Sendable () -> ControlHandler
    /// What the fake agent of this capture answers with.
    let agentHandler: @Sendable (JSON, FakeAgent) -> [JSON]
    /// The lines the handlers wrote to their log.
    let hostLog: LockedBox<[String]>

    var journal: CaptureJournal { CaptureJournal(directory: directory) }

    func start(_ params: [String: JSON] = [:]) async throws -> JSON {
        var all = params
        all["name"] = "Win"
        return try await h.handle(op: "vm.http.start", params: .object(all))
    }

    func failure(_ op: String, _ params: JSON = ["name": "Win"]) async -> String {
        do { _ = try await h.handle(op: op, params: params); return "no error" } catch { return "\(error)" }
    }

    /// Answers the held requests of the recipe `name` with exit code 0 and `printed`.
    func release(_ name: String, printing printed: String) {
        let ready = waiting.value.filter { $0.name == name }
        waiting.value = waiting.value.filter { $0.name != name }
        held.value = held.value.subtracting([name])
        for item in ready {
            item.agent.sendLine(agentReply(item.request, ["code": 0, "stdout": .string(printed + "\r\n"), "stderr": "", "timed_out": false]))
        }
    }
}

final class ControlHTTPTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("control-http-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The log name of a recipe script; `recipe.other` for a script that is none of the capture's recipes.
    private static func recipeName(_ script: String, os: VMConfig.GuestOS) -> String {
        if script == GuestRecipes.installProxyCA(thumbprint: caThumbprint, os: os) { return "recipe.installCA" }
        if script == GuestRecipes.clearSystemProxy(os: os) { return "recipe.clearProxy" }
        if script == GuestRecipes.readSystemProxy(os: os) { return "recipe.readProxy" }
        if script == GuestRecipes.removeProxyCA(thumbprint: caThumbprint, os: os) { return "recipe.removeCA" }
        if script == GuestRecipes.removeProxyCA(thumbprint: otherThumbprint, os: os) { return "recipe.removeCA(other)" }
        if script == GuestRecipes.removeProxyCA(thumbprint: nil, os: os) { return "recipe.removeCA(file)" }
        for port in 49152..<49156 {
            if script == GuestRecipes.setSystemProxy(port: port, thumbprint: caThumbprint, apply: true, os: os) { return "recipe.setProxy(\(port))" }
            if script == GuestRecipes.setSystemProxy(port: port, thumbprint: caThumbprint, apply: false, os: os) { return "recipe.recordCapture(\(port))" }
        }
        return "recipe.other"
    }

    /// What a recipe prints when the test gives it no output.
    private static func defaultOutput(_ name: String) -> String {
        switch name {
        case "recipe.installCA": return "{\"installed\":true,\"added\":true}"
        case "recipe.clearProxy": return noState
        case "recipe.readProxy": return guestProxy()
        case "recipe.removeCA": return "{\"removed\":true,\"fileRemoved\":true}"
        case "recipe.removeCA(other)": return "{\"removed\":true,\"fileRemoved\":false}"
        case "recipe.removeCA(file)": return "{\"removed\":false,\"fileRemoved\":false}"
        case "recipe.other":
            return "{\"user\":\"alcove\",\"locked\":false,\"freeBytes\":40000000000,\"utc\":\"2027-01-15T08:00:00Z\",\"dns\":true,\"scale\":100}"
        case _ where name.hasPrefix("recipe.recordCapture"):
            return "{\"set\":false,\"keptPrevious\":false,\"restored\":false,\"winhttp\":false,\"refreshed\":false}"
        default: return "{\"set\":true,\"keptPrevious\":false,\"restored\":false,\"winhttp\":true,\"refreshed\":true}"
        }
    }

    /// The limits a test handler works with: short waits for guest tools that are absent, and `vmPoll` between two
    /// looks at the VM.
    private static func timing(vmPoll: Duration) -> HTTPTiming {
        var timing = HTTPTiming()
        timing.vmPoll = vmPoll
        timing.toolsWait = .milliseconds(50)
        timing.staleToolsWait = .milliseconds(50)
        return timing
    }

    private func capture(os: VMConfig.GuestOS = .windows, connected: Bool = true, caps: [String]? = nil, vmPoll: Duration = .milliseconds(20),
                         directory: URL? = nil, bundle: String? = nil, adjust: (@Sendable (inout HTTPTiming) -> Void)? = nil,
                         registry: (@Sendable (FakeTarget) -> VMRegistry)? = nil,
                         makeProxy: (@Sendable () -> ProxyControlling)? = nil) async throws -> Capture {
        let dir = try directory ?? tempDir()
        let caPath = dir.appendingPathComponent("ca.pem").path
        try Data(caPEM.utf8).write(to: URL(fileURLWithPath: caPath))
        let log = CallLog()
        let factory = FakeProxyFactory(log: log, caPath: caPath)
        let outputs = LockedBox<[String: String]>([:])
        let failures = LockedBox<[String: String]>([:])
        let answers = LockedBox<[String: [String: JSON]]>([:])
        let held = LockedBox<Set<String>>([])
        let waiting = LockedBox<[(name: String, request: JSON, agent: FakeAgent)]>([])
        let onStep = LockedBox<(@Sendable (String) -> Void)?>(nil)
        let limits = LockedBox<[Int]>([])
        let launches = LockedBox<[JSON]>([])
        let hostLog = LockedBox<[String]>([])
        let fs = FakeFS()
        let agent = FakeAgent()
        if let caps { agent.caps = caps }
        fs.install(on: agent)
        let files = agent.handler
        let handler: @Sendable (JSON, FakeAgent) -> [JSON] = { m, a in
            guard m["t"]?.stringValue == "req" else { return [] }
            switch m["op"]?.stringValue {
            case "exec.run":
                let name = ControlHTTPTests.recipeName(m["cmd"]?.stringValue ?? "", os: os)
                onStep.value?(name)
                log.add(name)
                limits.value = limits.value + [m["timeout_ms"]?.intValue ?? -1]
                if held.value.contains(name) {
                    waiting.value = waiting.value + [(name, m, a)]
                    return []
                }
                if let fields = answers.value[name] { return [agentReply(m, fields)] }
                if let sentence = failures.value[name] {
                    return [agentReply(m, ["code": 2, "stdout": "", "stderr": .string(sentence + "\r\n"), "timed_out": false])]
                }
                let printed = outputs.value[name] ?? ControlHTTPTests.defaultOutput(name)
                return [agentReply(m, ["code": 0, "stdout": .string(printed + "\r\n"), "stderr": "", "timed_out": false])]
            case "app.launch":
                launches.value = launches.value + [m]
                return [agentReply(m, ["pid": 4242])]
            case "fs.rename":
                onStep.value?("push")
                log.add("push \(m["to"]?.stringValue ?? "")")
                return files?(m, a) ?? []
            default:
                onStep.value?("fs")
                return files?(m, a) ?? []
            }
        }
        agent.handler = handler
        _ = agent.start()
        addTeardownBlock { agent.stop() }
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 800, height: 600))
        await t.setOS(os)
        await t.setBundle(bundle)
        if connected {
            let client = AgentClient()
            try await client.connect(port: agent.port, expectedToken: nil)
            await t.setAgent(client)
        }
        let now = ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!
        let targets = registry?(t) ?? FakeRegistry(targets: ["Win": t])
        var adjusted = ControlHTTPTests.timing(vmPoll: vmPoll)
        adjust?(&adjusted)
        let timing = adjusted
        let makeHandler: @Sendable () -> ControlHandler = {
            ControlHandler(registry: targets, hostKind: "test", captureDirectory: dir, now: { now }, httpTiming: timing,
                           makeProxy: makeProxy ?? { factory.make() }, log: { line in hostLog.value = hostLog.value + [line] })
        }
        return Capture(h: makeHandler(), t: t, agent: agent, fs: fs, factory: factory, log: log, outputs: outputs, failures: failures,
                       answers: answers, held: held, waiting: waiting, onStep: onStep, limits: limits, launches: launches, directory: dir,
                       makeHandler: makeHandler, agentHandler: handler, hostLog: hostLog)
    }

    /// A new agent connection to a second fake agent that answers as the first one of `c` does.
    private func newConnection(_ c: Capture) async throws -> AgentClient {
        try await newAgent(c).client
    }

    /// A new agent connection, as `newConnection` makes it, and the fake agent at its other end.
    private func newAgent(_ c: Capture) async throws -> (client: AgentClient, agent: FakeAgent) {
        let agent = FakeAgent()
        agent.handler = c.agentHandler
        _ = agent.start()
        addTeardownBlock { agent.stop() }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        return (client, agent)
    }

    private func check(_ doctor: JSON, _ id: String) -> JSON? {
        doctor["checks"]?.arrayValue?.first { $0["id"]?.stringValue == id }
    }

    // MARK: - vm.http.start

    func testStartInstallsCAAndSetsProxy() async throws {
        let c = try await capture()
        let r = try await c.start(["secrets": true, "bodies": false])
        XCTAssertEqual(c.log.entries, ["proxy.start", "proxy.config", "push \(GuestRecipes.windowsProxyCAPath)",
                                       "recipe.installCA", "recipe.setProxy(49152)"])
        XCTAssertEqual(c.factory.latest.params(of: "config"), ["secrets": true, "bodies": false])
        XCTAssertEqual(c.fs[GuestRecipes.windowsProxyCAPath], Data(caPEM.utf8))
        XCTAssertEqual(r["proxy"]?.stringValue, "10.0.2.2:49152")
        XCTAssertEqual(r["caInstalled"]?.boolValue, true)
        XCTAssertEqual(r["systemProxySet"]?.boolValue, true)
        XCTAssertEqual(r["guestCAPath"]?.stringValue, "C:\\ProgramData\\Alcove\\proxy-ca.pem")
        XCTAssertNil(r["warning"])
        let env = try XCTUnwrap(r["env"]?.objectValue)
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            XCTAssertEqual(env[name]?.stringValue, "http://10.0.2.2:49152", name)
        }
        for name in ["NO_PROXY", "no_proxy"] { XCTAssertEqual(env[name]?.stringValue, "localhost,127.0.0.1,::1", name) }
        for name in ["NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"] {
            XCTAssertEqual(env[name]?.stringValue, "C:\\ProgramData\\Alcove\\proxy-ca.pem", name)
        }
        XCTAssertEqual(env.count, 11)
    }

    func testWindowsStartWithHostsLeavesTheTrustStoreVariablesOut() async throws {
        let c = try await capture()
        let r = try await c.start(["hosts": ["api.example.com", "*.corp.net"]])
        XCTAssertEqual(c.factory.latest.params(of: "config"), ["hosts": ["api.example.com", "*.corp.net"]])
        let env = try XCTUnwrap(r["env"]?.objectValue)
        XCTAssertEqual(env["NODE_EXTRA_CA_CERTS"]?.stringValue, GuestRecipes.windowsProxyCAPath)
        XCTAssertNil(env["SSL_CERT_FILE"])
        XCTAssertNil(env["REQUESTS_CA_BUNDLE"])
        XCTAssertEqual(env.count, 9)
        XCTAssertEqual(r["warning"]?.stringValue, "hosts is set: SSL_CERT_FILE and REQUESTS_CA_BUNDLE are not set, so programs that bring their own "
                       + "trust store (Python requests, OpenSSL tools) reject the intercepted hosts; omit hosts to capture them")

        let all = try await capture()
        let whole = try await all.start(["hosts": []])
        XCTAssertEqual(whole["env"]?["SSL_CERT_FILE"]?.stringValue, GuestRecipes.windowsProxyCAPath)
        XCTAssertEqual(whole["env"]?["REQUESTS_CA_BUNDLE"]?.stringValue, GuestRecipes.windowsProxyCAPath)
        XCTAssertNil(whole["warning"])
    }

    func testLinuxStartWithHostsKeepsTheSystemBundle() async throws {
        let c = try await capture(os: .linux)
        c.outputs.value["recipe.installCA"] = "{\"installed\":true,\"bundle\":\"/etc/ssl/certs/ca-certificates.crt\"}"
        let r = try await c.start(["hosts": ["api.example.com"]])
        XCTAssertEqual(r["env"]?["NODE_EXTRA_CA_CERTS"]?.stringValue, GuestRecipes.linuxProxyCAPath)
        XCTAssertEqual(r["env"]?["SSL_CERT_FILE"]?.stringValue, "/etc/ssl/certs/ca-certificates.crt")
        XCTAssertEqual(r["env"]?["REQUESTS_CA_BUNDLE"]?.stringValue, "/etc/ssl/certs/ca-certificates.crt")
        XCTAssertNil(r["warning"])
    }

    func testStartSendsOnlyTheGivenConfig() async throws {
        let c = try await capture()
        _ = try await c.start()
        XCTAssertEqual(c.factory.latest.params(of: "config"), [:])
    }

    func testStartWithoutSystemProxy() async throws {
        let c = try await capture()
        let r = try await c.start(["systemProxy": false])
        XCTAssertEqual(c.log.entries, ["proxy.start", "proxy.config", "push \(GuestRecipes.windowsProxyCAPath)", "recipe.installCA",
                                       "recipe.recordCapture(49152)"])
        XCTAssertEqual(r["caInstalled"]?.boolValue, true)
        XCTAssertEqual(r["systemProxySet"]?.boolValue, false)
        XCTAssertEqual(r["guestCAPath"]?.stringValue, GuestRecipes.windowsProxyCAPath)
        XCTAssertEqual(r["env"]?["HTTPS_PROXY"]?.stringValue, "http://10.0.2.2:49152")
        XCTAssertNil(r["warning"])
        XCTAssertEqual(c.journal.entry(for: "Win")?.systemProxy, false)

        c.log.clear()
        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(c.log.entries, ["proxy.list", "recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
    }

    func testStartWithoutSystemProxyTellsWhenRestoredSettingsWereNotAnnounced() async throws {
        let c = try await capture()
        c.outputs.value["recipe.recordCapture(49152)"] = "{\"set\":false,\"keptPrevious\":false,\"restored\":true,\"winhttp\":false,\"refreshed\":false}"
        let r = try await c.start(["systemProxy": false])
        XCTAssertEqual(r["warning"]?.stringValue, "the proxy settings were written, but Windows was not told to reread them; restart the app under test")
    }

    func testStartTwiceRefused() async throws {
        let c = try await capture()
        _ = try await c.start()
        let second = await c.failure("vm.http.start")
        XCTAssertEqual(second, "'Win' is already capturing on port 49152; call vm.http.stop first")
        XCTAssertEqual(c.factory.made.count, 1)
        XCTAssertEqual(c.factory.latest.stopCount, 0)
    }

    func testStartValidatesItsParameters() async throws {
        let c = try await capture()
        let hosts = await c.failure("vm.http.start", ["name": "Win", "hosts": "api.example.com"])
        XCTAssertEqual(hosts, "hosts must be an array of host globs such as [\"api.example.com\", \"*.corp.net\"]")
        let secrets = await c.failure("vm.http.start", ["name": "Win", "secrets": "yes"])
        XCTAssertEqual(secrets, "parameter 'secrets' must be a boolean")
        let system = await c.failure("vm.http.start", ["name": "Win", "systemProxy": 1])
        XCTAssertEqual(system, "parameter 'systemProxy' must be a boolean")
        XCTAssertEqual(c.log.entries, [])
    }

    func testStartWithoutToolsRefusesUnlessSystemProxyIsOff() async throws {
        let c = try await capture(connected: false)
        let refused = await c.failure("vm.http.start")
        XCTAssertEqual(refused, "guest tools are not connected in 'Win', and vm.http.start needs them to install the CA certificate and set "
                       + "the system proxy; install alcove-agent in the guest, or pass systemProxy: false")
        XCTAssertEqual(c.log.entries, [])

        let r = try await c.start(["systemProxy": false])
        XCTAssertEqual(c.log.entries, ["proxy.start", "proxy.config"])
        XCTAssertEqual(r["proxy"]?.stringValue, "10.0.2.2:49152")
        XCTAssertEqual(r["caInstalled"]?.boolValue, false)
        XCTAssertEqual(r["systemProxySet"]?.boolValue, false)
        XCTAssertNil(r["guestCAPath"])
        let env = try XCTUnwrap(r["env"]?.objectValue)
        XCTAssertEqual(env["HTTP_PROXY"]?.stringValue, "http://10.0.2.2:49152")
        XCTAssertNil(env["SSL_CERT_FILE"])
        XCTAssertEqual(env.count, 8)
        let warning = try XCTUnwrap(r["warning"]?.stringValue)
        XCTAssertTrue(warning.hasPrefix("the CA certificate is not installed in the guest (guest tools are not connected in 'Win'): "), warning)
        XCTAssertTrue(warning.contains(c.factory.caPath), warning)
        XCTAssertTrue(warning.hasSuffix("install alcove-agent in the guest and call vm.http.start again, or install that certificate yourself and start the apps with the returned env"), warning)
        XCTAssertNil(c.journal.entry(for: "Win"))
    }

    func testStartNeedsToolsThatRunCommands() async throws {
        let c = try await capture(caps: ["clipboard", "files"])
        let refused = await c.failure("vm.http.start")
        XCTAssertEqual(refused, "guest tools in 'Win' do not allow running commands, and vm.http.start needs them to install the CA certificate "
                       + "and set the system proxy; start alcove-agent with --allow-exec, or pass systemProxy: false")
    }

    func testStartOnAVMThatIsNotRunningNamesItsState() async throws {
        let c = try await capture()
        await c.t.setState(.paused)
        let paused = await c.failure("vm.http.start")
        XCTAssertEqual(paused, "VM 'Win' is paused; call vm.resume first")
        await c.t.setState(.stopped)
        let stopped = await c.failure("vm.http.start")
        XCTAssertEqual(stopped, "VM 'Win' is stopped; call vm.start first")
        XCTAssertEqual(c.log.entries, [])
    }

    func testStartUndoesTheGuestStepsWhenTheProxyRecipeFails() async throws {
        let c = try await capture()
        c.failures.value["recipe.setProxy(49152)"] = "could not set the system proxy of the guest: Access is denied.; check that alcove-agent runs elevated, or call vm.http.start with systemProxy false"
        let text = await c.failure("vm.http.start")
        XCTAssertEqual(text, "could not set the system proxy of the guest: Access is denied.; check that alcove-agent runs elevated, or call vm.http.start with systemProxy false")
        XCTAssertEqual(c.log.entries, ["proxy.start", "proxy.config", "push \(GuestRecipes.windowsProxyCAPath)", "recipe.installCA",
                                       "recipe.setProxy(49152)", "recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
        XCTAssertNil(c.journal.entry(for: "Win"))
        let after = await c.failure("vm.http.requests")
        XCTAssertEqual(after, "'Win' is not capturing; call vm.http.start first")
    }

    func testStartUndoesTheGuestStepsWhenTheCARecipeFails() async throws {
        let c = try await capture()
        c.failures.value["recipe.installCA"] = "could not install the proxy CA in the guest: Access is denied.; check that alcove-agent runs elevated"
        let text = await c.failure("vm.http.start")
        XCTAssertEqual(text, "could not install the proxy CA in the guest: Access is denied.; check that alcove-agent runs elevated")
        XCTAssertEqual(c.log.entries, ["proxy.start", "proxy.config", "push \(GuestRecipes.windowsProxyCAPath)", "recipe.installCA",
                                       "recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
        XCTAssertNil(c.journal.entry(for: "Win"))
    }

    func testAStartWhoseUndoFailsSaysWhatTheGuestKeeps() async throws {
        let c = try await capture()
        c.failures.value["recipe.setProxy(49152)"] = "could not set the system proxy of the guest: Access is denied.; check that alcove-agent runs elevated, or call vm.http.start with systemProxy false"
        c.failures.value["recipe.removeCA"] = "could not remove the proxy CA from the guest: Access is denied.; check that alcove-agent runs elevated, then call vm.http.stop again"
        let text = await c.failure("vm.http.start")
        XCTAssertEqual(text, "could not set the system proxy of the guest: Access is denied.; check that alcove-agent runs elevated, or call "
                       + "vm.http.start with systemProxy false; the guest keeps what this attempt changed, and Alcove restores it when its guest "
                       + "tools next connect; call vm.http.stop to restore it now")
        XCTAssertEqual(c.journal.entry(for: "Win")?.thumbprint, caThumbprint)
        XCTAssertEqual(c.factory.latest.stopCount, 1)
    }

    func testACopyThatFailsIsUndoneAndNamed() async throws {
        let c = try await capture()
        let files = c.agentHandler
        c.agent.handler = { m, a in
            guard m["op"]?.stringValue == "fs.write" else { return files(m, a) }
            var refusal: [String: JSON] = ["t": "res", "ok": false, "error": "cannot write 'C:\\ProgramData\\Alcove\\proxy-ca.pem.alcove-part': Access is denied.; check the folder"]
            refusal["id"] = m["id"] ?? .null
            return [.object(refusal)]
        }
        let text = await c.failure("vm.http.start")
        XCTAssertEqual(text, "could not copy the proxy CA into the guest: cannot write 'C:\\ProgramData\\Alcove\\proxy-ca.pem.alcove-part': Access is denied.; check the folder")
        XCTAssertEqual(c.log.entries, ["proxy.start", "proxy.config", "recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
        XCTAssertEqual(c.limits.value, [12_000, 12_000])
        XCTAssertNil(c.journal.entry(for: "Win"))
    }

    func testEachRequestOfTheCACopyWaitsAtMostThePushStep() async throws {
        let c = try await capture(adjust: { $0.pushStep = .milliseconds(300) })
        let files = c.agentHandler
        c.agent.handler = { m, a in m["op"]?.stringValue == "fs.stat" ? [] : files(m, a) }
        let text = LockedBox("")
        let ended = await finishes("vm.http.start gives up on the CA copy") { text.value = await c.failure("vm.http.start") }
        XCTAssertTrue(ended)
        XCTAssertEqual(text.value, "could not copy the proxy CA into the guest: guest tools in 'Win' did not answer vm.http.start in time; "
                       + "check vm.status and retry")
        XCTAssertEqual(c.log.entries, ["proxy.start", "proxy.config", "recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
    }

    func testTheHostWaitsForARecipeNoLongerThanItsLimit() async throws {
        let c = try await capture(adjust: { $0.recipe = RecipeLimit(guestMilliseconds: 1_000, marginSeconds: 1) })
        c.held.value = ["recipe.installCA"]
        let text = LockedBox("")
        let ended = await finishes("vm.http.start gives up on the recipe the guest does not answer") { text.value = await c.failure("vm.http.start") }
        XCTAssertTrue(ended)
        XCTAssertEqual(text.value, "guest tools in 'Win' did not answer vm.http.start in time; check vm.status and retry")
        XCTAssertEqual(c.limits.value, [1_000, 12_000, 12_000])
        XCTAssertEqual(c.log.entries, ["proxy.start", "proxy.config", "push \(GuestRecipes.windowsProxyCAPath)", "recipe.installCA",
                                       "recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
    }

    func testAStartOverAStateFileThatCannotBeReadIsRefusedBeforeTheCAIsTrusted() async throws {
        let c = try await capture()
        c.failures.value["recipe.installCA"] = GuestRecipes.unreadableProxyState
        c.failures.value["recipe.clearProxy"] = GuestRecipes.unreadableProxyState
        let text = await c.failure("vm.http.start")
        XCTAssertEqual(text, GuestRecipes.unreadableProxyState)
        XCTAssertEqual(c.log.entries, ["proxy.start", "proxy.config", "push \(GuestRecipes.windowsProxyCAPath)", "recipe.installCA",
                                       "recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
        XCTAssertEqual(c.journal.entry(for: "Win")?.port, 49152)
    }

    func testAStartOverAStateFileThatCannotBeReadNamesAnUndoStepThatFailedToo() async throws {
        let c = try await capture()
        let removal = "could not remove the proxy CA from the guest: Access is denied.; check that alcove-agent runs elevated, then call vm.http.stop again"
        c.failures.value["recipe.installCA"] = GuestRecipes.unreadableProxyState
        c.failures.value["recipe.clearProxy"] = GuestRecipes.unreadableProxyState
        c.failures.value["recipe.removeCA"] = removal
        let text = await c.failure("vm.http.start")
        XCTAssertEqual(text, GuestRecipes.unreadableProxyState + "; " + removal)
        XCTAssertEqual(c.journal.entry(for: "Win")?.port, 49152)
    }

    func testARecipeThatGivesNoReasonBecomesASentence() async throws {
        let c = try await capture()
        c.answers.value["recipe.installCA"] = ["code": 1, "stdout": "", "stderr": "", "timed_out": false]
        let silent = await c.failure("vm.http.start")
        XCTAssertEqual(silent, "the guest could not install the proxy CA and gave no reason (exit code 1); run vm.doctor to check its shell, "
                       + "then call vm.http.start again")

        let slow = try await capture()
        slow.answers.value["recipe.setProxy(49152)"] = ["code": -1, "stdout": "", "stderr": "", "timed_out": true]
        let late = await slow.failure("vm.http.start")
        XCTAssertEqual(late, "the guest took more than 25 s to set the system proxy; check that it responds with vm.exec, then call vm.http.start again")
    }

    func testStartReportsWhatTheProxyRecipeCouldNotDo() async throws {
        let c = try await capture()
        c.outputs.value["recipe.setProxy(49152)"] = "{\"set\":true,\"keptPrevious\":true,\"restored\":false,\"winhttp\":false,\"refreshed\":false}"
        let r = try await c.start()
        XCTAssertEqual(r["systemProxySet"]?.boolValue, true)
        XCTAssertEqual(r["warning"]?.stringValue, "netsh could not set the WinHTTP proxy, so services and apps that use WinHTTP are not captured; "
                       + "run 'netsh winhttp show proxy' with vm.exec to see why; "
                       + "the proxy settings were written, but Windows was not told to reread them; restart the app under test")
    }

    func testStartOnLinuxInstallsTheCAAndSetsNoSystemProxy() async throws {
        let c = try await capture(os: .linux)
        c.outputs.value["recipe.installCA"] = "{\"installed\":true,\"bundle\":\"/etc/ssl/certs/ca-certificates.crt\"}"
        let r = try await c.start()
        XCTAssertEqual(c.log.entries, ["proxy.start", "proxy.config", "push \(GuestRecipes.linuxProxyCAPath)", "recipe.installCA"])
        XCTAssertEqual(r["caInstalled"]?.boolValue, true)
        XCTAssertEqual(r["systemProxySet"]?.boolValue, false)
        XCTAssertEqual(r["guestCAPath"]?.stringValue, "/usr/local/share/ca-certificates/alcove-proxy.crt")
        XCTAssertEqual(r["env"]?["NODE_EXTRA_CA_CERTS"]?.stringValue, "/usr/local/share/ca-certificates/alcove-proxy.crt")
        XCTAssertEqual(r["env"]?["SSL_CERT_FILE"]?.stringValue, "/etc/ssl/certs/ca-certificates.crt")
        XCTAssertEqual(r["env"]?["REQUESTS_CA_BUNDLE"]?.stringValue, "/etc/ssl/certs/ca-certificates.crt")
        XCTAssertNil(r["warning"])
        XCTAssertEqual(c.journal.entry(for: "Win")?.systemProxy, false)

        c.log.clear()
        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(c.log.entries, ["proxy.list", "recipe.removeCA", "proxy.stop"])
        XCTAssertNil(c.journal.entry(for: "Win"))
    }

    func testStartKeepsToItsTimeLimits() async throws {
        let c = try await capture()
        _ = try await c.start()
        XCTAssertEqual(c.limits.value, [25_000, 25_000])
        let timing = HTTPTiming()
        XCTAssertEqual(timing.toolsWait, .seconds(25))
        XCTAssertEqual(timing.pushStep, .seconds(6))
        XCTAssertEqual(timing.recipe.hostSeconds, 30)
        XCTAssertEqual(timing.undo.hostSeconds, 15)

        let failing = try await capture()
        failing.failures.value["recipe.setProxy(49152)"] = "could not set the system proxy of the guest: Access is denied.; check that alcove-agent runs elevated, or call vm.http.start with systemProxy false"
        _ = await failing.failure("vm.http.start")
        XCTAssertEqual(failing.limits.value, [25_000, 25_000, 12_000, 12_000])
    }

    func testOneProxyIsStartedAtATime() async throws {
        let dir = try tempDir()
        let caPath = dir.appendingPathComponent("ca.pem").path
        try Data(caPEM.utf8).write(to: URL(fileURLWithPath: caPath))
        let hold = OneShotLatch()
        let starts = LockedBox(0)
        let targets = ["Win": FakeTarget(name: "Win", state: .running, png: makePNG(width: 8, height: 8)),
                       "Lin": FakeTarget(name: "Lin", state: .running, png: makePNG(width: 8, height: 8))]
        let h = ControlHandler(registry: FakeRegistry(targets: targets), hostKind: "test", captureDirectory: dir,
                               httpTiming: ControlHTTPTests.timing(vmPoll: .seconds(3600)),
                               makeProxy: { HeldProxy(hold: hold, starts: starts, caPath: caPath) })
        let first = Task { try await h.handle(op: "vm.http.start", params: ["name": "Win", "systemProxy": false]) }
        let begun = await eventually("the first proxy is being started") { starts.value == 1 }
        XCTAssertTrue(begun)
        let second = Task { try await h.handle(op: "vm.http.start", params: ["name": "Lin", "systemProxy": false]) }
        let queued = await eventually("the second start waits for the first proxy") { await h.proxyStartGate.waiterCount(for: "start") == 1 }
        XCTAssertTrue(queued)
        XCTAssertEqual(starts.value, 1)
        hold.open()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(starts.value, 2)
        await h.shutdown()
    }

    func testMissingProxyBinary() async throws {
        let dir = try tempDir()
        let c = try await capture(makeProxy: { ProxyProcess(executable: nil, caDirectory: dir) })
        let text = await c.failure("vm.http.start")
        XCTAssertEqual(text, "alcove-proxy was not found; build it with scripts/test/all.sh or set ALCOVE_PROXY")
        XCTAssertEqual(c.log.entries, [])
        let requests = await c.failure("vm.http.requests")
        XCTAssertEqual(requests, "'Win' is not capturing; call vm.http.start first")
    }

    func testToolLocatorOrder() throws {
        let dir = try tempDir()
        let fm = FileManager.default
        func program(_ name: String) throws -> String {
            let folder = dir.appendingPathComponent(name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent("alcove-proxy").path
            XCTAssertTrue(fm.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]))
            return path
        }
        let named = try program("named"), beside = try program("beside"), built = try program("built")
        let besideDir = dir.appendingPathComponent("beside").path, builtDir = dir.appendingPathComponent("built").path
        XCTAssertEqual(ToolLocator.proxy(environment: ["ALCOVE_PROXY": named], executableDirectory: besideDir, developmentRoot: builtDir), named)
        XCTAssertEqual(ToolLocator.proxy(environment: [:], executableDirectory: besideDir, developmentRoot: builtDir), beside)
        XCTAssertEqual(ToolLocator.proxy(environment: [:], executableDirectory: dir.appendingPathComponent("empty").path, developmentRoot: builtDir), built)
        XCTAssertEqual(ToolLocator.proxy(environment: [:], executableDirectory: nil, developmentRoot: builtDir), built)
        XCTAssertNil(ToolLocator.proxy(environment: ["ALCOVE_PROXY": dir.appendingPathComponent("gone").path], executableDirectory: besideDir,
                                       developmentRoot: builtDir))
        XCTAssertNil(ToolLocator.proxy(environment: [:], executableDirectory: nil, developmentRoot: dir.appendingPathComponent("empty").path))
        XCTAssertNil(ToolLocator.proxy(environment: [:], executableDirectory: nil, developmentRoot: dir.path))
        XCTAssertTrue(ToolLocator.developmentBuildDirectory.hasSuffix("/build"))

        let link = dir.appendingPathComponent("linked-alcovectl")
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: beside))
        let resolved = try XCTUnwrap(ToolLocator.directory(ofExecutable: link))
        XCTAssertEqual(URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path, URL(fileURLWithPath: besideDir).resolvingSymlinksInPath().path)
        XCTAssertNil(ToolLocator.directory(ofExecutable: nil))
    }

    // MARK: - vm.http.stop

    func testStopRestoresAndStops() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.factory.latest.reply("list", ["exchanges": [["id": 7]], "next": 7, "pending": []])
        c.log.clear()
        let r = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(c.log.entries, ["proxy.list", "recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
        XCTAssertEqual(c.factory.latest.params(of: "list"), ["limit": 1])
        XCTAssertEqual(r["exchanges"]?.intValue, 7)
        XCTAssertNil(r["warning"])
        XCTAssertEqual(Array(c.limits.value.suffix(2)), [25_000, 25_000])
        let after = await c.failure("vm.http.requests")
        XCTAssertEqual(after, "'Win' is not capturing; call vm.http.start first")

        let again = try await c.start()
        XCTAssertEqual(again["proxy"]?.stringValue, "10.0.2.2:49153")
        XCTAssertEqual(c.factory.made.count, 2)
    }

    func testStopRemovesTheCAOfTheStateFileToo() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.outputs.value["recipe.clearProxy"] = restoredState(otherThumbprint.lowercased())
        c.log.clear()
        let r = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(c.log.entries, ["proxy.list", "recipe.clearProxy", "recipe.removeCA", "recipe.removeCA(other)", "proxy.stop"])
        XCTAssertNil(r["warning"])
    }

    func testStopTellsWhenTheRestoredSettingsWereNotAnnounced() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.outputs.value["recipe.clearProxy"] = restoredState(caThumbprint, refreshed: false)
        let r = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(r["warning"]?.stringValue, "the proxy settings were written, but Windows was not told to reread them; restart the app under test")
        XCTAssertNil(c.journal.entry(for: "Win"))
    }

    func testStopEndsTheCaptureWhenTheGuestCannotBeRestored() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.failures.value["recipe.clearProxy"] = GuestRecipes.unreadableProxyState
        c.log.clear()
        let r = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(r["warning"]?.stringValue, "the stored proxy settings in C:\\ProgramData\\Alcove\\proxy-previous.json cannot be read; "
                       + "put the proxy settings right by hand, delete that file and call vm.http.stop again")
        XCTAssertEqual(c.log.entries, ["proxy.list", "recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
        XCTAssertEqual(c.journal.entry(for: "Win")?.port, 49152)
    }

    func testStopLeavesTheCAWhenTheGuestGivesNoAnswerAboutTheSettings() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.answers.value["recipe.clearProxy"] = ["code": -1, "stdout": "", "stderr": "", "timed_out": true]
        c.log.clear()
        let r = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(c.log.entries, ["proxy.list", "recipe.clearProxy", "proxy.stop"])
        XCTAssertEqual(r["warning"]?.stringValue, "the guest took more than 25 s to restore the proxy settings; check that it responds with vm.exec, "
                       + "then call vm.http.stop again")
        XCTAssertNotNil(c.journal.entry(for: "Win"))
    }

    func testStopWithoutToolsEndsTheCaptureAndSaysWhatIsLeft() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.t.setAgent(nil)
        c.log.clear()
        let r = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(c.log.entries, ["proxy.list", "proxy.stop"])
        XCTAssertEqual(r["warning"]?.stringValue, "the guest keeps the capture's proxy settings and CA certificate because its guest tools are not reachable; "
                       + "call vm.http.stop again once vm.status shows tools")
        XCTAssertNotNil(c.journal.entry(for: "Win"))

        let again = await c.failure("vm.http.stop")
        XCTAssertEqual(again, "'Win' is not capturing, and what an earlier capture left in its guest cannot be restored while its guest tools are "
                       + "not reachable; call vm.http.stop again once vm.status shows tools")
    }

    func testStopWithoutACapture() async throws {
        let c = try await capture()
        let text = await c.failure("vm.http.stop")
        XCTAssertEqual(text, "'Win' is not capturing; call vm.http.start first")
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA(file)"])

        let offline = try await capture(connected: false)
        let unreachable = await offline.failure("vm.http.stop")
        XCTAssertEqual(unreachable, "'Win' is not capturing; call vm.http.start first")
        await c.t.setState(.stopped)
        let stopped = await c.failure("vm.http.stop")
        XCTAssertEqual(stopped, "'Win' is not capturing; call vm.http.start first")
    }

    // MARK: - what an earlier capture left

    func testStaleProxyIsReportedAndCleared() async throws {
        let c = try await capture()
        c.outputs.value["recipe.readProxy"] = guestProxy(previous: true, port: 50000, system: true, ca: true, enabled: true,
                                                         server: "10.0.2.2:50000", winhttp: 50000)
        let doctor = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        let row = try XCTUnwrap(check(doctor, "proxy"))
        XCTAssertEqual(row["ok"]?.boolValue, false)
        XCTAssertEqual(row["detail"]?.stringValue, "no capture is running, but the system proxy points at 10.0.2.2:50000 and "
                       + "the settings from before a capture are still stored and the proxy CA is still installed")
        XCTAssertEqual(row["hint"]?.stringValue, "vm.http.stop clears stale proxy settings")
        XCTAssertEqual(c.log.entries, ["recipe.other", "recipe.readProxy"])

        c.log.clear()
        c.outputs.value["recipe.clearProxy"] = restoredState(otherThumbprint.lowercased())
        let stopped = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA(other)"])
        XCTAssertEqual(stopped["exchanges"]?.intValue, 0)
        XCTAssertEqual(stopped["staleCleared"]?.boolValue, true)
        XCTAssertNil(stopped["warning"])
        XCTAssertEqual(c.factory.made.count, 0)

        c.outputs.value["recipe.readProxy"] = guestProxy()
        let healthy = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(healthy, "proxy")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(healthy, "proxy")?["detail"]?.stringValue, "no system proxy")
        XCTAssertNil(check(healthy, "proxy")?["hint"])
    }

    func testAProxyAtTheHostAddressWithoutAStateFileIsTheUsers() async throws {
        let c = try await capture()
        c.outputs.value["recipe.readProxy"] = guestProxy(enabled: true, server: "10.0.2.2:8888", winhttp: 8888)
        let doctor = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(doctor, "proxy")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(doctor, "proxy")?["detail"]?.stringValue, "system proxy 10.0.2.2:8888 (not set by Alcove; if a capture left it, change it by hand)")

        c.log.clear()
        let stopped = await c.failure("vm.http.stop")
        XCTAssertEqual(stopped, "'Win' is not capturing; call vm.http.start first")
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA(file)"])
    }

    func testAProxyTheUserSetAfterACaptureIsNotCalledStale() async throws {
        let c = try await capture()
        c.outputs.value["recipe.readProxy"] = guestProxy(previous: true, port: 50000, system: true, enabled: true, server: "10.0.2.2:8888")
        let doctor = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(doctor, "proxy")?["ok"]?.boolValue, false)
        XCTAssertEqual(check(doctor, "proxy")?["detail"]?.stringValue, "no capture is running, but the settings from before a capture are still stored")

        c.outputs.value["recipe.readProxy"] = guestProxy(previous: true, port: 50000, system: false, enabled: true, server: "10.0.2.2:50000", winhttp: 50000)
        let recordOnly = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(recordOnly, "proxy")?["detail"]?.stringValue, "no capture is running, but the settings from before a capture are still stored")
    }

    func testDoctorNamesAStateFileThatCannotBeRead() async throws {
        let c = try await capture()
        c.outputs.value["recipe.readProxy"] = guestProxy(unreadable: true, enabled: true, server: "10.0.2.2:50000")
        let doctor = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(doctor, "proxy")?["ok"]?.boolValue, false)
        XCTAssertEqual(check(doctor, "proxy")?["detail"]?.stringValue, "no capture is running, but the stored proxy settings in "
                       + "C:\\ProgramData\\Alcove\\proxy-previous.json cannot be read; put the proxy settings right by hand, delete that file "
                       + "and call vm.http.stop again")
    }

    func testALeftoverCAAloneIsStale() async throws {
        let c = try await capture()
        c.outputs.value["recipe.readProxy"] = guestProxy(ca: true)
        let doctor = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(doctor, "proxy")?["ok"]?.boolValue, false)
        XCTAssertEqual(check(doctor, "proxy")?["detail"]?.stringValue, "no capture is running, but the proxy CA is still installed")
        c.outputs.value["recipe.removeCA(file)"] = "{\"removed\":true,\"fileRemoved\":true}"
        let stopped = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(stopped["staleCleared"]?.boolValue, true)
    }

    func testStaleCleanupFailureIsASentence() async throws {
        let c = try await capture()
        c.failures.value["recipe.clearProxy"] = GuestRecipes.unreadableProxyState
        let text = await c.failure("vm.http.stop")
        XCTAssertEqual(text, "the stored proxy settings in C:\\ProgramData\\Alcove\\proxy-previous.json cannot be read; put the proxy settings "
                       + "right by hand, delete that file and call vm.http.stop again")
    }

    func testDoctorProxyRowWhileCapturing() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.outputs.value["recipe.readProxy"] = guestProxy(previous: true, port: 49152, system: true, ca: true, enabled: true,
                                                         server: "10.0.2.2:49152", winhttp: 49152)
        let live = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(live, "proxy")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(live, "proxy")?["detail"]?.stringValue, "capturing through 10.0.2.2:49152, system proxy set")

        c.outputs.value["recipe.readProxy"] = guestProxy(previous: true, port: 49152, system: true, ca: true, enabled: true, server: "10.0.2.2:50000")
        let elsewhere = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(elsewhere, "proxy")?["ok"]?.boolValue, false)
        XCTAssertEqual(check(elsewhere, "proxy")?["detail"]?.stringValue, "the system proxy points at 10.0.2.2:50000, but the capture listens on port 49152")
        XCTAssertEqual(check(elsewhere, "proxy")?["hint"]?.stringValue, "call vm.http.stop, then vm.http.start")
    }

    func testDoctorLeavesTheUsersProxyAloneWhileACaptureWithoutSystemProxyRuns() async throws {
        let c = try await capture()
        _ = try await c.start(["systemProxy": false])
        c.outputs.value["recipe.readProxy"] = guestProxy(previous: true, port: 49152, system: false, ca: true, enabled: true,
                                                         server: "10.0.2.2:8888", winhttp: 8888)
        let doctor = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(doctor, "proxy")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(doctor, "proxy")?["detail"]?.stringValue, "capturing through 10.0.2.2:49152, system proxy not set")
    }

    func testDoctorProxyRowNamesAProxyAlcoveDidNotSet() async throws {
        let c = try await capture()
        c.outputs.value["recipe.readProxy"] = guestProxy(enabled: true, server: "proxy.corp.example:8080")
        let doctor = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(doctor, "proxy")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(doctor, "proxy")?["detail"]?.stringValue, "system proxy proxy.corp.example:8080")
    }

    func testDoctorProxyRowWhenTheGuestCannotBeRead() async throws {
        let c = try await capture()
        c.failures.value["recipe.readProxy"] = "could not read the proxy settings of the guest: Access is denied.; check that alcove-agent runs elevated"
        let doctor = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(doctor, "proxy")?["ok"]?.boolValue, false)
        XCTAssertEqual(check(doctor, "proxy")?["detail"]?.stringValue, "could not read the proxy settings of the guest: Access is denied.; check that alcove-agent runs elevated")
        XCTAssertEqual(check(doctor, "proxy")?["hint"]?.stringValue, "check that the guest shell works with vm.exec")
    }

    func testCapturePortReadsOnlyAWholeAlcoveAddress() {
        XCTAssertEqual(ControlHandler.capturePort(in: "10.0.2.2:49152"), 49152)
        XCTAssertEqual(ControlHandler.capturePort(in: "10.0.2.2:1"), 1)
        for other in ["110.0.2.2:3128", "http=10.0.2.2:8080;https=10.0.2.2:8081", "10.0.2.2:8080;10.0.2.2:8081", "10.0.2.2:8080 ", " 10.0.2.2:8080",
                      "host10.0.2.2:80", "10.0.2.20:80", "10.0.2.2.example.com:80", "proxy.corp.example:8080", "10.0.2.2:", "10.0.2.2:99999",
                      "10.0.2.2:0", "10.0.2.2:123456", "10.0.2.2:８０", "10.0.2.2", ""] {
            XCTAssertNil(ControlHandler.capturePort(in: other), other)
        }
    }

    // MARK: - the capture journal

    func testTheJournalIsWrittenBeforeTheFirstGuestStepAndGoneAfterStop() async throws {
        let c = try await capture()
        let journal = c.journal
        let seen = LockedBox<[String: CaptureJournal.Entry?]>([:])
        c.onStep.value = { step in
            if seen.value[step] == nil { seen.value[step] = .some(journal.entry(for: "Win")) }
        }
        XCTAssertNil(journal.entry(for: "Win"))
        _ = try await c.start()
        let expected = CaptureJournal.Entry(vm: "Win", port: 49152, thumbprint: caThumbprint, systemProxy: true, since: "2027-01-15T08:00:00Z")
        XCTAssertEqual(seen.value["fs"], .some(expected))
        XCTAssertEqual(seen.value["recipe.installCA"], .some(expected))
        XCTAssertEqual(journal.entry(for: "Win"), expected)
        let text = try String(contentsOf: journal.url, encoding: .utf8)
        XCTAssertEqual(try JSON.parse(Data(text.utf8)), [
            "version": 1,
            "captures": [["vm": "Win", "port": 49152, "thumbprint": .string(caThumbprint), "systemProxy": true, "since": "2027-01-15T08:00:00Z"]],
            "snapshots": [],
        ])
        XCTAssertEqual(journal.url.path, c.directory.appendingPathComponent("captures.json").path)

        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertNil(journal.entry(for: "Win"))
    }

    func testToolsThatConnectAfterAHostCrashGetTheGuestRestoredOnce() async throws {
        let c = try await capture()
        _ = try await c.start()
        let next = c.makeHandler()
        _ = try await next.handle(op: "vm.status", params: ["name": "Win"])
        c.log.clear()
        c.outputs.value["recipe.clearProxy"] = restoredState(caThumbprint)

        await c.t.connectAgent(try await newConnection(c))
        let cleanup = await next.runningCleanup(of: "Win")
        let cleaned = await cleanup?.value
        XCTAssertEqual(cleaned, true)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA"])
        XCTAssertEqual(Array(c.limits.value.suffix(2)), [25_000, 25_000])
        XCTAssertNil(c.journal.entry(for: "Win"))
        let running = await next.runningCleanup(of: "Win")
        XCTAssertNil(running)

        await c.t.connectAgent(try await newConnection(c))
        let second = await next.runningCleanup(of: "Win")
        XCTAssertNil(second)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA"])
    }

    func testToolsTheAppSeesMakeTheControlTargetConnectAndCleanOnce() async throws {
        let c = try await capture()
        _ = try await c.start()
        let next = c.makeHandler()
        await c.t.setAgent(nil)
        c.log.clear()
        c.outputs.value["recipe.clearProxy"] = restoredState(caThumbprint)
        await c.t.setLinkAgent(try await newConnection(c))
        let calls = await c.t.agentCalls.count

        await next.guestToolsSeen(vm: "Win")
        let cleaned = await next.runningCleanup(of: "Win")?.value
        XCTAssertEqual(cleaned, true)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA"])
        XCTAssertNil(c.journal.entry(for: "Win"))
        let linked = await c.t.agentCalls.count
        XCTAssertEqual(linked, calls + 1)
        let adopted = await c.t.agentClient
        XCTAssertNotNil(adopted)

        await next.guestToolsSeen(vm: "Win")
        let again = await next.runningCleanup(of: "Win")
        XCTAssertNil(again)
        let after = await c.t.agentCalls.count
        XCTAssertEqual(after, linked)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA"])
    }

    func testToolsTheAppSeesCleanOverAConnectionTheControlTargetHolds() async throws {
        let c = try await capture()
        _ = try await c.start()
        let next = c.makeHandler()
        c.log.clear()
        await next.guestToolsSeen(vm: "Win")
        let cleaned = await next.runningCleanup(of: "Win")?.value
        XCTAssertEqual(cleaned, true)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA"])
        XCTAssertNil(c.journal.entry(for: "Win"))
    }

    func testToolsTheAppSeesConnectNothingWithoutAnEntry() async throws {
        let c = try await capture()
        await c.t.setAgent(nil)
        await c.t.setLinkAgent(try await newConnection(c))
        await c.h.guestToolsSeen(vm: "Win")
        let calls = await c.t.agentCalls.count
        XCTAssertEqual(calls, 0)
        let linkAgent = await c.t.linkAgent
        XCTAssertNotNil(linkAgent)
        let cleanup = await c.h.runningCleanup(of: "Win")
        XCTAssertNil(cleanup)
        XCTAssertEqual(c.log.entries, [])
        await c.h.guestToolsSeen(vm: "Nope")
    }

    func testToolsTheAppSeesLeaveALiveCaptureAlone() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.t.setAgent(nil)
        await c.t.setLinkAgent(try await newConnection(c))
        let calls = await c.t.agentCalls.count
        c.log.clear()
        await c.h.guestToolsSeen(vm: "Win")
        let after = await c.t.agentCalls.count
        XCTAssertEqual(after, calls)
        let cleanup = await c.h.runningCleanup(of: "Win")
        XCTAssertNil(cleanup)
        XCTAssertEqual(c.log.entries, [])
        XCTAssertNotNil(c.journal.entry(for: "Win"))
    }

    func testACleanupWhoseGuestDoesNotAnswerAsksForAnotherConnectionOnce() async throws {
        let c = try await capture()
        _ = try await c.start()
        let next = c.makeHandler()
        _ = try await next.handle(op: "vm.status", params: ["name": "Win"])
        let stale = await c.t.agentClient
        c.agent.drop()
        await c.t.setLinkAgent(try await newConnection(c))
        c.log.clear()
        c.outputs.value["recipe.clearProxy"] = restoredState(caThumbprint)

        await next.guestToolsSeen(vm: "Win")
        let first = await next.runningCleanup(of: "Win")?.value
        XCTAssertEqual(first, false)
        let drops = await c.t.drops
        XCTAssertEqual(drops, [true])
        let adopted = await c.t.agentClient
        XCTAssertNotNil(adopted)
        XCTAssertFalse(adopted === stale)
        let retried = await next.runningCleanup(of: "Win")?.value
        XCTAssertEqual(retried, true)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA"])
        XCTAssertNil(c.journal.entry(for: "Win"))
        XCTAssertEqual(c.hostLog.value.count, 1)
        XCTAssertTrue(c.hostLog.value.first?.hasPrefix("the cleanup after an earlier HTTP capture of 'Win' failed to restore the proxy settings (") == true,
                      "\(c.hostLog.value)")
    }

    func testTheConnectionAskedForAfterAnUnansweredCleanupGetsNoFurtherRetry() async throws {
        let c = try await capture(adjust: { $0.recipe = RecipeLimit(guestMilliseconds: 1000, marginSeconds: 0) })
        _ = try await c.start()
        let next = c.makeHandler()
        _ = try await next.handle(op: "vm.status", params: ["name": "Win"])
        c.agent.drop()
        await c.t.setLinkAgent(try await newConnection(c))
        c.held.value = ["recipe.clearProxy"]
        c.log.clear()

        await next.guestToolsSeen(vm: "Win")
        let first = await next.runningCleanup(of: "Win")?.value
        XCTAssertEqual(first, false)
        let retry = await next.runningCleanup(of: "Win")
        let held = try XCTUnwrap(retry)
        let spare = try await newConnection(c)
        await c.t.setLinkAgent(spare)
        let second = await held.value
        XCTAssertEqual(second, false)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy"])
        let drops = await c.t.drops
        XCTAssertEqual(drops, [true])
        let unused = await c.t.linkAgent
        XCTAssertTrue(unused === spare)
        let running = await next.runningCleanup(of: "Win")
        XCTAssertNil(running)
        XCTAssertEqual(c.journal.entry(for: "Win")?.port, 49152)
        XCTAssertEqual(c.hostLog.value.count, 2)
    }

    func testACleanupRunningWhenARestoreBeginsIsAwaitedAndTheRestoreReportsTheNextOne() async throws {
        let c = try await capture()
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "mid-capture"])
        let next = c.makeHandler()
        await c.t.setSnapshotList([VMController.SnapshotInfo(name: "mid-capture", vmStateSize: 1, date: Date())])
        _ = try await next.handle(op: "vm.status", params: ["name": "Win"])
        c.log.clear()
        c.held.value = ["recipe.clearProxy"]
        c.failures.value["recipe.removeCA"] = "could not remove the proxy CA from the guest: Access is denied.; check that alcove-agent runs elevated, then call vm.http.stop again"
        let removals = LockedBox(0)
        c.onStep.value = { step in
            guard step == "recipe.removeCA" else { return }
            removals.value += 1
            if removals.value == 2 { c.failures.value = [:] }
        }
        await c.t.connectAgent(try await newConnection(c))
        let running = await next.runningCleanup(of: "Win")
        let earlier = try XCTUnwrap(running)
        let holding = await eventually("the earlier cleanup asks the guest to restore its proxy settings") { c.waiting.value.count == 1 }
        XCTAssertTrue(holding)

        let restore = Task {
            try await next.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "mid-capture", "waitTools": 0])
        }
        let synced = await eventually("the restore syncs the guest clock") { c.log.entries.contains("recipe.other") }
        XCTAssertTrue(synced)
        c.release("recipe.clearProxy", printing: restoredState(caThumbprint))
        let first = await earlier.value
        XCTAssertEqual(first, false)
        let restored = try await restore.value
        XCTAssertEqual(restored["staleProxyCleared"]?.boolValue, true)
        XCTAssertEqual(c.log.entries.filter { $0 != "recipe.other" }, ["recipe.clearProxy", "recipe.removeCA", "recipe.clearProxy", "recipe.removeCA"])
        XCTAssertNil(c.journal.entry(for: "Win"))
    }

    // MARK: - snapshots the app makes

    func testASnapshotTheAppTakesIsNotedAsTheOpNotesIt() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.h.snapshotCreated(vm: "Win", snapshot: "live")
        XCTAssertEqual(c.journal.snapshotEntry("live", vm: "Win"), c.journal.entry(for: "Win"))

        let next = c.makeHandler()
        await next.snapshotCreated(vm: "Win", snapshot: "unrestored")
        XCTAssertEqual(c.journal.snapshotEntry("unrestored", vm: "Win")?.port, 49152)

        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        await c.h.snapshotCreated(vm: "Win", snapshot: "live")
        XCTAssertNil(c.journal.snapshotEntry("live", vm: "Win"))
        XCTAssertEqual(c.journal.snapshotEntry("unrestored", vm: "Win")?.port, 49152)
        let unknown = CaptureJournal.Entry(vm: "Nope", port: 49153, thumbprint: otherThumbprint, systemProxy: true, since: "x")
        try c.journal.record(unknown, now: Date())
        try c.journal.record(CaptureJournal.Entry(vm: "Win", port: 49154, thumbprint: otherThumbprint, systemProxy: true, since: "x"), now: Date())
        await c.h.snapshotCreated(vm: "Nope", snapshot: "s")
        XCTAssertNil(c.journal.snapshotEntry("s", vm: "Nope"))
        XCTAssertNil(c.journal.snapshotEntry("s", vm: "Win"))
    }

    func testASnapshotTheAppRestoresGetsItsCaptureCleanedOverANewConnection() async throws {
        let c = try await capture()
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "mid-capture"])
        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertNil(c.journal.entry(for: "Win"))
        let before = await c.t.agentClient
        let next = c.makeHandler()
        await c.t.setLinkAgent(try await newConnection(c))
        c.log.clear()
        c.outputs.value["recipe.clearProxy"] = restoredState(caThumbprint)

        await next.snapshotRestored(vm: "Win", snapshot: "mid-capture")
        let drops = await c.t.drops
        XCTAssertEqual(drops, [true])
        let adopted = await c.t.agentClient
        XCTAssertNotNil(adopted)
        XCTAssertFalse(adopted === before)
        let cleaned = await next.runningCleanup(of: "Win")?.value
        XCTAssertEqual(cleaned, true)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA"])
        XCTAssertNil(c.journal.entry(for: "Win"))
        XCTAssertNotNil(c.journal.snapshotEntry("mid-capture", vm: "Win"))
        let calls = await c.t.snapshotCalls
        XCTAssertEqual(calls, ["create:mid-capture"])
    }

    func testARestoreInTheAppWhoseFirstConnectionAttemptFailsCleansOverTheConnectionTheWaitingAttemptAdopts() async throws {
        let c = try await capture()
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "mid-capture"])
        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        let next = c.makeHandler()
        let late = try await newConnection(c)
        await c.t.setAgentHook { target in await target.connectAgent(late) }
        let waitsBefore = await c.t.agentTimeouts.count
        c.log.clear()
        c.outputs.value["recipe.clearProxy"] = restoredState(caThumbprint)

        await next.snapshotRestored(vm: "Win", snapshot: "mid-capture")
        let cleaned = await eventually("the entry is gone") { c.journal.entry(for: "Win") == nil }
        XCTAssertTrue(cleaned)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA"])
        let timeouts = await c.t.agentTimeouts
        XCTAssertEqual(Array(timeouts.dropFirst(waitsBefore)), [.milliseconds(50)])
        let adopted = await c.t.agentClient
        XCTAssertTrue(adopted === late)
    }

    func testARestoreInTheAppWhoseFirstAttemptAdoptsStartsOneCleanupWhenTheWaitingAttemptAdoptsToo() async throws {
        let c = try await capture()
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "mid-capture"])
        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        let next = c.makeHandler()
        await c.t.setLinkAgent(try await newConnection(c))
        let waitsBefore = await c.t.agentTimeouts.count
        c.log.clear()
        c.outputs.value["recipe.clearProxy"] = restoredState(caThumbprint)

        await next.snapshotRestored(vm: "Win", snapshot: "mid-capture")
        let cleaned = await next.runningCleanup(of: "Win")?.value
        XCTAssertEqual(cleaned, true)
        let waited = await eventually("the waiting attempt ended") { await c.t.agentTimeouts.count == waitsBefore + 1 }
        XCTAssertTrue(waited)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA"])
        XCTAssertNil(c.journal.entry(for: "Win"))
    }

    func testAnUnansweredCleanupLeavesNoRetryForTheNextCleanupWhenItsReconnectGetsNoConnection() async throws {
        let c = try await capture(adjust: { $0.recipe = RecipeLimit(guestMilliseconds: 1000, marginSeconds: 0) })
        _ = try await c.start()
        let next = c.makeHandler()
        _ = try await next.handle(op: "vm.status", params: ["name": "Win"])
        c.agent.drop()
        await c.t.setLinkAgent(try await newConnection(c))
        c.held.value = ["recipe.clearProxy"]
        c.log.clear()

        await next.guestToolsSeen(vm: "Win")
        let first = await next.runningCleanup(of: "Win")?.value
        XCTAssertEqual(first, false)
        let afterFirst = await c.t.drops
        XCTAssertEqual(afterFirst, [true])

        await c.t.connectAgent(try await newConnection(c))
        let second = await next.runningCleanup(of: "Win")?.value
        XCTAssertEqual(second, false)
        let drops = await c.t.drops
        XCTAssertEqual(drops, [true])
        XCTAssertEqual(c.hostLog.value.count, 2)
    }

    func testARestoreInTheAppEndsTheLiveCaptureAsTheOpDoes() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.t.setLinkAgent(try await newConnection(c))
        c.log.clear()
        await c.h.snapshotRestored(vm: "Win", snapshot: "before-capture")
        XCTAssertEqual(c.log.entries.first, "proxy.stop")
        let text = await c.failure("vm.http.requests")
        XCTAssertEqual(text, "'Win' is not capturing; call vm.http.start first")
        let cleaned = await c.h.runningCleanup(of: "Win")?.value
        XCTAssertEqual(cleaned, true)
        XCTAssertEqual(c.log.entries, ["proxy.stop", "recipe.clearProxy", "recipe.removeCA"])
        XCTAssertNil(c.journal.entry(for: "Win"))
    }

    func testARestoreInTheAppWithoutAnEntryDropsTheConnectionAndConnectsNothing() async throws {
        let c = try await capture()
        _ = try await c.h.handle(op: "vm.status", params: ["name": "Win"])
        await c.t.setLinkAgent(try await newConnection(c))
        let calls = await c.t.agentCalls.count
        await c.h.snapshotRestored(vm: "Win", snapshot: "clean")
        let drops = await c.t.drops
        XCTAssertEqual(drops, [true])
        let after = await c.t.agentCalls.count
        XCTAssertEqual(after, calls)
        let unused = await c.t.linkAgent
        XCTAssertNotNil(unused)
        let cleanup = await c.h.runningCleanup(of: "Win")
        XCTAssertNil(cleanup)
        XCTAssertEqual(c.log.entries, [])
        let unknown = CaptureJournal.Entry(vm: "Nope", port: 49153, thumbprint: otherThumbprint, systemProxy: true, since: "x")
        try c.journal.record(unknown, now: Date())
        try c.journal.noteSnapshot("s", during: unknown, now: Date())
        await c.h.snapshotRestored(vm: "Nope", snapshot: "s")
        let dropsAfter = await c.t.drops
        XCTAssertEqual(dropsAfter, drops)
        let callsAfter = await c.t.agentCalls.count
        XCTAssertEqual(callsAfter, calls)
        let unknownCleanup = await c.h.runningCleanup(of: "Nope")
        XCTAssertNil(unknownCleanup)
        XCTAssertEqual(c.log.entries, [])
        XCTAssertEqual(c.hostLog.value, [])
    }

    func testASnapshotTheAppDeletesLosesItsNote() async throws {
        let c = try await capture()
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "mid-capture"])
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "kept"])
        await c.h.snapshotDeleted(vm: "Win", snapshot: "mid-capture")
        XCTAssertNil(c.journal.snapshotEntry("mid-capture", vm: "Win"))
        XCTAssertNotNil(c.journal.snapshotEntry("kept", vm: "Win"))
        XCTAssertNotNil(c.journal.entry(for: "Win"))
    }

    func testAVMTheAppDeletesLosesItsEntryAndNotes() async throws {
        let dir = try tempDir()
        let path = "/VMs/Win.alcove"
        let c = try await capture(directory: dir, bundle: path)
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "mid-capture"])
        let other = CaptureJournal.Entry(vm: "Win", port: 49153, thumbprint: otherThumbprint, systemProxy: true, since: "x", path: "/Other/Win.alcove")
        try c.journal.record(other, now: Date())
        c.log.clear()
        await c.h.vmDeleted(vm: "Win", path: path)
        let here = CaptureJournal.VM(name: "Win", path: path)
        XCTAssertNil(c.journal.entry(for: here))
        XCTAssertNil(c.journal.snapshotEntry("mid-capture", vm: here))
        XCTAssertEqual(c.journal.entry(for: other.owner), other)
        XCTAssertEqual(c.log.entries, ["proxy.stop"])
    }

    func testAVMTheAppRenamesKeepsItsEntryAndNotesUnderItsNewNameAndPath() async throws {
        let dir = try tempDir()
        let path = "/VMs/Win.alcove"
        let c = try await capture(directory: dir, bundle: path)
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "mid-capture"])
        let other = CaptureJournal.Entry(vm: "Win", port: 49153, thumbprint: otherThumbprint, systemProxy: true, since: "x", path: "/Other/Win.alcove")
        try c.journal.record(other, now: Date())
        c.log.clear()
        await c.h.vmRenamed(from: "Win", oldPath: path, to: "Work", newPath: "/VMs/Work.alcove")
        XCTAssertEqual(c.log.entries, ["proxy.stop"])
        let renamed = CaptureJournal.VM(name: "Work", path: "/VMs/Work.alcove")
        let entry = try XCTUnwrap(c.journal.entry(for: renamed))
        XCTAssertEqual(entry.vm, "Work")
        XCTAssertEqual(entry.path, "/VMs/Work.alcove")
        XCTAssertEqual(entry.port, 49152)
        XCTAssertEqual(c.journal.snapshotEntry("mid-capture", vm: renamed)?.owner, renamed)
        XCTAssertNil(c.journal.entry(for: CaptureJournal.VM(name: "Win", path: path)))
        XCTAssertEqual(c.journal.entry(for: other.owner), other)
    }

    func testARenameWithoutAHandlerMovesTheEntryOfAnEntryWithoutAPath() throws {
        let dir = try tempDir()
        let journal = CaptureJournal(directory: dir)
        try journal.record(CaptureJournal.Entry(vm: "Win", port: 49152, thumbprint: caThumbprint, systemProxy: true, since: "x"), now: Date())
        try ControlHandler.vmRenamed(from: "Win", oldPath: "/VMs/Win.alcove", to: "Work", newPath: "/VMs/Work.alcove", captureDirectory: dir)
        XCTAssertEqual(journal.entry(for: CaptureJournal.VM(name: "Work", path: "/VMs/Work.alcove"))?.port, 49152)
        XCTAssertNil(journal.entry(for: "Win"))
    }

    func testCloneOfAVMWhoseGuestHoldsAnEarlierCaptureIsRefused() async throws {
        let provisioning = LockedBox<FakeProvisioningRegistry?>(nil)
        let c = try await capture(registry: { target in
            let registry = FakeProvisioningRegistry(targets: ["Win": target])
            provisioning.value = registry
            return registry
        })
        try c.journal.record(CaptureJournal.Entry(vm: "Win", port: 49152, thumbprint: caThumbprint, systemProxy: true, since: "x"), now: Date())
        await c.t.setState(.stopped)
        let text = await c.failure("vm.clone", ["name": "Win", "newName": "Copy"])
        XCTAssertEqual(text, "'Win' still holds the proxy settings and the CA certificate of an earlier HTTP capture in its guest; start it, wait "
                       + "until vm.status shows tools so that Alcove removes them, stop it and call vm.clone again")
        let calls = await provisioning.value?.calls
        XCTAssertEqual(calls, [])
        try c.journal.remove(vm: "Win", now: Date())
        _ = try await c.h.handle(op: "vm.clone", params: ["name": "Win", "newName": "Copy"])
        let after = await provisioning.value?.calls
        XCTAssertEqual(after, ["clone:Win->Copy"])
    }

    func testTheHeadlessLogWritesEachLineToStandardErrorAndTheSystemLog() {
        let written = LockedBox<[String]>([])
        let log = ControlHandler.standardErrorAndSystemLog(write: { written.value = written.value + [$0] })
        log("the cleanup after an earlier HTTP capture of 'Win' failed to remove the proxy CA (x)")
        log("second")
        XCTAssertEqual(written.value, ["the cleanup after an earlier HTTP capture of 'Win' failed to remove the proxy CA (x)\n", "second\n"])
    }

    func testACleanupThatFailsKeepsTheEntryForTheNextConnection() async throws {
        let c = try await capture()
        _ = try await c.start()
        let next = c.makeHandler()
        _ = try await next.handle(op: "vm.status", params: ["name": "Win"])
        c.failures.value["recipe.removeCA"] = "could not remove the proxy CA from the guest: Access is denied.; check that alcove-agent runs elevated, then call vm.http.stop again"
        c.log.clear()

        await c.t.connectAgent(try await newConnection(c))
        let failed = await next.runningCleanup(of: "Win")?.value
        XCTAssertEqual(failed, false)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA"])
        XCTAssertEqual(c.journal.entry(for: "Win")?.port, 49152)
        XCTAssertEqual(c.hostLog.value, ["the cleanup after an earlier HTTP capture of 'Win' failed to remove the proxy CA (could not remove the proxy CA "
                                         + "from the guest: Access is denied.; check that alcove-agent runs elevated, then call vm.http.stop again)"])
        let drops = await c.t.drops
        XCTAssertEqual(drops, [])

        c.failures.value = [:]
        c.log.clear()
        await c.t.connectAgent(try await newConnection(c))
        let retried = await next.runningCleanup(of: "Win")?.value
        XCTAssertEqual(retried, true)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA"])
        XCTAssertNil(c.journal.entry(for: "Win"))
        XCTAssertEqual(c.hostLog.value.count, 1)
    }

    func testACleanupOverGuestToolsThatCannotRunCommandsIsLogged() async throws {
        let c = try await capture()
        _ = try await c.start()
        let next = c.makeHandler()
        _ = try await next.handle(op: "vm.status", params: ["name": "Win"])
        c.log.clear()
        let old = FakeAgent()
        old.caps = ["clipboard"]
        _ = old.start()
        addTeardownBlock { old.stop() }
        let client = AgentClient()
        try await client.connect(port: old.port, expectedToken: nil)
        await c.t.connectAgent(client)
        let cleaned = await next.runningCleanup(of: "Win")?.value
        XCTAssertEqual(cleaned, false)
        XCTAssertEqual(c.log.entries, [])
        XCTAssertEqual(c.hostLog.value, ["the cleanup after an earlier HTTP capture of 'Win' failed to run its recipes (guest tools in 'Win' do not allow "
                                         + "running commands; start alcove-agent with --allow-exec)"])
    }

    func testAVMWithALiveCaptureIsNotCleaned() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.log.clear()
        await c.t.connectAgent(try await newConnection(c))
        let cleanup = await c.h.runningCleanup(of: "Win")
        XCTAssertNil(cleanup)
        XCTAssertEqual(c.log.entries, [])
        XCTAssertNotNil(c.journal.entry(for: "Win"))
        _ = try await c.h.handle(op: "vm.http.requests", params: ["name": "Win"])
    }

    func testAVMWithoutAnEntryIsNotCleaned() async throws {
        let c = try await capture()
        _ = try await c.h.handle(op: "vm.status", params: ["name": "Win"])
        c.log.clear()
        await c.t.connectAgent(try await newConnection(c))
        let cleanup = await c.h.runningCleanup(of: "Win")
        XCTAssertNil(cleanup)
        XCTAssertEqual(c.log.entries, [])
    }

    func testStartWaitsForACleanupThatIsRunning() async throws {
        let c = try await capture()
        _ = try await c.start()
        let next = c.makeHandler()
        _ = try await next.handle(op: "vm.status", params: ["name": "Win"])
        c.log.clear()
        c.held.value = ["recipe.clearProxy"]
        await c.t.connectAgent(try await newConnection(c))
        let running = await next.runningCleanup(of: "Win")
        let cleanup = try XCTUnwrap(running)
        let holding = await eventually("the cleanup asks the guest to restore its proxy settings") { c.waiting.value.count == 1 }
        XCTAssertTrue(holding)

        let started = Task { try await next.handle(op: "vm.http.start", params: ["name": "Win"]) }
        let queued = await eventually("vm.http.start waits behind the cleanup") { await next.captureGate.waiterCount(for: "Win") == 1 }
        XCTAssertTrue(queued)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy"])

        c.release("recipe.clearProxy", printing: restoredState(caThumbprint))
        let cleaned = await cleanup.value
        XCTAssertEqual(cleaned, true)
        let result = try await started.value
        XCTAssertEqual(result["proxy"]?.stringValue, "10.0.2.2:49153")
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA", "proxy.start", "proxy.config",
                                       "push \(GuestRecipes.windowsProxyCAPath)", "recipe.installCA", "recipe.setProxy(49153)"])
        XCTAssertEqual(c.journal.entry(for: "Win")?.port, 49153)
    }

    func testStopWithoutACaptureRestoresFromTheJournalEntry() async throws {
        let c = try await capture()
        _ = try await c.start()
        let next = c.makeHandler()
        c.log.clear()
        let stopped = try await next.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(stopped["staleCleared"]?.boolValue, true)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA"])
        XCTAssertNil(c.journal.entry(for: "Win"))
    }

    func testASnapshotCreatedDuringACaptureIsCleanedAfterItsRestoreByAnotherHandler() async throws {
        let c = try await capture()
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "mid-capture"])
        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertNil(c.journal.entry(for: "Win"))
        XCTAssertEqual(c.journal.snapshotEntry("mid-capture", vm: "Win")?.port, 49152)

        let next = c.makeHandler()
        await c.t.setSnapshotList([VMController.SnapshotInfo(name: "mid-capture", vmStateSize: 1, date: Date())])
        c.log.clear()
        c.outputs.value["recipe.clearProxy"] = restoredState(caThumbprint)
        let restored = try await next.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "mid-capture", "waitTools": 0])
        XCTAssertEqual(restored["staleProxyCleared"]?.boolValue, true)
        XCTAssertEqual(c.log.entries.filter { $0 != "recipe.other" }, ["recipe.clearProxy", "recipe.removeCA"])
        XCTAssertNil(c.journal.entry(for: "Win"))
        XCTAssertNotNil(c.journal.snapshotEntry("mid-capture", vm: "Win"))

        _ = try await next.handle(op: "vm.snapshot.delete", params: ["name": "Win", "snapshot": "mid-capture"])
        XCTAssertNil(c.journal.snapshotEntry("mid-capture", vm: "Win"))
    }

    func testHostsWithEquallyNamedVMsKeepTheirOwnEntries() async throws {
        let dir = try tempDir()
        let here = CaptureJournal.VM(name: "Win", path: "/Users/someone/Library/Application Support/Alcove/VMs/Win.alcove")
        let there = CaptureJournal.VM(name: "Win", path: "/Volumes/Other/VMs/Win.alcove")
        let a = try await capture(directory: dir, bundle: here.path)
        let b = try await capture(directory: dir, bundle: there.path)
        _ = try await a.start()
        XCTAssertEqual(a.journal.entry(for: here)?.path, here.path)
        XCTAssertNil(a.journal.entry(for: there))

        _ = try await b.h.handle(op: "vm.status", params: ["name": "Win"])
        b.log.clear()
        await b.t.connectAgent(try await newConnection(b))
        let cleanup = await b.h.runningCleanup(of: "Win")
        XCTAssertNil(cleanup)
        XCTAssertEqual(b.log.entries, [])

        _ = try await b.start()
        XCTAssertEqual(a.journal.entry(for: here)?.path, here.path)
        XCTAssertEqual(a.journal.entry(for: there)?.path, there.path)
        _ = try await b.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "s"])
        _ = try await b.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertNil(a.journal.entry(for: there))
        XCTAssertEqual(a.journal.entry(for: here)?.path, here.path)
        XCTAssertNil(a.journal.snapshotEntry("s", vm: here))
        XCTAssertEqual(a.journal.snapshotEntry("s", vm: there)?.path, there.path)

        let text = await b.failure("vm.http.stop")
        XCTAssertEqual(text, "'Win' is not capturing; call vm.http.start first")
        XCTAssertEqual(a.journal.entry(for: here)?.path, here.path)
    }

    func testAJournalEntryWithoutAPathBelongsToEveryVMOfItsName() throws {
        let dir = try tempDir()
        let journal = CaptureJournal(directory: dir)
        try Data(("{\"version\":1,\"captures\":[{\"vm\":\"Win\",\"port\":49152,\"thumbprint\":\"\(caThumbprint)\",\"systemProxy\":true,"
                  + "\"since\":\"2027-01-15T08:00:00Z\"}],\"snapshots\":[]}").utf8).write(to: journal.url)
        let here = CaptureJournal.VM(name: "Win", path: "/VMs/Win.alcove")
        XCTAssertEqual(journal.entry(for: here)?.port, 49152)
        XCTAssertNil(journal.entry(for: here)?.path)
        XCTAssertEqual(journal.entry(for: CaptureJournal.VM(name: "Win", path: "/Other/Win.alcove"))?.port, 49152)
        XCTAssertNil(journal.entry(for: CaptureJournal.VM(name: "Lin", path: "/VMs/Win.alcove")))

        let now = Date()
        let recorded = CaptureJournal.Entry(vm: "Win", port: 49153, thumbprint: caThumbprint, systemProxy: true, since: "later", path: here.path)
        try journal.record(recorded, now: now)
        XCTAssertEqual(journal.entry(for: here), recorded)
        XCTAssertNil(journal.entry(for: CaptureJournal.VM(name: "Win", path: "/Other/Win.alcove")))
        XCTAssertEqual(journal.entry(for: CaptureJournal.VM(name: "Renamed", path: here.path)), recorded)
        let text = try String(contentsOf: journal.url, encoding: .utf8)
        XCTAssertEqual(try JSON.parse(Data(text.utf8))["captures"], [["vm": "Win", "path": "/VMs/Win.alcove", "port": 49153,
                                                                     "thumbprint": .string(caThumbprint), "systemProxy": true, "since": "later"]])
        try journal.remove(vm: CaptureJournal.VM(name: "Win", path: "/Other/Win.alcove"), now: now)
        XCTAssertEqual(journal.entry(for: here), recorded)
        try journal.remove(vm: here, now: now)
        XCTAssertNil(journal.entry(for: here))
    }

    func testAControllerTargetNamesItsBundleByItsStandardizedPath() async {
        let bundle = VMBundle(url: URL(fileURLWithPath: "/Users/someone/VMs/../VMs/./Win.alcove"))
        let engine = EngineLocator.Engine(qemuSystem: "/e/qemu-system-aarch64", qemuImg: "/e/qemu-img", firmwareDir: "/e", swtpm: nil)
        let controller = VMController(bundle: bundle, config: VMConfig.defaults(name: "Win", guestOS: .windows), engine: engine)
        let path = await ControllerTarget(name: "Win", controller: controller).bundlePath()
        XCTAssertEqual(path, "/Users/someone/VMs/Win.alcove")
    }

    func testARestoreCountsTheCleanupThatEndedBeforeItAsked() async throws {
        let c = try await capture()
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "mid-capture"])
        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        let next = c.makeHandler()
        await c.t.setSnapshotList([VMController.SnapshotInfo(name: "mid-capture", vmStateSize: 1, date: Date())])
        _ = try await next.handle(op: "vm.status", params: ["name": "Win"])
        let connection = try await newConnection(c)
        await c.t.setAgentHook { t in
            await t.connectAgent(connection)
            _ = await next.runningCleanup(of: "Win")?.value
        }
        c.log.clear()
        c.outputs.value["recipe.clearProxy"] = restoredState(caThumbprint)
        let restored = try await next.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "mid-capture", "waitTools": 0])
        XCTAssertEqual(restored["staleProxyCleared"]?.boolValue, true)
        XCTAssertEqual(c.log.entries.filter { $0 != "recipe.other" }, ["recipe.clearProxy", "recipe.removeCA"])
        XCTAssertNil(c.journal.entry(for: "Win"))
    }

    func testASnapshotOfAGuestThatStillHoldsAnEarlierCaptureIsNoted() async throws {
        let c = try await capture()
        _ = try await c.start()
        let next = c.makeHandler()
        _ = try await next.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "after-crash"])
        XCTAssertEqual(c.journal.snapshotEntry("after-crash", vm: "Win"), c.journal.entry(for: "Win"))
        XCTAssertEqual(c.journal.snapshotEntry("after-crash", vm: "Win")?.port, 49152)
    }

    func testDeleteRemovesTheJournalEntriesOfTheVM() async throws {
        let c = try await capture(registry: { FakeProvisioningRegistry(targets: ["Win": $0]) })
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "mid-capture"])
        XCTAssertNotNil(c.journal.entry(for: "Win"))
        _ = try await c.h.handle(op: "vm.delete", params: ["name": "Win"])
        XCTAssertNil(c.journal.entry(for: "Win"))
        XCTAssertNil(c.journal.snapshotEntry("mid-capture", vm: "Win"))
    }

    func testAJournalThatCannotBeWrittenRefusesTheStart() async throws {
        let c = try await capture()
        try FileManager.default.createDirectory(atPath: c.journal.url.path + ".lock", withIntermediateDirectories: true)
        let text = await c.failure("vm.http.start")
        XCTAssertTrue(text.hasPrefix("the record of captures to restore at \(c.journal.url.path) could not be written ("), text)
        XCTAssertTrue(text.hasSuffix("); make its folder writable and call vm.http.start again"), text)
        XCTAssertEqual(c.log.entries, ["proxy.start", "proxy.config", "proxy.stop"])
    }

    func testJournalFileKeepsOneEntryPerVMAndSurvivesConcurrentWriters() async throws {
        let dir = try tempDir()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let entry = CaptureJournal.Entry(vm: "vm-\(index)", port: 50000 + index, thumbprint: caThumbprint, systemProxy: index % 2 == 0,
                                                     since: "2027-01-15T08:00:00Z")
                    try? CaptureJournal(directory: dir).record(entry, now: now)
                }
            }
        }
        let journal = CaptureJournal(directory: dir)
        for index in 0..<24 { XCTAssertEqual(journal.entry(for: "vm-\(index)")?.port, 50000 + index, "vm-\(index)") }

        let replaced = CaptureJournal.Entry(vm: "vm-3", port: 60000, thumbprint: otherThumbprint, systemProxy: true, since: "later")
        try journal.record(replaced, now: now)
        XCTAssertEqual(journal.entry(for: "vm-3"), replaced)
        try journal.remove(vm: "vm-3", now: now)
        XCTAssertNil(journal.entry(for: "vm-3"))
        XCTAssertEqual(journal.entry(for: "vm-4")?.port, 50004)
        let mode = try FileManager.default.attributesOfItem(atPath: journal.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testAnUnreadableJournalIsKeptAsideAndANewOneStarted() throws {
        let dir = try tempDir()
        let journal = CaptureJournal(directory: dir)
        XCTAssertNil(journal.entry(for: "Win"))
        try journal.remove(vm: "Win", now: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path))

        let unreadable = ["{\"version\":1,\"captures\":[{\"vm\":\"Win\"", "{\"version\":2,\"captures\":[],\"snapshots\":[]}",
                          "{\"version\":1,\"captures\":[{\"vm\":\"Win\",\"port\":0,\"thumbprint\":\"zz\",\"systemProxy\":true,\"since\":\"\"}],\"snapshots\":[]}"]
        for (index, broken) in unreadable.enumerated() {
            try Data(broken.utf8).write(to: journal.url)
            XCTAssertNil(journal.entry(for: "Win"), broken)
            XCTAssertEqual(try String(contentsOf: journal.url, encoding: .utf8), broken)
            let now = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            let entry = CaptureJournal.Entry(vm: "Win", port: 49152, thumbprint: caThumbprint, systemProxy: true, since: "2027-01-15T08:00:00Z")
            try journal.record(entry, now: now)
            XCTAssertEqual(journal.entry(for: "Win"), entry)
            let aside = dir.appendingPathComponent("captures.json.unreadable-20270115T08000\(index)Z")
            XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), broken)
            try journal.remove(vm: "Win", now: now)
        }
    }

    func testJournalSnapshotNotes() throws {
        let dir = try tempDir()
        let journal = CaptureJournal(directory: dir)
        let now = Date()
        let win = CaptureJournal.Entry(vm: "Win", port: 49152, thumbprint: caThumbprint, systemProxy: true, since: "a")
        let other = CaptureJournal.Entry(vm: "Other", port: 49153, thumbprint: otherThumbprint, systemProxy: false, since: "b")
        try journal.noteSnapshot("s1", during: win, now: now)
        try journal.noteSnapshot("s1", during: other, now: now)
        try journal.noteSnapshot("s2", during: win, now: now)
        XCTAssertEqual(journal.snapshotEntry("s1", vm: "Win"), win)
        XCTAssertEqual(journal.snapshotEntry("s1", vm: "Other"), other)
        XCTAssertNil(journal.snapshotEntry("s3", vm: "Win"))
        XCTAssertNil(journal.entry(for: "Win"))

        var later = win
        later.port = 50001
        try journal.noteSnapshot("s1", during: later, now: now)
        XCTAssertEqual(journal.snapshotEntry("s1", vm: "Win")?.port, 50001)
        try journal.forgetSnapshot("s1", vm: "Win", now: now)
        XCTAssertNil(journal.snapshotEntry("s1", vm: "Win"))
        XCTAssertEqual(journal.snapshotEntry("s2", vm: "Win"), win)

        try journal.record(win, now: now)
        try journal.forget(vm: "Win", now: now)
        XCTAssertNil(journal.entry(for: "Win"))
        XCTAssertNil(journal.snapshotEntry("s2", vm: "Win"))
        XCTAssertEqual(journal.snapshotEntry("s1", vm: "Other"), other)
    }

    // MARK: - requests and rules

    func testRequestsAndRequestPassThrough() async throws {
        let c = try await capture()
        _ = try await c.start()
        let proxy = c.factory.latest
        let listing: JSON = ["exchanges": [["id": 3, "kind": "http", "method": "GET", "url": "https://api.example.com/v1", "status": 404]],
                             "next": 3, "pending": []]
        proxy.reply("list", listing)
        let list = try await c.h.handle(op: "vm.http.requests", params: ["name": "Win", "lease": "x", "since": 2, "host": "api", "path": "/v1",
                                                                         "status": "4xx", "limit": 10, "other": true])
        XCTAssertEqual(list, listing)
        XCTAssertEqual(proxy.params(of: "list"), ["since": 2, "host": "api", "path": "/v1", "status": "4xx", "limit": 10])
        _ = try await c.h.handle(op: "vm.http.requests", params: ["name": "Win"])
        XCTAssertEqual(proxy.params(of: "list"), [:])

        let part: JSON = ["headers": [["Content-Type", "application/json"]], "body": "{\"ok\":true}", "total": 11, "bodyTruncated": false]
        proxy.reply("get", part)
        let got = try await c.h.handle(op: "vm.http.request", params: ["name": "Win", "exchange": 3, "part": "response", "offset": 4, "length": 100])
        XCTAssertEqual(got, part)
        XCTAssertEqual(proxy.params(of: "get"), ["exchange": 3, "part": "response", "offset": 4, "length": 100])
        let missing = await c.failure("vm.http.request", ["name": "Win", "part": "response"])
        XCTAssertEqual(missing, "missing or invalid parameter 'exchange'")
        let envelope = await c.failure("vm.http.request", ["name": "Win", "id": 3, "part": "response"])
        XCTAssertEqual(envelope, "missing or invalid parameter 'exchange'")

        proxy.fail("get", ProxyProcess.ProxyError.remote("no exchange with id 9; the store keeps the newest 2000 exchanges and 'clear' removes them all"))
        let gone = await c.failure("vm.http.request", ["name": "Win", "exchange": 9, "part": "request"])
        XCTAssertEqual(gone, "no exchange with id 9; the store keeps the newest 2000 exchanges and 'clear' removes them all")

        let cleared = try await c.h.handle(op: "vm.http.clear", params: ["name": "Win"])
        XCTAssertNotNil(cleared["eventSeq"])
        XCTAssertEqual(proxy.params(of: "clear"), [:])
    }

    func testARequestLineReadsTheExchangeFromItsOwnParameter() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.factory.latest.reply("get", ["headers": [], "body": "ok", "total": 2, "bodyTruncated": false])
        let line = Data(#"{"id":41,"op":"vm.http.request","name":"Win","exchange":3,"part":"response"}"#.utf8)
        let reply = try JSON.parse(await ControlServer.process(line, handler: c.h))
        XCTAssertEqual(reply["id"]?.intValue, 41)
        XCTAssertEqual(reply["ok"]?.boolValue, true)
        XCTAssertEqual(reply["body"]?.stringValue, "ok")
        XCTAssertEqual(c.factory.latest.params(of: "get"), ["exchange": 3, "part": "response"])
    }

    func testNoHTTPParameterIsAFieldOfTheEnvelope() async throws {
        XCTAssertEqual(ControlHandler.httpParameters, [
            "vm.http.start": ["hosts", "secrets", "bodies", "systemProxy"],
            "vm.http.stop": [],
            "vm.http.requests": ["since", "host", "path", "status", "limit"],
            "vm.http.request": ["exchange", "part", "offset", "length"],
            "vm.http.clear": [],
            "vm.http.rule.add": ["match", "action"],
            "vm.http.rule.list": [],
            "vm.http.rule.remove": ["rule"],
            "vm.http.rule.clear": [],
        ])
        XCTAssertEqual(ControlHandler.envelopeFields, ["id", "op", "ok", "error"])
        for (op, names) in ControlHandler.httpParameters {
            XCTAssertTrue(ControlHandler.envelopeFields.union(["name", "lease"]).isDisjoint(with: names), op)
        }

        let c = try await capture()
        _ = try await c.start()
        let proxy = c.factory.latest
        proxy.reply("list", ["exchanges": [], "next": 0, "pending": []])
        proxy.reply("get", ["headers": [], "body": "", "total": 0, "bodyTruncated": false])
        proxy.reply("rule.add", ["rule": 1])
        proxy.reply("rule.list", ["rules": [["id": 1, "match": [:], "action": ["status": 500], "hits": 0]]])
        let values: [String: JSON] = ["since": 1, "host": "a", "path": "/", "status": 500, "limit": 5, "exchange": 2, "part": "request", "offset": 0,
                                      "length": 10, "match": [:], "action": ["status": 500], "rule": 1]
        let ops = ["vm.http.requests", "vm.http.request", "vm.http.clear", "vm.http.rule.add", "vm.http.rule.list", "vm.http.rule.remove",
                   "vm.http.rule.clear", "vm.http.stop"]
        for (index, op) in ops.enumerated() {
            var fields: [String: JSON] = ["id": .int(Int64(700 + index)), "op": .string(op), "name": "Win"]
            let names = try XCTUnwrap(ControlHandler.httpParameters[op])
            for name in names { fields[name] = try XCTUnwrap(values[name], name) }
            XCTAssertEqual(fields.count, 3 + names.count, op)
            let reply = try JSON.parse(await ControlServer.process(try JSON.object(fields).serialized(), handler: c.h))
            XCTAssertEqual(reply["id"]?.intValue, 700 + index, op)
            XCTAssertEqual(reply["ok"]?.boolValue, true, "\(op): \(reply)")
        }
        XCTAssertEqual(proxy.params(of: "get"), ["exchange": 2, "part": "request", "offset": 0, "length": 10])
        let line = Data(#"{"id":900,"op":"vm.http.start","name":"Win","hosts":[],"secrets":false,"bodies":true,"systemProxy":true}"#.utf8)
        let started = try JSON.parse(await ControlServer.process(line, handler: c.h))
        XCTAssertEqual(started["id"]?.intValue, 900)
        XCTAssertEqual(started["ok"]?.boolValue, true, "\(started)")
    }

    func testRuleOpsPassThrough() async throws {
        let c = try await capture()
        _ = try await c.start()
        let proxy = c.factory.latest
        proxy.reply("rule.add", ["rule": 4])
        let match: JSON = ["host": "api.example.com", "path": "/v1/*", "method": "POST"]
        let action: JSON = ["status": 503, "headers": ["Retry-After": "1"], "body": "{}", "delayMs": 200, "times": 2]
        let added = try await c.h.handle(op: "vm.http.rule.add", params: ["name": "Win", "match": match, "action": action])
        XCTAssertEqual(added["rule"]?.intValue, 4)
        XCTAssertEqual(proxy.params(of: "rule.add"), ["match": match, "action": action])

        let rules: JSON = ["rules": [["id": 4, "match": match, "action": action, "hits": 1, "remaining": 1]]]
        proxy.reply("rule.list", rules)
        let listed = try await c.h.handle(op: "vm.http.rule.list", params: ["name": "Win"])
        XCTAssertEqual(listed, rules)
        XCTAssertEqual(proxy.params(of: "rule.list"), [:])

        _ = try await c.h.handle(op: "vm.http.rule.remove", params: ["name": "Win", "rule": 4])
        XCTAssertEqual(proxy.params(of: "rule.remove"), ["rule": 4])
        let missing = await c.failure("vm.http.rule.remove")
        XCTAssertEqual(missing, "missing or invalid parameter 'rule'")

        _ = try await c.h.handle(op: "vm.http.rule.clear", params: ["name": "Win"])
        XCTAssertEqual(proxy.params(of: "rule.clear"), [:])

        proxy.fail("rule.add", ProxyProcess.ProxyError.remote("the action needs at least one of status, body, delayMs or drop"))
        let refused = await c.failure("vm.http.rule.add", ["name": "Win", "match": [:], "action": [:]])
        XCTAssertEqual(refused, "the action needs at least one of status, body, delayMs or drop")
    }

    func testOpsWithoutACaptureNameTheNextStep() async throws {
        let c = try await capture()
        for op in ["vm.http.requests", "vm.http.clear", "vm.http.rule.list", "vm.http.rule.clear"] {
            let text = await c.failure(op)
            XCTAssertEqual(text, "'Win' is not capturing; call vm.http.start first", op)
        }
        let unknown = await c.failure("vm.http.requests", ["name": "Nope"])
        XCTAssertEqual(unknown, "no VM named 'Nope'; call vm.list")
    }

    func testAProxyThatExitedIsReportedByEveryCall() async throws {
        let c = try await capture()
        _ = try await c.start()
        let sentence = "alcove-proxy is not running (it exited with status 2); call vm.http.stop, then vm.http.start to capture again"
        c.factory.latest.fail("list", ProxyProcess.ProxyError.failed(sentence))
        let text = await c.failure("vm.http.requests")
        XCTAssertEqual(text, sentence)
        let stopped = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(stopped["exchanges"]?.intValue, 0)
        XCTAssertEqual(c.factory.latest.stopCount, 1)
    }

    func testACaptureWhoseProxyEndsOnItsOwnIsEndedAndItsGuestRestored() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.log.clear()
        c.factory.latest.end("alcove-proxy exited with status 2: listener failed")
        let stopped = await c.factory.latest.stopped()
        XCTAssertTrue(stopped)
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
        XCTAssertEqual(Array(c.limits.value.suffix(2)), [25_000, 25_000])
        XCTAssertNil(c.journal.entry(for: "Win"))
        XCTAssertEqual(c.hostLog.value, ["the HTTP capture of 'Win' ended because alcove-proxy exited with status 2: listener failed"])

        let sentence = "the HTTP capture of 'Win' ended because alcove-proxy exited with status 2: listener failed; call vm.http.start to capture again"
        for op in ["vm.http.requests", "vm.http.rule.list"] {
            let text = await c.failure(op)
            XCTAssertEqual(text, sentence, op)
        }
        _ = try await c.h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "C:\\app\\app.exe", "waitWindow": 0])
        XCTAssertNil(c.launches.value.last?["env"])

        let stop = await c.failure("vm.http.stop")
        XCTAssertEqual(stop, sentence)
        let again = await c.failure("vm.http.requests")
        XCTAssertEqual(again, "'Win' is not capturing; call vm.http.start first")

        let restarted = try await c.start()
        XCTAssertEqual(restarted["proxy"]?.stringValue, "10.0.2.2:49153")
    }

    func testAStartAfterALostCaptureDropsItsReason() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.factory.latest.end("alcove-proxy was ended by signal 9")
        _ = await c.factory.latest.stopped()
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        let text = await c.failure("vm.http.requests")
        XCTAssertEqual(text, "'Win' is not capturing; call vm.http.start first")
    }

    func testALostCaptureWhoseGuestToolsAreGoneKeepsItsEntryAndSaysSo() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.t.setAgent(nil)
        c.log.clear()
        c.factory.latest.end("alcove-proxy exited with status 2")
        _ = await c.factory.latest.stopped()
        XCTAssertEqual(c.log.entries, ["proxy.stop"])
        XCTAssertEqual(c.journal.entry(for: "Win")?.port, 49152)
        XCTAssertEqual(c.hostLog.value, ["the HTTP capture of 'Win' ended because alcove-proxy exited with status 2; the guest keeps the proxy "
                                         + "settings and the CA certificate of the capture (its guest tools were not connected); Alcove restores "
                                         + "them when its guest tools next connect"])
    }

    func testDoctorAndLaunchesSeeAProxyThatEndedBeforeTheCaptureIsEnded() async throws {
        let c = try await capture(vmPoll: .seconds(3600))
        _ = try await c.start()
        c.factory.latest.end("alcove-proxy exited with status 2")
        c.outputs.value["recipe.readProxy"] = guestProxy(enabled: true, server: "10.0.2.2:49152", winhttp: 49152)
        let doctor = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(doctor, "proxy"), ["id": "proxy", "ok": false,
                                                "detail": "the capture through 10.0.2.2:49152 is broken: alcove-proxy exited with status 2",
                                                "hint": "call vm.http.stop, then vm.http.start"])
        _ = try await c.h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "C:\\app\\app.exe", "waitWindow": 0])
        XCTAssertNil(c.launches.value.last?["env"])
    }

    func testChangingOpsNeedTheLease() async throws {
        let c = try await capture()
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.lease.acquire", params: ["name": "Win", "owner": "agent-a"])
        for op in ["vm.http.start", "vm.http.stop", "vm.http.clear", "vm.http.rule.add", "vm.http.rule.remove", "vm.http.rule.clear"] {
            let text = await c.failure(op)
            XCTAssertTrue(text.contains("is leased by agent-a"), "\(op): \(text)")
        }
        for op in ["vm.http.requests", "vm.http.rule.list"] {
            _ = try await c.h.handle(op: op, params: ["name": "Win"])
        }
        _ = try await c.h.handle(op: "vm.http.request", params: ["name": "Win", "exchange": 1, "part": "request"])
    }

    func testHTTPOpsAreKnownAndRunInRequestOrder() {
        for op in ControlHandler.httpOps {
            XCTAssertTrue(ControlHandler.knownOps.contains(op), op)
            XCTAssertFalse(ControlHandler.isConcurrent(op: op), op)
            XCTAssertFalse(ControlHandler.movesEventBaseline(op: op), op)
            XCTAssertFalse(ControlHandler.capturesFrames(op: op), op)
        }
        XCTAssertEqual(Set(ControlHandler.knownOps.filter { $0.hasPrefix("vm.http.") }), ControlHandler.httpOps)
        XCTAssertEqual(ControlHandler.httpOps.count, 9)
    }

    // MARK: - launches

    func testLaunchGetsProxyEnvWhileCapturing() async throws {
        let c = try await capture()
        _ = try await c.h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "C:\\app\\app.exe", "waitWindow": 0])
        XCTAssertNil(c.launches.value.last?["env"])

        let started = try await c.start()
        _ = try await c.h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "C:\\app\\app.exe", "waitWindow": 0])
        XCTAssertEqual(c.launches.value.last?["env"], started["env"])

        _ = try await c.h.handle(op: "vm.app.launch", params: [
            "name": "Win", "path": "C:\\app\\app.exe", "waitWindow": 0,
            "env": ["HTTP_PROXY": "http://mine:1", "no_proxy": "internal.example", "Ssl_Cert_File": "C:\\mine.pem", "APP_MODE": "test"],
        ])
        let env = try XCTUnwrap(c.launches.value.last?["env"]?.objectValue)
        XCTAssertEqual(env["HTTP_PROXY"]?.stringValue, "http://mine:1")
        XCTAssertNil(env["http_proxy"])
        XCTAssertEqual(env["no_proxy"]?.stringValue, "internal.example")
        XCTAssertNil(env["NO_PROXY"])
        XCTAssertEqual(env["Ssl_Cert_File"]?.stringValue, "C:\\mine.pem")
        XCTAssertNil(env["SSL_CERT_FILE"])
        XCTAssertEqual(env["APP_MODE"]?.stringValue, "test")
        XCTAssertEqual(env["HTTPS_PROXY"]?.stringValue, "http://10.0.2.2:49152")
        XCTAssertEqual(env["https_proxy"]?.stringValue, "http://10.0.2.2:49152")
        XCTAssertEqual(env["NODE_EXTRA_CA_CERTS"]?.stringValue, GuestRecipes.windowsProxyCAPath)
        XCTAssertEqual(env.count, 4 + 6)

        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        _ = try await c.h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "C:\\app\\app.exe", "waitWindow": 0])
        XCTAssertNil(c.launches.value.last?["env"])
        _ = try await c.h.handle(op: "vm.app.launch", params: ["name": "Win", "path": "C:\\app\\app.exe", "waitWindow": 0, "env": ["APP_MODE": "test"]])
        XCTAssertEqual(c.launches.value.last?["env"], ["APP_MODE": "test"])
    }

    func testDeployLaunchGetsProxyEnvWhileCapturing() async throws {
        let c = try await capture()
        let dir = try tempDir()
        let file = dir.appendingPathComponent("tool.exe")
        try Data("MZ".utf8).write(to: file)
        let launch: JSON = ["exe": "tool.exe", "env": ["https_proxy": "http://mine:2"]]
        let params: JSON = ["name": "Win", "path": .string(file.path), "killRunning": false, "waitWindow": 0, "launch": launch]
        _ = try await c.h.handle(op: "vm.deploy", params: params)
        XCTAssertEqual(c.launches.value.last?["env"], ["https_proxy": "http://mine:2"])

        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.deploy", params: params)
        let env = try XCTUnwrap(c.launches.value.last?["env"]?.objectValue)
        XCTAssertEqual(env["https_proxy"]?.stringValue, "http://mine:2")
        XCTAssertNil(env["HTTPS_PROXY"])
        XCTAssertEqual(env["HTTP_PROXY"]?.stringValue, "http://10.0.2.2:49152")
        XCTAssertEqual(env["REQUESTS_CA_BUNDLE"]?.stringValue, GuestRecipes.windowsProxyCAPath)
        XCTAssertEqual(env.count, 1 + 9)
    }

    func testExecGetsNoProxyEnv() async throws {
        let c = try await capture()
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.exec", params: ["name": "Win", "command": "whoami"])
        XCTAssertNil(agentRequests(c.agent, "exec.run").last?["env"])
    }

    // MARK: - the end of a capture

    func testCaptureEndsWhenVMStops() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.log.clear()
        let stopped = try await c.h.handle(op: "vm.stop", params: ["name": "Win"])
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
        XCTAssertEqual(Array(c.limits.value.suffix(2)), [12_000, 12_000])
        XCTAssertEqual(stopped["captureEnded"]?.boolValue, true)
        XCTAssertNil(stopped["warning"])
        XCTAssertEqual(stopped["state"]?.stringValue, "stopped")
        XCTAssertNil(c.journal.entry(for: "Win"))
        let stopCount = await c.t.stopCount
        XCTAssertEqual(stopCount, 1)

        _ = try await c.h.handle(op: "vm.start", params: ["name": "Win"])
        let after = await c.failure("vm.http.requests")
        XCTAssertEqual(after, "'Win' is not capturing; call vm.http.start first")
        let plain = try await c.h.handle(op: "vm.stop", params: ["name": "Win"])
        XCTAssertNil(plain["captureEnded"])
        XCTAssertNil(plain["warning"])
    }

    func testCaptureEndsWhenTheVMDoesNotStop() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.t.setStopError(ControlHandler.ControlError.failed("the guest ignored the power button"))
        let text = await c.failure("vm.stop")
        XCTAssertEqual(text, "stop failed: the guest ignored the power button; its HTTP capture was ended, call vm.http.start to capture again")
        XCTAssertEqual(c.factory.latest.stopCount, 1)
        let after = await c.failure("vm.http.requests")
        XCTAssertEqual(after, "'Win' is not capturing; call vm.http.start first")
    }

    func testStopOfAVMThatAlreadyStoppedEndsItsCapture() async throws {
        let c = try await capture(vmPoll: .seconds(3600))
        _ = try await c.start()
        await c.t.setState(.stopped)
        c.log.clear()
        let stopped = try await c.h.handle(op: "vm.stop", params: ["name": "Win"])
        XCTAssertEqual(c.log.entries, ["proxy.stop"])
        XCTAssertEqual(stopped["captureEnded"]?.boolValue, true)
        XCTAssertEqual(stopped["warning"]?.stringValue, "the guest keeps the proxy settings and the CA certificate of the capture (the VM was not "
                       + "running); Alcove restores them when its guest tools next connect")
    }

    func testStartOfAVMThatStoppedByItselfEndsItsCapture() async throws {
        let c = try await capture(vmPoll: .seconds(3600))
        _ = try await c.start()
        await c.t.setState(.stopped)
        _ = try await c.h.handle(op: "vm.start", params: ["name": "Win"])
        XCTAssertEqual(c.factory.latest.stopCount, 1)
        let after = await c.failure("vm.http.requests")
        XCTAssertEqual(after, "'Win' is not capturing; call vm.http.start first")
    }

    func testForcedStopEndsTheCaptureWithoutAskingTheGuest() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.log.clear()
        let stopped = try await c.h.handle(op: "vm.stop", params: ["name": "Win", "force": true])
        XCTAssertEqual(c.log.entries, ["proxy.stop"])
        XCTAssertEqual(stopped["warning"]?.stringValue, "the guest keeps the proxy settings and the CA certificate of the capture (the stop was "
                       + "forced); Alcove restores them when its guest tools next connect")
        XCTAssertNotNil(c.journal.entry(for: "Win"))
    }

    func testAStopWhoseRestoreFailsSaysWhatTheGuestKeeps() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.failures.value["recipe.removeCA"] = "could not remove the proxy CA from the guest: Access is denied.; check that alcove-agent runs elevated, then call vm.http.stop again"
        let stopped = try await c.h.handle(op: "vm.stop", params: ["name": "Win"])
        XCTAssertEqual(stopped["warning"]?.stringValue, "the guest keeps the proxy settings and the CA certificate of the capture (could not remove "
                       + "the proxy CA from the guest: Access is denied.; check that alcove-agent runs elevated, then call vm.http.stop again); "
                       + "Alcove restores them when its guest tools next connect")
        XCTAssertNotNil(c.journal.entry(for: "Win"))

        let offline = try await capture()
        _ = try await offline.start()
        await offline.t.setAgent(nil)
        let unreachable = try await offline.h.handle(op: "vm.stop", params: ["name": "Win"])
        XCTAssertEqual(unreachable["warning"]?.stringValue, "the guest keeps the proxy settings and the CA certificate of the capture (its guest "
                       + "tools were not connected); Alcove restores them when its guest tools next connect")
    }

    func testStopOfAPausedCapturingVMSaysTheVMWasPaused() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.t.setState(.paused)
        c.log.clear()
        let r = try await c.h.handle(op: "vm.stop", params: ["name": "Win"])
        XCTAssertEqual(r["warning"]?.stringValue, ControlHandler.unrestoredWarning("the VM was paused"))
        XCTAssertEqual(c.log.entries, ["proxy.stop"])
        XCTAssertNotNil(c.journal.entry(for: "Win"))
    }

    func testCaptureEndsWhenTheVMIsFoundStopped() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.t.setState(.stopped)
        let ended = await c.factory.latest.stopped()
        XCTAssertTrue(ended)
        XCTAssertEqual(c.factory.latest.stopCount, 1)
        let text = await c.failure("vm.http.requests")
        XCTAssertEqual(text, "VM 'Win' is stopped; call vm.start first")
    }

    func testCaptureEndsWhenTheVMFailed() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.t.setState(.failed("the engine exited"))
        let ended = await c.factory.latest.stopped()
        XCTAssertTrue(ended)
    }

    func testCaptureEndsWhenTheVMRunsInAnotherEngineProcess() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.t.setInstance(2)
        let ended = await c.factory.latest.stopped()
        XCTAssertTrue(ended)
        XCTAssertEqual(c.factory.latest.stopCount, 1)
        let text = await c.failure("vm.http.requests")
        XCTAssertEqual(text, "'Win' is not capturing; call vm.http.start first")
    }

    func testTheStatesThatKeepACapture() {
        let states: [VMController.State] = [.stopped, .starting, .running, .paused, .suspending, .stopping, .failed("x")]
        XCTAssertEqual(states.filter(ControlHandler.keepsCapture), [.running, .paused, .suspending, .stopping])
    }

    func testTheCaptureSurvivesASuspendThatFails() async throws {
        let c = try await capture()
        _ = try await c.start()
        for state in [VMController.State.suspending, .stopping] {
            await c.t.setState(state)
            let before = await c.t.stateCalls
            let polled = await eventually("the watcher looks at the \(describe(state)) VM three times") { await c.t.stateCalls >= before + 3 }
            XCTAssertTrue(polled)
            XCTAssertEqual(c.factory.latest.stopCount, 0, describe(state))
        }
        await c.t.setState(.running)
        _ = try await c.h.handle(op: "vm.http.requests", params: ["name": "Win"])
        XCTAssertEqual(c.factory.latest.stopCount, 0)
    }

    func testAnOpDuringASuspendKeepsTheCapture() async throws {
        let c = try await capture(vmPoll: .seconds(3600))
        _ = try await c.start()
        for state in [VMController.State.suspending, .stopping] {
            await c.t.setState(state)
            let text = await c.failure("vm.http.requests")
            XCTAssertEqual(text, "VM 'Win' is \(describe(state)); call vm.start first")
            XCTAssertEqual(c.factory.latest.stopCount, 0, describe(state))
        }
        await c.t.setState(.running)
        _ = try await c.h.handle(op: "vm.http.requests", params: ["name": "Win"])
    }

    func testAnOpThatFindsTheVMStartingEndsTheCaptureOfTheEarlierSession() async throws {
        let c = try await capture(vmPoll: .seconds(3600))
        _ = try await c.start()
        await c.t.setState(.starting)
        let text = await c.failure("vm.screenshot")
        XCTAssertEqual(text, "VM 'Win' is starting; call vm.start first")
        XCTAssertEqual(c.factory.latest.stopCount, 1)
    }

    func testAnOpThatFindsTheVMStoppedEndsTheCapture() async throws {
        let c = try await capture(vmPoll: .seconds(3600))
        _ = try await c.start()
        await c.t.setState(.stopped)
        let text = await c.failure("vm.screenshot")
        XCTAssertEqual(text, "VM 'Win' is stopped; call vm.start first")
        XCTAssertEqual(c.factory.latest.stopCount, 1)
    }

    func testARefusedDeleteKeepsTheCapture() async throws {
        let provisioning = LockedBox<FakeProvisioningRegistry?>(nil)
        let c = try await capture(registry: { t in
            let made = FakeProvisioningRegistry(targets: ["Win": t])
            provisioning.value = made
            return made
        })
        let registry = try XCTUnwrap(provisioning.value)
        _ = try await c.start()
        await registry.setFailure(VMBundle.CloneError.cloneRunning("Win"))
        let refused = await c.failure("vm.delete")
        XCTAssertNotEqual(refused, "no error")
        XCTAssertEqual(c.factory.latest.stopCount, 0)
        XCTAssertNotNil(c.journal.entry(for: "Win"))
        _ = try await c.h.handle(op: "vm.http.requests", params: ["name": "Win"])

        await registry.setFailure(nil)
        c.log.clear()
        _ = try await c.h.handle(op: "vm.delete", params: ["name": "Win"])
        let calls = await registry.calls
        XCTAssertEqual(calls, ["delete:Win"])
        XCTAssertEqual(c.log.entries, ["proxy.stop"])
    }

    func testSnapshotRestoreEndsTheCapture() async throws {
        let c = try await capture()
        await c.t.setSnapshotList([VMController.SnapshotInfo(name: "clean", vmStateSize: 1, date: Date())])
        _ = try await c.start()
        c.log.clear()
        let restored = try await c.h.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "clean", "waitTools": 0])
        XCTAssertEqual(restored["captureEnded"]?.boolValue, true)
        XCTAssertNil(restored["staleProxyCleared"])
        XCTAssertEqual(c.log.entries.filter { $0 != "recipe.other" }, ["proxy.stop"])
        XCTAssertNotNil(c.journal.entry(for: "Win"))
        let after = await c.failure("vm.http.requests")
        XCTAssertEqual(after, "'Win' is not capturing; call vm.http.start first")
    }

    func testRestoringASnapshotTakenDuringACaptureClearsItsSettings() async throws {
        let c = try await capture()
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "mid-capture"])
        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        await c.t.setSnapshotList([VMController.SnapshotInfo(name: "mid-capture", vmStateSize: 1, date: Date()),
                                   VMController.SnapshotInfo(name: "clean", vmStateSize: 1, date: Date())])
        c.log.clear()
        c.outputs.value["recipe.clearProxy"] = restoredState(caThumbprint)
        let restored = try await c.h.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "mid-capture", "waitTools": 0])
        XCTAssertEqual(restored["staleProxyCleared"]?.boolValue, true)
        XCTAssertNil(restored["captureEnded"])
        XCTAssertEqual(c.log.entries.filter { $0 != "recipe.other" }, ["recipe.clearProxy", "recipe.removeCA"])

        c.log.clear()
        let clean = try await c.h.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "clean", "waitTools": 0])
        XCTAssertNil(clean["staleProxyCleared"])
        XCTAssertEqual(c.log.entries.filter { $0 != "recipe.other" }, [])
    }

    func testASnapshotCreatedWithoutACaptureDropsTheNoteOfItsName() async throws {
        let c = try await capture()
        _ = try await c.start()
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "reused"])
        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertNotNil(c.journal.snapshotEntry("reused", vm: "Win"))
        _ = try await c.h.handle(op: "vm.snapshot.create", params: ["name": "Win", "snapshot": "reused"])
        XCTAssertNil(c.journal.snapshotEntry("reused", vm: "Win"))
    }

    func testShutdownRestoresTheGuestsAndEndsEveryCapture() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.log.clear()
        await c.h.shutdown()
        XCTAssertEqual(c.log.entries, ["recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
        XCTAssertNil(c.journal.entry(for: "Win"))
        let after = await c.failure("vm.http.requests")
        XCTAssertEqual(after, "'Win' is not capturing; call vm.http.start first")
    }

    func testShutdownWithinALimitReturnsWhileAGuestStillHoldsItUp() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.held.value = ["recipe.clearProxy"]
        let returned = await finishes("shutdown(within:) returns while the guest does not answer") { await c.h.shutdown(within: .milliseconds(50)) }
        XCTAssertTrue(returned)
        XCTAssertEqual(c.factory.latest.stopCount, 0)
        let asked = await eventually("the shutdown asks the guest to restore its proxy settings") { c.waiting.value.count == 1 }
        XCTAssertTrue(asked)
        c.release("recipe.clearProxy", printing: noState)
        let ended = await c.factory.latest.stopped()
        XCTAssertTrue(ended)

        let quick = try await capture()
        _ = try await quick.start()
        await quick.h.shutdown(within: .seconds(3600))
        XCTAssertEqual(quick.factory.latest.stopCount, 1)
    }

    // MARK: - trace

    func testTraceMasksSecretHeadersAndCutsTheBody() throws {
        let long = String(repeating: "b", count: 5000)
        let result: JSON = [
            "headers": [["Authorization", "Bearer abc"], ["cookie", "sid=1"], ["Set-Cookie", "<redacted 12 chars>"], ["X-Api-Key", "k"],
                        ["api-key", "k2"], ["Proxy-Authorization", "Basic x"], ["Content-Type", "text/plain"]],
            "trailers": [["Set-Cookie", "late=1"], ["X-Checksum", "9"]],
            "body": .string(long), "total": 5000, "bodyTruncated": false,
        ]
        let traced = TraceSanitizer.sanitize(result: result, op: "vm.http.request")
        XCTAssertEqual(traced["headers"], [["Authorization", "<masked>"], ["cookie", "<masked>"], ["Set-Cookie", "<redacted 12 chars>"],
                                           ["X-Api-Key", "<masked>"], ["api-key", "<masked>"], ["Proxy-Authorization", "<masked>"],
                                           ["Content-Type", "text/plain"]])
        XCTAssertEqual(traced["trailers"], [["Set-Cookie", "<masked>"], ["X-Checksum", "9"]])
        XCTAssertEqual(traced["body"]?.stringValue, String(repeating: "b", count: 2000) + "…")
        XCTAssertEqual(traced["bodyCut"]?.boolValue, true)
        XCTAssertEqual(traced["bodyTruncated"]?.boolValue, false)
        XCTAssertEqual(traced["total"]?.intValue, 5000)

        let short = TraceSanitizer.sanitize(result: ["headers": [], "body": "ok", "bodyTruncated": true], op: "vm.http.request")
        XCTAssertEqual(short, ["headers": [], "body": "ok", "bodyTruncated": true])
        let other = TraceSanitizer.sanitize(result: ["headers": [["Authorization", "Bearer abc"]]], op: "vm.exec")
        XCTAssertEqual(other, ["headers": [["Authorization", "Bearer abc"]]])
    }

    func testTraceMasksEveryShapeOfASecretHeader() throws {
        let result: JSON = [
            "headers": [["Authorization", ["Bearer abc", "Bearer def"]], ["Cookie", 5], ["Set-Cookie", "<redacted 12 chars> and more"],
                        ["X-Api-Key", "<redacted x chars>"], ["api-key"], ["Cookie", "a", "b"], ["Content-Type", ["text/plain"]], "Authorization"],
        ]
        let traced = TraceSanitizer.sanitize(result: result, op: "vm.http.request")
        XCTAssertEqual(traced["headers"], [["Authorization", "<masked>"], ["Cookie", "<masked>"], ["Set-Cookie", "<masked>"],
                                           ["X-Api-Key", "<masked>"], ["api-key", "<masked>"], ["Cookie", "<masked>"],
                                           ["Content-Type", ["text/plain"]], "Authorization"])
    }

    func testTraceLineOfARequestHoldsNoSecretHeaderValue() throws {
        let result: JSON = ["headers": [["Authorization", "Bearer abc"]], "body": "ok", "total": 2, "bodyTruncated": false]
        let entry = TraceEntry(seq: 1, time: Date(), ms: 0, op: "vm.http.request", params: ["name": "Win", "exchange": 1, "part": "request", "lease": "x"],
                               outcome: .success(result), durationMs: 1, before: nil, after: nil)
        let line = String(decoding: try entry.json.serialized(), as: UTF8.self)
        XCTAssertFalse(line.contains("Bearer abc"), line)
        XCTAssertTrue(line.contains("<masked>"), line)
    }

    // MARK: - recipes

    func testThumbprintIsTheSHA1OfTheCertificate() {
        XCTAssertEqual(ControlHandler.certificateThumbprint(pem: caPEM), caThumbprint)
        XCTAssertEqual(caThumbprint.count, 40)
        XCTAssertTrue(ControlHandler.isThumbprint(caThumbprint))
        XCTAssertFalse(ControlHandler.isThumbprint(String(caThumbprint.dropLast())))
        XCTAssertFalse(ControlHandler.isThumbprint(String(repeating: "G", count: 40)))
        XCTAssertNil(ControlHandler.certificateThumbprint(pem: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"))
        XCTAssertNil(ControlHandler.certificateThumbprint(pem: "-----BEGIN CERTIFICATE-----\n!!\n-----END CERTIFICATE-----\n"))
        let crlf = caPEM.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(ControlHandler.certificateThumbprint(pem: crlf), caThumbprint)
    }

    /// The Windows scripts of the capture for port 49152.
    private func windowsRecipes() throws -> [String: String] {
        ["installProxyCA": try XCTUnwrap(GuestRecipes.installProxyCA(thumbprint: caThumbprint, os: .windows)),
         "removeProxyCA": try XCTUnwrap(GuestRecipes.removeProxyCA(thumbprint: caThumbprint, os: .windows)),
         "removeProxyCA(file)": try XCTUnwrap(GuestRecipes.removeProxyCA(thumbprint: nil, os: .windows)),
         "setSystemProxy": try XCTUnwrap(GuestRecipes.setSystemProxy(port: 49152, thumbprint: caThumbprint, apply: true, os: .windows)),
         "setSystemProxy(record)": try XCTUnwrap(GuestRecipes.setSystemProxy(port: 49152, thumbprint: caThumbprint, apply: false, os: .windows)),
         "clearSystemProxy": try XCTUnwrap(GuestRecipes.clearSystemProxy(os: .windows)),
         "readSystemProxy": try XCTUnwrap(GuestRecipes.readSystemProxy(os: .windows))]
    }

    /// `script` without its single-quoted PowerShell strings.
    private func withoutQuotedStrings(_ script: String) -> String {
        var out = ""
        var quoted = false
        for ch in script {
            if ch == "'" { quoted.toggle(); continue }
            if !quoted { out.append(ch) }
        }
        return out
    }

    /// The text of `script` from the first `start` up to the first `end` after it.
    private func part(of script: String, from start: String, to end: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let begin = try XCTUnwrap(script.range(of: start), "missing: \(start)", file: file, line: line)
        let stop = try XCTUnwrap(script.range(of: end, range: begin.upperBound..<script.endIndex), "missing: \(end)", file: file, line: line)
        return String(script[begin.lowerBound..<stop.lowerBound])
    }

    /// The statements of `script` that run when it starts: what follows its function definitions.
    private func mainPart(of script: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let begin = try XCTUnwrap(script.range(of: "\ntry {\n", options: .backwards), "the script has no try block", file: file, line: line)
        return String(script[begin.lowerBound...])
    }

    /// Records a failure unless `first` stands before `second` in `script`.
    private func assertOrder(_ script: String, _ first: String, _ second: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let a = script.range(of: first), let b = script.range(of: second) else {
            XCTFail("missing: \(script.range(of: first) == nil ? first : second)", file: file, line: line)
            return
        }
        XCTAssertLessThan(a.lowerBound, b.lowerBound, "\(first) must come before \(second)", file: file, line: line)
    }

    /// How many times `text` stands in `script`.
    private func count(_ text: String, in script: String) -> Int {
        script.components(separatedBy: text).count - 1
    }

    func testWindowsProxyRecipesAreBalancedAndPrintOneJSONLine() throws {
        for (name, script) in try windowsRecipes() {
            XCTAssertTrue(script.hasPrefix("$ErrorActionPreference = 'Stop'\n$WarningPreference = 'SilentlyContinue'\n"), name)
            XCTAssertEqual(script.filter { $0 == "'" }.count % 2, 0, name)
            let code = withoutQuotedStrings(script)
            for (open, close) in [("{", "}"), ("(", ")"), ("[", "]")] {
                XCTAssertEqual(code.filter { String($0) == open }.count, code.filter { String($0) == close }.count, "\(name): \(open)\(close)")
            }
            XCTAssertFalse(code.contains("\""), name)
            let last = try XCTUnwrap(script.split(separator: "\n").last)
            XCTAssertTrue(last.hasPrefix("'{\""), "\(name): \(last)")
            XCTAssertTrue(script.contains("[Console]::Error.WriteLine("), name)
            XCTAssertTrue(script.contains("exit 2"), name)
            XCTAssertFalse(script.contains("ConvertTo-Json"), name)
            XCTAssertFalse(script.contains("\t"), name)
            XCTAssertFalse(script.contains("\n\n"), name)
            XCTAssertLessThan(script.utf16.count, 16_000, name)
        }
    }

    func testTheCACertificateIsComparedBeforeItIsAddedAndRemovedByThumbprintOnly() throws {
        let recipes = try windowsRecipes()
        let install = try XCTUnwrap(recipes["installProxyCA"])
        XCTAssertTrue(install.contains("$thumb = '\(caThumbprint)'\n"), install)
        XCTAssertTrue(install.contains("$caPath = 'C:\\ProgramData\\Alcove\\proxy-ca.pem'\n"), install)
        for sid in ["S-1-5-32-544", "S-1-5-18", "S-1-5-32-545"] { XCTAssertTrue(install.contains("'\(sid)'"), sid) }
        XCTAssertTrue(install.contains("[System.Security.AccessControl.FileSystemRights]::Read, $allow"), install)
        XCTAssertTrue(install.contains("$acl.SetAccessRuleProtection($true, $false)"), install)
        XCTAssertTrue(install.contains("[System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine"), install)
        let compare = "if ($null -eq $cert -or $cert.Thumbprint -ne $thumb) { [Console]::Error.WriteLine('the proxy CA file in the guest is not the "
            + "certificate the host sent; call vm.http.start again'); exit 2 }"
        let main = try mainPart(of: install)
        assertOrder(main, "[System.IO.File]::SetAccessControl($caPath, $acl)", "$cert = AlcoveCA")
        assertOrder(main, "$cert = AlcoveCA", compare)
        assertOrder(main, compare, "AlcoveRoot 'ReadWrite'")
        assertOrder(main, compare, "$store.Add($cert)")
        XCTAssertEqual(count("$store.Add(", in: install), 1)
        XCTAssertEqual(count(".Add(", in: install), 1)
        XCTAssertEqual(count("AlcoveCA\n", in: install), 1)

        let remove = try XCTUnwrap(recipes["removeProxyCA"])
        XCTAssertTrue(remove.contains("$thumb = '\(caThumbprint)'\n"), remove)
        XCTAssertTrue(remove.contains("  if (-not $thumb -and [System.IO.File]::Exists($caPath)) {\n    try { $cert = AlcoveCA; if ($cert) { $thumb = $cert.Thumbprint } } catch { }\n  }\n"), remove)
        XCTAssertEqual(count("AlcoveCA;", in: remove), 1)
        XCTAssertTrue(try XCTUnwrap(recipes["removeProxyCA(file)"]).contains("$thumb = ''\n"))
        let byThumb = "foreach ($found in @($store.Certificates.Find($byThumbprint, $thumb, $false))) { $store.Remove($found)"
        let byOld = "foreach ($found in @($store.Certificates.Find($byThumbprint, $old, $false))) { $store.Remove($found)"
        let removals = ["removeProxyCA": byThumb, "removeProxyCA(file)": byThumb, "setSystemProxy": byOld, "setSystemProxy(record)": byOld]
        for (name, script) in recipes {
            XCTAssertFalse(script.contains("Subject"), name)
            XCTAssertEqual(count("FindBy", in: script), count("FindByThumbprint", in: script), name)
            XCTAssertEqual(count("$store.Remove(", in: script), removals[name] == nil ? 0 : 1, name)
            XCTAssertEqual(count(".Remove(", in: script), count("$store.Remove(", in: script), name)
            XCTAssertEqual(count(".RemoveRange(", in: script), 0, name)
            if let removal = removals[name] { XCTAssertTrue(script.contains(removal), name) }
            if name != "installProxyCA" { XCTAssertEqual(count(".Add(", in: script), 0, name) }
        }
        let set = try XCTUnwrap(recipes["setSystemProxy"])
        XCTAssertTrue(set.contains("    $old = [string]$state.thumbprint\n    if ($old -ne $thumb) {\n      $store = AlcoveRoot 'ReadWrite'\n      " + byOld), set)
    }

    func testTheStateFileRecordsEveryStartAndIsWrittenBeforeTheFirstChange() throws {
        let recipes = try windowsRecipes()
        let template = "  $json = '{\"version\":1,\"thumbprint\":\"' + $thumb + '\",\"port\":49152,\"systemProxy\":' + (AlcoveBool $apply)"
            + " + ',\"proxyEnable\":' + $enableText + ',\"proxyEnableKind\":' + (AlcoveField (AlcoveKindText $enableKind))"
            + " + ',\"proxyServer\":' + (AlcoveField $proxyServer) + ',\"proxyServerKind\":' + (AlcoveField (AlcoveKindText $proxyServerKind))"
            + " + ',\"proxyOverride\":' + (AlcoveField $proxyOverride) + ',\"proxyOverrideKind\":' + (AlcoveField (AlcoveKindText $proxyOverrideKind))"
            + " + ',\"autoConfigURL\":' + (AlcoveField $autoConfigURL) + ',\"autoConfigURLKind\":' + (AlcoveField (AlcoveKindText $autoConfigURLKind))"
            + " + ',\"winhttp\":' + (AlcoveField $blob) + '}'\n  AlcoveWriteState $json\n"
        let none = "  $enable = $null; $enableKind = $null; $proxyServer = $null; $proxyServerKind = $null; $proxyOverride = $null; "
            + "$proxyOverrideKind = $null; $autoConfigURL = $null; $autoConfigURLKind = $null; $blob = $null\n  if ($apply) {\n"
        for (name, apply) in [("setSystemProxy", "$true"), ("setSystemProxy(record)", "$false")] {
            let set = try XCTUnwrap(recipes[name])
            XCTAssertTrue(set.contains("$server = '10.0.2.2:49152'\n$thumb = '\(caThumbprint)'\n$apply = \(apply)\n"), name)
            XCTAssertTrue(set.contains("$statePath = 'C:\\ProgramData\\Alcove\\proxy-previous.json'\n"), name)
            let main = try mainPart(of: set)
            XCTAssertTrue(main.contains(template), name)
            XCTAssertTrue(main.contains(none), name)
            XCTAssertEqual(count("AlcoveWriteState $json", in: set), 1, name)
            for change in ["$key.SetValue(", "$key.DeleteValue(", "& $netsh", "AlcoveRefresh"] {
                assertOrder(main, "AlcoveWriteState $json\n", change)
            }
            let writer = try part(of: set, from: "function AlcoveWriteState($json) {", to: "\n}\n")
            XCTAssertEqual(writer, """
                function AlcoveWriteState($json) {
                  $new = $statePath + '.new'
                  [System.IO.File]::WriteAllText($new, $json)
                  if ([System.IO.File]::Exists($statePath)) { [System.IO.File]::Replace($new, $statePath, [NullString]::Value) } else { [System.IO.File]::Move($new, $statePath) }
                """, name)
            XCTAssertEqual(count("WriteAllText(", in: set), 1, name)
            XCTAssertEqual(count("::Delete(", in: set), 0, name)

            let applied = try part(of: main, from: "  if ($apply) {\n    $key = $hkcu.CreateSubKey($inet)", to: "  } elseif ($state -and $state.systemProxy) {")
            XCTAssertFalse(applied.contains("AlcoveRestore"), name)
            let unapplied = try part(of: main, from: "  } elseif ($state -and $state.systemProxy) {", to: "  $enableText = 'null'")
            XCTAssertEqual(unapplied, "  } elseif ($state -and $state.systemProxy) {\n    $restored = AlcoveRestore $state $hkcu $hklm\n  }\n", name)
            let changes = try part(of: main, from: "  AlcoveWriteState $json\n", to: "} catch {")
            XCTAssertEqual(changes, """
                  AlcoveWriteState $json
                  if ($apply) {
                    $key.SetValue('ProxyServer', $server, [Microsoft.Win32.RegistryValueKind]::String)
                    $key.SetValue('ProxyOverride', '<local>', [Microsoft.Win32.RegistryValueKind]::String)
                    $key.DeleteValue('AutoConfigURL', $false)
                    $key.SetValue('ProxyEnable', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
                    $key.Close()
                    $netsh = $env:SystemRoot + '\\System32\\netsh.exe'
                    $ErrorActionPreference = 'Continue'
                    $null = & $netsh winhttp set proxy ('proxy-server=' + $server) 'bypass-list=<local>' 2>&1
                    $ErrorActionPreference = 'Stop'
                    $winhttp = $LASTEXITCODE -eq 0
                    $refreshed = AlcoveRefresh
                  } elseif ($restored) {
                    $refreshed = AlcoveRefresh
                  }

                """, name)
            XCTAssertTrue(set.hasSuffix("'{\"set\":' + (AlcoveBool $apply) + ',\"keptPrevious\":' + (AlcoveBool $kept) + ',\"restored\":' + (AlcoveBool $restored)"
                                        + " + ',\"winhttp\":' + (AlcoveBool $winhttp) + ',\"refreshed\":' + (AlcoveBool $refreshed) + '}'"), name)
        }
        let set = try XCTUnwrap(recipes["setSystemProxy"])
        XCTAssertTrue(set.contains("InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)"), set)
        XCTAssertTrue(set.contains("InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)"), set)
    }

    func testOnlySettingsOfTheStateFilesOwnPortCountAsAlcoves() throws {
        let recipes = try windowsRecipes()
        let set = try XCTUnwrap(recipes["setSystemProxy"])
        let remembering = try part(of: set, from: "    $inetOurs = $false\n", to: "  } elseif ($state -and $state.systemProxy) {")
        XCTAssertEqual(remembering, """
                $inetOurs = $false
                $httpOurs = $false
                if ($state -and $state.systemProxy) {
                  $serverNow = $key.GetValue('ProxyServer', $null, $asStored)
                  $inetOurs = ($serverNow -is [string]) -and ($serverNow -ceq ('10.0.2.2:' + [int]$state.port))
                  $httpOurs = (AlcovePort (AlcoveBlobText $raw)) -eq [int]$state.port
                }
                if ($inetOurs) {
                  $kept = $true
                  $enable = $state.proxyEnable
                  $enableKind = $state.proxyEnableKind
                  $proxyServer = AlcoveSafe $state.proxyServer
                  $proxyServerKind = $state.proxyServerKind
                  $proxyOverride = AlcoveSafe $state.proxyOverride
                  $proxyOverrideKind = $state.proxyOverrideKind
                  $autoConfigURL = AlcoveSafe $state.autoConfigURL
                  $autoConfigURLKind = $state.autoConfigURLKind
                } else {
                  $enable = $key.GetValue('ProxyEnable')
                  $enableKind = AlcoveKindName $key 'ProxyEnable'
                  $proxyServer = AlcoveText ($key.GetValue('ProxyServer', $null, $asStored))
                  $proxyServerKind = AlcoveKindName $key 'ProxyServer'
                  $proxyOverride = AlcoveText ($key.GetValue('ProxyOverride', $null, $asStored))
                  $proxyOverrideKind = AlcoveKindName $key 'ProxyOverride'
                  $autoConfigURL = AlcoveText ($key.GetValue('AutoConfigURL', $null, $asStored))
                  $autoConfigURLKind = AlcoveKindName $key 'AutoConfigURL'
                }
                if ($httpOurs) {
                  $kept = $true
                  $blob = AlcoveSafe $state.winhttp
                } elseif ($raw -is [byte[]]) {
                  $blob = [Convert]::ToBase64String($raw)
                }

            """)
        XCTAssertEqual(count("$inetOurs = ", in: set), 2)
        XCTAssertEqual(count("$httpOurs = ", in: set), 2)
        XCTAssertEqual(count("$enable = ", in: set), 3)
        XCTAssertFalse(set.contains("$enable = 0"), set)

        for (name, script) in recipes where script.contains("function AlcovePort") {
            XCTAssertTrue(script.contains("[regex]::Match([string]$text, '(?<![0-9A-Za-z.=;:/ ,-])10\\.0\\.2\\.2:([0-9]{1,5})(?![0-9A-Za-z.;: ,-])')"), name)
        }
        let pattern = try NSRegularExpression(pattern: "(?<![0-9A-Za-z.=;:/ ,-])10\\.0\\.2\\.2:([0-9]{1,5})(?![0-9A-Za-z.;: ,-])")
        func port(_ text: String) -> String? {
            guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let digits = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[digits])
        }
        XCTAssertEqual(port("\u{18}\u{3}\u{e}10.0.2.2:49152\u{7}<local>"), "49152")
        XCTAssertEqual(port("10.0.2.2:8080"), "8080")
        XCTAssertEqual(port("\u{18}\u{3}\u{d}10.0.2.2:8080\u{7}<local>"), "8080")
        XCTAssertEqual(port("\u{18}\u{3}\u{a}10.0.2.2:5\u{7}<local>"), "5")
        for other in ["110.0.2.2:3128", "210.0.2.2:80", "host10.0.2.2:80", "http=10.0.2.2:8080", "x;10.0.2.2:8080", "10.0.2.2:8080;10.0.2.2:8081",
                      "10.0.2.2:808080", "10.0.2.2:80.example", "a.10.0.2.2:80", "//10.0.2.2:80", "proxy.corp:3128 10.0.2.2:49152",
                      "10.0.2.2:49152 proxy.corp:3128", "proxy.corp:3128,10.0.2.2:49152", "10.0.2.2:49152,proxy.corp:3128"] {
            XCTAssertNil(port(other), other)
        }
    }

    func testRestoreDeletesAbsentValuesAndKeepsTheKinds() throws {
        let recipes = try windowsRecipes()
        for name in ["clearSystemProxy", "setSystemProxy(record)", "setSystemProxy"] {
            let script = try XCTUnwrap(recipes[name])
            let restorer = try part(of: script, from: "function AlcoveRestoreText($key, $name, $stored, $kindName) {", to: "function AlcoveRefresh {")
            XCTAssertEqual(restorer, """
                function AlcoveRestoreText($key, $name, $stored, $kindName) {
                  if ($null -eq $stored) { $key.DeleteValue($name, $false); return }
                  $kind = [Microsoft.Win32.RegistryValueKind]::String
                  if ((AlcoveKindText $kindName) -ceq 'ExpandString') { $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
                  $key.SetValue($name, [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($stored)), $kind)
                }
                function AlcoveRestore($state, $hkcu, $hklm) {
                  $restored = $false
                  $key = $hkcu.CreateSubKey($inet)
                  $serverNow = $key.GetValue('ProxyServer', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                  if (($serverNow -is [string]) -and ($serverNow -ceq ('10.0.2.2:' + [int]$state.port))) {
                    if ($null -eq $state.proxyEnable) { $key.DeleteValue('ProxyEnable', $false) } elseif ((AlcoveKindText $state.proxyEnableKind) -ceq 'String') { $key.SetValue('ProxyEnable', [string][int]$state.proxyEnable, [Microsoft.Win32.RegistryValueKind]::String) } else { $key.SetValue('ProxyEnable', [int]$state.proxyEnable, [Microsoft.Win32.RegistryValueKind]::DWord) }
                    AlcoveRestoreText $key 'ProxyOverride' (AlcoveSafe $state.proxyOverride) $state.proxyOverrideKind
                    AlcoveRestoreText $key 'AutoConfigURL' (AlcoveSafe $state.autoConfigURL) $state.autoConfigURLKind
                    AlcoveRestoreText $key 'ProxyServer' (AlcoveSafe $state.proxyServer) $state.proxyServerKind
                    $restored = $true
                  }
                  $key.Close()
                  $ck = $hklm.OpenSubKey($conn, $true)
                  if ($ck) {
                    if ((AlcovePort (AlcoveBlobText ($ck.GetValue('WinHttpSettings')))) -eq [int]$state.port) {
                      $blob = AlcoveSafe $state.winhttp
                      if ($null -eq $blob) { $ck.DeleteValue('WinHttpSettings', $false) } else { [byte[]]$raw = [Convert]::FromBase64String($blob); $ck.SetValue('WinHttpSettings', $raw, [Microsoft.Win32.RegistryValueKind]::Binary) }
                      $restored = $true
                    }
                    $ck.Close()
                  }
                  return $restored
                }

                """, name)
        }
        let restore = try part(of: try XCTUnwrap(recipes["clearSystemProxy"]), from: "function AlcoveRestore($state, $hkcu, $hklm) {", to: "  $key.Close()")
        assertOrder(restore, "'ProxyEnable'", "AlcoveRestoreText $key 'ProxyServer'")
        assertOrder(restore, "AlcoveRestoreText $key 'ProxyOverride'", "AlcoveRestoreText $key 'ProxyServer'")
        assertOrder(restore, "AlcoveRestoreText $key 'AutoConfigURL'", "AlcoveRestoreText $key 'ProxyServer'")
        XCTAssertTrue(restore.hasSuffix("AlcoveRestoreText $key 'ProxyServer' (AlcoveSafe $state.proxyServer) $state.proxyServerKind\n    $restored = $true\n  }\n"), restore)
        let kinds = try part(of: try XCTUnwrap(recipes["setSystemProxy"]), from: "function AlcoveKindName($key, $name) {", to: "function AlcoveWriteState")
        XCTAssertEqual(kinds, """
            function AlcoveKindName($key, $name) {
              if ($null -eq $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) { return $null }
              $kind = $key.GetValueKind($name)
              if ($kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) { return 'ExpandString' }
              if ($kind -eq [Microsoft.Win32.RegistryValueKind]::DWord) { return 'DWord' }
              return 'String'
            }

            """)
        XCTAssertTrue(try XCTUnwrap(recipes["clearSystemProxy"]).contains(
            "function AlcoveKindText($name) { foreach ($known in 'String', 'ExpandString', 'DWord') { if ($name -ceq $known) { return $known } }; return $null }\n"))

        let clear = try XCTUnwrap(recipes["clearSystemProxy"])
        let body = try part(of: try mainPart(of: clear), from: "  $state = AlcoveState\n", to: "} catch {")
        XCTAssertEqual(body, """
              $state = AlcoveState
              if ($state -is [string]) { [Console]::Error.WriteLine('\(GuestRecipes.unreadableProxyState)'); exit 2 }
              if ($state) {
                $had = $true
                $thumb = ([string]$state.thumbprint).ToUpper()
                if ($state.systemProxy) { $restored = AlcoveRestore $state $hkcu $hklm }
                [System.IO.File]::Delete($statePath)
              }
              if ([System.IO.File]::Exists($statePath + '.new')) { [System.IO.File]::Delete($statePath + '.new') }
              if ($restored) { $refreshed = AlcoveRefresh }

            """)
        XCTAssertTrue(clear.hasSuffix("'{\"state\":' + (AlcoveBool $had) + ',\"restored\":' + (AlcoveBool $restored) + ',\"thumbprint\":\"' + $thumb"
                                      + " + '\",\"refreshed\":' + (AlcoveBool $refreshed) + '}'"), clear)
    }

    func testAnUnreadableStateFileIsRefusedAndKept() throws {
        XCTAssertEqual(GuestRecipes.unreadableProxyState, "the stored proxy settings in C:\\ProgramData\\Alcove\\proxy-previous.json cannot be read; "
                       + "put the proxy settings right by hand, delete that file and call vm.http.stop again")
        let recipes = try windowsRecipes()
        let refusal = "  $state = AlcoveState\n  if ($state -is [string]) { [Console]::Error.WriteLine('\(GuestRecipes.unreadableProxyState)'); exit 2 }\n"
        let reader = """
            function AlcoveState {
              if (-not [System.IO.File]::Exists($statePath)) { return $null }
              $text = $null
              foreach ($attempt in 1, 2, 3) {
                try { $text = [System.IO.File]::ReadAllText($statePath); break } catch { Start-Sleep -Milliseconds 200 }
              }
              if (($null -eq $text) -and (-not [System.IO.File]::Exists($statePath))) { return $null }
              $s = $null
              try { $s = ConvertFrom-Json $text } catch { $s = $null }
              if (($s -is [System.Management.Automation.PSCustomObject]) -and ([string]$s.version -ceq '1') -and ([string]$s.thumbprint -match '^[0-9A-Fa-f]{40}\\z') -and ([string]$s.port -match '^[1-9][0-9]{0,4}\\z') -and ($s.systemProxy -is [bool])) {
                if ([int]$s.port -le 65535) { return $s }
              }
              return 'unreadable'
            }

            """
        for name in ["installProxyCA", "setSystemProxy", "setSystemProxy(record)", "clearSystemProxy"] {
            let script = try XCTUnwrap(recipes[name])
            XCTAssertTrue(script.contains(reader), name)
            let main = try mainPart(of: script)
            XCTAssertTrue(main.contains(refusal), name)
            XCTAssertEqual(count("AlcoveState\n", in: main), 1, name)
            for touching in ["CreateSubKey(", "OpenSubKey(", "$store.Remove(", "AlcoveWriteState $json", "::Delete(", "AlcoveRestore $state", "SetValue(",
                             "DeleteValue(", "& $netsh", "SetAccessControl(", "AlcoveRoot 'ReadWrite'", "$store.Add("] where main.contains(touching) {
                assertOrder(main, refusal, touching)
            }
        }
        XCTAssertTrue(try mainPart(of: try XCTUnwrap(recipes["installProxyCA"])).contains("  $state = AlcoveState\n"))
        let read = try XCTUnwrap(recipes["readSystemProxy"])
        XCTAssertTrue(read.contains(reader), read)
        XCTAssertTrue(read.contains("  $state = AlcoveState\n  if ($state -is [string]) {\n    $unreadable = $true\n  } elseif ($state) {\n"), read)
    }

    func testReadSystemProxyChangesNothing() throws {
        let recipes = try windowsRecipes()
        let read = try XCTUnwrap(recipes["readSystemProxy"])
        for write in ["SetValue(", "DeleteValue(", "::Delete(", "WriteAllText(", "::Replace(", "::Move(", "$store.Add(", "$store.Remove(", "CreateSubKey(",
                      "netsh", "AlcoveRestore", "AlcoveWriteState", "OpenSubKey($conn, $true)", "ReadWrite"] {
            XCTAssertFalse(read.contains(write), write)
        }
        XCTAssertTrue(read.contains("AlcoveRoot 'ReadOnly'"), read)
        XCTAssertTrue(read.contains("foreach ($thumb in $thumbs) { if ($store.Certificates.Find($byThumbprint, $thumb, $false).Count -gt 0) { $caInStore = $true } }"), read)
        XCTAssertTrue(read.hasSuffix("'{\"previous\":' + (AlcoveBool $previous) + ',\"previousUnreadable\":' + (AlcoveBool $unreadable) + ',\"previousPort\":' "
                                     + "+ $previousPort + ',\"previousSystemProxy\":' + (AlcoveBool $previousSystem) + ',\"caFile\":' + (AlcoveBool $caFile) + "
                                     + "',\"caInStore\":' + (AlcoveBool $caInStore) + ',\"wininetEnabled\":' + (AlcoveBool $enabled) + ',\"wininetServer\":\"' + "
                                     + "[Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($server)) + '\",\"winhttpPort\":' + $winhttpPort + '}'"), read)
        for (name, script) in recipes where !name.hasPrefix("installProxyCA") && !name.hasPrefix("removeProxyCA") {
            XCTAssertTrue(script.contains("[Microsoft.Win32.RegistryView]::Registry64"), name)
        }
    }

    func testProxyRecipesByGuestOS() {
        XCTAssertNil(GuestRecipes.setSystemProxy(port: 1, thumbprint: caThumbprint, apply: true, os: .linux))
        XCTAssertNil(GuestRecipes.setSystemProxy(port: 1, thumbprint: caThumbprint, apply: false, os: .linux))
        XCTAssertNil(GuestRecipes.clearSystemProxy(os: .linux))
        for os in [VMConfig.GuestOS.windows, .linux] {
            XCTAssertNotNil(GuestRecipes.installProxyCA(thumbprint: caThumbprint, os: os))
            XCTAssertNotNil(GuestRecipes.removeProxyCA(thumbprint: nil, os: os))
            XCTAssertNotNil(GuestRecipes.readSystemProxy(os: os))
        }
        XCTAssertNil(GuestRecipes.installProxyCA(thumbprint: caThumbprint, os: .other))
        XCTAssertNil(GuestRecipes.removeProxyCA(thumbprint: nil, os: .other))
        XCTAssertNil(GuestRecipes.setSystemProxy(port: 1, thumbprint: caThumbprint, apply: true, os: .other))
        XCTAssertNil(GuestRecipes.clearSystemProxy(os: .other))
        XCTAssertNil(GuestRecipes.readSystemProxy(os: .other))
        XCTAssertNil(GuestRecipes.proxyCAPath(os: .other))
    }

    func testLinuxProxyRecipesAreValidShell() throws {
        let scripts = [try XCTUnwrap(GuestRecipes.installProxyCA(thumbprint: caThumbprint, os: .linux)),
                       try XCTUnwrap(GuestRecipes.removeProxyCA(thumbprint: nil, os: .linux)),
                       try XCTUnwrap(GuestRecipes.readSystemProxy(os: .linux))]
        XCTAssertEqual(GuestRecipes.linuxProxyCAAsidePath, "/usr/local/share/alcove-proxy.crt.removing")
        for script in scripts.dropFirst() {
            XCTAssertTrue(script.contains("=/usr/local/share/alcove-proxy.crt.removing\n"), script)
            XCTAssertFalse(script.contains("$ca.removing"), script)
        }
        for script in scripts {
            XCTAssertTrue(script.contains("/usr/local/share/ca-certificates/alcove-proxy.crt"), script)
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/bin/sh")
            check.arguments = ["-n", "-c", script]
            check.standardOutput = FileHandle.nullDevice
            check.standardError = FileHandle.nullDevice
            try check.run()
            check.waitUntilExit()
            XCTAssertEqual(check.terminationStatus, 0, script)
        }
    }

    /// Runs `script` with `/bin/sh`, with `caPath` and `asidePath` in place of the Linux CA path and its aside path, and
    /// `bin` first on the PATH.
    private func runShell(_ script: String, caPath: String, asidePath: String, bin: URL) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script.replacingOccurrences(of: GuestRecipes.linuxProxyCAAsidePath, with: asidePath)
                                .replacingOccurrences(of: GuestRecipes.linuxProxyCAPath, with: caPath)]
        process.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let printed = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: printed, as: UTF8.self), String(decoding: errors, as: UTF8.self))
    }

    func testLinuxRemovalKeepsTheCAAsideUntilTheBundleIsRefreshed() throws {
        let dir = try tempDir()
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let calls = dir.appendingPathComponent("calls").path
        let fail = dir.appendingPathComponent("fail").path
        let stub = bin.appendingPathComponent("update-ca-certificates").path
        try "#!/bin/sh\necho \"$*\" >> '\(calls)'\nif [ -e '\(fail)' ]; then rm -f '\(fail)'; exit 1; fi\nexit 0\n"
            .write(toFile: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
        let store = dir.appendingPathComponent("ca-certificates")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let ca = store.appendingPathComponent("alcove-proxy.crt").path
        let aside = dir.appendingPathComponent("alcove-proxy.crt.removing").path
        let remove = try XCTUnwrap(GuestRecipes.removeProxyCA(thumbprint: nil, os: .linux))
        let read = try XCTUnwrap(GuestRecipes.readSystemProxy(os: .linux))
        let files = FileManager.default
        func refreshes() -> [String] { ((try? String(contentsOfFile: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

        try "pem".write(toFile: ca, atomically: true, encoding: .utf8)
        try "".write(toFile: fail, atomically: true, encoding: .utf8)
        let failed = try runShell(remove, caPath: ca, asidePath: aside, bin: bin)
        XCTAssertEqual(failed.status, 2)
        XCTAssertEqual(failed.stdout, "")
        XCTAssertEqual(failed.stderr, "update-ca-certificates --fresh failed in the guest, so the guest still trusts the proxy CA; "
                       + "run it with vm.exec to see why, then call vm.http.stop again\n")
        XCTAssertFalse(files.fileExists(atPath: ca))
        XCTAssertTrue(files.fileExists(atPath: aside))
        XCTAssertEqual(try files.contentsOfDirectory(atPath: store.path), [])
        XCTAssertEqual(try runShell(read, caPath: ca, asidePath: aside, bin: bin).stdout, "{\"caFile\":true,\"caRemoving\":true}\n")

        let retried = try runShell(remove, caPath: ca, asidePath: aside, bin: bin)
        XCTAssertEqual(retried.status, 0)
        XCTAssertEqual(retried.stdout, "{\"removed\":true,\"fileRemoved\":true}\n")
        XCTAssertEqual(refreshes(), ["--fresh", "--fresh"])
        XCTAssertFalse(files.fileExists(atPath: aside))
        XCTAssertEqual(try runShell(read, caPath: ca, asidePath: aside, bin: bin).stdout, "{\"caFile\":false,\"caRemoving\":false}\n")

        let idle = try runShell(remove, caPath: ca, asidePath: aside, bin: bin)
        XCTAssertEqual(idle.stdout, "{\"removed\":false,\"fileRemoved\":false}\n")
        XCTAssertEqual(refreshes().count, 2)

        try "pem".write(toFile: ca, atomically: true, encoding: .utf8)
        try "old".write(toFile: aside, atomically: true, encoding: .utf8)
        XCTAssertEqual(try runShell(read, caPath: ca, asidePath: aside, bin: bin).stdout, "{\"caFile\":true,\"caRemoving\":true}\n")
        let both = try runShell(remove, caPath: ca, asidePath: aside, bin: bin)
        XCTAssertEqual(both.stdout, "{\"removed\":true,\"fileRemoved\":true}\n")
        XCTAssertEqual(refreshes().count, 3)
        XCTAssertFalse(files.fileExists(atPath: ca))
        XCTAssertFalse(files.fileExists(atPath: aside))

        let script = remove
        assertOrder(script, "mv -f \"$ca\" \"$gone\"", "update-ca-certificates --fresh")
        assertOrder(script, "update-ca-certificates --fresh", "rm -f \"$gone\"")
        XCTAssertFalse(script.contains("rm -f \"$ca\""), script)
    }

    func testOtherGuestOSStartsWithoutGuestSteps() async throws {
        let c = try await capture(os: .other)
        let r = try await c.start()
        XCTAssertEqual(c.log.entries, ["proxy.start", "proxy.config"])
        XCTAssertEqual(r["caInstalled"]?.boolValue, false)
        XCTAssertEqual(r["systemProxySet"]?.boolValue, false)
        XCTAssertTrue(r["warning"]?.stringValue?.contains("Alcove has no recipe for this guest OS") == true)
        XCTAssertNil(c.journal.entry(for: "Win"))
    }
}
