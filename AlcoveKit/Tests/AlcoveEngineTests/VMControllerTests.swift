import XCTest
@testable import AlcoveEngine
import AlcoveDisplayProtocol

/// End-to-end tests against the real engine in build/qemu-build (EDK2 only, no OS).
/// Skipped when the engine has not been built. The state machine itself is
/// covered without QEMU in VMControllerFakeEngineTests.
final class VMControllerTests: XCTestCase {
    private var tmp: URL!
    private var engine: EngineLocator.Engine!

    override func setUpWithError() throws {
        engine = try? EngineLocator(roots: [EngineLocator.developmentBuildRoot]).locate()
        try XCTSkipIf(engine == nil, "engine not built; run scripts/build-qemu.sh")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alcove-vm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let tmp { try? FileManager.default.removeItem(at: tmp) } }

    /// Firmware-only VM with one ISO-backed CD-ROM and one empty tray, so the
    /// usb-bot/scsi-cd topology is exercised by the real engine.
    private func makeVM() throws -> VMController {
        let iso = tmp.appendingPathComponent("blank.iso")
        try Data(count: 2 * 1024 * 1024).write(to: iso)
        var config = VMConfig.defaults(name: "FirmwareOnly", guestOS: .other)
        config.cpuCount = 2; config.memoryMiB = 512
        config.disks = [.init(id: "disk0", fileName: "disk0.qcow2", sizeGiB: 1, bus: .virtioBlk)]
        config.cdroms = [.init(id: "cd0", path: iso.path), .init(id: "cd1", path: nil)]
        config.display = .ramfb
        config.network = .none
        let bundle = try VMBundle.create(config, in: tmp, engine: engine)
        return VMController(bundle: bundle, config: config, engine: engine)
    }

    private func firstDisplayMessage(_ vm: VMController, _ matches: @escaping @Sendable (FromQEMU) -> Bool, timeout: Duration = .seconds(30)) async throws -> FromQEMU? {
        guard let display = await vm.display else { return nil }
        return try await withThrowingTaskGroup(of: FromQEMU?.self) { group in
            group.addTask { for await m in display.messages where matches(m) { return m }; return nil }
            group.addTask { try await Task.sleep(for: timeout); return nil }
            let r = try await group.next() ?? nil
            group.cancelAll()
            return r
        }
    }

    func testStartPauseResumeSnapshotScreenshotShutdown() async throws {
        let vm = try makeVM()
        try await vm.start()
        var s = await vm.state
        XCTAssertEqual(s, .running)
        // QEMU holds a write lock on its pidfile while alive
        let pid = VMController.pidfileLockHolder(vm.bundle.pidFileURL.path)
        XCTAssertNotNil(pid)

        let hello = try await firstDisplayMessage(vm, { if case .hello = $0 { return true }; return false })
        XCTAssertNotNil(hello, "display backend must connect")

        try await vm.pause()
        s = await vm.state; XCTAssertEqual(s, .paused)
        let paused = try await vm.qmp!.queryStatus()
        XCTAssertEqual(paused.state, "paused")
        try await vm.resume()
        s = await vm.state; XCTAssertEqual(s, .running)

        try await vm.createSnapshot(named: "first")
        var list = try await vm.snapshots()
        XCTAssertEqual(list.map(\.name), ["first"])
        XCTAssertGreaterThan(list[0].vmStateSize, 0)
        try await vm.restoreSnapshot(named: "first")
        s = await vm.state; XCTAssertEqual(s, .running)
        try await vm.deleteSnapshot(named: "first")
        list = try await vm.snapshots()
        XCTAssertTrue(list.isEmpty)
        // a failed restore leaves the guest running, not silently paused
        await XCTAssertThrowsErrorAsync(try await vm.restoreSnapshot(named: "missing"))
        s = await vm.state; XCTAssertEqual(s, .running)
        let afterFailedRestore = try await vm.qmp!.queryStatus()
        XCTAssertTrue(afterFailedRestore.running)

        // media change on the real scsi-cd devices: insert into the empty tray, then eject
        let iso = tmp.appendingPathComponent("blank.iso")
        try await vm.changeMedium(cdromID: "cd1", isoPath: iso.path)
        var cfg = await vm.config; XCTAssertEqual(cfg.cdroms[1].path, iso.path)
        try await vm.changeMedium(cdromID: "cd1", isoPath: nil)
        cfg = await vm.config; XCTAssertNil(cfg.cdroms[1].path)

        let shot = tmp.appendingPathComponent("shot.png")
        try await vm.screenshot(to: shot)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: shot.path)[.size] as? Int) ?? 0, 100)

        // no OS handles the power button, so shutdown falls back to quit
        try await vm.shutdown(force: false, gracePeriod: .seconds(2))
        s = await vm.state
        XCTAssertEqual(s, .stopped)
        let qmpAfter = await vm.qmp; XCTAssertNil(qmpAfter)
        let displayAfter = await vm.display; XCTAssertNil(displayAfter)
        XCTAssertNil(VMController.pidfileLockHolder(vm.bundle.pidFileURL.path))
    }

    func testSuspendToDiskAndResume() async throws {
        let vm = try makeVM()
        try await vm.start()
        try await vm.suspendToDisk()
        var s = await vm.state
        XCTAssertEqual(s, .stopped)
        XCTAssertTrue(vm.bundle.isSuspended)
        XCTAssertNotNil(vm.bundle.loadSuspendedConfig())
        try await vm.start()
        s = await vm.state
        XCTAssertEqual(s, .running)
        XCTAssertFalse(vm.bundle.isSuspended)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.bundle.suspendConfigURL.path))
        try await vm.shutdown(force: true)
    }

    func testFailureIsReportedWithLogExactlyOnce() async throws {
        let vm = try makeVM()
        let log = StateLog()
        let observer = Task { for await s in vm.states { await log.append(s) } }
        defer { observer.cancel() }
        try FileManager.default.removeItem(at: vm.bundle.efiVarsURL)   // QEMU refuses to start
        await XCTAssertThrowsErrorAsync(try await vm.start())
        let s = await vm.state
        guard case .failed(let msg) = s else { return XCTFail("expected failed, got \(s)") }
        XCTAssertTrue(msg.contains("efi-vars.fd"), msg)
        try await Task.sleep(for: .seconds(1))
        let states = await log.states
        XCTAssertEqual(states, [.starting, .failed(msg)], "the late exit notification must not replace the report")
    }
}

func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> some Any, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected error", file: file, line: line) } catch {}
}

/// Collects a controller's `states` stream.
actor StateLog {
    private(set) var states: [VMController.State] = []
    func append(_ s: VMController.State) { states.append(s) }
}
