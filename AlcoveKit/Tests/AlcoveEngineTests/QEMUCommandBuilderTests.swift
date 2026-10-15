import XCTest
@testable import AlcoveEngine

final class QEMUCommandBuilderTests: XCTestCase {
    private let engine = EngineLocator.Engine(qemuSystem: "/e/qemu-system-aarch64", qemuImg: "/e/qemu-img", firmwareDir: "/e/pc-bios", swtpm: "/e/swtpm")
    private let bundle = VMBundle(url: URL(fileURLWithPath: "/vms/Test.alcovevm"))

    private func args(_ config: VMConfig, _ options: QEMUCommandBuilder.Options = .init()) -> [String] {
        QEMUCommandBuilder(engine: engine).arguments(for: config, bundle: bundle, options: options)
    }

    func testWindowsProfileGolden() {
        var c = VMConfig.defaults(name: "Win", guestOS: .windows, installISO: "/isos/win.iso")
        c.macAddress = "52:54:00:aa:bb:cc"
        c.network = .user(portForwards: [.init(hostPort: 2222, guestPort: 22)])
        c.agentKey = String(repeating: "a5", count: 32)
        let a = args(c)
        let expected: [String] = [
            "-name", "guest=Win,debug-threads=on",
            "-M", "virt", "-accel", "hvf", "-cpu", "host",
            "-smp", "4", "-m", "6144",
            "-nodefaults", "-no-user-config",
            "-drive", "if=pflash,format=raw,readonly=on,file=/e/pc-bios/edk2-aarch64-code.fd",
            "-drive", "if=pflash,format=raw,file=/vms/Test.alcovevm/efi-vars.fd",
            "-device", "ramfb",
            "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd", "-device", "usb-tablet",
            "-display", "alcove,socket=\(bundle.displaySocketPath),shmdir=/vms/Test.alcovevm/run",
            "-blockdev", "driver=file,node-name=disk0-file,filename=/vms/Test.alcovevm/disk0.qcow2,discard=unmap",
            "-blockdev", "driver=qcow2,node-name=disk0,file=disk0-file,discard=unmap",
            "-device", "nvme,drive=disk0,id=disk0-dev,serial=alcove-disk0,bootindex=1",
            "-blockdev", "driver=file,node-name=cd0-file,filename=/isos/win.iso,read-only=on,locking=off",
            "-blockdev", "driver=raw,node-name=cd0,file=cd0-file,read-only=on",
            // a scsi-cd behind usb-bot: usb-storage would turn the -blockdev node into a scsi-hd
            "-device", "usb-bot,id=cd0-bot,bus=xhci.0",
            "-device", "scsi-cd,drive=cd0,id=cd0-dev,bus=cd0-bot.0,bootindex=100",
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:\(c.agentHostPort)-:\(VMConfig.agentGuestPort)",
            "-device", "virtio-net-pci,netdev=net0,mac=52:54:00:aa:bb:cc",
            "-device", "virtio-rng-pci",
            "-device", "virtio-serial-pci,id=vser0",
            "-smbios", "type=11,value=alcove-token=\(c.agentToken)",
            "-smbios", "type=11,value=alcove-hostkey=29e5833a915a6429a4e3a7948475c338ef436eb82be89c92f059704403db9d55",
            "-qmp", "unix:\(bundle.qmpSocketPath),server=on,wait=off",
            "-serial", "file:/vms/Test.alcovevm/run/serial.log", "-monitor", "none",
            "-pidfile", "/vms/Test.alcovevm/run/qemu.pid",
            "-rtc", "base=utc,clock=host",
        ]
        XCTAssertEqual(a, expected)
        XCTAssertEqual(QEMUCommandBuilder.cdromDeviceID("cd0"), "cd0-dev")
    }

    func testLinuxProfileUsesVirtioBlkAndGPU() {
        let c = VMConfig.defaults(name: "Lin", guestOS: .linux)
        let a = args(c)
        XCTAssertTrue(a.contains("virtio-gpu-pci"))
        XCTAssertTrue(a.contains("virtio-blk-pci,drive=disk0,id=disk0-dev,bootindex=1"))
        XCTAssertFalse(a.contains("ramfb"))
        // only the guest-agent forward, no user port forwards
        XCTAssertTrue(a.contains("user,id=net0,hostfwd=tcp:127.0.0.1:\(c.agentHostPort)-:\(VMConfig.agentGuestPort)"))
    }

