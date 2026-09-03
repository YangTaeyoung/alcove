import XCTest
@testable import AlcoveEngine

final class VMConfigTests: XCTestCase {
    func testDefaultsPerOS() {
        let w = VMConfig.defaults(name: "Win", guestOS: .windows, installISO: "/x.iso")
        XCTAssertEqual(w.disks.first?.bus, .nvme); XCTAssertEqual(w.display, .ramfb); XCTAssertEqual(w.cdroms.first?.path, "/x.iso")
        let l = VMConfig.defaults(name: "Lin", guestOS: .linux)
        XCTAssertEqual(l.disks.first?.bus, .virtioBlk); XCTAssertEqual(l.display, .virtioGPU); XCTAssertTrue(l.cdroms.isEmpty)
        XCTAssertNoThrow(try w.validate()); XCTAssertNoThrow(try l.validate())
    }

    func testRoundTripPreservesEverything() throws {
        var c = VMConfig.defaults(name: "RT", guestOS: .linux)
        c.network = .user(portForwards: [.init(hostPort: 2222, guestPort: 22)])
        c.usbPassthrough = [.init(vendorID: 0x05ac, productID: 0x12a8, name: "iPhone")]
        c.sharedFolders = [.init(hostPath: "/Users/me", tag: "home")]
        c.tpm = true
        let back = try VMConfig.decode(try c.encoded())
        XCTAssertEqual(back.name, c.name); XCTAssertEqual(back.network, c.network)
        XCTAssertEqual(back.usbPassthrough, c.usbPassthrough); XCTAssertEqual(back.sharedFolders, c.sharedFolders)
        XCTAssertEqual(back.macAddress, c.macAddress); XCTAssertEqual(back.tpm, true)
        XCTAssertEqual(back.createdAt.timeIntervalSince1970, c.createdAt.timeIntervalSince1970, accuracy: 1)
    }

    func testEncodedJSONIsStableAndReadable() throws {
        let c = VMConfig(name: "S", guestOS: .other, cpuCount: 2, memoryMiB: 1024, disks: [.init(id: "disk0", fileName: "disk0.qcow2", sizeGiB: 8, bus: .virtioBlk)],
                         display: .ramfb, macAddress: "52:54:00:00:00:01", createdAt: Date(timeIntervalSince1970: 0))
        let json = String(decoding: try c.encoded(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(json.contains("\"bus\" : \"virtio-blk\""))
        XCTAssertTrue(json.contains("\"createdAt\" : \"1970-01-01T00:00:00Z\""))
    }

    func testOlderSchemaIsMigratedForward() throws {
        var c = VMConfig.defaults(name: "Old", guestOS: .linux)
        c.schemaVersion = 0
        let back = try VMConfig.decode(try c.encoded())
        XCTAssertEqual(back.schemaVersion, VMConfig.currentSchemaVersion)
    }

    func testValidation() {
        var c = VMConfig.defaults(name: "V", guestOS: .linux)
        c.name = " "; XCTAssertThrowsError(try c.validate()) { XCTAssertEqual($0 as? VMConfig.ValidationError, .emptyName) }
        c.name = "a/b"; XCTAssertThrowsError(try c.validate())
        c.name = "ok"; c.cpuCount = 0; XCTAssertThrowsError(try c.validate())
        c.cpuCount = 2; c.memoryMiB = 64; XCTAssertThrowsError(try c.validate())
        c.memoryMiB = 1024; c.disks = []; XCTAssertThrowsError(try c.validate()) { XCTAssertEqual($0 as? VMConfig.ValidationError, .noDisks) }
        c.disks = [.init(id: "d", fileName: "d.qcow2", sizeGiB: 1, bus: .nvme), .init(id: "d", fileName: "e.qcow2", sizeGiB: 1, bus: .nvme)]
        XCTAssertThrowsError(try c.validate()) { XCTAssertEqual($0 as? VMConfig.ValidationError, .duplicateID("d")) }
        c.disks = [.init(id: "d", fileName: "d.qcow2", sizeGiB: 1, bus: .nvme)]; c.macAddress = "nope"
        XCTAssertThrowsError(try c.validate())
    }

    func testRandomMACIsLocallyAdministeredUnicast() {
        for _ in 0..<20 {
            let m = VMConfig.randomMAC()
            XCTAssertTrue(m.hasPrefix("52:54:00:"))
            XCTAssertEqual(m.count, 17)
        }
    }
}
