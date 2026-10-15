import XCTest
import CryptoKit
@testable import AlcoveControl
@testable import AlcoveEngine
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

/// `ControllerTarget` over a `VMController` whose engine is a Python stand-in for `qemu-system-aarch64`: it holds the
/// `-pidfile` lock, serves QMP on the `-qmp` socket with a running guest and exits on `quit`.
final class ControllerTargetTests: XCTestCase {
    private var tmp: URL!
    private var controllers: [VMController] = []

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alcove-target-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for vm in controllers where await vm.state.isActive { try? await vm.shutdown(force: true) }
        controllers.removeAll()
        try? FileManager.default.removeItem(at: tmp)
    }

    /// An engine folder whose `qemu-system-aarch64` runs `fakeEngineSource` and whose `qemu-img` writes empty images.
    private func engine() throws -> EngineLocator.Engine {
        let root = tmp.appendingPathComponent("engine")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("pc-bios"), withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake-engine.py")
        try fakeEngineSource.write(to: script, atomically: true, encoding: .utf8)
        let wrapper = "#!/bin/sh\nexec /usr/bin/env python3 '\(script.path)' \"$@\"\n"
        fm.createFile(atPath: root.appendingPathComponent("qemu-system-aarch64").path, contents: Data(wrapper.utf8),
                      attributes: [.posixPermissions: 0o755])
        let img = "#!/bin/sh\ncase \"$1\" in\ncreate) out=\"$5\"; if [ \"$5\" = -F ]; then for out; do :; done; fi; printf 'QFI' > \"$out\";;\n"
            + "info) echo '{\"snapshots\": []}';;\nesac\n"
        fm.createFile(atPath: root.appendingPathComponent("qemu-img").path, contents: Data(img.utf8), attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: root.appendingPathComponent("pc-bios/edk2-aarch64-code.fd").path, contents: Data(count: 16))
        return EngineLocator.Engine(qemuSystem: root.appendingPathComponent("qemu-system-aarch64").path,
                                    qemuImg: root.appendingPathComponent("qemu-img").path,
                                    firmwareDir: root.appendingPathComponent("pc-bios").path, swtpm: nil)
    }

    private func makeVM(_ configure: (inout VMConfig) -> Void) throws -> VMController {
        let engine = try engine()
        var config = VMConfig.defaults(name: "Fake", guestOS: .other)
        config.cpuCount = 2
        config.memoryMiB = 512
        configure(&config)
        let dir = tmp.appendingPathComponent("vms")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundle = try VMBundle.create(config, in: dir, engine: engine)
        let vm = VMController(bundle: bundle, config: config, engine: engine)
        controllers.append(vm)
        return vm
    }

    func testAControllerTargetUsesTheConfigurationTheEngineRunsWith() async throws {
        let agent = FakeAgent()
        agent.helloExtra = ["auth": "key", "nonce": .string(String(repeating: "c3", count: 32))]
        agent.handler = { m, _ in m["t"]?.stringValue == "auth" ? [["t": "authed"]] : [] }
        let launched = [VMConfig.PortForward(hostPort: 22_222, guestPort: 22), VMConfig.PortForward(proto: .udp, hostPort: 5353, guestPort: 53)]
        let vm = try makeVM { config in
            config.agentToken = agent.token
            config.agentHostPort = agent.port
            config.network = .user(portForwards: launched)
        }
        _ = agent.start()
        addTeardownBlock { agent.stop() }
        try await vm.start()

        let launchedKey = await vm.config.agentKey
        var edited = await vm.config
        edited.agentHostPort = agent.port == 17_999 ? 17_998 : 17_999
        edited.network = .user(portForwards: [VMConfig.PortForward(hostPort: 33_333, guestPort: 80)])
        edited.agentToken = "next-token"
        edited.agentKey = VMConfig.randomAgentKey()
        try await vm.update(config: edited)
        let next = await vm.config
        XCTAssertNotEqual(next.agentHostPort, agent.port)
        XCTAssertEqual(next.agentToken, "next-token")
        XCTAssertNotEqual(next.agentKey, launchedKey)

        let target = ControllerTarget(name: "Fake", controller: vm)
        let port = await target.agentHostPort()
        XCTAssertEqual(port, agent.port)
        let forwards = await target.staticForwards()
        XCTAssertEqual(forwards, [VMConfig.PortForward(hostPort: 22_222, guestPort: 22)])
        let client = await target.agent(timeout: .seconds(10))
        let connected = try XCTUnwrap(client)
        let authenticated = await connected.hello?.authenticated
        XCTAssertEqual(authenticated, true)
        XCTAssertEqual(agent.received.first?["t"]?.stringValue, "auth")
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap(hexData(XCTUnwrap(AgentKey.publicKey(launchedKey)))))
        let signature = try XCTUnwrap(hexData(XCTUnwrap(agent.received.first?["signature"]?.stringValue)))
        let nonce = try XCTUnwrap(hexData(String(repeating: "c3", count: 32)))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data((AgentKey.authContext + agent.token).utf8) + nonce))
        await target.dropAgent(nil)
    }
}

/// The bytes an even number of hexadecimal digits encode, or nil.
private func hexData(_ text: String) -> Data? {
    guard text.count % 2 == 0 else { return nil }
    var out = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        out.append(byte)
        index = next
    }
    return out
}

private let fakeEngineSource = #"""
#!/usr/bin/env python3
import fcntl, json, os, socket, sys, threading, time

args = sys.argv[1:]

def opt(name):
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            return args[i + 1]
    return None

qmp_path = opt("-qmp")[len("unix:"):].split(",")[0]
pf = open(opt("-pidfile"), "w")
fcntl.lockf(pf, fcntl.LOCK_EX | fcntl.LOCK_NB)
pf.write(str(os.getpid())); pf.flush()

def send(conn, obj):
    try:
        conn.sendall((json.dumps(obj) + "\n").encode())
    except OSError:
        pass

def die(delay):
    def run():
        time.sleep(delay)
        os._exit(0)
    threading.Thread(target=run, daemon=True).start()

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(qmp_path)
srv.listen(1)
while True:
    c, _ = srv.accept()
    send(c, {"QMP": {"version": {"qemu": {"major": 11, "minor": 1, "micro": 1}, "package": "fake"}, "capabilities": ["oob"]}})
    for line in c.makefile("rb"):
        try:
            req = json.loads(line)
        except ValueError:
            continue
        cmd = req.get("execute"); rid = req.get("id")
        if cmd == "query-status":
            send(c, {"return": {"running": True, "status": "running"}, "id": rid})
        elif cmd in ("quit", "system_powerdown"):
            send(c, {"return": {}, "id": rid})
            send(c, {"event": "SHUTDOWN", "data": {"guest": False, "reason": "host-qmp-quit"},
                     "timestamp": {"seconds": int(time.time()), "microseconds": 0}})
            die(0.1)
        else:
            send(c, {"return": {}, "id": rid})
    c.close()
"""#
