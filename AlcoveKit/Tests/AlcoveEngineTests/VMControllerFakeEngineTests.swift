import XCTest
@testable import AlcoveEngine

/// The controller state machine against a fake engine: a Python stand-in for
/// `qemu-system-aarch64` that serves QMP on the `-qmp` socket, holds the
/// `-pidfile` lock like QEMU, records its argv, and misbehaves on request
/// (`FAKE_QEMU_MODE`). Runs without the real engine.
final class VMControllerFakeEngineTests: XCTestCase {
    private var tmp: URL!
    private var script: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alcove-fake-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        script = tmp.appendingPathComponent("fake-qemu.py")
        try fakeQEMUSource.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }
    /// Every controller a test created; force-stopped on teardown so a failing
    /// test cannot leak a fake engine.
    private var controllers: [VMController] = []

    override func tearDown() async throws {
        for vm in controllers where await vm.state.isActive { try? await vm.shutdown(force: true) }
        controllers.removeAll()
        if ProcessInfo.processInfo.environment["ALCOVE_KEEP_TEST_TMP"] == nil { try? FileManager.default.removeItem(at: tmp) }
    }

    private func engine(mode: String) throws -> EngineLocator.Engine {
        let root = tmp.appendingPathComponent("engine-\(mode.isEmpty ? "normal" : mode)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("pc-bios"), withIntermediateDirectories: true)
        let wrapper = "#!/bin/sh\nFAKE_QEMU_MODE='\(mode)' exec /usr/bin/env python3 '\(script.path)' \"$@\"\n"
        fm.createFile(atPath: root.appendingPathComponent("qemu-system-aarch64").path, contents: Data(wrapper.utf8), attributes: [.posixPermissions: 0o755])
        // create -q -f qcow2 FILE SIZE | create -q -f qcow2 -F qcow2 -b BACKING FILE | info ...
        let img = "#!/bin/sh\ncase \"$1\" in\ncreate) out=\"$5\"; if [ \"$5\" = -F ]; then for out; do :; done; fi; printf 'QFI' > \"$out\";;\n"
            + "info) echo '{\"snapshots\": []}';;\nesac\n"
        fm.createFile(atPath: root.appendingPathComponent("qemu-img").path, contents: Data(img.utf8), attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: root.appendingPathComponent("pc-bios/edk2-aarch64-code.fd").path, contents: Data(count: 16))
        return EngineLocator.Engine(qemuSystem: root.appendingPathComponent("qemu-system-aarch64").path,
                                    qemuImg: root.appendingPathComponent("qemu-img").path,
                                    firmwareDir: root.appendingPathComponent("pc-bios").path, swtpm: nil)
    }

    private func makeVM(mode: String = "", configure: (inout VMConfig) -> Void = { _ in }) throws -> VMController {
        let engine = try engine(mode: mode)
        var config = VMConfig.defaults(name: "Fake", guestOS: .other)
        config.cpuCount = 2; config.memoryMiB = 512; config.network = .none
        configure(&config)
        let dir = tmp.appendingPathComponent("vms-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundle = try VMBundle.create(config, in: dir, engine: engine)
        let vm = VMController(bundle: bundle, config: config, engine: engine)
        controllers.append(vm)
        return vm
    }

    /// The argv the fake engine was launched with (written next to the pidfile).
    private func argv(_ vm: VMController) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(contentsOf: vm.bundle.runURL.appendingPathComponent("fake-argv.json")))
    }

    private func waitUntil(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    func testLifecycleAndStateStream() async throws {
        let vm = try makeVM()
        let log = StateLog()
        let observer = Task { for await s in vm.states { await log.append(s) } }
        defer { observer.cancel() }
        try await vm.start()
        var s = await vm.state; XCTAssertEqual(s, .running)
        let running = await vm.runningConfig; XCTAssertEqual(running?.name, "Fake")
        XCTAssertNotNil(VMController.pidfileLockHolder(vm.bundle.pidFileURL.path), "the fake locks its pidfile like QEMU")
        try await vm.pause(); s = await vm.state; XCTAssertEqual(s, .paused)
        try await vm.resume(); s = await vm.state; XCTAssertEqual(s, .running)
        try await vm.createSnapshot(named: "one")
        try await vm.restoreSnapshot(named: "one"); s = await vm.state; XCTAssertEqual(s, .running)
        try await vm.deleteSnapshot(named: "one")
        let shot = tmp.appendingPathComponent("shot.png")
        try await vm.screenshot(to: shot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shot.path))
        try await vm.shutdown(force: false, gracePeriod: .seconds(5))
        s = await vm.state; XCTAssertEqual(s, .stopped)
        XCTAssertNil(VMController.pidfileLockHolder(vm.bundle.pidFileURL.path))
        let after = await vm.runningConfig; XCTAssertNil(after)
        let states = await log.states
        XCTAssertEqual(states, [.starting, .running, .paused, .running, .paused, .running, .stopping, .stopped])
    }

    /// Stopped vCPUs cannot act on the power button: the guest is resumed first
    /// (the fake only honours `system_powerdown` while running).
    func testShutdownWhilePausedResumesTheGuestFirst() async throws {
        let vm = try makeVM()
        try await vm.start()
        try await vm.pause()
        let t0 = ContinuousClock.now
        try await vm.shutdown(force: false, gracePeriod: .seconds(8))
        XCTAssertLessThan(ContinuousClock.now - t0, .seconds(4), "must not burn the grace period")
        let s = await vm.state; XCTAssertEqual(s, .stopped)
    }

    func testFailedSuspendLeavesTheGuestRunningAndNoStateFile() async throws {
        let vm = try makeVM(mode: "migrate-fails")
        try await vm.start()
        await XCTAssertThrowsErrorAsync(try await vm.suspendToDisk())
        let s = await vm.state; XCTAssertEqual(s, .running)
        XCTAssertFalse(vm.bundle.isSuspended, "a partial state file must not survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.bundle.suspendConfigURL.path))
        let status = try await vm.qmp!.queryStatus(); XCTAssertTrue(status.running)
        try await vm.pause(); try await vm.resume()   // still fully operational
        try await vm.shutdown(force: true)
        let s2 = await vm.state; XCTAssertEqual(s2, .stopped)
    }

    /// The `-incoming` stream only loads into the machine that produced it: a
    /// resume launches the saved configuration, later edits apply to the next cold start.
    func testResumeUsesTheConfigurationThatWasSuspended() async throws {
        let vm = try makeVM()
        try await vm.start()
        var edited = await vm.config
        edited.memoryMiB = 1024
        try await vm.update(config: edited)
        try await vm.suspendToDisk()
        var s = await vm.state; XCTAssertEqual(s, .stopped)
        XCTAssertTrue(vm.bundle.isSuspended)
        XCTAssertEqual(vm.bundle.loadSuspendedConfig()?.memoryMiB, 512)
        try await vm.start(bootFromCDROM: true)   // ignored while resuming
        s = await vm.state; XCTAssertEqual(s, .running)
        XCTAssertFalse(vm.bundle.isSuspended)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.bundle.suspendConfigURL.path))
        let running = await vm.runningConfig; XCTAssertEqual(running?.memoryMiB, 512)
        let next = await vm.config; XCTAssertEqual(next.memoryMiB, 1024)
        var a = try argv(vm)
        XCTAssertEqual(a[a.firstIndex(of: "-m")! + 1], "512")
        XCTAssertTrue(a.contains("-incoming"))
        try await vm.shutdown(force: true)
        try await vm.start()
        a = try argv(vm)
        XCTAssertEqual(a[a.firstIndex(of: "-m")! + 1], "1024")
        XCTAssertFalse(a.contains("-incoming"))
        try await vm.shutdown(force: true)
    }

    func testFailedResumeKeepsTheSavedSessionUntilDiscarded() async throws {
        let vm = try makeVM(mode: "incoming-fails")
        let log = StateLog()
        let observer = Task { for await s in vm.states { await log.append(s) } }
        defer { observer.cancel() }
        try await vm.start()
        try await vm.suspendToDisk()
        XCTAssertTrue(vm.bundle.isSuspended)
        await XCTAssertThrowsErrorAsync(try await vm.start())
        let s = await vm.state
        guard case .failed(let msg) = s else { return XCTFail("\(s)") }
        XCTAssertTrue(msg.contains("load of migration failed"), msg)
        XCTAssertTrue(msg.contains("saved session was kept"), msg)
        XCTAssertTrue(vm.bundle.isSuspended, "a failed resume must not destroy the session")
        try await Task.sleep(for: .milliseconds(500))
        let states = await log.states
        XCTAssertEqual(states, [.starting, .running, .suspending, .stopped, .starting, .failed(msg)], "one failure report")
        try await vm.discardSuspendState()
        XCTAssertFalse(vm.bundle.isSuspended)
        try await vm.start()   // cold boot works again
        let s2 = await vm.state; XCTAssertEqual(s2, .running)
        try await vm.shutdown(force: true)
    }

    func testFailureWhileTheEngineIsAliveReportsTheCauseOnce() async throws {
        let vm = try makeVM(mode: "bad-status")
        let log = StateLog()
        let observer = Task { for await s in vm.states { await log.append(s) } }
        defer { observer.cancel() }
        await XCTAssertThrowsErrorAsync(try await vm.start())
        let s = await vm.state
        guard case .failed(let msg) = s else { return XCTFail("\(s)") }
        XCTAssertTrue(msg.contains("query-status"), "the thrown error, not a bare exit status: \(msg)")
        // the still-running engine is killed, and its exit must not replace the report
        let gone = await waitUntil { VMController.pidfileLockHolder(vm.bundle.pidFileURL.path) == nil }
        XCTAssertTrue(gone)
        try await Task.sleep(for: .milliseconds(500))
        let states = await log.states
        XCTAssertEqual(states, [.starting, .failed(msg)])
    }

    /// Stop while a resume is still loading: the start is aborted cleanly (no
    /// `.running` after `.stopping`), the engine is gone, the session survives.
    func testStopDuringStartAbortsTheStart() async throws {
        let vm = try makeVM(mode: "slow-incoming")
        try await vm.start()
        try await vm.suspendToDisk()
        let log = StateLog()
        let observer = Task { for await s in vm.states { await log.append(s) } }
        defer { observer.cancel() }
        let starter = Task { try await vm.start() }
        let loading = await waitUntil { await vm.qmp != nil }
        XCTAssertTrue(loading)
        try await vm.shutdown(force: true)
        let s = await vm.state; XCTAssertEqual(s, .stopped)
        do {
            try await starter.value
            XCTFail("the aborted start must not succeed")
        } catch {
            XCTAssertEqual(error as? VMController.ControllerError, .notRunning)
        }
        XCTAssertTrue(vm.bundle.isSuspended)
        XCTAssertNil(VMController.pidfileLockHolder(vm.bundle.pidFileURL.path))
        try await Task.sleep(for: .milliseconds(500))
        let states = await log.states
        XCTAssertEqual(Array(states.suffix(3)), [.starting, .stopping, .stopped])
        XCTAssertFalse(states.dropFirst(4).contains(.running), "no .running after the aborted start: \(states)")
        try await vm.start()   // and the session can still be resumed
        let s2 = await vm.state; XCTAssertEqual(s2, .running)
        try await vm.shutdown(force: true)
    }

    /// After an app crash the engine outlives it; a new controller must stop
    /// that orphan (found through the pidfile lock) before relaunching.
    func testOrphanedEngineIsStoppedBeforeRelaunch() async throws {
        let vm = try makeVM()
        try await vm.start()
        guard let orphan = VMController.pidfileLockHolder(vm.bundle.pidFileURL.path) else { return XCTFail("no pidfile lock") }
        let cfg = await vm.config
        let fresh = VMController(bundle: vm.bundle, config: cfg, engine: vm.engine)
        controllers.append(fresh)
        try await fresh.start()
        let s = await fresh.state; XCTAssertEqual(s, .running)
        let holder = VMController.pidfileLockHolder(vm.bundle.pidFileURL.path)
        XCTAssertNotNil(holder)
        XCTAssertNotEqual(holder, orphan)
        let reaped = await waitUntil { kill(orphan, 0) != 0 }
        XCTAssertTrue(reaped, "orphan pid \(orphan) must be gone")
        try await fresh.shutdown(force: true)
        let old = await vm.state
        XCTAssertFalse(old.isActive, "the old controller observed its engine's exit: \(old)")
    }

    func testRestoreFailureLeavesTheGuestRunning() async throws {
        let vm = try makeVM()
        try await vm.start()
        await XCTAssertThrowsErrorAsync(try await vm.restoreSnapshot(named: "missing"))
        let s = await vm.state; XCTAssertEqual(s, .running)
        let status = try await vm.qmp!.queryStatus(); XCTAssertTrue(status.running)
        try await vm.shutdown(force: true)
    }

    func testUSBAttachIDsAreUniquePerAttachment() async throws {
        let vm = try makeVM()
        try await vm.start()
        let sel = VMConfig.USBSelector(vendorID: 0x05ac, productID: 0x12a8)
        let a = try await vm.attachUSB(sel)
        let b = try await vm.attachUSB(sel)   // the fake rejects duplicate ids like device_add
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("usbhot-05ac-12a8"), a)
        try await vm.detachUSB(id: a)
        try await vm.shutdown(force: true)
    }

    func testChangeMediumUpdatesBothConfigurations() async throws {
        let iso = tmp.appendingPathComponent("x.iso")
        try Data(count: 2048).write(to: iso)
        let vm = try makeVM { $0.cdroms = [.init(id: "cd0", path: nil)] }
        try await vm.start(bootFromCDROM: true)
        XCTAssertTrue(try argv(vm).contains("scsi-cd,id=cd0-dev,bus=cd0-bot.0,bootindex=0"))
        do {
            try await vm.changeMedium(cdromID: "cd0", isoPath: iso.path)
        } catch {
            let log = (try? String(contentsOf: vm.bundle.qemuLogURL, encoding: .utf8)) ?? "<no log>"
            XCTFail("changeMedium: \(error)\n\(log)")
            throw error
        }
        var c = await vm.config; XCTAssertEqual(c.cdroms[0].path, iso.path)
        let r = await vm.runningConfig; XCTAssertEqual(r?.cdroms[0].path, iso.path)
        try await vm.changeMedium(cdromID: "cd0", isoPath: nil)
        c = await vm.config; XCTAssertNil(c.cdroms[0].path)
        try await vm.shutdown(force: true)
    }

    private func launched(_ vm: VMController) -> Bool {
        FileManager.default.fileExists(atPath: vm.bundle.runURL.appendingPathComponent("fake-argv.json").path)
    }

    private func ephemeralFiles(_ vm: VMController) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: vm.bundle.runURL.path)) ?? []).filter { $0.hasPrefix("ephemeral-") }.sorted()
    }

    func testTemplateRefusesToStart() async throws {
        let vm = try makeVM()
        let clone = try vm.bundle.cloneLinked(named: "Clone", engine: vm.engine)
        do {
            try await vm.start()
            XCTFail("a template with clones started")
        } catch {
            XCTAssertEqual(error as? VMController.ControllerError,
                           .engineDidNotStart("'Fake' is a template with clones (Clone); delete the clones first or start a clone"))
        }
        await XCTAssertThrowsErrorAsync(try await vm.start(discardChanges: true))
        var s = await vm.state; XCTAssertEqual(s, .stopped)
        XCTAssertFalse(launched(vm))

        let cloned = VMController(bundle: clone, config: try clone.loadConfig(), engine: vm.engine)
        controllers.append(cloned)
        try await cloned.start()
        s = await cloned.state; XCTAssertEqual(s, .running)
        try await cloned.shutdown(force: true)

        try clone.deleteClone()
        try await vm.start()
        s = await vm.state; XCTAssertEqual(s, .running)
        try await vm.shutdown(force: true)
    }

    func testCloneRefusedWhileTemplateStarting() async throws {
        let vm = try makeVM()
        let cloneURL = vm.bundle.url.deletingLastPathComponent().appendingPathComponent("Clone.alcovevm")
        let starter = Task { try await vm.start() }
        let active = await waitUntil { await vm.state.isActive }
        XCTAssertTrue(active)
        do {
            _ = try await vm.cloneLinked(named: "Clone")
            XCTFail("an active template was cloned")
        } catch {
            XCTAssertEqual(error as? VMBundle.CloneError, .sourceRunning("Fake"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneURL.path))
        XCTAssertEqual(vm.bundle.liveClones(), [])
        try await starter.value
        await XCTAssertThrowsErrorAsync(try await vm.cloneLinked(named: "Clone"))
        try await vm.shutdown(force: true)

        let clone = try await vm.cloneLinked(named: "Clone")
        XCTAssertEqual(clone.url.lastPathComponent, "Clone.alcovevm")
        try FileManager.default.removeItem(at: vm.bundle.runURL.appendingPathComponent("fake-argv.json"))
        do {
            try await vm.start()
            XCTFail("a template with clones started")
        } catch {
            XCTAssertEqual(error as? VMController.ControllerError,
                           .engineDidNotStart("'Fake' is a template with clones (Clone); delete the clones first or start a clone"))
        }
        XCTAssertFalse(launched(vm))
    }

    func testCloneDeletionRefusedWhileTheCloneIsActive() async throws {
        let vm = try makeVM()
        let bundle = try await vm.cloneLinked(named: "Clone")
        let clone = VMController(bundle: bundle, config: try bundle.loadConfig(), engine: vm.engine)
        controllers.append(clone)
        let starter = Task { try await clone.start() }
        let active = await waitUntil { await clone.state.isActive }
        XCTAssertTrue(active)
        do {
            try await clone.deleteClone()
            XCTFail("an active clone was deleted")
        } catch {
            XCTAssertEqual(error as? VMBundle.CloneError, .cloneRunning("Clone"))
        }
        try await starter.value
        try await clone.shutdown(force: true)
        try await clone.deleteClone()
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.url.path))
        XCTAssertEqual(vm.bundle.liveClones(), [])
    }

    func testTemplateGuardNamesClonesByTheirConfigName() async throws {
        let vm = try makeVM()
        let clone = try await vm.cloneLinked(named: "Clone")
        let moved = clone.url.deletingLastPathComponent().appendingPathComponent("Moved.alcovevm")
        try FileManager.default.moveItem(at: clone.url, to: moved)
        do {
            try await vm.start()
            XCTFail("a template with a moved clone started")
        } catch {
            XCTAssertEqual(error as? VMController.ControllerError,
                           .engineDidNotStart("'Fake' is a template with clones (Clone); delete the clones first or start a clone"))
        }
        let s = await vm.state; XCTAssertEqual(s, .stopped)
    }

    func testEphemeralOverlayRemovedOnStop() async throws {
        let vm = try makeVM { $0.disks.append(.init(id: "disk1", fileName: "disk1.qcow2", sizeGiB: 1, bus: .virtioBlk)) }
        let run = vm.bundle.runURL
        try await vm.start(discardChanges: true)
        var ephemeral = await vm.isEphemeral; XCTAssertTrue(ephemeral)
        XCTAssertEqual(ephemeralFiles(vm), ["ephemeral-disk0.qcow2", "ephemeral-disk1.qcow2", "ephemeral-efi-vars.fd"])
        XCTAssertEqual(try Data(contentsOf: run.appendingPathComponent("ephemeral-efi-vars.fd")), try Data(contentsOf: vm.bundle.efiVarsURL))
        var a = try argv(vm)
        XCTAssertTrue(a.contains("driver=file,node-name=disk0-file,filename=\(run.path)/ephemeral-disk0.qcow2,discard=unmap"))
        XCTAssertTrue(a.contains("driver=file,node-name=disk1-file,filename=\(run.path)/ephemeral-disk1.qcow2,discard=unmap"))
        XCTAssertTrue(a.contains("if=pflash,format=raw,file=\(run.path)/ephemeral-efi-vars.fd"))

        try await vm.shutdown(force: true)
        XCTAssertEqual(ephemeralFiles(vm), [])
        ephemeral = await vm.isEphemeral; XCTAssertFalse(ephemeral)

        try await vm.start()
        ephemeral = await vm.isEphemeral; XCTAssertFalse(ephemeral)
        XCTAssertEqual(ephemeralFiles(vm), [])
        a = try argv(vm)
        XCTAssertTrue(a.contains("driver=file,node-name=disk0-file,filename=\(vm.bundle.url.path)/disk0.qcow2,discard=unmap"))
        XCTAssertTrue(a.contains("if=pflash,format=raw,file=\(vm.bundle.efiVarsURL.path)"))
        try await vm.shutdown(force: true)
    }

    func testEphemeralOverlayRemovedWhenTheGuestPowersOff() async throws {
        let vm = try makeVM()
        try await vm.start(discardChanges: true)
        try await vm.shutdown(force: false, gracePeriod: .seconds(5))
        let s = await vm.state; XCTAssertEqual(s, .stopped)
        XCTAssertEqual(ephemeralFiles(vm), [])
        let ephemeral = await vm.isEphemeral; XCTAssertFalse(ephemeral)
    }

    func testEphemeralFailedStartLeavesNoOverlay() async throws {
        let vm = try makeVM(mode: "bad-status")
        await XCTAssertThrowsErrorAsync(try await vm.start(discardChanges: true))
        let s = await vm.state
        guard case .failed = s else { return XCTFail("\(s)") }
        XCTAssertTrue(launched(vm))
        XCTAssertEqual(ephemeralFiles(vm), [])
        let ephemeral = await vm.isEphemeral; XCTAssertFalse(ephemeral)
    }

    func testEphemeralRefusesSuspend() async throws {
        let vm = try makeVM()
        try await vm.start(discardChanges: true)
        do {
            try await vm.suspendToDisk()
            XCTFail("a session that discards changes was suspended")
        } catch {
            XCTAssertEqual(error as? VMController.ControllerError,
                           .engineDidNotStart("this session discards changes and cannot be suspended; stop it instead"))
        }
        let s = await vm.state; XCTAssertEqual(s, .running)
        XCTAssertFalse(vm.bundle.isSuspended)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.bundle.suspendConfigURL.path))
        try await vm.pause(); try await vm.resume()
        try await vm.shutdown(force: true)
    }

    func testSuspendedBundleRefusesDiscardChanges() async throws {
        let vm = try makeVM()
        try await vm.start()
        try await vm.suspendToDisk()
        try FileManager.default.removeItem(at: vm.bundle.runURL.appendingPathComponent("fake-argv.json"))
        do {
            try await vm.start(discardChanges: true)
            XCTFail("a suspended session was started discarding changes")
        } catch {
            guard case .engineDidNotStart(let message)? = error as? VMController.ControllerError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("suspended session"), message)
        }
        var s = await vm.state; XCTAssertEqual(s, .stopped)
        XCTAssertTrue(vm.bundle.isSuspended)
        XCTAssertFalse(launched(vm))
        try await vm.start()
        s = await vm.state; XCTAssertEqual(s, .running)
        XCTAssertTrue(try argv(vm).contains("-incoming"))
        try await vm.shutdown(force: true)
    }

    /// tpm-tis-device aborts under HVF in this engine build: refuse before launching anything.
    func testTPMIsRefusedUpFront() async throws {
        let vm = try makeVM { $0.tpm = true }
        await XCTAssertThrowsErrorAsync(try await vm.start())
        let s = await vm.state
        guard case .failed(let msg) = s else { return XCTFail("\(s)") }
        XCTAssertTrue(msg.contains("TPM"), msg)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.bundle.runURL.appendingPathComponent("fake-argv.json").path), "nothing must be launched")
        try await vm.discardSuspendState()   // allowed while not active
    }
}

