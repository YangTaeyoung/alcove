import Foundation

/// Turns a `VMConfig` + bundle into a `qemu-system-aarch64` argument list.
///
/// Device choices (see docs/research/qemu-11.1.1-virt-machine-devices.md):
/// `virt` machine, HVF, `-cpu host`, EDK2 pflash, xHCI with usb-kbd/usb-tablet,
/// named block nodes (`-blockdev`) so snapshots can address `disk0`, user-mode
/// networking, the `alcove` display backend and a QMP unix socket.
public struct QEMUCommandBuilder: Sendable {
    public struct Options: Sendable, Equatable {
        /// Resume from a suspend-to-disk state file (`-incoming`).
        public var incomingStatePath: String?
        /// Boot from the first CD-ROM this time (firmware order is not
        /// overridable on `virt`; kept for the app's boot menu logic).
        public var bootFromCDROM: Bool
        public init(incomingStatePath: String? = nil, bootFromCDROM: Bool = false) {
            self.incomingStatePath = incomingStatePath; self.bootFromCDROM = bootFromCDROM
        }
    }

    public static let xhciID = "xhci"
    public static let usbBus = "xhci.0"

    public let engine: EngineLocator.Engine
    public init(engine: EngineLocator.Engine) { self.engine = engine }

    public func arguments(for config: VMConfig, bundle: VMBundle, options: Options = Options()) -> [String] {
        var a: [String] = []
        a += ["-name", "guest=\(config.name),debug-threads=on"]
        a += ["-M", "virt", "-accel", "hvf", "-cpu", "host"]
        a += ["-smp", "\(config.cpuCount)", "-m", "\(config.memoryMiB)"]
        a += ["-nodefaults", "-no-user-config"]
        a += ["-drive", "if=pflash,format=raw,readonly=on,file=\(engine.firmwareCode)"]
        a += ["-drive", "if=pflash,format=raw,file=\(bundle.efiVarsURL.path)"]

        // display, input
        switch config.display {
        case .ramfb: a += ["-device", "ramfb"]
        case .virtioGPU: a += ["-device", "virtio-gpu-pci"]
        }
        a += ["-device", "qemu-xhci,id=\(Self.xhciID)", "-device", "usb-kbd", "-device", "usb-tablet"]
        a += ["-display", "alcove,socket=\(bundle.displaySocketPath),shmdir=\(bundle.runURL.path)"]

        // disks: named nodes so QMP snapshot commands can address them
        for disk in config.disks {
            let file = bundle.diskURL(disk).path
            a += ["-blockdev", "driver=file,node-name=\(disk.id)-file,filename=\(file),discard=unmap"]
            a += ["-blockdev", "driver=qcow2,node-name=\(disk.id),file=\(disk.id)-file,discard=unmap"]
            switch disk.bus {
            case .virtioBlk: a += ["-device", "virtio-blk-pci,drive=\(disk.id),id=\(disk.id)-dev,bootindex=\(bootIndex(disk: disk, config: config, options: options))"]
            case .nvme: a += ["-device", "nvme,drive=\(disk.id),id=\(disk.id)-dev,serial=alcove-\(disk.id),bootindex=\(bootIndex(disk: disk, config: config, options: options))"]
            }
        }
        for cd in config.cdroms {
            guard let path = cd.path else { continue }
            a += ["-blockdev", "driver=file,node-name=\(cd.id)-file,filename=\(path),read-only=on,locking=off"]
            a += ["-blockdev", "driver=raw,node-name=\(cd.id),file=\(cd.id)-file,read-only=on"]
            let bootindex = options.bootFromCDROM ? 0 : 10
            switch cd.bus ?? (config.guestOS == .windows ? .usb : .virtio) {
            case .usb:
                a += ["-device", "usb-storage,drive=\(cd.id),id=\(cd.id)-dev,bus=\(Self.usbBus),removable=on,bootindex=\(bootindex)"]
            case .virtio:
                a += ["-device", "virtio-blk-pci,drive=\(cd.id),id=\(cd.id)-dev,bootindex=\(bootindex)"]
            }
        }

        // network
        switch config.network {
        case .user(let forwards):
            var netdev = "user,id=net0"
            for f in forwards {
                netdev += ",hostfwd=\(f.proto.rawValue):127.0.0.1:\(f.hostPort)-:\(f.guestPort)"
            }
            a += ["-netdev", netdev, "-device", "virtio-net-pci,netdev=net0,mac=\(config.macAddress)"]
        case .none:
            break
        }

        a += ["-device", "virtio-rng-pci"]
        a += ["-device", "virtio-serial-pci,id=vser0"]

        if config.tpm, engine.swtpm != nil {
            a += ["-chardev", "socket,id=chrtpm,path=\(bundle.swtpmSocketPath)"]
            a += ["-tpmdev", "emulator,id=tpm0,chardev=chrtpm", "-device", "tpm-tis-device,tpmdev=tpm0"]
        }

        for (i, usb) in config.usbPassthrough.enumerated() {
            let vid = String(format: "0x%04x", usb.vendorID), pid = String(format: "0x%04x", usb.productID)
            a += ["-device", "usb-host,bus=\(Self.usbBus),id=usbhost\(i),vendorid=\(vid),productid=\(pid)"]
        }

        // control and logs
        a += ["-qmp", "unix:\(bundle.qmpSocketPath),server=on,wait=off"]
        a += ["-serial", "file:\(bundle.serialLogURL.path)", "-monitor", "none"]
        a += ["-rtc", "base=utc,clock=host"]
        if let incoming = options.incomingStatePath {
            a += ["-incoming", "file:\(incoming)"]
        }
        return a
    }

    private func bootIndex(disk: VMConfig.Disk, config: VMConfig, options: Options) -> Int {
        let base = options.bootFromCDROM ? 20 : 1
        return base + (config.disks.firstIndex(where: { $0.id == disk.id }) ?? 0)
    }
}