    func testOptionsAndExtras() {
        var c = VMConfig.defaults(name: "X", guestOS: .linux, installISO: "/i.iso")
        c.tpm = true
        c.usbPassthrough = [.init(vendorID: 0x05ac, productID: 0x12a8)]
        c.network = .none
        let a = args(c, .init(incomingStatePath: "/vms/Test.alcovevm/suspend.state", bootFromCDROM: true))
        let joined = a.joined(separator: " ")
        XCTAssertTrue(joined.contains("-incoming file:/vms/Test.alcovevm/suspend.state"))
        XCTAssertTrue(joined.contains("-device usb-bot,id=cd0-bot,bus=xhci.0 -device scsi-cd,drive=cd0,id=cd0-dev,bus=cd0-bot.0,bootindex=0"))
        XCTAssertTrue(joined.contains("virtio-blk-pci,drive=disk0,id=disk0-dev,bootindex=20"))
        XCTAssertTrue(joined.contains("-chardev socket,id=chrtpm,path=\(bundle.swtpmSocketPath) -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis-device,tpmdev=tpm0"))
        XCTAssertTrue(joined.contains("usb-host,bus=xhci.0,id=usbhost0,vendorid=0x05ac,productid=0x12a8"))
        XCTAssertFalse(joined.contains("-netdev"))
    }

    func testDiskPathOverrides() {
        var c = VMConfig.defaults(name: "O", guestOS: .linux)
        c.disks.append(.init(id: "disk1", fileName: "disk1.qcow2", sizeGiB: 8, bus: .virtioBlk))
        let a = args(c, .init(diskPathOverrides: ["disk0": "/vms/Test.alcovevm/run/ephemeral-disk0.qcow2"],
                              efiVarsPath: "/vms/a, b/ephemeral-efi-vars.fd"))
        XCTAssertTrue(a.contains("driver=file,node-name=disk0-file,filename=/vms/Test.alcovevm/run/ephemeral-disk0.qcow2,discard=unmap"))
        XCTAssertTrue(a.contains("driver=file,node-name=disk1-file,filename=/vms/Test.alcovevm/disk1.qcow2,discard=unmap"))
        XCTAssertTrue(a.contains("if=pflash,format=raw,file=/vms/a,, b/ephemeral-efi-vars.fd"))
        XCTAssertFalse(a.contains { $0.contains("/vms/Test.alcovevm/disk0.qcow2") || $0.contains("/vms/Test.alcovevm/efi-vars.fd") })
        let plain = args(c)
        XCTAssertTrue(plain.contains("driver=file,node-name=disk0-file,filename=/vms/Test.alcovevm/disk0.qcow2,discard=unmap"))
        XCTAssertTrue(plain.contains("if=pflash,format=raw,file=/vms/Test.alcovevm/efi-vars.fd"))
    }

    /// Every device needs its own boot index; QEMU refuses a duplicate
    /// ("The bootindex 10 has already been used", system/bootdevice.c).
    func testEveryCDROMAndDiskGetsADistinctBootIndex() {
        var c = VMConfig.defaults(name: "Two", guestOS: .windows, installISO: "/isos/win.iso")
        c.cdroms.append(.init(id: "cd1", path: "/isos/virtio-win.iso"))
        c.disks.append(.init(id: "disk1", fileName: "disk1.qcow2", sizeGiB: 8, bus: .virtioBlk))
        func bootIndexes(_ a: [String]) -> [Int] {
            a.compactMap { arg in
                arg.split(separator: ",").first { $0.hasPrefix("bootindex=") }.flatMap { Int($0.dropFirst("bootindex=".count)) }
            }
        }
        let normal = bootIndexes(args(c))
        XCTAssertEqual(normal, [1, 2, 100, 101])
        let cdFirst = bootIndexes(args(c, .init(bootFromCDROM: true)))
        XCTAssertEqual(cdFirst, [20, 21, 0, 1])
        XCTAssertTrue(args(c).contains("scsi-cd,drive=cd1,id=cd1-dev,bus=cd1-bot.0,bootindex=101"))
    }