/// See the class comment. `FAKE_QEMU_MODE`: "" | exit-early | bad-status |
/// migrate-fails | incoming-fails | slow-incoming | ignore-powerdown.
private let fakeQEMUSource = #"""
#!/usr/bin/env python3
import fcntl, json, os, socket, sys, threading, time

mode = os.environ.get("FAKE_QEMU_MODE", "")
args = sys.argv[1:]

def opt(name):
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            return args[i + 1]
    return None

def err(msg):
    sys.stderr.write("qemu-system-aarch64: " + msg + "\n"); sys.stderr.flush()

if mode == "exit-early":
    err("-drive if=pflash,format=raw,file=efi-vars.fd: Could not open 'efi-vars.fd': No such file or directory")
    sys.exit(1)

qmp_path = opt("-qmp")[len("unix:"):].split(",")[0]
pidfile = opt("-pidfile")
incoming = opt("-incoming")
with open(os.path.join(os.path.dirname(pidfile), "fake-argv.json"), "w") as f:
    json.dump(args, f)
pf = open(pidfile, "w")
fcntl.lockf(pf, fcntl.LOCK_EX | fcntl.LOCK_NB)   # F_SETLK write lock, like qemu_write_pidfile
pf.write(str(os.getpid())); pf.flush()

lock = threading.Lock()
st = {"running": False, "status": "inmigrate"} if incoming else {"running": True, "status": "running"}
snapshots, jobs, devices, migration = set(), {}, set(), {}
pending_powerdown = False
conn = None

