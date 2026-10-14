import XCTest
import CryptoKit
@testable import AlcoveControl
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

/// What the fake proxy and the fake agent were asked to do, in the order it happened.
final class CaptureJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func clear() { lock.lock(); items.removeAll(); lock.unlock() }
}

/// A scripted proxy: records its calls in a journal and answers from `replies`.
final class FakeProxy: ProxyControlling, @unchecked Sendable {
    let journal: CaptureJournal
    let port: Int
    let caPath: String
    private let lock = NSLock()
    private var recorded: [(op: String, params: [String: JSON])] = []
    private var answers: [String: JSON] = [:]
    private var errors: [String: Error] = [:]
    private var startFailure: Error?
    private var stops = 0
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init(journal: CaptureJournal, port: Int, caPath: String) {
        self.journal = journal
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
        journal.add("proxy.start")
        if let failure = lock.withLock({ startFailure }) { throw failure }
        return (port, caPath)
    }

    func call(_ op: String, _ params: [String: JSON]) async throws -> JSON {
        journal.add("proxy.\(op)")
        let (failure, answer) = lock.withLock { () -> (Error?, JSON) in
            recorded.append((op, params))
            return (errors[op], answers[op] ?? [:])
        }
        if let failure { throw failure }
        return answer
    }

    func stop() async {
        journal.add("proxy.stop")
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            stops += 1
            defer { stopWaiters.removeAll() }
            return stopWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Returns once `stop` has been called.
    func stopped() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            lock.lock()
            if stops > 0 { lock.unlock(); waiter.resume(); return }
            stopWaiters.append(waiter)
            lock.unlock()
        }
    }
}

/// Hands out one new `FakeProxy` per capture, with ports counting up from 49152.
final class FakeProxyFactory: @unchecked Sendable {
    let journal: CaptureJournal
    let caPath: String
    private let lock = NSLock()
    private var proxies: [FakeProxy] = []
    var startFailure: Error?

    init(journal: CaptureJournal, caPath: String) {
        self.journal = journal
        self.caPath = caPath
    }

    var made: [FakeProxy] { lock.lock(); defer { lock.unlock() }; return proxies }
    var latest: FakeProxy { made[made.count - 1] }

    func make() -> FakeProxy {
        lock.lock(); defer { lock.unlock() }
        let proxy = FakeProxy(journal: journal, port: 49152 + proxies.count, caPath: caPath)
        if let startFailure { proxy.failStart(startFailure) }
        proxies.append(proxy)
        return proxy
    }
}

private let caBody = Data("alcove test certificate authority".utf8)
private let caPEM = "-----BEGIN CERTIFICATE-----\n\(caBody.base64EncodedString())\n-----END CERTIFICATE-----\n"
private let caThumbprint = Insecure.SHA1.hash(data: caBody).map { String(format: "%02X", $0) }.joined()
private let otherThumbprint = String(repeating: "AB", count: 20)
private let noStaleProxy = "{\"restored\":false,\"cleared\":false,\"thumbprint\":\"\",\"refreshed\":false}"
private let cleanGuest = "{\"previous\":false,\"previousPort\":0,\"caFile\":false,\"caInStore\":false,\"wininetEnabled\":false,\"wininetServer\":\"\",\"winhttpPort\":0}"

private func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

/// A handler over the running VM "Win", its fake agent and the proxies the handler makes.
private struct Capture {
    let h: ControlHandler
    let t: FakeTarget
    let agent: FakeAgent
    let fs: FakeFS
    let factory: FakeProxyFactory
    let journal: CaptureJournal
    /// What a recipe prints, by journal name; a recipe without an entry prints its default.
    let outputs: LockedBox<[String: String]>
    /// The recipes that exit with 2 and this sentence on stderr, by journal name.
    let failures: LockedBox<[String: String]>
    let launches: LockedBox<[JSON]>

    func start(_ params: [String: JSON] = [:]) async throws -> JSON {
        var all = params
        all["name"] = "Win"
        return try await h.handle(op: "vm.http.start", params: .object(all))
    }

    func failure(_ op: String, _ params: JSON = ["name": "Win"]) async -> String {
        do { _ = try await h.handle(op: op, params: params); return "no error" } catch { return "\(error)" }
    }
}

final class ControlHTTPTests: XCTestCase {
    override func setUp() {
        HTTPTiming.vmPoll = .milliseconds(20)
        HTTPTiming.toolsWait = .milliseconds(50)
        HTTPTiming.staleToolsWait = .milliseconds(50)
    }