    /// Both QEMU option parsers end a value at a single comma and read `,,` as a
    /// literal comma; every user-controlled path or name must be escaped, while
    /// `-serial file:`, `-pidfile` and `-incoming file:` take their string verbatim.
    func testCommasInNamesAndPathsAreEscaped() {
        let engine = EngineLocator.Engine(qemuSystem: "/e, f/qemu-system-aarch64", qemuImg: "/e, f/qemu-img", firmwareDir: "/e, f/pc-bios", swtpm: "/e, f/swtpm")
        let bundle = VMBundle(url: URL(fileURLWithPath: "/vms/a, b/Test.alcovevm"))
        var c = VMConfig.defaults(name: "Work, Dev", guestOS: .linux, installISO: "/isos/x, y.iso")
        c.tpm = true
        let a = QEMUCommandBuilder(engine: engine).arguments(for: c, bundle: bundle, options: .init(incomingStatePath: bundle.suspendStateURL.path))
        XCTAssertEqual(QEMUCommandBuilder.escape("a,b,,c"), "a,,b,,,,c")
        XCTAssertTrue(a.contains("guest=Work,, Dev,debug-threads=on"))
        XCTAssertTrue(a.contains("if=pflash,format=raw,readonly=on,file=/e,, f/pc-bios/edk2-aarch64-code.fd"))
        XCTAssertTrue(a.contains("if=pflash,format=raw,file=/vms/a,, b/Test.alcovevm/efi-vars.fd"))
        XCTAssertTrue(a.contains("alcove,socket=\(bundle.displaySocketPath),shmdir=/vms/a,, b/Test.alcovevm/run"))
        XCTAssertTrue(a.contains("driver=file,node-name=disk0-file,filename=/vms/a,, b/Test.alcovevm/disk0.qcow2,discard=unmap"))
        XCTAssertTrue(a.contains("driver=file,node-name=cd0-file,filename=/isos/x,, y.iso,read-only=on,locking=off"))
        XCTAssertTrue(a.contains("file:/vms/a, b/Test.alcovevm/run/serial.log"))
        XCTAssertTrue(a.contains("/vms/a, b/Test.alcovevm/run/qemu.pid"))
        XCTAssertTrue(a.contains("file:/vms/a, b/Test.alcovevm/suspend.state"))
        // nothing else carries an unescaped comma from a path
        let verbatim = Set(["file:/vms/a, b/Test.alcovevm/run/serial.log", "/vms/a, b/Test.alcovevm/run/qemu.pid", "file:/vms/a, b/Test.alcovevm/suspend.state"])
        for arg in a where arg.contains(", ") && !verbatim.contains(arg) {
            XCTAssertTrue(arg.contains(",, "), "unescaped comma in \(arg)")
        }
    }

    /// A configured TPM is always emitted; a missing swtpm must fail loudly
    /// (VMController refuses to start) instead of silently dropping the device.
    func testTPMIsEmittedEvenWithoutSwtpm() {
        var c = VMConfig.defaults(name: "T", guestOS: .windows)
        c.tpm = true
        let noSwtpm = EngineLocator.Engine(qemuSystem: "/e/q", qemuImg: "/e/i", firmwareDir: "/e", swtpm: nil)
        let a = QEMUCommandBuilder(engine: noSwtpm).arguments(for: c, bundle: bundle)
        XCTAssertTrue(a.contains("-tpmdev"))
        XCTAssertTrue(a.contains("tpm-tis-device,tpmdev=tpm0"))
        c.tpm = false
        XCTAssertFalse(QEMUCommandBuilder(engine: noSwtpm).arguments(for: c, bundle: bundle).contains("-tpmdev"))
    }

    /// An ISO-less drive is still a device (an empty tray), so media can be inserted later.
    func testEmptyCDROMIsAnEmptyTray() {
        var c = VMConfig.defaults(name: "E", guestOS: .linux)
        c.cdroms = [.init(id: "cd0", path: nil)]
        let a = args(c)
        XCTAssertFalse(a.contains { $0.contains("node-name=cd0") })
        XCTAssertTrue(a.contains("usb-bot,id=cd0-bot,bus=xhci.0"))
        XCTAssertTrue(a.contains("scsi-cd,id=cd0-dev,bus=cd0-bot.0,bootindex=100"))
    }
    /// The values of the `-drive`, `-blockdev` and `-device` options, in order.
    private func driveAndDeviceValues(_ a: [String]) -> [String] {
        zip(a, a.dropFirst()).compactMap { ["-drive", "-blockdev", "-device"].contains($0.0) ? $0.1 : nil }
    }

    func testCDROMVirtioBusOption() {
        var l = VMConfig.defaults(name: "L", guestOS: .linux, installISO: "/i.iso")
        l.agentToken = "00000000-0000-0000-0000-000000000000"
        l.macAddress = "52:54:00:aa:bb:cc"
        l.agentKey = String(repeating: "a5", count: 32)
        XCTAssertTrue(driveAndDeviceValues(args(l)).contains { $0.hasPrefix("scsi-cd,drive=cd0,") }, "USB CD by default")
        var seed = l
        seed.cdroms[0].bus = .virtio
        let devices = driveAndDeviceValues(args(seed))
        XCTAssertTrue(devices.contains("virtio-blk-pci,drive=cd0,id=\(QEMUCommandBuilder.cdromDeviceID("cd0")),bootindex=100"), "\(devices)")
        XCTAssertFalse(devices.contains { $0.contains("usb-bot") })
        seed.cdroms[0].path = nil
        let empty = driveAndDeviceValues(args(seed))
        XCTAssertFalse(empty.contains { $0.contains("cd0") }, "an empty virtio CD is omitted: \(empty)")
    }
}
