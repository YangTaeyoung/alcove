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
        // swtpm's --tpmstate dir= is comma-delimited with no escape
        c.name = "Work, Dev"; XCTAssertThrowsError(try c.validate()) { XCTAssertEqual($0 as? VMConfig.ValidationError, .invalidName("Work, Dev")) }
        c.name = "ok"; c.cpuCount = 0; XCTAssertThrowsError(try c.validate())
        c.cpuCount = 2; c.memoryMiB = 64; XCTAssertThrowsError(try c.validate())
        c.memoryMiB = 1024; c.disks = []; XCTAssertThrowsError(try c.validate()) { XCTAssertEqual($0 as? VMConfig.ValidationError, .noDisks) }
        c.disks = [.init(id: "d", fileName: "d.qcow2", sizeGiB: 1, bus: .nvme), .init(id: "d", fileName: "e.qcow2", sizeGiB: 1, bus: .nvme)]
        XCTAssertThrowsError(try c.validate()) { XCTAssertEqual($0 as? VMConfig.ValidationError, .duplicateID("d")) }
        c.disks = [.init(id: "d", fileName: "d.qcow2", sizeGiB: 1, bus: .nvme)]; c.macAddress = "nope"
        XCTAssertThrowsError(try c.validate())
    }

    func testAgentFieldsAreGeneratedAndMigrated() throws {
        let c = VMConfig.defaults(name: "A", guestOS: .linux)
        XCTAssertEqual(c.agentToken.count, 36)
        XCTAssertTrue((17000...17999).contains(c.agentHostPort))
        XCTAssertEqual(c.agentHostPort, VMConfig.agentPort(for: c.agentToken))
        // an old config without the fields decodes with fresh values
        var obj = try JSONSerialization.jsonObject(with: try c.encoded()) as! [String: Any]
        obj.removeValue(forKey: "agentToken"); obj.removeValue(forKey: "agentHostPort")
        let oldData = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertTrue(VMConfig.needsMigration(oldData))
        XCTAssertFalse(VMConfig.needsMigration(try c.encoded()))
        let old = try VMConfig.decode(oldData)
        XCTAssertEqual(old.agentToken.count, 36)
        XCTAssertEqual(old.agentHostPort, VMConfig.agentPort(for: old.agentToken))
        XCTAssertEqual(try VMConfig.decode(try c.encoded()).agentToken, c.agentToken)
    }

    func testCloneOfRoundTripsAndIsOmittedWhenNil() throws {
        var c = VMConfig.defaults(name: "C", guestOS: .linux)
        XCTAssertNil(c.cloneOf)
        let plain = try c.encoded()
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("cloneOf"))
        XCTAssertNil(try VMConfig.decode(plain).cloneOf)
        XCTAssertFalse(VMConfig.needsMigration(plain))
        c.cloneOf = "Template"
        XCTAssertEqual(try VMConfig.decode(try c.encoded()).cloneOf, "Template")
    }

    func testEpochFieldsRoundTripAndAreOmittedWhenNil() throws {
        var c = VMConfig.defaults(name: "E", guestOS: .linux)
        XCTAssertNil(c.diskEpoch); XCTAssertNil(c.templateEpoch); XCTAssertNil(c.templatePath)
        let plain = try c.encoded()
        let json = String(decoding: plain, as: UTF8.self)
        for key in ["diskEpoch", "templateEpoch", "templatePath"] { XCTAssertFalse(json.contains(key), key) }
        XCTAssertFalse(VMConfig.needsMigration(plain))

        c.diskEpoch = 3; c.templateEpoch = 7; c.templatePath = "/vms/Template.alcovevm"
        let data = try c.encoded()
        let back = try VMConfig.decode(data)
        XCTAssertEqual(back.diskEpoch, 3)
        XCTAssertEqual(back.templateEpoch, 7)
        XCTAssertEqual(back.templatePath, "/vms/Template.alcovevm")
        XCTAssertFalse(VMConfig.needsMigration(data))

        let made = VMConfig(name: "I", guestOS: .other, cpuCount: 1, memoryMiB: 512, disks: c.disks, display: .ramfb,
                            diskEpoch: 0, templateEpoch: 2, templatePath: "/t")
        XCTAssertEqual(made.diskEpoch, 0); XCTAssertEqual(made.templateEpoch, 2); XCTAssertEqual(made.templatePath, "/t")
    }

    func testConfigWithoutEpochFieldsDecodesWithNil() throws {
        let json = #"""
        {"schemaVersion": 1, "name": "Old", "guestOS": "linux", "cpuCount": 2, "memoryMiB": 1024, "display": "ramfb",
         "disks": [{"id": "disk0", "fileName": "disk0.qcow2", "sizeGiB": 8, "bus": "virtio-blk"}],
         "agentToken": "0f0e0d0c-0000-4000-8000-000000000001", "agentHostPort": 17001, "cloneOf": "Template"}
        """#
        let old = Data(json.utf8)
        let c = try VMConfig.decode(old)
        XCTAssertNil(c.diskEpoch); XCTAssertNil(c.templateEpoch); XCTAssertNil(c.templatePath)
        XCTAssertNil(c.diskID); XCTAssertNil(c.templateDiskID)
        XCTAssertEqual(c.cloneOf, "Template")
        XCTAssertFalse(VMConfig.needsMigration(old))

        var withoutAgent = try JSONSerialization.jsonObject(with: old) as! [String: Any]
        withoutAgent.removeValue(forKey: "agentToken")
        withoutAgent["diskEpoch"] = 1
        XCTAssertTrue(VMConfig.needsMigration(try JSONSerialization.data(withJSONObject: withoutAgent)))
    }

    func testDiskIDFieldsRoundTripAndAreOmittedWhenNil() throws {
        var c = VMConfig.defaults(name: "D", guestOS: .linux)
        XCTAssertNil(c.diskID); XCTAssertNil(c.templateDiskID)
        let plain = try c.encoded()
        let json = String(decoding: plain, as: UTF8.self)
        for key in ["diskID", "templateDiskID"] { XCTAssertFalse(json.contains(key), key) }
        XCTAssertFalse(VMConfig.needsMigration(plain))

        c.diskID = "own"; c.templateDiskID = "template"
        let data = try c.encoded()
        let back = try VMConfig.decode(data)
        XCTAssertEqual(back.diskID, "own")
        XCTAssertEqual(back.templateDiskID, "template")
        XCTAssertFalse(VMConfig.needsMigration(data))

        let made = VMConfig(name: "I", guestOS: .other, cpuCount: 1, memoryMiB: 512, disks: c.disks, display: .ramfb,
                            diskID: "x", templateDiskID: "y")
        XCTAssertEqual(made.diskID, "x"); XCTAssertEqual(made.templateDiskID, "y")
    }

    func testPreservingDiskIdentityKeepsTheHigherEpochAndTheStoredDiskID() {
        var stored = VMConfig.defaults(name: "S", guestOS: .linux)
        var draft = stored
        draft.memoryMiB = 2048
        XCTAssertEqual(draft.preservingDiskIdentity(from: stored), draft)

        stored.diskEpoch = 3; stored.diskID = "stored"
        var expected = draft
        expected.diskEpoch = 3; expected.diskID = "stored"
        XCTAssertEqual(draft.preservingDiskIdentity(from: stored), expected)
        draft.diskEpoch = 2; draft.diskID = "other"
        XCTAssertEqual(draft.preservingDiskIdentity(from: stored), expected)
        draft.diskEpoch = 3
        XCTAssertEqual(draft.preservingDiskIdentity(from: stored), expected)
        draft.diskEpoch = 5
        expected.diskEpoch = 5
        XCTAssertEqual(draft.preservingDiskIdentity(from: stored), expected)

        stored.diskEpoch = nil; stored.diskID = nil
        XCTAssertEqual(draft.preservingDiskIdentity(from: stored), draft)
    }

    func testPreservingDiskIdentityKeepsStoredCloneFieldsWhereTheConfigHasNone() {
        var stored = VMConfig.defaults(name: "C", guestOS: .linux)
        var draft = stored
        draft.memoryMiB = 2048
        stored.cloneOf = "T"; stored.templateEpoch = 2; stored.templatePath = "/vms/T.alcovevm"; stored.templateDiskID = "id"
        var expected = draft
        expected.cloneOf = "T"; expected.templateEpoch = 2; expected.templatePath = "/vms/T.alcovevm"; expected.templateDiskID = "id"
        XCTAssertEqual(draft.preservingDiskIdentity(from: stored), expected)

        draft.cloneOf = "U"; draft.templateEpoch = 0; draft.templatePath = "/x"; draft.templateDiskID = "z"
        XCTAssertEqual(draft.preservingDiskIdentity(from: stored), draft)
    }

    func testRandomMACIsLocallyAdministeredUnicast() {
        for _ in 0..<20 {
            let m = VMConfig.randomMAC()
            XCTAssertTrue(m.hasPrefix("52:54:00:"))
            XCTAssertEqual(m.count, 17)
        }
    }
}
