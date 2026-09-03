import Foundation

/// Persistent description of a virtual machine (`config.json` in the bundle).
public struct VMConfig: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public enum GuestOS: String, Codable, Sendable, CaseIterable {
        case windows, linux, other
    }

    public enum DiskBus: String, Codable, Sendable, CaseIterable {
        /// virtio-blk-pci: fastest, needs a driver in Windows (viostor).
        case virtioBlk = "virtio-blk"
        /// NVMe: Windows has an inbox driver.
        case nvme
    }

    public struct Disk: Codable, Sendable, Equatable, Identifiable {
        /// Stable identifier, also the QEMU block node name (`disk0`, ...).
        public var id: String
        /// File name inside the bundle (qcow2).
        public var fileName: String
        /// Virtual size used when the image is created.
        public var sizeGiB: Int
        public var bus: DiskBus
        public init(id: String, fileName: String, sizeGiB: Int, bus: DiskBus) {
            self.id = id; self.fileName = fileName; self.sizeGiB = sizeGiB; self.bus = bus
        }
    }

    public enum CDBus: String, Codable, Sendable, CaseIterable {
        /// USB mass storage on the xHCI controller: what Windows Setup expects.
        case usb
        /// A read-only virtio-blk device: visible to Linux without USB storage
        /// drivers, which cloud images may lack early in boot.
        case virtio
    }

    public struct CDROM: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        /// Absolute path of the ISO, or nil for an empty drive.
        public var path: String?
        /// Bus to attach on; nil means USB (a SCSI CD-ROM behind usb-bot, with a
        /// tray so media can be changed while running).
        public var bus: CDBus?
        public init(id: String, path: String?, bus: CDBus? = nil) { self.id = id; self.path = path; self.bus = bus }
    }

    public struct PortForward: Codable, Sendable, Equatable {
        public enum Proto: String, Codable, Sendable { case tcp, udp }
        public var proto: Proto
        public var hostPort: Int
        public var guestPort: Int
        public init(proto: Proto = .tcp, hostPort: Int, guestPort: Int) {
            self.proto = proto; self.hostPort = hostPort; self.guestPort = guestPort
        }
    }

    public enum Network: Codable, Sendable, Equatable {
        /// QEMU user-mode networking (slirp): NAT, no host configuration needed.
        case user(portForwards: [PortForward])
        case none
    }

    public enum DisplayDevice: String, Codable, Sendable, CaseIterable {
        /// Simple framebuffer driven through the firmware; works on every guest.
        case ramfb
        /// virtio-gpu (2D): dynamic resolution with a guest driver.
        case virtioGPU = "virtio-gpu"
    }

    public struct USBSelector: Codable, Sendable, Equatable, Identifiable {
        public var vendorID: Int
        public var productID: Int
        public var name: String?
        public var id: String { String(format: "%04x:%04x", vendorID, productID) }
        public init(vendorID: Int, productID: Int, name: String? = nil) {
            self.vendorID = vendorID; self.productID = productID; self.name = name
        }
    }

    public struct SharedFolder: Codable, Sendable, Equatable {
        public var hostPath: String
        public var tag: String
        public var readOnly: Bool
        public init(hostPath: String, tag: String, readOnly: Bool = false) {
            self.hostPath = hostPath; self.tag = tag; self.readOnly = readOnly
        }
    }

    public var schemaVersion: Int
    public var name: String
    public var guestOS: GuestOS
    public var cpuCount: Int
    public var memoryMiB: Int
    public var disks: [Disk]
    public var cdroms: [CDROM]
    public var network: Network
    public var display: DisplayDevice
    public var tpm: Bool
    public var usbPassthrough: [USBSelector]
    public var sharedFolders: [SharedFolder]
    /// Locally administered MAC for the first NIC, fixed at creation.
    public var macAddress: String
    public var createdAt: Date
    /// Secret the guest agent must echo (passed to the guest as an SMBIOS OEM string).
    public var agentToken: String
    /// Host loopback port forwarded to the guest agent (guest port 7645).
    public var agentHostPort: Int

    public init(schemaVersion: Int = VMConfig.currentSchemaVersion, name: String, guestOS: GuestOS, cpuCount: Int,
                memoryMiB: Int, disks: [Disk], cdroms: [CDROM] = [], network: Network = .user(portForwards: []),
                display: DisplayDevice, tpm: Bool = false, usbPassthrough: [USBSelector] = [],
                sharedFolders: [SharedFolder] = [], macAddress: String = VMConfig.randomMAC(), createdAt: Date = Date(),
                agentToken: String = UUID().uuidString.lowercased(), agentHostPort: Int? = nil) {
        self.schemaVersion = schemaVersion; self.name = name; self.guestOS = guestOS; self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB; self.disks = disks; self.cdroms = cdroms; self.network = network
        self.display = display; self.tpm = tpm; self.usbPassthrough = usbPassthrough
        self.sharedFolders = sharedFolders; self.macAddress = macAddress; self.createdAt = createdAt
        self.agentToken = agentToken
        self.agentHostPort = agentHostPort ?? VMConfig.agentPort(for: agentToken)
    }

    /// Guest port the agent listens on.
    public static let agentGuestPort = 7645

    /// A host port in 17000...17999 derived from the token (stable per VM).
    public static func agentPort(for token: String) -> Int {
        var h: UInt32 = 2166136261
        for b in token.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return 17000 + Int(h % 1000)
    }

    /// Sensible defaults per guest OS.
    public static func defaults(name: String, guestOS: GuestOS, installISO: String? = nil) -> VMConfig {
        let cdroms = installISO.map { [CDROM(id: "cd0", path: $0)] } ?? []
        switch guestOS {
        case .windows:
            return VMConfig(name: name, guestOS: .windows, cpuCount: 4, memoryMiB: 6144,
                            disks: [Disk(id: "disk0", fileName: "disk0.qcow2", sizeGiB: 64, bus: .nvme)],
                            cdroms: cdroms, display: .ramfb)
        case .linux:
            return VMConfig(name: name, guestOS: .linux, cpuCount: 4, memoryMiB: 4096,
                            disks: [Disk(id: "disk0", fileName: "disk0.qcow2", sizeGiB: 32, bus: .virtioBlk)],
                            cdroms: cdroms, display: .virtioGPU)
        case .other:
            return VMConfig(name: name, guestOS: .other, cpuCount: 2, memoryMiB: 2048,
                            disks: [Disk(id: "disk0", fileName: "disk0.qcow2", sizeGiB: 32, bus: .virtioBlk)],
                            cdroms: cdroms, display: .ramfb)
        }
    }

    /// A random locally administered unicast MAC (`52:54:00:xx:xx:xx`, the QEMU OUI).
    public static func randomMAC() -> String {
        String(format: "52:54:00:%02x:%02x:%02x", Int.random(in: 0...255), Int.random(in: 0...255), Int.random(in: 0...255))
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case emptyName, invalidName(String), cpuCount(Int), memory(Int), noDisks, duplicateID(String), invalidMAC(String), diskSize(String, Int)
    }

    /// Check invariants before saving or starting.
    public func validate() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.emptyName }
        // The name is part of every bundle path. "," is refused because swtpm's
        // `--tpmstate dir=` is comma-delimited with no escape (QEMU's own options are escaped by the builder).
        guard !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.contains(","), trimmed != ".", trimmed != ".." else {
            throw ValidationError.invalidName(name)
        }
        guard (1...64).contains(cpuCount) else { throw ValidationError.cpuCount(cpuCount) }
        guard (256...(512 * 1024)).contains(memoryMiB) else { throw ValidationError.memory(memoryMiB) }
        guard !disks.isEmpty else { throw ValidationError.noDisks }
        var seen = Set<String>()
        for d in disks {
            guard seen.insert(d.id).inserted else { throw ValidationError.duplicateID(d.id) }
            guard d.sizeGiB >= 1 else { throw ValidationError.diskSize(d.id, d.sizeGiB) }
        }
        for c in cdroms { guard seen.insert(c.id).inserted else { throw ValidationError.duplicateID(c.id) } }
        let mac = macAddress.split(separator: ":")
        guard mac.count == 6, mac.allSatisfy({ $0.count == 2 && Int($0, radix: 16) != nil }) else { throw ValidationError.invalidMAC(macAddress) }
    }
}

