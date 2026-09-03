import XCTest
@testable import AlcoveEngine

final class VMBundleAndLocatorTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alcove-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// A fake engine root: `qemu-img` is a shell script that creates the file.
    private func fakeEngineRoot(withVarsTemplate: Bool) throws -> String {
        let root = tmp.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pc-bios"), withIntermediateDirectories: true)
        let fm = FileManager.default
        fm.createFile(atPath: root.appendingPathComponent("qemu-system-aarch64").path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
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
        // listing ignores non-bundles
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("junk.alcovevm"), withIntermediateDirectories: true)
        XCTAssertEqual(VMBundle.list(in: tmp).map(\.url.lastPathComponent), ["Fedora.alcovevm"])
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
