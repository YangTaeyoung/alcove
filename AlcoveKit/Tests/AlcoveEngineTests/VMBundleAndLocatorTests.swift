import XCTest
@testable import AlcoveEngine

final class VMBundleAndLocatorTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alcove-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// A fake engine root: `qemu-system-aarch64` answers `-display help` like the
    /// patched engine (or like stock QEMU when `alcove` is false) and `qemu-img`
    /// is a shell script that creates the file.
    private func fakeEngineRoot(withVarsTemplate: Bool, name: String = "engine", alcove: Bool = true) throws -> String {
        let root = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pc-bios"), withIntermediateDirectories: true)
        let fm = FileManager.default
        let backends = alcove ? "none cocoa dbus alcove" : "none cocoa dbus"
        // real QEMU prints the header, then one backend per line (ui/console.c qemu_display_help)
        let qemu = "#!/bin/sh\ncase \"$1 $2\" in \"-display help\") echo \"Available display backend types:\"; for b in \(backends); do echo \"$b\"; done;; esac\n"
        fm.createFile(atPath: root.appendingPathComponent("qemu-system-aarch64").path, contents: Data(qemu.utf8), attributes: [.posixPermissions: 0o755])
        let img = "#!/bin/sh\n# create -q -f qcow2 FILE SIZE\ncase \"$5\" in *boom)  echo 'qemu-img: boom' >&2; exit 1;; esac\nprintf 'QFI' > \"$5\"\n"
        fm.createFile(atPath: root.appendingPathComponent("qemu-img").path, contents: Data(img.utf8), attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: root.appendingPathComponent("pc-bios/edk2-aarch64-code.fd").path, contents: Data(count: 16))
        if withVarsTemplate {
            fm.createFile(atPath: root.appendingPathComponent("pc-bios/edk2-arm-vars.fd").path, contents: Data(repeating: 0xEE, count: 32))
        }
        return root.path
    }

    func testLocatorFindsBinariesAndFirmware() throws {
        let root = try fakeEngineRoot(withVarsTemplate: true)
        let e = try EngineLocator(roots: ["/nonexistent", root]).locate()
        XCTAssertEqual(e.qemuSystem, root + "/qemu-system-aarch64")
        XCTAssertEqual(e.firmwareCode, root + "/pc-bios/edk2-aarch64-code.fd")
        XCTAssertEqual(e.firmwareVarsTemplate, root + "/pc-bios/edk2-arm-vars.fd")
        XCTAssertThrowsError(try EngineLocator(roots: ["/nonexistent"]).locate())
        XCTAssertTrue(EngineLocator.developmentBuildRoot.hasSuffix("/build/qemu-build"))
        XCTAssertEqual(EngineLocator.standard(environment: ["ALCOVE_QEMU_DIR": "/env"]).roots.first, "/env")
        // $PATH entries are searched as engine roots (<prefix>/bin -> <prefix>), deduplicated
        let roots = EngineLocator.standard(environment: ["PATH": "/usr/bin:/opt/homebrew/bin:/x/qemu:relative:/opt/homebrew/bin"]).roots
        XCTAssertEqual(roots.filter { $0 == "/opt/homebrew" }.count, 1)
        XCTAssertTrue(roots.contains("/usr") && roots.contains("/x/qemu"))
        XCTAssertFalse(roots.contains("relative"))
        XCTAssertLessThan(roots.firstIndex(of: EngineLocator.developmentBuildRoot)!, roots.firstIndex(of: "/usr")!)
    }

    /// A stock QEMU (Homebrew, $PATH) has binaries and firmware but no `alcove`
    /// display backend; it must be skipped with a reason, not reported as usable.
    func testLocatorRejectsEnginesWithoutTheAlcoveDisplay() throws {
        let stock = try fakeEngineRoot(withVarsTemplate: true, name: "stock", alcove: false)
        let patched = try fakeEngineRoot(withVarsTemplate: true, name: "patched", alcove: true)
        XCTAssertEqual(try EngineLocator(roots: [stock, patched]).locate().qemuSystem, patched + "/qemu-system-aarch64")
        XCTAssertThrowsError(try EngineLocator(roots: ["/nonexistent", stock]).locate()) { error in
            guard case .notFound(let searched)? = error as? EngineLocator.LocateError else { return XCTFail("\(error)") }
            XCTAssertEqual(searched.count, 2)
            XCTAssertEqual(searched[0], "/nonexistent")
            XCTAssertTrue(searched[1].hasPrefix(stock) && searched[1].contains("alcove display backend"), searched[1])
        }
        XCTAssertTrue(EngineLocator.hasAlcoveDisplay(qemuSystem: patched + "/qemu-system-aarch64"))
        XCTAssertFalse(EngineLocator.hasAlcoveDisplay(qemuSystem: stock + "/qemu-system-aarch64"))
        XCTAssertFalse(EngineLocator.hasAlcoveDisplay(qemuSystem: "/nonexistent/qemu-system-aarch64"))
    }

    func testSuspendStateFilesAndDiscard() throws {
        let engine = try EngineLocator(roots: [try fakeEngineRoot(withVarsTemplate: true)]).locate()
        var config = VMConfig.defaults(name: "Susp", guestOS: .linux)
        let b = try VMBundle.create(config, in: tmp, engine: engine)
        XCTAssertFalse(b.isSuspended)
        XCTAssertNil(b.loadSuspendedConfig())
        XCTAssertNoThrow(try b.discardSuspendState())
        config.memoryMiB = 8192
        try config.encoded().write(to: b.suspendConfigURL)
        try Data("state".utf8).write(to: b.suspendStateURL)
        XCTAssertTrue(b.isSuspended)
        XCTAssertEqual(b.loadSuspendedConfig()?.memoryMiB, 8192)
        XCTAssertEqual(b.pidFileURL, b.runURL.appendingPathComponent("qemu.pid"))
        try b.discardSuspendState()
        XCTAssertFalse(b.isSuspended)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.suspendConfigURL.path))
    }

    func testCreateLoadListAndRunDirectory() throws {
        let engine = try EngineLocator(roots: [try fakeEngineRoot(withVarsTemplate: true)]).locate()
        let config = VMConfig.defaults(name: "Fedora", guestOS: .linux)
        let b = try VMBundle.create(config, in: tmp, engine: engine)
        XCTAssertEqual(b.url.lastPathComponent, "Fedora.alcovevm")
        XCTAssertEqual(try b.loadConfig().name, "Fedora")
        XCTAssertEqual(try Data(contentsOf: b.diskURL(config.disks[0])), Data("QFI".utf8))
        XCTAssertEqual(try Data(contentsOf: b.efiVarsURL), Data(repeating: 0xEE, count: 32))
        XCTAssertFalse(b.isSuspended)
        XCTAssertThrowsError(try VMBundle.create(config, in: tmp, engine: engine)) {
            XCTAssertEqual($0 as? VMBundle.BundleError, .alreadyExists(b.url.path))
        }
        // stale run files are cleared
        try Data().write(to: b.runURL.appendingPathComponent("fb0-3.bgra"))
        try b.prepareRunDirectory()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: b.runURL.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.socketDirectory))
        XCTAssertLessThan(b.displaySocketPath.utf8.count, 104)
        XCTAssertTrue(b.displaySocketPath.hasPrefix("/tmp/alcove-"))
        XCTAssertEqual(b.socketDirectory, VMBundle(url: b.url).socketDirectory)
        // listing ignores non-bundles
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("junk.alcovevm"), withIntermediateDirectories: true)
        XCTAssertEqual(VMBundle.list(in: tmp).map(\.url.lastPathComponent), ["Fedora.alcovevm"])
    }

    /// A config written before the agent fields existed must gain them on the
    /// first load and keep them, or the token would differ between the process
    /// that starts the VM and anyone talking to its guest agent.
    func testLoadConfigPersistsSynthesizedAgentFields() throws {
        let engine = try EngineLocator(roots: [try fakeEngineRoot(withVarsTemplate: true)]).locate()
        let b = try VMBundle.create(VMConfig.defaults(name: "Legacy", guestOS: .linux), in: tmp, engine: engine)
        var raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: b.configURL)) as! [String: Any]
        raw.removeValue(forKey: "agentToken"); raw.removeValue(forKey: "agentHostPort")
        try JSONSerialization.data(withJSONObject: raw).write(to: b.configURL)
        let first = try b.loadConfig()
        let second = try b.loadConfig()
        XCTAssertEqual(first.agentToken, second.agentToken)
        XCTAssertEqual(first.agentHostPort, second.agentHostPort)
        XCTAssertFalse(VMConfig.needsMigration(try Data(contentsOf: b.configURL)))
    }

    func testZeroFilledVarsWithoutTemplateAndCleanupOnFailure() throws {
        let engine = try EngineLocator(roots: [try fakeEngineRoot(withVarsTemplate: false)]).locate()
        XCTAssertNil(engine.firmwareVarsTemplate)
        var config = VMConfig.defaults(name: "NoVars", guestOS: .other)
        let b = try VMBundle.create(config, in: tmp, engine: engine)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: b.efiVarsURL.path)[.size] as? Int, 64 * 1024 * 1024)

        config.name = "Broken"
        config.disks[0].sizeGiB = 1
        config.disks[0].fileName = "boom"   // the fake qemu-img fails on this name
        XCTAssertThrowsError(try VMBundle.create(config, in: tmp, engine: engine)) {
            guard case .qemuImgFailed(let msg)? = $0 as? VMBundle.BundleError else { return XCTFail("\($0)") }
            XCTAssertTrue(msg.contains("boom"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Broken.alcovevm").path))
    }
}