def send(obj):
    with lock:
        if conn is not None:
            try:
                conn.sendall((json.dumps(obj) + "\n").encode())
            except OSError:
                pass

def event(name, data=None):
    send({"event": name, "data": data or {}, "timestamp": {"seconds": int(time.time()), "microseconds": 0}})

def die(code, delay):
    def run():
        time.sleep(delay)
        os._exit(code)
    threading.Thread(target=run, daemon=True).start()

def finish_incoming():
    time.sleep(3.0 if mode == "slow-incoming" else 0.4)
    path = incoming[len("file:"):]
    if mode == "incoming-fails" or not (os.path.exists(path) and os.path.getsize(path) > 0):
        err("load of migration failed: Invalid argument")
        os._exit(1)
    st.update(running=False, status="paused")   # the saved run state

if incoming:
    threading.Thread(target=finish_incoming, daemon=True).start()

def handle(req):
    global pending_powerdown
    cmd = req.get("execute"); rid = req.get("id"); a = req.get("arguments") or {}
    def ok(ret=None):
        send({"return": {} if ret is None else ret, "id": rid})
    def fail(cls, desc):
        send({"error": {"class": cls, "desc": desc}, "id": rid})
    if cmd == "qmp_capabilities":
        ok()
    elif cmd == "query-status":
        ok({"bogus": True} if mode == "bad-status" else dict(st))
    elif cmd == "stop":
        st.update(running=False, status="paused"); ok(); event("STOP")
    elif cmd == "cont":
        if st["status"] == "inmigrate":
            ok()
        else:
            st.update(running=True, status="running"); ok(); event("RESUME")
            if pending_powerdown:
                pending_powerdown = False
                event("SHUTDOWN", {"guest": True, "reason": "guest-shutdown"}); die(0, 0.2)
    elif cmd == "system_powerdown":
        ok(); event("POWERDOWN")
        if mode == "ignore-powerdown":
            pass
        elif st["running"]:
            event("SHUTDOWN", {"guest": True, "reason": "guest-shutdown"}); die(0, 0.2)
        else:
            pending_powerdown = True   # stopped vCPUs cannot act on the button
    elif cmd == "system_reset":
        ok(); event("RESET", {"guest": False, "reason": "host-qmp-system-reset"})
    elif cmd == "quit":
        ok(); event("SHUTDOWN", {"guest": False, "reason": "host-qmp-quit"}); die(0, 0.1)
    elif cmd == "migrate":
        path = a["uri"][len("file:"):]
        if mode == "migrate-fails":
            open(path, "wb").close()   # QEMU creates the file before failing
            migration.update({"status": "failed", "error-desc": "fake: no space left on device"})
        else:
            with open(path, "wb") as f:
                f.write(b"FAKESTATE" * 1024)
            migration.update({"status": "completed"})
            st.update(running=False, status="postmigrate")
        ok()
    elif cmd == "query-migrate":
        ok(dict(migration))
    elif cmd in ("snapshot-save", "snapshot-load", "snapshot-delete"):
        tag = a["tag"]; jid = a["job-id"]; e = None
        if cmd == "snapshot-save":
            snapshots.add(tag)
        elif cmd == "snapshot-load":
            if tag not in snapshots:
                e = "Snapshot '%s' does not exist in one or more devices" % tag
        else:
            snapshots.discard(tag)
        jobs[jid] = e
        ok()
        for s in ("created", "running", "waiting", "pending", "concluded"):
            event("JOB_STATUS_CHANGE", {"id": jid, "status": s})
    elif cmd == "query-jobs":
        ok([dict({"id": j, "type": cmd, "status": "concluded", "current-progress": 1, "total-progress": 1},
                 **({"error": e} if e else {})) for j, e in jobs.items()])
    elif cmd == "job-dismiss":
        jobs.pop(a["id"], None); ok()
    elif cmd == "device_add":
        if a["id"] in devices:
            fail("GenericError", "Duplicate device ID '%s'" % a["id"])
        else:
            devices.add(a["id"]); ok()
    elif cmd == "device_del":
        devices.discard(a["id"]); ok()
        event("DEVICE_DELETED", {"device": a["id"], "path": "/machine/peripheral/" + a["id"]})
    elif cmd == "screendump":
        with open(a["filename"], "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n" + b"\0" * 256)
        ok()
    elif cmd == "query-block":
        # one backend per guest device with drive= (or an empty scsi-cd), keyed by its qdev id
        out = []
        for i, a2 in enumerate(args):
            if a2 == "-device" and i + 1 < len(args):
                parts = args[i + 1].split(",")
                props = dict(p.split("=", 1) for p in parts[1:] if "=" in p)
                if "id" in props and ("drive" in props or parts[0] == "scsi-cd"):
                    entry = {"device": "", "qdev": props["id"], "removable": parts[0] == "scsi-cd",
                             "locked": False, "tray_open": False, "type": "unknown"}
                    if "drive" in props:
                        entry["inserted"] = {"node-name": props["drive"], "file": "x"}
                    out.append(entry)
        ok(out)
    elif cmd in ("eject", "blockdev-change-medium"):
        ok()
    else:
        fail("CommandNotFound", "The command %s has not been found" % cmd)

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(qmp_path)
srv.listen(1)
while True:
    c, _ = srv.accept()
    with lock:
        conn = c
    send({"QMP": {"version": {"qemu": {"major": 11, "minor": 1, "micro": 1}, "package": "fake"}, "capabilities": ["oob"]}})
    for line in c.makefile("rb"):
        sys.stderr.write("qmp< " + line.decode(errors="replace")); sys.stderr.flush()
        try:
            req = json.loads(line)
        except ValueError:
            continue
        handle(req)
    with lock:
        conn = None
    c.close()
"""#