    override func tearDown() {
        HTTPTiming.vmPoll = .seconds(2)
        HTTPTiming.toolsWait = .seconds(25)
        HTTPTiming.staleToolsWait = .seconds(5)
    }

    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("control-http-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The journal name of a recipe script; `recipe.other` for a script that is none of the capture's recipes.
    private static func recipeName(_ script: String, os: VMConfig.GuestOS) -> String {
        if script == GuestRecipes.installProxyCA(thumbprint: caThumbprint, os: os) { return "recipe.installCA" }
        if script == GuestRecipes.clearSystemProxy(os: os) { return "recipe.clearProxy" }
        if script == GuestRecipes.readSystemProxy(os: os) { return "recipe.readProxy" }
        if script == GuestRecipes.removeProxyCA(thumbprint: caThumbprint, os: os) { return "recipe.removeCA" }
        if script == GuestRecipes.removeProxyCA(thumbprint: otherThumbprint, os: os) { return "recipe.removeCA(other)" }
        if script == GuestRecipes.removeProxyCA(thumbprint: nil, os: os) { return "recipe.removeCA(file)" }
        for port in 49152..<49156 where script == GuestRecipes.setSystemProxy(port: port, thumbprint: caThumbprint, os: os) {
            return "recipe.setProxy(\(port))"
        }
        return "recipe.other"
    }

    private static let defaultOutputs: [String: String] = [
        "recipe.installCA": "{\"installed\":true,\"added\":true}",
        "recipe.clearProxy": noStaleProxy,
        "recipe.readProxy": cleanGuest,
        "recipe.removeCA": "{\"removed\":true,\"fileRemoved\":true}",
        "recipe.removeCA(other)": "{\"removed\":true,\"fileRemoved\":false}",
        "recipe.removeCA(file)": "{\"removed\":false,\"fileRemoved\":false}",
        "recipe.other": "{\"user\":\"alcove\",\"locked\":false,\"freeBytes\":40000000000,\"utc\":\"2027-01-15T08:00:00Z\",\"dns\":true,\"scale\":100}",
    ]

    private func capture(os: VMConfig.GuestOS = .windows, connected: Bool = true, caps: [String]? = nil,
                         makeProxy: (@Sendable () -> ProxyControlling)? = nil) async throws -> Capture {
        let dir = try tempDir()
        let caPath = dir.appendingPathComponent("ca.pem").path
        try Data(caPEM.utf8).write(to: URL(fileURLWithPath: caPath))
        let journal = CaptureJournal()
        let factory = FakeProxyFactory(journal: journal, caPath: caPath)
        let outputs = LockedBox<[String: String]>([:])
        let failures = LockedBox<[String: String]>([:])
        let launches = LockedBox<[JSON]>([])
        let fs = FakeFS()
        let agent = FakeAgent()
        if let caps { agent.caps = caps }
        fs.install(on: agent)
        let files = agent.handler
        agent.handler = { m, a in
            guard m["t"]?.stringValue == "req" else { return [] }
            switch m["op"]?.stringValue {
            case "exec.run":
                let name = ControlHTTPTests.recipeName(m["cmd"]?.stringValue ?? "", os: os)
                journal.add(name)
                if let sentence = failures.value[name] {
                    return [agentReply(m, ["code": 2, "stdout": "", "stderr": .string(sentence + "\r\n"), "timed_out": false])]
                }
                let printed = outputs.value[name] ?? ControlHTTPTests.defaultOutputs[name]
                    ?? "{\"set\":true,\"keptPrevious\":false,\"winhttp\":true,\"refreshed\":true}"
                return [agentReply(m, ["code": 0, "stdout": .string(printed + "\r\n"), "stderr": "", "timed_out": false])]
            case "app.launch":
                launches.value = launches.value + [m]
                return [agentReply(m, ["pid": 4242])]
            case "fs.rename":
                journal.add("push \(m["to"]?.stringValue ?? "")")
                return files?(m, a) ?? []
            default:
                return files?(m, a) ?? []
            }
        }
        _ = agent.start()
        addTeardownBlock { agent.stop() }
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 800, height: 600))
        await t.setOS(os)
        if connected {
            let client = AgentClient()
            try await client.connect(port: agent.port, expectedToken: nil)
            await t.setAgent(client)
        }
        let now = ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", now: { now },
                               makeProxy: makeProxy ?? { factory.make() })
        return Capture(h: h, t: t, agent: agent, fs: fs, factory: factory, journal: journal, outputs: outputs, failures: failures, launches: launches)
    }

    private func check(_ doctor: JSON, _ id: String) -> JSON? {
        doctor["checks"]?.arrayValue?.first { $0["id"]?.stringValue == id }
    }

    // MARK: - vm.http.start

    func testStartInstallsCAAndSetsProxy() async throws {
        let c = try await capture()
        let r = try await c.start(["hosts": ["api.example.com", "*.corp.net"], "secrets": true, "bodies": false])
        XCTAssertEqual(c.journal.entries, ["proxy.start", "proxy.config", "push \(GuestRecipes.windowsProxyCAPath)",
                                           "recipe.installCA", "recipe.setProxy(49152)"])
        XCTAssertEqual(c.factory.latest.params(of: "config"), ["hosts": ["api.example.com", "*.corp.net"], "secrets": true, "bodies": false])
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

    func testStartSendsOnlyTheGivenConfig() async throws {
        let c = try await capture()
        _ = try await c.start()
        XCTAssertEqual(c.factory.latest.params(of: "config"), [:])
    }

    func testStartWithoutSystemProxy() async throws {
        let c = try await capture()
        let r = try await c.start(["systemProxy": false])
        XCTAssertEqual(c.journal.entries, ["proxy.start", "proxy.config", "recipe.clearProxy", "push \(GuestRecipes.windowsProxyCAPath)",
                                           "recipe.installCA"])
        XCTAssertEqual(r["caInstalled"]?.boolValue, true)
        XCTAssertEqual(r["systemProxySet"]?.boolValue, false)
        XCTAssertEqual(r["guestCAPath"]?.stringValue, GuestRecipes.windowsProxyCAPath)
        XCTAssertEqual(r["env"]?["HTTPS_PROXY"]?.stringValue, "http://10.0.2.2:49152")
        XCTAssertNil(r["warning"])

        c.journal.clear()
        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(c.journal.entries, ["proxy.list", "recipe.removeCA", "proxy.stop"])
    }

    func testStartWithoutSystemProxyRemovesTheCAOfAnEarlierCapture() async throws {
        let c = try await capture()
        c.outputs.value["recipe.clearProxy"] = "{\"restored\":true,\"cleared\":false,\"thumbprint\":\"\(otherThumbprint)\",\"refreshed\":true}"
        _ = try await c.start(["systemProxy": false])
        XCTAssertEqual(c.journal.entries, ["proxy.start", "proxy.config", "recipe.clearProxy", "recipe.removeCA(other)",
                                           "push \(GuestRecipes.windowsProxyCAPath)", "recipe.installCA"])
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
        XCTAssertEqual(c.journal.entries, [])
    }

    func testStartWithoutToolsRefusesUnlessSystemProxyIsOff() async throws {
        let c = try await capture(connected: false)
        let refused = await c.failure("vm.http.start")
        XCTAssertEqual(refused, "guest tools are not connected in 'Win', and vm.http.start needs them to install the CA certificate and set "
                       + "the system proxy; install alcove-agent in the guest, or pass systemProxy: false")
        XCTAssertEqual(c.journal.entries, [])

        let r = try await c.start(["systemProxy": false])
        XCTAssertEqual(c.journal.entries, ["proxy.start", "proxy.config"])
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
    }

    func testStartNeedsToolsThatRunCommands() async throws {
        let c = try await capture(caps: ["clipboard", "files"])
        let refused = await c.failure("vm.http.start")
        XCTAssertEqual(refused, "guest tools in 'Win' do not allow running commands, and vm.http.start needs them to install the CA certificate "
                       + "and set the system proxy; start alcove-agent with --allow-exec, or pass systemProxy: false")
    }

    func testStartOnAPausedVMIsRefused() async throws {
        let c = try await capture()
        await c.t.setState(.paused)
        let refused = await c.failure("vm.http.start")
        XCTAssertEqual(refused, "VM 'Win' is paused; call vm.resume first")
        XCTAssertEqual(c.journal.entries, [])
    }

    func testStartUndoesTheGuestStepsWhenTheProxyRecipeFails() async throws {
        let c = try await capture()
        c.failures.value["recipe.setProxy(49152)"] = "could not set the system proxy of the guest: Access is denied.; check that alcove-agent runs elevated, or call vm.http.start with systemProxy false"
        let text = await c.failure("vm.http.start")
        XCTAssertEqual(text, "could not set the system proxy of the guest: Access is denied.; check that alcove-agent runs elevated, or call vm.http.start with systemProxy false")
        XCTAssertEqual(c.journal.entries, ["proxy.start", "proxy.config", "push \(GuestRecipes.windowsProxyCAPath)", "recipe.installCA",
                                           "recipe.setProxy(49152)", "recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
        let after = await c.failure("vm.http.requests")
        XCTAssertEqual(after, "'Win' is not capturing; call vm.http.start first")
    }

    func testStartStopsTheProxyWhenTheCARecipeFails() async throws {
        let c = try await capture()
        c.failures.value["recipe.installCA"] = "could not install the proxy CA in the guest: Access is denied.; check that alcove-agent runs elevated"
        let text = await c.failure("vm.http.start")
        XCTAssertEqual(text, "could not install the proxy CA in the guest: Access is denied.; check that alcove-agent runs elevated")
        XCTAssertEqual(c.journal.entries, ["proxy.start", "proxy.config", "push \(GuestRecipes.windowsProxyCAPath)", "recipe.installCA",
                                           "recipe.removeCA", "proxy.stop"])
    }

    func testStartReportsWhatTheProxyRecipeCouldNotDo() async throws {
        let c = try await capture()
        c.outputs.value["recipe.setProxy(49152)"] = "{\"set\":true,\"keptPrevious\":true,\"winhttp\":false,\"refreshed\":false}"
        let r = try await c.start()
        XCTAssertEqual(r["systemProxySet"]?.boolValue, true)
        XCTAssertEqual(r["warning"]?.stringValue, "netsh could not set the WinHTTP proxy, so services and apps that use WinHTTP are not captured; "
                       + "run 'netsh winhttp show proxy' with vm.exec to see why; "
                       + "running apps were not told about the new proxy; restart the apps you want to capture")
    }

    func testStartOnLinuxInstallsTheCAAndSetsNoSystemProxy() async throws {
        let c = try await capture(os: .linux)
        c.outputs.value["recipe.installCA"] = "{\"installed\":true,\"bundle\":\"/etc/ssl/certs/ca-certificates.crt\"}"
        let r = try await c.start()
        XCTAssertEqual(c.journal.entries, ["proxy.start", "proxy.config", "push \(GuestRecipes.linuxProxyCAPath)", "recipe.installCA"])
        XCTAssertEqual(r["caInstalled"]?.boolValue, true)
        XCTAssertEqual(r["systemProxySet"]?.boolValue, false)
        XCTAssertEqual(r["guestCAPath"]?.stringValue, "/usr/local/share/ca-certificates/alcove-proxy.crt")
        XCTAssertEqual(r["env"]?["NODE_EXTRA_CA_CERTS"]?.stringValue, "/usr/local/share/ca-certificates/alcove-proxy.crt")
        XCTAssertEqual(r["env"]?["SSL_CERT_FILE"]?.stringValue, "/etc/ssl/certs/ca-certificates.crt")
        XCTAssertEqual(r["env"]?["REQUESTS_CA_BUNDLE"]?.stringValue, "/etc/ssl/certs/ca-certificates.crt")
        XCTAssertNil(r["warning"])

        c.journal.clear()
        _ = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(c.journal.entries, ["proxy.list", "recipe.removeCA", "proxy.stop"])
    }

    func testMissingProxyBinary() async throws {
        let dir = try tempDir()
        let c = try await capture(makeProxy: { ProxyProcess(executable: nil, caDirectory: dir) })
        let text = await c.failure("vm.http.start")
        XCTAssertEqual(text, "alcove-proxy was not found; build it with scripts/test/all.sh or set ALCOVE_PROXY")
        XCTAssertEqual(c.journal.entries, [])
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
    }

    // MARK: - vm.http.stop

    func testStopRestoresAndStops() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.factory.latest.reply("list", ["exchanges": [["id": 7]], "next": 7, "pending": []])
        c.journal.clear()
        let r = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(c.journal.entries, ["proxy.list", "recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
        XCTAssertEqual(c.factory.latest.params(of: "list"), ["limit": 1])
        XCTAssertEqual(r["exchanges"]?.intValue, 7)
        XCTAssertNil(r["warning"])
        let after = await c.failure("vm.http.requests")
        XCTAssertEqual(after, "'Win' is not capturing; call vm.http.start first")

        let again = try await c.start()
        XCTAssertEqual(again["proxy"]?.stringValue, "10.0.2.2:49153")
        XCTAssertEqual(c.factory.made.count, 2)
    }

    func testStopEndsTheCaptureWhenTheGuestCannotBeRestored() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.failures.value["recipe.clearProxy"] = "could not restore the proxy settings of the guest: Access is denied.; check that alcove-agent runs elevated, then call vm.http.stop again"
        let r = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(r["warning"]?.stringValue, "could not restore the proxy settings of the guest: Access is denied.; check that alcove-agent runs elevated, then call vm.http.stop again")
        XCTAssertEqual(c.factory.latest.stopCount, 1)
        XCTAssertTrue(c.journal.entries.contains("recipe.removeCA"))
    }

    func testStopWithoutToolsEndsTheCaptureAndSaysWhatIsLeft() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.t.setAgent(nil)
        c.journal.clear()
        let r = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(c.journal.entries, ["proxy.list", "proxy.stop"])
        XCTAssertEqual(r["warning"]?.stringValue, "the guest keeps the capture's proxy settings and CA certificate because its guest tools are not reachable; "
                       + "call vm.http.stop again once vm.status shows tools")
    }

    func testStopWithoutACapture() async throws {
        let c = try await capture()
        let text = await c.failure("vm.http.stop")
        XCTAssertEqual(text, "'Win' is not capturing; call vm.http.start first")
        XCTAssertEqual(c.journal.entries, ["recipe.clearProxy", "recipe.removeCA(file)"])

        let offline = try await capture(connected: false)
        let unreachable = await offline.failure("vm.http.stop")
        XCTAssertEqual(unreachable, "'Win' is not capturing; call vm.http.start first")
        await c.t.setState(.stopped)
        let stopped = await c.failure("vm.http.stop")
        XCTAssertEqual(stopped, "'Win' is not capturing; call vm.http.start first")
    }

    // MARK: - stale state

    func testStaleProxyIsReportedAndCleared() async throws {
        let c = try await capture()
        c.outputs.value["recipe.readProxy"] = "{\"previous\":true,\"previousPort\":50000,\"caFile\":true,\"caInStore\":true,\"wininetEnabled\":true,"
            + "\"wininetServer\":\"\(base64("10.0.2.2:50000"))\",\"winhttpPort\":50000}"
        let doctor = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        let row = try XCTUnwrap(check(doctor, "proxy"))
        XCTAssertEqual(row["ok"]?.boolValue, false)
        XCTAssertEqual(row["detail"]?.stringValue, "no capture is running, but the system proxy points at 10.0.2.2:50000 and "
                       + "the settings from before a capture are still stored and the proxy CA is still installed")
        XCTAssertEqual(row["hint"]?.stringValue, "vm.http.stop clears stale proxy settings")
        XCTAssertEqual(c.journal.entries, ["recipe.other", "recipe.readProxy"])

        c.journal.clear()
        c.outputs.value["recipe.clearProxy"] = "{\"restored\":true,\"cleared\":false,\"thumbprint\":\"\(otherThumbprint.lowercased())\",\"refreshed\":true}"
        let stopped = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(c.journal.entries, ["recipe.clearProxy", "recipe.removeCA(other)"])
        XCTAssertEqual(stopped["exchanges"]?.intValue, 0)
        XCTAssertEqual(stopped["staleCleared"]?.boolValue, true)
        XCTAssertEqual(c.factory.made.count, 0)

        c.outputs.value["recipe.readProxy"] = cleanGuest
        let healthy = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(healthy, "proxy")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(healthy, "proxy")?["detail"]?.stringValue, "no system proxy")
        XCTAssertNil(check(healthy, "proxy")?["hint"])
    }

    func testStaleSettingsWithoutAStateFileAreCleared() async throws {
        let c = try await capture()
        c.outputs.value["recipe.clearProxy"] = "{\"restored\":false,\"cleared\":true,\"thumbprint\":\"\",\"refreshed\":true}"
        let stopped = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(c.journal.entries, ["recipe.clearProxy", "recipe.removeCA(file)"])
        XCTAssertEqual(stopped["staleCleared"]?.boolValue, true)
    }

    func testALeftoverCAAloneIsStale() async throws {
        let c = try await capture()
        c.outputs.value["recipe.readProxy"] = "{\"previous\":false,\"previousPort\":0,\"caFile\":true,\"caInStore\":true,\"wininetEnabled\":false,"
            + "\"wininetServer\":\"\",\"winhttpPort\":0}"
        let doctor = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(doctor, "proxy")?["ok"]?.boolValue, false)
        XCTAssertEqual(check(doctor, "proxy")?["detail"]?.stringValue, "no capture is running, but the proxy CA is still installed")
        c.outputs.value["recipe.removeCA(file)"] = "{\"removed\":true,\"fileRemoved\":true}"
        let stopped = try await c.h.handle(op: "vm.http.stop", params: ["name": "Win"])
        XCTAssertEqual(stopped["staleCleared"]?.boolValue, true)
    }

    func testStaleCleanupFailureIsASentence() async throws {
        let c = try await capture()
        c.failures.value["recipe.clearProxy"] = "could not restore the proxy settings of the guest: Access is denied.; check that alcove-agent runs elevated, then call vm.http.stop again"
        let text = await c.failure("vm.http.stop")
        XCTAssertEqual(text, "could not restore the proxy settings of the guest: Access is denied.; check that alcove-agent runs elevated, then call vm.http.stop again")
    }

    func testStartAfterAHostRestartKeepsThePreviousSettings() async throws {
        let c = try await capture()
        c.outputs.value["recipe.setProxy(49152)"] = "{\"set\":true,\"keptPrevious\":true,\"winhttp\":true,\"refreshed\":true}"
        let r = try await c.start()
        XCTAssertEqual(c.journal.entries, ["proxy.start", "proxy.config", "push \(GuestRecipes.windowsProxyCAPath)", "recipe.installCA",
                                           "recipe.setProxy(49152)"])
        XCTAssertEqual(r["systemProxySet"]?.boolValue, true)
        XCTAssertNil(r["warning"])
    }

    func testDoctorProxyRowWhileCapturing() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.outputs.value["recipe.readProxy"] = "{\"previous\":true,\"previousPort\":49152,\"caFile\":true,\"caInStore\":true,\"wininetEnabled\":true,"
            + "\"wininetServer\":\"\(base64("10.0.2.2:49152"))\",\"winhttpPort\":49152}"
        let live = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(live, "proxy")?["ok"]?.boolValue, true)
        XCTAssertEqual(check(live, "proxy")?["detail"]?.stringValue, "capturing through 10.0.2.2:49152, system proxy set")

        c.outputs.value["recipe.readProxy"] = "{\"previous\":true,\"previousPort\":50000,\"caFile\":true,\"caInStore\":true,\"wininetEnabled\":true,"
            + "\"wininetServer\":\"\(base64("http=10.0.2.2:50000;https=10.0.2.2:50000"))\",\"winhttpPort\":0}"
        let elsewhere = try await c.h.handle(op: "vm.doctor", params: ["name": "Win"])
        XCTAssertEqual(check(elsewhere, "proxy")?["ok"]?.boolValue, false)
        XCTAssertEqual(check(elsewhere, "proxy")?["detail"]?.stringValue, "the system proxy points at 10.0.2.2:50000, but the capture listens on port 49152")
        XCTAssertEqual(check(elsewhere, "proxy")?["hint"]?.stringValue, "call vm.http.stop, then vm.http.start")
    }

    func testDoctorProxyRowNamesAProxyAlcoveDidNotSet() async throws {
        let c = try await capture()
        c.outputs.value["recipe.readProxy"] = "{\"previous\":false,\"previousPort\":0,\"caFile\":false,\"caInStore\":false,\"wininetEnabled\":true,"
            + "\"wininetServer\":\"\(base64("proxy.corp.example:8080"))\",\"winhttpPort\":0}"
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

    func testCapturePortReadsTheFirstAlcoveAddress() {
        XCTAssertEqual(ControlHandler.capturePort(in: "10.0.2.2:49152"), 49152)
        XCTAssertEqual(ControlHandler.capturePort(in: "http=10.0.2.2:8080;https=10.0.2.2:8081"), 8080)
        XCTAssertNil(ControlHandler.capturePort(in: "proxy.corp.example:8080"))
        XCTAssertNil(ControlHandler.capturePort(in: "10.0.2.2:"))
        XCTAssertNil(ControlHandler.capturePort(in: "10.0.2.2:99999"))
        XCTAssertNil(ControlHandler.capturePort(in: ""))
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
        let got = try await c.h.handle(op: "vm.http.request", params: ["name": "Win", "id": 3, "part": "response", "offset": 4, "length": 100])
        XCTAssertEqual(got, part)
        XCTAssertEqual(proxy.params(of: "get"), ["exchange": 3, "part": "response", "offset": 4, "length": 100])
        let missing = await c.failure("vm.http.request", ["name": "Win", "part": "response"])
        XCTAssertEqual(missing, "missing or invalid parameter 'id'")

        proxy.fail("get", ProxyProcess.ProxyError.remote("no exchange with id 9; the store keeps the newest 2000 exchanges and 'clear' removes them all"))
        let gone = await c.failure("vm.http.request", ["name": "Win", "id": 9, "part": "request"])
        XCTAssertEqual(gone, "no exchange with id 9; the store keeps the newest 2000 exchanges and 'clear' removes them all")

        let cleared = try await c.h.handle(op: "vm.http.clear", params: ["name": "Win"])
        XCTAssertNotNil(cleared["eventSeq"])
        XCTAssertEqual(proxy.params(of: "clear"), [:])
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
        _ = try await c.h.handle(op: "vm.http.request", params: ["name": "Win", "id": 1, "part": "request"])
    }

    func testHTTPOpsAreKnownAndRunInRequestOrder() {
        for op in ControlHandler.httpOps {
            XCTAssertTrue(ControlHandler.knownOps.contains(op), op)
            XCTAssertFalse(ControlHandler.isConcurrent(op: op), op)
            XCTAssertFalse(ControlHandler.movesEventBaseline(op: op), op)
            XCTAssertFalse(ControlHandler.capturesFrames(op: op), op)
        }
        XCTAssertEqual(ControlHandler.knownOps.filter { $0.hasPrefix("vm.http.") }.count, ControlHandler.httpOps.count)
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
        c.journal.clear()
        let stopped = try await c.h.handle(op: "vm.stop", params: ["name": "Win"])
        XCTAssertEqual(c.journal.entries, ["recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
        XCTAssertEqual(stopped["captureEnded"]?.boolValue, true)
        XCTAssertEqual(stopped["state"]?.stringValue, "stopped")
        let stopCount = await c.t.stopCount
        XCTAssertEqual(stopCount, 1)

        _ = try await c.h.handle(op: "vm.start", params: ["name": "Win"])
        let after = await c.failure("vm.http.requests")
        XCTAssertEqual(after, "'Win' is not capturing; call vm.http.start first")
        let plain = try await c.h.handle(op: "vm.stop", params: ["name": "Win"])
        XCTAssertNil(plain["captureEnded"])
    }

    func testCaptureEndsWhenTheVMDoesNotStop() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.t.setStopError(ControlHandler.ControlError.failed("the guest ignored the power button"))
        let text = await c.failure("vm.stop")
        XCTAssertEqual(text, "stop failed: the guest ignored the power button")
        XCTAssertEqual(c.factory.latest.stopCount, 1)
        let after = await c.failure("vm.http.requests")
        XCTAssertEqual(after, "'Win' is not capturing; call vm.http.start first")
    }

    func testStopOfAVMThatAlreadyStoppedEndsItsCapture() async throws {
        HTTPTiming.vmPoll = .seconds(3600)
        let c = try await capture()
        _ = try await c.start()
        await c.t.setState(.stopped)
        c.journal.clear()
        let stopped = try await c.h.handle(op: "vm.stop", params: ["name": "Win"])
        XCTAssertEqual(c.journal.entries, ["proxy.stop"])
        XCTAssertEqual(stopped["captureEnded"]?.boolValue, true)
    }

    func testStartOfAVMThatStoppedByItselfEndsItsCapture() async throws {
        HTTPTiming.vmPoll = .seconds(3600)
        let c = try await capture()
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
        c.journal.clear()
        _ = try await c.h.handle(op: "vm.stop", params: ["name": "Win", "force": true])
        XCTAssertEqual(c.journal.entries, ["proxy.stop"])
    }

    func testCaptureEndsWhenTheVMIsFoundStopped() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.t.setState(.stopped)
        await c.factory.latest.stopped()
        XCTAssertEqual(c.factory.latest.stopCount, 1)
        let text = await c.failure("vm.http.requests")
        XCTAssertEqual(text, "VM 'Win' is stopped; call vm.start first")
    }

    func testCaptureEndsWhenTheVMRunsInAnotherEngineProcess() async throws {
        let c = try await capture()
        _ = try await c.start()
        await c.t.setInstance(2)
        await c.factory.latest.stopped()
        XCTAssertEqual(c.factory.latest.stopCount, 1)
        let text = await c.failure("vm.http.requests")
        XCTAssertEqual(text, "'Win' is not capturing; call vm.http.start first")
    }

    func testAnOpThatFindsTheVMStoppedEndsTheCapture() async throws {
        HTTPTiming.vmPoll = .seconds(3600)
        let c = try await capture()
        _ = try await c.start()
        await c.t.setState(.stopped)
        let text = await c.failure("vm.screenshot")
        XCTAssertEqual(text, "VM 'Win' is stopped; call vm.start first")
        XCTAssertEqual(c.factory.latest.stopCount, 1)
    }

    func testSnapshotRestoreEndsTheCapture() async throws {
        let c = try await capture()
        await c.t.setSnapshotList([VMController.SnapshotInfo(name: "clean", vmStateSize: 1, date: Date())])
        _ = try await c.start()
        c.journal.clear()
        let restored = try await c.h.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "clean", "waitTools": 0])
        XCTAssertEqual(restored["captureEnded"]?.boolValue, true)
        XCTAssertNil(restored["staleProxyCleared"])
        XCTAssertEqual(c.journal.entries.filter { $0 != "recipe.other" }, ["proxy.stop"])
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
        c.journal.clear()
        c.outputs.value["recipe.clearProxy"] = "{\"restored\":true,\"cleared\":false,\"thumbprint\":\"\(caThumbprint)\",\"refreshed\":true}"
        let restored = try await c.h.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "mid-capture", "waitTools": 0])
        XCTAssertEqual(restored["staleProxyCleared"]?.boolValue, true)
        XCTAssertNil(restored["captureEnded"])
        XCTAssertEqual(c.journal.entries.filter { $0 != "recipe.other" }, ["recipe.clearProxy", "recipe.removeCA"])

        c.journal.clear()
        let clean = try await c.h.handle(op: "vm.snapshot.restore", params: ["name": "Win", "snapshot": "clean", "waitTools": 0])
        XCTAssertNil(clean["staleProxyCleared"])
        XCTAssertEqual(c.journal.entries.filter { $0 != "recipe.other" }, [])
    }

    func testShutdownRestoresTheGuestsAndEndsEveryCapture() async throws {
        let c = try await capture()
        _ = try await c.start()
        c.journal.clear()
        await c.h.shutdown()
        XCTAssertEqual(c.journal.entries, ["recipe.clearProxy", "recipe.removeCA", "proxy.stop"])
        let after = await c.failure("vm.http.requests")
        XCTAssertEqual(after, "'Win' is not capturing; call vm.http.start first")
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

    func testTraceLineOfARequestHoldsNoSecretHeaderValue() throws {
        let result: JSON = ["headers": [["Authorization", "Bearer abc"]], "body": "ok", "total": 2, "bodyTruncated": false]
        let entry = TraceEntry(seq: 1, time: Date(), ms: 0, op: "vm.http.request", params: ["name": "Win", "id": 1, "part": "request", "lease": "x"],
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
         "setSystemProxy": try XCTUnwrap(GuestRecipes.setSystemProxy(port: 49152, thumbprint: caThumbprint, os: .windows)),
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
            XCTAssertLessThan(script.utf16.count, 12_000, name)
        }
    }

    func testWindowsProxyRecipesCarryTheirParameters() throws {
        let recipes = try windowsRecipes()
        let install = try XCTUnwrap(recipes["installProxyCA"])
        XCTAssertTrue(install.contains("$thumb = '\(caThumbprint)'\n"), install)
        XCTAssertTrue(install.contains("$caPath = 'C:\\ProgramData\\Alcove\\proxy-ca.pem'\n"), install)
        for sid in ["S-1-5-32-544", "S-1-5-18", "S-1-5-32-545"] { XCTAssertTrue(install.contains("'\(sid)'"), sid) }
        XCTAssertTrue(install.contains("[System.Security.AccessControl.FileSystemRights]::Read, $allow"), install)
        XCTAssertTrue(install.contains("$acl.SetAccessRuleProtection($true, $false)"), install)
        XCTAssertTrue(install.contains("[System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine"), install)
        XCTAssertTrue(install.contains("$cert.Thumbprint -ne $thumb"), install)

        let remove = try XCTUnwrap(recipes["removeProxyCA"])
        XCTAssertTrue(remove.contains("$thumb = '\(caThumbprint)'\n"), remove)
        XCTAssertTrue(remove.contains("$store.Certificates.Find($byThumbprint, $thumb, $false)"), remove)
        XCTAssertFalse(remove.contains("FindBySubject"), remove)
        XCTAssertTrue(try XCTUnwrap(recipes["removeProxyCA(file)"]).contains("$thumb = ''\n"))

        let set = try XCTUnwrap(recipes["setSystemProxy"])
        XCTAssertTrue(set.contains("$server = '10.0.2.2:49152'\n$thumb = '\(caThumbprint)'\n"), set)
        XCTAssertTrue(set.contains("'{\"version\":1,\"thumbprint\":\"' + $thumb + '\",\"port\":49152,\"proxyEnable\":' + $enableText"
                                   + " + ',\"proxyServer\":' + (AlcoveField $proxyServer) + ',\"proxyOverride\":' + (AlcoveField $proxyOverride)"
                                   + " + ',\"autoConfigURL\":' + (AlcoveField $autoConfigURL) + ',\"winhttp\":' + (AlcoveField $blob) + '}'"), set)
        XCTAssertTrue(set.contains("$statePath = 'C:\\ProgramData\\Alcove\\proxy-previous.json'\n"), set)
        XCTAssertTrue(set.contains("$key.SetValue('ProxyOverride', '<local>', [Microsoft.Win32.RegistryValueKind]::String)"), set)
        XCTAssertTrue(set.contains("$key.DeleteValue('AutoConfigURL', $false)"), set)
        XCTAssertTrue(set.contains("& $netsh winhttp set proxy ('proxy-server=' + $server) 'bypass-list=<local>' 2>&1"), set)
        XCTAssertTrue(set.contains("InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)"), set)
        XCTAssertTrue(set.contains("InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)"), set)
        XCTAssertTrue(set.contains("    $proxyServer = AlcoveSafe $state.proxyServer\n"), set)
        XCTAssertTrue(set.contains("    $autoConfigURL = $key.GetValue('AutoConfigURL', $null, $asStored)\n"), set)
        let written = try XCTUnwrap(set.range(of: "[System.IO.File]::WriteAllText($statePath, $json)"))
        let applied = try XCTUnwrap(set.range(of: "$key.SetValue('ProxyServer', $server"))
        XCTAssertLessThan(written.lowerBound, applied.lowerBound)

        let clear = try XCTUnwrap(recipes["clearSystemProxy"])
        for name in ["ProxyServer", "ProxyOverride", "AutoConfigURL", "ProxyEnable", "WinHttpSettings"] {
            XCTAssertTrue(clear.contains("DeleteValue('\(name)', $false)"), name)
        }
        XCTAssertTrue(clear.contains("$ck.SetValue('WinHttpSettings', $raw, [Microsoft.Win32.RegistryValueKind]::Binary)"), clear)
        XCTAssertTrue(clear.contains("[System.IO.File]::Delete($statePath)"), clear)

        let read = try XCTUnwrap(recipes["readSystemProxy"])
        for write in ["SetValue(", "DeleteValue(", "::Delete(", "WriteAllText(", "$store.Add(", "$store.Remove(", "CreateSubKey(", "netsh"] {
            XCTAssertFalse(read.contains(write), write)
        }
        XCTAssertTrue(read.contains("AlcoveRoot 'ReadOnly'"), read)
        for (name, script) in recipes where name != "installProxyCA" && name != "removeProxyCA" && name != "removeProxyCA(file)" {
            XCTAssertTrue(script.contains("[Microsoft.Win32.RegistryView]::Registry64"), name)
        }
    }

    func testProxyRecipesByGuestOS() {
        XCTAssertNil(GuestRecipes.setSystemProxy(port: 1, thumbprint: caThumbprint, os: .linux))
        XCTAssertNil(GuestRecipes.clearSystemProxy(os: .linux))
        for os in [VMConfig.GuestOS.windows, .linux] {
            XCTAssertNotNil(GuestRecipes.installProxyCA(thumbprint: caThumbprint, os: os))
            XCTAssertNotNil(GuestRecipes.removeProxyCA(thumbprint: nil, os: os))
            XCTAssertNotNil(GuestRecipes.readSystemProxy(os: os))
        }
        XCTAssertNil(GuestRecipes.installProxyCA(thumbprint: caThumbprint, os: .other))
        XCTAssertNil(GuestRecipes.removeProxyCA(thumbprint: nil, os: .other))
        XCTAssertNil(GuestRecipes.setSystemProxy(port: 1, thumbprint: caThumbprint, os: .other))
        XCTAssertNil(GuestRecipes.clearSystemProxy(os: .other))
        XCTAssertNil(GuestRecipes.readSystemProxy(os: .other))
        XCTAssertNil(GuestRecipes.proxyCAPath(os: .other))
    }

    func testLinuxProxyRecipesAreValidShell() throws {
        let scripts = [try XCTUnwrap(GuestRecipes.installProxyCA(thumbprint: caThumbprint, os: .linux)),
                       try XCTUnwrap(GuestRecipes.removeProxyCA(thumbprint: nil, os: .linux)),
                       try XCTUnwrap(GuestRecipes.readSystemProxy(os: .linux))]
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

    func testOtherGuestOSStartsWithoutGuestSteps() async throws {
        let c = try await capture(os: .other)
        let r = try await c.start()
        XCTAssertEqual(c.journal.entries, ["proxy.start", "proxy.config"])
        XCTAssertEqual(r["caInstalled"]?.boolValue, false)
        XCTAssertEqual(r["systemProxySet"]?.boolValue, false)
        XCTAssertTrue(r["warning"]?.stringValue?.contains("Alcove has no recipe for this guest OS") == true)
    }
}

/// The sentence `body` fails with; `no error` when it does not fail.
private func proxyFailure(_ body: @Sendable () async throws -> Void) async -> String {
    do { try await body(); return "no error" } catch { return "\(error)" }
}

/// `ProxyProcess` against stand-in scripts and against the `alcove-proxy` built from this repository.
final class ProxyProcessTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("proxy-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// An executable `/bin/sh` script with `body`, and the directory to pass as the CA directory.
    private func standIn(_ body: String) throws -> (path: String, dir: URL) {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("stand-in.sh").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(("#!/bin/sh\n" + body + "\n").utf8), attributes: [.posixPermissions: 0o755]))
        return (path, dir)
    }

    private static let ready = "printf '{\"ev\":\"ready\",\"port\":4321,\"ca\":\"/tmp/ca.pem\"}\\n'"
    /// Reads request lines and answers each with its `id`.
    private static let echo = """
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *'"op":"bad"'*) printf '{"id":%s,"ok":false,"error":"no rule with id 9; run rule.list to see the ids"}\\n' "$id" ;;
            *) printf '{"id":%s,"ok":true,"seen":%s}\\n' "$id" "$id" ;;
          esac
        done
        """

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    func testProxyProcessReadyAndCall() async throws {
        let script = try standIn("echo \"$1 $2\" > \"$2/args\"\n" + Self.ready + "\n" + Self.echo)
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        let started = try await proxy.start()
        XCTAssertEqual(started.port, 4321)
        XCTAssertEqual(started.caPath, "/tmp/ca.pem")
        let args = try String(contentsOf: script.dir.appendingPathComponent("args"), encoding: .utf8)
        XCTAssertEqual(args, "--ca-dir \(script.dir.path)\n")

        let first = try await proxy.call("list", ["limit": 5])
        XCTAssertEqual(first, ["seen": 1])
        async let second = proxy.call("rule.list", [:])
        async let third = proxy.call("clear", [:])
        let answers = try await [second, third].compactMap { $0["seen"]?.intValue }.sorted()
        XCTAssertEqual(answers, [2, 3])

        let refused = await proxyFailure { _ = try await proxy.call("bad", [:]) }
        XCTAssertEqual(refused, "no rule with id 9; run rule.list to see the ids")
        let after = try await proxy.call("list", [:])
        XCTAssertEqual(after, ["seen": 5])

        let pid = try XCTUnwrap(proxy.processIdentifier)
        await proxy.stop()
        XCTAssertFalse(isAlive(pid))
        let stopped = await proxyFailure { _ = try await proxy.call("list", [:]) }
        XCTAssertEqual(stopped, "the capture was stopped; call vm.http.start to capture again")
        await proxy.stop()
    }

    func testProxyProcessExitFailsPendingCalls() async throws {
        let script = try standIn(Self.ready + "\nIFS= read -r line\necho 'the proxy listener stopped: boom' >&2\nexit 3")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        _ = try await proxy.start()
        let expected = "alcove-proxy is not running (it exited with status 3: the proxy listener stopped: boom); call vm.http.stop, then vm.http.start to capture again"
        let pending = await proxyFailure { _ = try await proxy.call("list", [:]) }
        XCTAssertEqual(pending, expected)
        let later = await proxyFailure { _ = try await proxy.call("list", [:]) }
        XCTAssertEqual(later, expected)
        await proxy.stop()
    }

    func testProxyProcessFailsEveryPendingCallWhenTheChildExits() async throws {
        let script = try standIn(Self.ready + "\nIFS= read -r one\nIFS= read -r two\nexit 0")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        _ = try await proxy.start()
        async let first = proxyFailure { _ = try await proxy.call("list", [:]) }
        async let second = proxyFailure { _ = try await proxy.call("rule.list", [:]) }
        let texts = await [first, second]
        let expected = "alcove-proxy is not running (it exited with status 0); call vm.http.stop, then vm.http.start to capture again"
        XCTAssertEqual(texts, [expected, expected])
    }

    func testProxyProcessWithoutAProgram() async throws {
        let dir = try tempDir()
        for executable in [nil, dir.appendingPathComponent("missing").path] {
            let proxy = ProxyProcess(executable: executable, caDirectory: dir)
            let text = await proxyFailure { _ = try await proxy.start() }
            XCTAssertEqual(text, "alcove-proxy was not found; build it with scripts/test/all.sh or set ALCOVE_PROXY")
            let call = await proxyFailure { _ = try await proxy.call("list", [:]) }
            XCTAssertEqual(call, "alcove-proxy was not found; build it with scripts/test/all.sh or set ALCOVE_PROXY")
            await proxy.stop()
        }
    }

    func testProxyProcessThatExitsBeforeReadySaysWhy() async throws {
        let script = try standIn("echo 'alcove-proxy: cannot listen on 127.0.0.1:0: address in use' >&2\nexit 2")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        let text = await proxyFailure { _ = try await proxy.start() }
        XCTAssertEqual(text, "alcove-proxy did not start: cannot listen on 127.0.0.1:0: address in use")

        let silent = try standIn("exit 5")
        let quiet = ProxyProcess(executable: silent.path, caDirectory: silent.dir)
        let bare = await proxyFailure { _ = try await quiet.start() }
        XCTAssertEqual(bare, "alcove-proxy exited with status 5 before it was ready; run '\(silent.path) --ca-dir \(silent.dir.path)' to see why")
    }

    func testProxyProcessReadyTimeoutEndsTheChild() async throws {
        let script = try standIn("echo $$ > \"$2/pid\"\nexec sleep 600")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir, limits: .init(ready: .milliseconds(300)))
        let text = await proxyFailure { _ = try await proxy.start() }
        XCTAssertEqual(text, "alcove-proxy did not report its port within 0.3 s; run '\(script.path) --ca-dir \(script.dir.path)' to see why")
        let pid = try XCTUnwrap(proxy.processIdentifier)
        await proxy.stop()
        XCTAssertFalse(isAlive(pid))
    }

    func testProxyProcessUnreadableFirstLine() async throws {
        let script = try standIn("echo 'listening'\nexec sleep 600")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        let text = await proxyFailure { _ = try await proxy.start() }
        XCTAssertEqual(text, "alcove-proxy printed a first line Alcove cannot read; build it again with scripts/test/all.sh")
        let pid = try XCTUnwrap(proxy.processIdentifier)
        await proxy.stop()
        XCTAssertFalse(isAlive(pid))
    }

    func testProxyProcessCallTimeout() async throws {
        let script = try standIn(Self.ready + "\nexec sleep 600")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir, limits: .init(call: .milliseconds(200), exit: .milliseconds(100)))
        _ = try await proxy.start()
        let text = await proxyFailure { _ = try await proxy.call("list", [:]) }
        XCTAssertEqual(text, "alcove-proxy did not answer list within 0.2 s; call vm.http.stop, then vm.http.start to capture again")
        await proxy.stop()
    }

    func testProxyProcessStopEndsAChildThatIgnoresItsInputAndSIGTERM() async throws {
        let script = try standIn("trap '' TERM\n" + Self.ready + "\nwhile :; do sleep 1; done")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir, limits: .init(exit: .milliseconds(100)))
        _ = try await proxy.start()
        let pid = try XCTUnwrap(proxy.processIdentifier)
        XCTAssertTrue(isAlive(pid))
        await proxy.stop()
        XCTAssertFalse(isAlive(pid))
    }

    func testProxyProcessStopFailsPendingCalls() async throws {
        let script = try standIn(Self.ready + "\nIFS= read -r line\necho got > \"$2/got\"\nwhile IFS= read -r more; do :; done")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir)
        _ = try await proxy.start()
        async let pending = proxyFailure { _ = try await proxy.call("list", [:]) }
        let marker = script.dir.appendingPathComponent("got").path
        while !FileManager.default.fileExists(atPath: marker) { await Task.yield() }
        await proxy.stop()
        let text = await pending
        XCTAssertEqual(text, "the capture was stopped; call vm.http.start to capture again")
    }

    func testProxyProcessReleasedWithoutStopEndsTheChild() async throws {
        let script = try standIn(Self.ready + "\n" + Self.echo)
        var proxy: ProxyProcess? = ProxyProcess(executable: script.path, caDirectory: script.dir)
        _ = try await proxy?.start()
        let pid = try XCTUnwrap(proxy?.processIdentifier)
        proxy = nil
        var status: Int32 = 0
        while kill(pid, 0) == 0 {
            _ = waitpid(pid, &status, WNOHANG)
            await Task.yield()
        }
        XCTAssertFalse(isAlive(pid))
    }

    func testProxyProcessLongAnswerAndOversizedAnswer() async throws {
        let body = """
            \(Self.ready)
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
              case "$line" in
                *'"op":"big"'*) printf '{"id":%s,"ok":true,"body":"' "$id"; head -c 300000 /dev/zero | tr '\\0' 'x'; printf '"}\\n' ;;
                *'"op":"huge"'*) printf '{"id":%s,"ok":true,"body":"' "$id"; head -c 2000000 /dev/zero | tr '\\0' 'x'; printf '"}\\n' ;;
                *) printf '{"id":%s,"ok":true}\\n' "$id" ;;
              esac
            done
            """
        let script = try standIn(body)
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir, limits: .init(lineBytes: 1 << 20))
        _ = try await proxy.start()
        let big = try await proxy.call("big", [:])
        XCTAssertEqual(big["body"]?.stringValue?.count, 300_000)
        let huge = await proxyFailure { _ = try await proxy.call("huge", [:]) }
        XCTAssertEqual(huge, "alcove-proxy sent an answer larger than 1 MiB; ask for less with limit, offset or length")
        let after = try await proxy.call("list", [:])
        XCTAssertEqual(after, [:])
        let request = await proxyFailure { _ = try await proxy.call("rule.add", ["action": ["body": .string(String(repeating: "y", count: 1 << 20))]]) }
        XCTAssertEqual(request, "the request 'rule.add' is larger than 1 MiB; send less data")
        await proxy.stop()
    }

    func testProxyProcessFailsACallWhoseAnswerOutgrowsTheLimitBeforeItsLineEnds() async throws {
        let script = try standIn(Self.ready + "\nIFS= read -r line\nprintf '{\"id\":1,\"ok\":true,\"body\":\"'\nhead -c 2000000 /dev/zero | tr '\\0' 'x'\nexec sleep 600")
        let proxy = ProxyProcess(executable: script.path, caDirectory: script.dir, limits: .init(call: .seconds(3600), exit: .milliseconds(100), lineBytes: 1 << 20))
        _ = try await proxy.start()
        let text = await proxyFailure { _ = try await proxy.call("get", ["exchange": 1, "part": "response"]) }
        XCTAssertEqual(text, "alcove-proxy sent an answer larger than 1 MiB; ask for less with limit, offset or length")
        await proxy.stop()
    }

    func testProxyProcessAgainstTheRealBinary() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = try tempDir()
        let binary = dir.appendingPathComponent("alcove-proxy").path
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["go", "build", "-o", binary, "./cmd/alcove-proxy"]
        build.currentDirectoryURL = repo.appendingPathComponent("guest-tools")
        let output = Pipe()
        build.standardOutput = output
        build.standardError = output
        do { try build.run() } catch { throw XCTSkip("go is not installed: \(error.localizedDescription)") }
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        build.waitUntilExit()
        if build.terminationStatus == 127 { throw XCTSkip("go is not installed: \(log)") }
        XCTAssertEqual(build.terminationStatus, 0, log)

        let caDir = dir.appendingPathComponent("ca")
        let proxy = ProxyProcess(executable: binary, caDirectory: caDir)
        let started = try await proxy.start()
        XCTAssertTrue((1...65_535).contains(started.port))
        XCTAssertEqual(URL(fileURLWithPath: started.caPath).resolvingSymlinksInPath().path, caDir.appendingPathComponent("ca.pem").resolvingSymlinksInPath().path)
        let pem = try String(contentsOfFile: started.caPath, encoding: .utf8)
        XCTAssertNotNil(ControlHandler.certificateThumbprint(pem: pem))
        let key = try FileManager.default.attributesOfItem(atPath: caDir.appendingPathComponent("ca.key").path)
        XCTAssertEqual((key[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let configured = try await proxy.call("config", ["hosts": ["api.example.com"], "secrets": false, "bodies": true])
        XCTAssertEqual(configured, [:])
        let empty = try await proxy.call("list", ["limit": 1])
        XCTAssertEqual(empty["exchanges"], [])
        XCTAssertEqual(empty["next"]?.intValue, 0)
        XCTAssertEqual(empty["pending"], [])

        let canned = String(repeating: "z", count: 300_000)
        let added = try await proxy.call("rule.add", ["match": ["host": "api.example.com", "path": "/v1/*"],
                                                      "action": ["status": 503, "body": .string(canned), "times": 2]])
        let rule = try XCTUnwrap(added["rule"]?.intValue)
        let listed = try await proxy.call("rule.list", [:])
        let rows = try XCTUnwrap(listed["rules"]?.arrayValue)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"]?.intValue, rule)
        XCTAssertEqual(rows[0]["hits"]?.intValue, 0)
        XCTAssertEqual(rows[0]["remaining"]?.intValue, 2)
        XCTAssertEqual(rows[0]["match"]?["host"]?.stringValue, "api.example.com")
        XCTAssertEqual(rows[0]["action"]?["body"]?.stringValue?.count, 300_000)

        let noExchange = await proxyFailure { _ = try await proxy.call("get", ["exchange": 9, "part": "response"]) }
        XCTAssertEqual(noExchange, "no exchange with id 9; the store keeps the newest 2000 exchanges and 'clear' removes them all")
        let unknown = await proxyFailure { _ = try await proxy.call("nope", [:]) }
        XCTAssertEqual(unknown, "unknown op 'nope'")
        _ = try await proxy.call("rule.remove", ["rule": .int(Int64(rule))])
        _ = try await proxy.call("rule.clear", [:])
        _ = try await proxy.call("clear", [:])

        let pid = try XCTUnwrap(proxy.processIdentifier)
        await proxy.stop()
        XCTAssertFalse(isAlive(pid))
    }
}
