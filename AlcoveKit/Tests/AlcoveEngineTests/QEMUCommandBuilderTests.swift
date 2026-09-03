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
            "-display", "alcove,socket=/vms/Test.alcovevm/run/display.sock,shmdir=/vms/Test.alcovevm/run",
            "-blockdev", "driver=file,node-name=disk0-file,filename=/vms/Test.alcovevm/disk0.qcow2,discard=unmap",
            "-blockdev", "driver=qcow2,node-name=disk0,file=disk0-file,discard=unmap",
            "-device", "nvme,drive=disk0,id=disk0-dev,serial=alcove-disk0,bootindex=1",
            "-blockdev", "driver=file,node-name=cd0-file,filename=/isos/win.iso,read-only=on,locking=off",
            "-blockdev", "driver=raw,node-name=cd0,file=cd0-file,read-only=on",
            "-device", "usb-storage,drive=cd0,id=cd0-dev,bus=xhci.0,removable=on,bootindex=10",
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22",
            "-device", "virtio-net-pci,netdev=net0,mac=52:54:00:aa:bb:cc",
            "-device", "virtio-rng-pci",
            "-device", "virtio-serial-pci,id=vser0",
            "-qmp", "unix:/vms/Test.alcovevm/run/qmp.sock,server=on,wait=off",
            "-serial", "file:/vms/Test.alcovevm/run/serial.log", "-monitor", "none",
            "-rtc", "base=utc,clock=host",
        ]
        XCTAssertEqual(a, expected)
    }

    func testLinuxProfileUsesVirtioBlkAndGPU() {
        let c = VMConfig.defaults(name: "Lin", guestOS: .linux)
        let a = args(c)
        XCTAssertTrue(a.contains("virtio-gpu-pci"))
        XCTAssertTrue(a.contains("virtio-blk-pci,drive=disk0,id=disk0-dev,bootindex=1"))
        XCTAssertFalse(a.contains("ramfb"))
        XCTAssertFalse(a.joined(separator: " ").contains("hostfwd"))
    }

    func testOptionsAndExtras() {
        var c = VMConfig.defaults(name: "X", guestOS: .linux, installISO: "/i.iso")
        c.tpm = true
        c.usbPassthrough = [.init(vendorID: 0x05ac, productID: 0x12a8)]
        c.network = .none
        let a = args(c, .init(incomingStatePath: "/vms/Test.alcovevm/suspend.state", bootFromCDROM: true))
        let joined = a.joined(separator: " ")
        XCTAssertTrue(joined.contains("-incoming file:/vms/Test.alcovevm/suspend.state"))
        XCTAssertTrue(joined.contains("usb-storage,drive=cd0,id=cd0-dev,bus=xhci.0,removable=on,bootindex=0"))
        XCTAssertTrue(joined.contains("virtio-blk-pci,drive=disk0,id=disk0-dev,bootindex=20"))
        XCTAssertTrue(joined.contains("-tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis-device,tpmdev=tpm0"))
        XCTAssertTrue(joined.contains("usb-host,bus=xhci.0,id=usbhost0,vendorid=0x05ac,productid=0x12a8"))
        XCTAssertFalse(joined.contains("-netdev"))
    }

    func testTPMIsSkippedWithoutSwtpm() {
        var c = VMConfig.defaults(name: "T", guestOS: .windows)
        c.tpm = true
        let noSwtpm = EngineLocator.Engine(qemuSystem: "/e/q", qemuImg: "/e/i", firmwareDir: "/e", swtpm: nil)
        let a = QEMUCommandBuilder(engine: noSwtpm).arguments(for: c, bundle: bundle)
        XCTAssertFalse(a.contains("-tpmdev"))
    }

    func testEmptyCDROMIsOmitted() {
        var c = VMConfig.defaults(name: "E", guestOS: .linux)
        c.cdroms = [.init(id: "cd0", path: nil)]
        XCTAssertFalse(args(c).joined(separator: " ").contains("cd0"))
    }
}
