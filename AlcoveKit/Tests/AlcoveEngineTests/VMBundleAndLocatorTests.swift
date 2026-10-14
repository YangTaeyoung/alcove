import XCTest
@testable import AlcoveEngine

/// Values appended from closures that run concurrently.
private final class Collected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    func append(_ value: Value) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return stored }
}

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
        let img = "#!/bin/sh\n# create -q -f qcow2 FILE SIZE | create -q -f qcow2 -F qcow2 -b BACKING FILE\n"
            + "out=\"$5\"; if [ \"$5\" = -F ]; then for out; do :; done; fi\n"
            + "case \"$out\" in *boom*)  echo 'qemu-img: boom' >&2; exit 1;; esac\nprintf 'QFI' > \"$out\"\n"
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
        XCTAssertTrue(EngineLocator.repositoryBuildRoot.hasSuffix("/build/qemu-build"))
        XCTAssertEqual(EngineLocator.developmentBuildRoot(environment: [:]), EngineLocator.repositoryBuildRoot)
        XCTAssertEqual(EngineLocator.developmentBuildRoot(environment: ["ALCOVE_QEMU_DIR": ""]), EngineLocator.repositoryBuildRoot)
        XCTAssertEqual(EngineLocator.developmentBuildRoot(environment: ["ALCOVE_QEMU_DIR": "/env"]), "/env")
        XCTAssertEqual(EngineLocator.developmentBuildRoot,
                       EngineLocator.developmentBuildRoot(environment: ProcessInfo.processInfo.environment))
        XCTAssertEqual(EngineLocator.standard(environment: ["ALCOVE_QEMU_DIR": "/env"]).roots.first, "/env")
        // $PATH entries are searched as engine roots (<prefix>/bin -> <prefix>), deduplicated
        let roots = EngineLocator.standard(environment: ["PATH": "/usr/bin:/opt/homebrew/bin:/x/qemu:relative:/opt/homebrew/bin"]).roots
        XCTAssertEqual(roots.filter { $0 == "/opt/homebrew" }.count, 1)
        XCTAssertTrue(roots.contains("/usr") && roots.contains("/x/qemu"))
        XCTAssertFalse(roots.contains("relative"))
        XCTAssertLessThan(roots.firstIndex(of: EngineLocator.repositoryBuildRoot)!, roots.firstIndex(of: "/usr")!)
        let withEngineDirectory = EngineLocator.standard(environment: ["ALCOVE_QEMU_DIR": "/env"]).roots
        XCTAssertLessThan(withEngineDirectory.firstIndex(of: "/env")!, withEngineDirectory.firstIndex(of: EngineLocator.repositoryBuildRoot)!)
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

    func testLoadConfigPersistsAGeneratedAgentKey() throws {
        let engine = try EngineLocator(roots: [try fakeEngineRoot(withVarsTemplate: true)]).locate()
        let b = try VMBundle.create(VMConfig.defaults(name: "Keyless", guestOS: .windows), in: tmp, engine: engine)
        var raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: b.configURL)) as! [String: Any]
        raw.removeValue(forKey: "agentKey")
        try JSONSerialization.data(withJSONObject: raw).write(to: b.configURL)
        let first = try b.loadConfig()
        let second = try b.loadConfig()
        XCTAssertEqual(first.agentKey.count, 64)
        XCTAssertEqual(first.agentKey, second.agentKey)
        let stored = try JSONSerialization.jsonObject(with: try Data(contentsOf: b.configURL)) as! [String: Any]
        XCTAssertEqual(stored["agentKey"] as? String, first.agentKey)
    }

    func testSaveKeepsTheStoredAgentKey() throws {
        let engine = try EngineLocator(roots: [try fakeEngineRoot(withVarsTemplate: true)]).locate()
        let b = try VMBundle.create(VMConfig.defaults(name: "Keyed", guestOS: .windows), in: tmp, engine: engine)
        let stored = try b.loadConfig()
        var other = stored
        other.agentKey = String(repeating: "ab", count: 32)
        other.cpuCount = stored.cpuCount + 1
        let written = try b.save(other)
        XCTAssertEqual(written.agentKey, stored.agentKey)
        let reloaded = try b.loadConfig()
        XCTAssertEqual(reloaded.agentKey, stored.agentKey)
        XCTAssertEqual(reloaded.cpuCount, stored.cpuCount + 1)
    }

    /// Two loads of a config without a key that run before either saved: both return the key the first save wrote.
    func testTwoMigratingLoadsAgreeOnTheAgentKey() throws {
        let engine = try EngineLocator(roots: [try fakeEngineRoot(withVarsTemplate: true)]).locate()
        let b = try VMBundle.create(VMConfig.defaults(name: "Racing", guestOS: .windows), in: tmp, engine: engine)
        var raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: b.configURL)) as! [String: Any]
        raw.removeValue(forKey: "agentKey")
        let old = try JSONSerialization.data(withJSONObject: raw)
        let early = try VMConfig.decode(old)
        try old.write(to: b.configURL)
        let first = try b.loadConfig()
        XCTAssertNotEqual(early.agentKey, first.agentKey)
        XCTAssertEqual(try b.save(early).agentKey, first.agentKey)
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

    // MARK: - clone registry (stand-in qemu-img)

    private func stubTemplate(name: String = "Base") throws -> (VMBundle, EngineLocator.Engine) {
        let engine = try EngineLocator(roots: [try fakeEngineRoot(withVarsTemplate: true)]).locate()
        return (try VMBundle.create(VMConfig.defaults(name: name, guestOS: .linux), in: tmp, engine: engine), engine)
    }

    private func standardPath(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Moves `bundle` to `<newName>.alcovevm` and saves its config under that name.
    private func rename(_ bundle: VMBundle, to newName: String) throws -> VMBundle {
        let moved = VMBundle(url: tmp.appendingPathComponent(newName).appendingPathExtension(VMBundle.pathExtension))
        try FileManager.default.moveItem(at: bundle.url, to: moved.url)
        var config = try moved.loadConfig()
        config.name = newName
        try moved.save(config)
        return moved
    }

    func testRenamedCloneStillGuardsTemplate() throws {
        let (template, engine) = try stubTemplate()
        let clone = try template.cloneLinked(named: "Copy", engine: engine)
        let renamed = try rename(clone, to: "Renamed")
        XCTAssertEqual(template.liveClones().map(standardPath), [standardPath(renamed.url)])
        XCTAssertEqual(try listedClones(template), [standardPath(renamed.url)])
        XCTAssertEqual(template.liveClones().map { VMBundle(url: $0).configName }, ["Renamed"])

        let movedOnly = VMBundle(url: tmp.appendingPathComponent("Elsewhere.alcovevm"))
        try FileManager.default.moveItem(at: renamed.url, to: movedOnly.url)
        XCTAssertEqual(template.liveClones().map(standardPath), [standardPath(movedOnly.url)])
        XCTAssertEqual(movedOnly.configName, "Renamed")
    }

    func testUnreadableCloneListFallsBackToSiblings() throws {
        let (template, engine) = try stubTemplate()
        let clone = try template.cloneLinked(named: "Copy", engine: engine)
        try Data("not json".utf8).write(to: template.clonesURL)
        XCTAssertEqual(template.liveClones().map(standardPath), [standardPath(clone.url)])
        XCTAssertEqual(try listedClones(template), [standardPath(clone.url)])
        try FileManager.default.removeItem(at: template.clonesURL)
        XCTAssertEqual(template.liveClones().map(standardPath), [standardPath(clone.url)])
        XCTAssertEqual(try listedClones(template), [standardPath(clone.url)])
    }

    func testPlainVMUnderOldCloneNameIsNotAClone() throws {
        let (template, engine) = try stubTemplate()
        let clone = try template.cloneLinked(named: "Copy", engine: engine)
        try FileManager.default.removeItem(at: clone.url)
        XCTAssertEqual(try listedClones(template), [standardPath(clone.url)])
        _ = try VMBundle.create(VMConfig.defaults(name: "Copy", guestOS: .linux), in: tmp, engine: engine)
        XCTAssertEqual(template.liveClones(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: template.clonesURL.path))
    }

    func testRecloneDoesNotDuplicate() throws {
        let (template, engine) = try stubTemplate()
        let first = try template.cloneLinked(named: "Copy", engine: engine)
        try FileManager.default.removeItem(at: first.url)
        XCTAssertEqual(try listedClones(template), [standardPath(first.url)])
        let second = try template.cloneLinked(named: "Copy", engine: engine)
        XCTAssertEqual(try listedClones(template), [standardPath(second.url)])
        XCTAssertEqual(template.liveClones().map(standardPath), [standardPath(second.url)])
    }

    func testClonePortsAvoidSiblings() throws {
        let (template, engine) = try stubTemplate()
        var config = try template.loadConfig()
        var ports = [config.agentHostPort]
        // sibling bundles hold every port of the range except the template's and three others
        let free = Set([17011, 17503, 17998, 17100].filter { $0 != config.agentHostPort }.prefix(3))
        var crowd = VMConfig.defaults(name: "Crowd", guestOS: .linux)
        for (i, port) in (17000...17999).filter({ !free.contains($0) && $0 != config.agentHostPort }).enumerated() {
            crowd.name = "Crowd\(i)"
            crowd.agentHostPort = port
            let sibling = VMBundle(url: tmp.appendingPathComponent(crowd.name).appendingPathExtension(VMBundle.pathExtension))
            try FileManager.default.createDirectory(at: sibling.url, withIntermediateDirectories: true)
            try sibling.save(crowd)
        }
        for name in ["One", "Two", "Three"] {
            config = try template.cloneLinked(named: name, engine: engine).loadConfig()
            XCTAssertEqual(config.agentHostPort, VMConfig.agentPort(for: config.agentToken))
            ports.append(config.agentHostPort)
        }
        XCTAssertEqual(Set(ports.dropFirst()), free)
        XCTAssertFalse(ports.dropFirst().contains(ports[0]))
    }

    /// Sibling bundles named `Crowd<i>` whose guest-tools ports cover 17000...17999 except `free`.
    private func crowdAgentPorts(except free: Set<Int>) throws {
        var crowd = VMConfig.defaults(name: "Crowd", guestOS: .linux)
        for (i, port) in (17000...17999).filter({ !free.contains($0) }).enumerated() {
            crowd.name = "Crowd\(i)"
            crowd.agentHostPort = port
            let sibling = VMBundle(url: tmp.appendingPathComponent(crowd.name).appendingPathExtension(VMBundle.pathExtension))
            try FileManager.default.createDirectory(at: sibling.url, withIntermediateDirectories: true)
            try sibling.save(crowd)
        }
    }

    func testClonePortsAvoidSiblingsTCPForwards() throws {
        let (template, engine) = try stubTemplate()
        let own = try template.loadConfig().agentHostPort
        let free = Set([17011, 17503, 17998, 17100].filter { $0 != own }.prefix(3))
        try crowdAgentPorts(except: free.union([own]))
        let forwarded = try XCTUnwrap(free.sorted().first)
        var forwarding = VMConfig.defaults(name: "Forwarding", guestOS: .linux)
        forwarding.agentHostPort = own
        forwarding.network = .user(portForwards: [.init(proto: .tcp, hostPort: forwarded, guestPort: 22)])
        _ = try VMBundle.create(forwarding, in: tmp, engine: engine)
        var ports: [Int] = []
        for name in ["One", "Two"] {
            ports.append(try template.cloneLinked(named: name, engine: engine).loadConfig().agentHostPort)
        }
        XCTAssertEqual(Set(ports), free.subtracting([forwarded]))
    }

    func testCloneIsRefusedWhenEveryAgentPortIsTaken() throws {
        let (template, engine) = try stubTemplate()
        try crowdAgentPorts(except: [try template.loadConfig().agentHostPort])
        XCTAssertThrowsError(try template.cloneLinked(named: "Copy", engine: engine)) {
            XCTAssertEqual($0 as? VMBundle.CloneError, .noFreeAgentPort(self.tmp.path))
            XCTAssertEqual("\($0)", "every guest-tools port from 17000 to 17999 is used by a VM in \(self.tmp.path); "
                + "delete a VM there or move it to another folder, then clone again")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Copy.alcovevm").path))
    }

    func testAListedCloneWhoseConfigCannotBeReadStillGuardsTheTemplate() throws {
        let (template, engine) = try stubTemplate()
        let clone = try template.cloneLinked(named: "Copy", engine: engine)
        try Data("not json".utf8).write(to: clone.configURL)
        XCTAssertEqual(template.liveClones().map(standardPath), [standardPath(clone.url)])
        XCTAssertEqual(try listedClones(template), [standardPath(clone.url)])
        XCTAssertEqual(template.liveClones().map { VMBundle(url: $0).configName }, ["Copy"])
        try FileManager.default.removeItem(at: clone.url)
        XCTAssertEqual(template.liveClones(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: template.clonesURL.path))
    }

    func testDeletingACloneUpdatesTheListOfTheTemplateAtItsRecordedPath() throws {
        let (template, engine) = try stubTemplate()
        let clone = try template.cloneLinked(named: "Copy", engine: engine)
        let elsewhere = tmp.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let moved = VMBundle(url: elsewhere.appendingPathComponent(clone.url.lastPathComponent))
        try FileManager.default.moveItem(at: clone.url, to: moved.url)
        XCTAssertEqual(try listedClones(template), [standardPath(clone.url)])
        try moved.deleteClone()
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: template.clonesURL.path))
    }

    func testCloneNameIsTrimmed() throws {
        let (template, engine) = try stubTemplate()
        let clone = try template.cloneLinked(named: "  Copy \n", engine: engine)
        XCTAssertEqual(clone.url.lastPathComponent, "Copy.alcovevm")
        XCTAssertEqual(try clone.loadConfig().name, "Copy")
        XCTAssertThrowsError(try template.cloneLinked(named: "   ", engine: engine)) {
            XCTAssertEqual($0 as? VMBundle.CloneError, .invalidName(""))
        }
        XCTAssertEqual(VMBundle.list(in: tmp).map(\.url.lastPathComponent), ["Base.alcovevm", "Copy.alcovevm"])
    }

    func testFailedOverlayLeavesNoClone() throws {
        let (template, engine) = try stubTemplate()
        XCTAssertThrowsError(try template.cloneLinked(named: "boom", engine: engine)) {
            XCTAssertEqual($0 as? VMBundle.CloneError, .overlayFailed("qemu-img: boom"))
            XCTAssertEqual("\($0)", "qemu-img could not create the clone's disk (qemu-img: boom); check the template's disk images and the free space, then clone again")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("boom.alcovevm").path))
        XCTAssertEqual(template.liveClones(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: template.clonesURL.path))
    }

    // MARK: - disk epoch (stand-in qemu-img)

    /// Writes the `config.json` of `bundle` with `diskEpoch` set to `epoch` and every other field as stored.
    private func setDiskEpoch(_ epoch: Int?, of bundle: VMBundle) throws {
        var config = try bundle.loadConfig()
        config.diskEpoch = epoch
        try config.encoded().write(to: bundle.configURL, options: .atomic)
    }

    private func setPermissions(_ mode: Int, of bundle: VMBundle) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: bundle.url.path)
    }

    func testTemplateMismatchIsNilForAVMThatIsNotAClone() throws {
        let (template, engine) = try stubTemplate()
        XCTAssertNil(VMBundle.templateMismatch(for: try template.loadConfig()))
        _ = try template.cloneLinked(named: "Copy", engine: engine)
        XCTAssertNil(VMBundle.templateMismatch(for: try template.loadConfig()))
    }

    func testTemplateMismatchComparesTheCloneEpochWithTheStoredTemplateEpoch() throws {
        let (template, engine) = try stubTemplate()
        let config = try template.cloneLinked(named: "Copy", engine: engine).loadConfig()
        let stale = "the template 'Base' was started after 'Copy' was cloned from it, so the clone's disk no longer matches; "
            + "delete the clone and clone again"
        XCTAssertNil(VMBundle.templateMismatch(for: config))
        try setDiskEpoch(1, of: template)
        XCTAssertEqual(VMBundle.templateMismatch(for: config), stale)
        try setDiskEpoch(nil, of: template)
        XCTAssertEqual(VMBundle.templateMismatch(for: config), stale)
        try setDiskEpoch(0, of: template)
        XCTAssertNil(VMBundle.templateMismatch(for: config))
    }

    func testTemplateMismatchReportsATemplateThatCannotBeRead() throws {
        let (template, engine) = try stubTemplate()
        var config = try template.cloneLinked(named: "Copy", engine: engine).loadConfig()
        let path = standardPath(template.url)
        XCTAssertEqual(config.templatePath, path)
        let notFound = "the template of 'Copy' was not found at \(path); the clone cannot run without it"

        try Data("not json".utf8).write(to: template.configURL)
        XCTAssertEqual(VMBundle.templateMismatch(for: config), notFound)
        try FileManager.default.removeItem(at: template.url)
        XCTAssertEqual(VMBundle.templateMismatch(for: config), notFound)

        config.templatePath = nil
        XCTAssertEqual(VMBundle.templateMismatch(for: config),
                       "the template of 'Copy' was not found at an unrecorded path; the clone cannot run without it")
    }

    func testAdvanceDiskEpochLeavesAVMWithoutEpochUntouched() throws {
        let (bundle, _) = try stubTemplate()
        let before = try Data(contentsOf: bundle.configURL)
        XCTAssertNil(try bundle.advanceDiskEpoch())
        XCTAssertEqual(try Data(contentsOf: bundle.configURL), before)
    }

    func testAdvanceDiskEpochStoresTheNextEpochAndNothingElse() throws {
        let (template, engine) = try stubTemplate()
        _ = try template.cloneLinked(named: "Copy", engine: engine)
        var expected = try template.loadConfig()
        XCTAssertEqual(expected.diskEpoch, 0)
        XCTAssertEqual(try template.advanceDiskEpoch(), 1)
        expected.diskEpoch = 1
        XCTAssertEqual(try template.loadConfig(), expected)
        XCTAssertEqual(try template.advanceDiskEpoch(), 2)
        expected.diskEpoch = 2
        XCTAssertEqual(try template.loadConfig(), expected)
    }

    func testAdvanceDiskEpochThrowsWhenTheConfigCannotBeSaved() throws {
        let (template, engine) = try stubTemplate()
        _ = try template.cloneLinked(named: "Copy", engine: engine)
        try setPermissions(0o555, of: template)
        defer { try? setPermissions(0o755, of: template) }
        XCTAssertThrowsError(try template.advanceDiskEpoch())
        XCTAssertEqual(try template.loadConfig().diskEpoch, 0)
    }

    /// `advanceDiskEpoch` and `save` of a copy that holds epoch 0 run concurrently on one bundle, 200 calls each.
    func testConcurrentSavesOfAnOlderCopyNeverLoseAnEpochBump() throws {
        let (template, engine) = try stubTemplate()
        _ = try template.cloneLinked(named: "Copy", engine: engine)
        var older = try template.loadConfig()
        let id = try XCTUnwrap(older.diskID)
        XCTAssertEqual(older.diskEpoch, 0)
        older.memoryMiB = 2048

        let rounds = 200
        let bumps = Collected<Int?>(), errors = Collected<String>()
        let saved = older
        DispatchQueue.concurrentPerform(iterations: rounds * 2) { i in
            do {
                if i.isMultiple(of: 2) {
                    bumps.append(try template.advanceDiskEpoch())
                } else {
                    try template.save(saved)
                }
            } catch {
                errors.append("\(error)")
            }
        }

        XCTAssertEqual(errors.values, [])
        XCTAssertEqual(bumps.values.compactMap { $0 }.sorted(), Array(1...rounds))
        let stored = try template.loadConfig()
        XCTAssertEqual(stored.diskEpoch, rounds)
        XCTAssertEqual(stored.diskID, id)
        XCTAssertEqual(stored.memoryMiB, 2048)
    }

    func testNoCloneIsCreatedWhenTheTemplateConfigCannotBeSaved() throws {
        let (template, engine) = try stubTemplate()
        try setPermissions(0o555, of: template)
        defer { try? setPermissions(0o755, of: template) }
        XCTAssertThrowsError(try template.cloneLinked(named: "Clone", engine: engine)) {
            let path = ($0 as NSError).userInfo[NSFilePathErrorKey] as? String ?? ""
            XCTAssertTrue(path.hasSuffix("/Base.alcovevm/config.json"), "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Clone.alcovevm").path))
        try setPermissions(0o755, of: template)
        XCTAssertNil(try template.loadConfig().diskEpoch)
        XCTAssertNil(try template.loadConfig().diskID)
        XCTAssertEqual(template.liveClones(), [])
    }

    func testSaveKeepsTheStoredDiskEpochAndDiskIDWhenTheSavedConfigHasLess() throws {
        let (template, engine) = try stubTemplate()
        var beforeClone = try template.loadConfig()
        _ = try template.cloneLinked(named: "Copy", engine: engine)
        var beforeBump = try template.loadConfig()
        let id = try XCTUnwrap(beforeBump.diskID)
        XCTAssertEqual(beforeBump.diskEpoch, 0)
        XCTAssertEqual(try template.advanceDiskEpoch(), 1)

        beforeBump.memoryMiB = 2048
        var written = try template.save(beforeBump)
        XCTAssertEqual(written.diskEpoch, 1)
        XCTAssertEqual(written.memoryMiB, 2048)
        XCTAssertEqual(try template.loadConfig(), written)

        XCTAssertNil(beforeClone.diskEpoch); XCTAssertNil(beforeClone.diskID)
        beforeClone.cpuCount = 2
        written = try template.save(beforeClone)
        XCTAssertEqual(written.diskEpoch, 1)
        XCTAssertEqual(written.diskID, id)
        XCTAssertEqual(written.cpuCount, 2)
        XCTAssertEqual(try template.loadConfig(), written)

        var higher = written
        higher.diskEpoch = 5; higher.diskID = "another"
        written = try template.save(higher)
        XCTAssertEqual(written.diskEpoch, 5)
        XCTAssertEqual(written.diskID, id)
        XCTAssertEqual(try template.loadConfig(), written)
    }

    func testSaveKeepsTheStoredCloneFieldsWhenTheSavedConfigHasNone() throws {
        let (template, engine) = try stubTemplate()
        let clone = try template.cloneLinked(named: "Copy", engine: engine)
        let stored = try clone.loadConfig()
        XCTAssertEqual(stored.cloneOf, "Base")
        XCTAssertEqual(stored.templateEpoch, 0)
        XCTAssertEqual(stored.templatePath, standardPath(template.url))
        XCTAssertNotNil(stored.templateDiskID)

        var draft = stored
        draft.cloneOf = nil; draft.templateEpoch = nil; draft.templatePath = nil; draft.templateDiskID = nil
        draft.memoryMiB = 2048
        var expected = stored
        expected.memoryMiB = 2048
        XCTAssertEqual(try clone.save(draft), expected)
        XCTAssertEqual(try clone.loadConfig(), expected)
    }

    func testFirstCloneSetsTheTemplateDiskIDAndClonesRecordIt() throws {
        let (template, engine) = try stubTemplate()
        XCTAssertNil(try template.loadConfig().diskID)

        let first = try template.cloneLinked(named: "First", engine: engine).loadConfig()
        let id = try XCTUnwrap(try template.loadConfig().diskID)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(first.templateDiskID, id)
        XCTAssertNil(first.diskID)
        XCTAssertNil(try template.loadConfig().templateDiskID)

        XCTAssertEqual(try template.advanceDiskEpoch(), 1)
        let second = try template.cloneLinked(named: "Second", engine: engine).loadConfig()
        XCTAssertEqual(try template.loadConfig().diskID, id)
        XCTAssertEqual(second.templateDiskID, id)
    }

    func testTemplateMismatchRefusesADifferentVMAtTheTemplatePath() throws {
        let (template, engine) = try stubTemplate()
        let old = try template.cloneLinked(named: "Copy", engine: engine).loadConfig()
        let path = standardPath(template.url)
        let other = "the VM at \(path) is not the template 'Copy' was cloned from; the clone cannot run"
        XCTAssertNil(VMBundle.templateMismatch(for: old))

        try FileManager.default.removeItem(at: template.url)
        let replacement = try VMBundle.create(VMConfig.defaults(name: "Base", guestOS: .linux), in: tmp, engine: engine)
        XCTAssertEqual(standardPath(replacement.url), path)
        XCTAssertEqual(VMBundle.templateMismatch(for: old), other)

        let fresh = try replacement.cloneLinked(named: "Fresh", engine: engine).loadConfig()
        XCTAssertEqual(try replacement.loadConfig().diskEpoch, 0)
        XCTAssertEqual(old.templateEpoch, 0)
        XCTAssertEqual(VMBundle.templateMismatch(for: old), other)
        XCTAssertNil(VMBundle.templateMismatch(for: fresh))
    }

    // MARK: - linked clones (real qemu-img)

    func testFirstCloneSetsTheTemplateEpochAndLaterClonesKeepIt() throws {
        let engine = try realEngine()
        let (template, _) = try makeTemplate(engine)
        XCTAssertNil(try template.loadConfig().diskEpoch)

        let first = try template.cloneLinked(named: "First", engine: engine).loadConfig()
        XCTAssertEqual(try template.loadConfig().diskEpoch, 0)
        XCTAssertEqual(first.templateEpoch, 0)
        XCTAssertEqual(first.templatePath, standardPath(template.url))
        XCTAssertNotNil(first.templateDiskID)
        XCTAssertEqual(first.templateDiskID, try template.loadConfig().diskID)
        XCTAssertNil(first.diskEpoch)
        XCTAssertNil(try template.loadConfig().templateEpoch)
        XCTAssertNil(try template.loadConfig().templatePath)

        let stored = try Data(contentsOf: template.configURL)
        let second = try template.cloneLinked(named: "Second", engine: engine).loadConfig()
        XCTAssertEqual(try Data(contentsOf: template.configURL), stored)
        XCTAssertEqual(second.templateEpoch, 0)
        XCTAssertEqual(second.templatePath, standardPath(template.url))
        XCTAssertEqual(second.templateDiskID, first.templateDiskID)

        try setDiskEpoch(4, of: template)
        let third = try template.cloneLinked(named: "Third", engine: engine).loadConfig()
        XCTAssertEqual(try template.loadConfig().diskEpoch, 4)
        XCTAssertEqual(third.templateEpoch, 4)
    }

    private func realEngine() throws -> EngineLocator.Engine {
        let engine = try? EngineLocator.standard().locate()
        try XCTSkipIf(engine == nil, "engine not built; run scripts/build-qemu.sh")
        return engine!
    }

    private func makeTemplate(_ engine: EngineLocator.Engine, name: String = "Template") throws -> (VMBundle, VMConfig) {
        var config = VMConfig.defaults(name: name, guestOS: .linux, installISO: "/isos/x.iso")
        config.disks[0].sizeGiB = 1
        config.network = .user(portForwards: [.init(hostPort: 2222, guestPort: 22)])
        config.usbPassthrough = [.init(vendorID: 0x05ac, productID: 0x12a8)]
        config.sharedFolders = [.init(hostPath: "/Users/me", tag: "home")]
        return (try VMBundle.create(config, in: tmp, engine: engine), config)
    }

    private func imageInfo(_ url: URL, _ engine: EngineLocator.Engine) throws -> [String: Any] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: engine.qemuImg)
        p.arguments = ["info", "--output=json", url.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func listedClones(_ bundle: VMBundle) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(contentsOf: bundle.clonesURL))
    }

    func testCloneLinkedCreatesOverlay() throws {
        let engine = try realEngine()
        let (template, config) = try makeTemplate(engine)
        let clone = try template.cloneLinked(named: "Clone", engine: engine)
        XCTAssertEqual(clone.url.path, tmp.appendingPathComponent("Clone.alcovevm").path)
        let info = try imageInfo(clone.diskURL(config.disks[0]), engine)
        XCTAssertEqual(info["backing-filename"] as? String, template.diskURL(config.disks[0]).path)
        XCTAssertEqual(info["backing-filename-format"] as? String, "qcow2")
        XCTAssertEqual(info["virtual-size"] as? Int, 1 << 30)
        XCTAssertEqual(try Data(contentsOf: clone.efiVarsURL), try Data(contentsOf: template.efiVarsURL))

        let c = try clone.loadConfig()
        XCTAssertEqual(c.name, "Clone")
        XCTAssertEqual(c.cloneOf, "Template")
        XCTAssertNotEqual(c.agentToken, config.agentToken)
        XCTAssertEqual(c.agentKey, config.agentKey)
        XCTAssertNotEqual(c.agentHostPort, config.agentHostPort)
        XCTAssertEqual(c.agentHostPort, VMConfig.agentPort(for: c.agentToken))
        XCTAssertNotEqual(c.macAddress, config.macAddress)
        XCTAssertEqual(c.network, .user(portForwards: []))
        XCTAssertEqual(c.cdroms, [])
        XCTAssertEqual(c.usbPassthrough, [])
        XCTAssertEqual(c.sharedFolders, config.sharedFolders)
        XCTAssertEqual(c.disks, config.disks)
        XCTAssertEqual(c.cpuCount, config.cpuCount); XCTAssertEqual(c.memoryMiB, config.memoryMiB)
        XCTAssertEqual(c.display, config.display); XCTAssertEqual(c.guestOS, config.guestOS)
        XCTAssertFalse(c.tpm)
        XCTAssertNil(try template.loadConfig().cloneOf)
    }

    func testCloneOfTemplateWithoutNetworkHasNoNetwork() throws {
        let engine = try realEngine()
        let (template, _) = try makeTemplate(engine)
        var config = try template.loadConfig()
        config.network = .none
        try template.save(config)
        XCTAssertEqual(try template.cloneLinked(named: "Offline", engine: engine).loadConfig().network, VMConfig.Network.none)
    }

    func testCloneRegisteredAndPruned() throws {
        let engine = try realEngine()
        let fm = FileManager.default
        let (template, _) = try makeTemplate(engine)
        XCTAssertEqual(template.liveClones(), [])
        XCTAssertFalse(fm.fileExists(atPath: template.clonesURL.path))

        let first = try template.cloneLinked(named: "First", engine: engine)
        let second = try template.cloneLinked(named: "Second", engine: engine)
        XCTAssertEqual(template.liveClones().map(standardPath), [standardPath(first.url), standardPath(second.url)])
        XCTAssertEqual(try listedClones(template), [standardPath(first.url), standardPath(second.url)])

        try fm.removeItem(at: first.url)
        XCTAssertEqual(template.liveClones().map(standardPath), [standardPath(second.url)])
        XCTAssertEqual(try listedClones(template), [standardPath(second.url)])

        try second.deleteClone()
        XCTAssertFalse(fm.fileExists(atPath: second.url.path))
        XCTAssertFalse(fm.fileExists(atPath: template.clonesURL.path))
        XCTAssertEqual(template.liveClones(), [])
    }

    func testCloneRefusals() throws {
        let engine = try realEngine()
        let fm = FileManager.default
        let (template, _) = try makeTemplate(engine)
        let clone = try template.cloneLinked(named: "Clone", engine: engine)

        XCTAssertThrowsError(try template.cloneLinked(named: "Clone", engine: engine)) {
            XCTAssertEqual($0 as? VMBundle.CloneError, .nameExists("Clone"))
            XCTAssertEqual("\($0)", "a VM named 'Clone' already exists; choose another name")
        }
        XCTAssertThrowsError(try clone.cloneLinked(named: "Grandchild", engine: engine)) {
            XCTAssertEqual($0 as? VMBundle.CloneError, .sourceIsClone("Clone", template: "Template"))
            XCTAssertEqual("\($0)", "'Clone' is a clone of 'Template'; clone 'Template' instead")
        }
        XCTAssertThrowsError(try template.cloneLinked(named: "a/b", engine: engine)) {
            XCTAssertEqual($0 as? VMBundle.CloneError, .invalidName("a/b"))
        }

        try Data("state".utf8).write(to: template.suspendStateURL)
        XCTAssertThrowsError(try template.cloneLinked(named: "FromSuspended", engine: engine)) {
            XCTAssertEqual($0 as? VMBundle.CloneError, .sourceSuspended("Template"))
        }
        try template.discardSuspendState()

        var withTPM = try template.loadConfig()
        withTPM.tpm = true
        try template.save(withTPM)
        XCTAssertThrowsError(try template.cloneLinked(named: "WithTPM", engine: engine)) {
            XCTAssertEqual("\($0)", "cannot clone a VM with a TPM")
        }

        XCTAssertThrowsError(try template.deleteClone()) {
            XCTAssertEqual("\($0)", "'Template' is not a clone; delete it in the Alcove app")
        }
        XCTAssertEqual(VMBundle.list(in: tmp).map(\.url.lastPathComponent), ["Clone.alcovevm", "Template.alcovevm"])
        XCTAssertEqual(try listedClones(template), [standardPath(clone.url)])
        XCTAssertTrue(fm.fileExists(atPath: template.configURL.path))
    }
}
