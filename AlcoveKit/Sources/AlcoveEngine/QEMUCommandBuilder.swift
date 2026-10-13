import Foundation

/// Turns a `VMConfig` + bundle into a `qemu-system-aarch64` argument list.
///
/// Device choices (see docs/research/qemu-11.1.1-virt-machine-devices.md):
/// `virt` machine, HVF, `-cpu host`, EDK2 pflash, xHCI with usb-kbd/usb-tablet,
/// named block nodes (`-blockdev`) so snapshots can address `disk0`, CD-ROMs as
/// `scsi-cd` behind a `usb-bot` (a `usb-storage` fed from a `-blockdev` node
/// always becomes a `scsi-hd`, hw/scsi/scsi-bus.c `scsi_bus_legacy_add_drive`),
/// user-mode networking, the `alcove` display backend, a QMP unix socket and a
/// pidfile that QEMU keeps write-locked while it lives.
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

    /// Escape a value embedded in a comma-separated option string. Both QEMU
    /// parsers end a value at a single comma and read `,,` as one literal comma:
    /// QemuOpts for `-name`/`-drive`/`-chardev` (util/qemu-option.c `get_opt_value`)
    /// and keyval for `-blockdev`/`-display` (util/keyval.c `keyval_parse_one`).
    public static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: ",", with: ",,")
    }

    /// qdev id of the `scsi-cd` that holds CD-ROM `id`: the device with the tray
    /// that `eject` and `blockdev-change-medium` address.
    public static func cdromDeviceID(_ id: String) -> String { "\(id)-dev" }

    public let engine: EngineLocator.Engine
    public init(engine: EngineLocator.Engine) { self.engine = engine }

    public func arguments(for config: VMConfig, bundle: VMBundle, options: Options = Options()) -> [String] {
        let esc = Self.escape
        var a: [String] = []
        a += ["-name", "guest=\(esc(config.name)),debug-threads=on"]
        a += ["-M", "virt", "-accel", "hvf", "-cpu", "host"]
        a += ["-smp", "\(config.cpuCount)", "-m", "\(config.memoryMiB)"]
        a += ["-nodefaults", "-no-user-config"]
        a += ["-drive", "if=pflash,format=raw,readonly=on,file=\(esc(engine.firmwareCode))"]
        a += ["-drive", "if=pflash,format=raw,file=\(esc(bundle.efiVarsURL.path))"]

        // display, input
        switch config.display {
        case .ramfb: a += ["-device", "ramfb"]
        case .virtioGPU: a += ["-device", "virtio-gpu-pci"]
        }
        a += ["-device", "qemu-xhci,id=\(Self.xhciID)", "-device", "usb-kbd", "-device", "usb-tablet"]
        a += ["-display", "alcove,socket=\(esc(bundle.displaySocketPath)),shmdir=\(esc(bundle.runURL.path))"]

        // disks: named nodes so QMP snapshot commands can address them
        for (i, disk) in config.disks.enumerated() {
            let file = esc(bundle.diskURL(disk).path)
            let boot = (options.bootFromCDROM ? 20 : 1) + i
            a += ["-blockdev", "driver=file,node-name=\(disk.id)-file,filename=\(file),discard=unmap"]
            a += ["-blockdev", "driver=qcow2,node-name=\(disk.id),file=\(disk.id)-file,discard=unmap"]
            switch disk.bus {
            case .virtioBlk: a += ["-device", "virtio-blk-pci,drive=\(disk.id),id=\(disk.id)-dev,bootindex=\(boot)"]
            case .nvme: a += ["-device", "nvme,drive=\(disk.id),id=\(disk.id)-dev,serial=alcove-\(disk.id),bootindex=\(boot)"]
            }
        }
        // CD-ROMs: a real scsi-cd (with a tray) on its own usb-bot. Every device
        // needs a distinct boot index (system/bootdevice.c `check_boot_index`
        // rejects duplicates); an ISO-less drive is an empty tray.
        for (i, cd) in config.cdroms.enumerated() {
            let boot = (options.bootFromCDROM ? 0 : 100) + i
            // Optional read-only virtio-blk "CD" (no tray, no media change): for
            // cloud-init seeds, which cloud images do not find on USB early enough.
            if cd.bus == .virtio {
                guard let path = cd.path else { continue }
                a += ["-blockdev", "driver=file,node-name=\(cd.id)-file,filename=\(esc(path)),read-only=on,locking=off"]
                a += ["-blockdev", "driver=raw,node-name=\(cd.id),file=\(cd.id)-file,read-only=on"]
                a += ["-device", "virtio-blk-pci,drive=\(cd.id),id=\(Self.cdromDeviceID(cd.id)),bootindex=\(boot)"]
                continue
            }
            var device = ["scsi-cd"]
            if let path = cd.path {
                a += ["-blockdev", "driver=file,node-name=\(cd.id)-file,filename=\(esc(path)),read-only=on,locking=off"]
                a += ["-blockdev", "driver=raw,node-name=\(cd.id),file=\(cd.id)-file,read-only=on"]
                device.append("drive=\(cd.id)")
            }
            device += ["id=\(Self.cdromDeviceID(cd.id))", "bus=\(cd.id)-bot.0", "bootindex=\(boot)"]
            a += ["-device", "usb-bot,id=\(cd.id)-bot,bus=\(Self.usbBus)"]
            a += ["-device", device.joined(separator: ",")]
        }

        // network
        switch config.network {
        case .user(let forwards):
            var netdev = "user,id=\(VMController.netdevID)"
            for f in forwards {
                netdev += ",hostfwd=\(f.proto.rawValue):127.0.0.1:\(f.hostPort)-:\(f.guestPort)"
            }
            // guest agent: the app connects to 127.0.0.1:agentHostPort -> guest 7645
            netdev += ",hostfwd=tcp:127.0.0.1:\(config.agentHostPort)-:\(VMConfig.agentGuestPort)"
            a += ["-netdev", netdev, "-device", "virtio-net-pci,netdev=\(VMController.netdevID),mac=\(config.macAddress)"]
        case .none:
            break
        }

        a += ["-device", "virtio-rng-pci"]
        a += ["-device", "virtio-serial-pci,id=vser0"]
        // the guest agent reads its token from the SMBIOS OEM strings (type 11)
        a += ["-smbios", "type=11,value=alcove-token=\(config.agentToken)"]

        // Emitted whenever the config asks for it: a missing swtpm must fail
        // loudly (VMController refuses to start), never silently drop the TPM.
        if config.tpm {
            a += ["-chardev", "socket,id=chrtpm,path=\(esc(bundle.swtpmSocketPath))"]
            a += ["-tpmdev", "emulator,id=tpm0,chardev=chrtpm", "-device", "tpm-tis-device,tpmdev=tpm0"]
        }

        for (i, usb) in config.usbPassthrough.enumerated() {
            let vid = String(format: "0x%04x", usb.vendorID), pid = String(format: "0x%04x", usb.productID)
            a += ["-device", "usb-host,bus=\(Self.usbBus),id=usbhost\(i),vendorid=\(vid),productid=\(pid)"]
        }

        // control and logs. The socket directory is /tmp/alcove-<uid>/<hex>, comma-free
        // by construction; `-serial file:` takes the rest of the string verbatim
        // (chardev/char.c `qemu_chr_parse_compat`), as do `-pidfile` and
        // `-incoming file:` (migration/file.c only recognises ",offset=").
        a += ["-qmp", "unix:\(bundle.qmpSocketPath),server=on,wait=off"]
        a += ["-serial", "file:\(bundle.serialLogURL.path)", "-monitor", "none"]
        a += ["-pidfile", bundle.pidFileURL.path]
        a += ["-rtc", "base=utc,clock=host"]
        if let incoming = options.incomingStatePath {
            a += ["-incoming", "file:\(incoming)"]
        }
        return a
    }
}