extension VMConfig {
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func encoded() throws -> Data { try VMConfig.encoder.encode(self) }

    /// Decode, migrating older schema versions forward. Configs written before
    /// the agent fields existed get a fresh token and port.
    public static func decode(_ data: Data) throws -> VMConfig {
        var config = try decoder.decode(VMConfig.self, from: data)
        if config.schemaVersion < currentSchemaVersion {
            // future migrations go here, in order
            config.schemaVersion = currentSchemaVersion
        }
        return config
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, guestOS, cpuCount, memoryMiB, disks, cdroms, network, display, tpm,
             usbPassthrough, sharedFolders, macAddress, createdAt, agentToken, agentHostPort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        name = try c.decode(String.self, forKey: .name)
        guestOS = try c.decode(GuestOS.self, forKey: .guestOS)
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memoryMiB = try c.decode(Int.self, forKey: .memoryMiB)
        disks = try c.decode([Disk].self, forKey: .disks)
        cdroms = try c.decodeIfPresent([CDROM].self, forKey: .cdroms) ?? []
        network = try c.decodeIfPresent(Network.self, forKey: .network) ?? .user(portForwards: [])
        display = try c.decode(DisplayDevice.self, forKey: .display)
        tpm = try c.decodeIfPresent(Bool.self, forKey: .tpm) ?? false
        usbPassthrough = try c.decodeIfPresent([USBSelector].self, forKey: .usbPassthrough) ?? []
        sharedFolders = try c.decodeIfPresent([SharedFolder].self, forKey: .sharedFolders) ?? []
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress) ?? VMConfig.randomMAC()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        let token = try c.decodeIfPresent(String.self, forKey: .agentToken) ?? UUID().uuidString.lowercased()
        agentToken = token
        agentHostPort = try c.decodeIfPresent(Int.self, forKey: .agentHostPort) ?? VMConfig.agentPort(for: token)
    }
}
