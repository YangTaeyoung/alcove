import XCTest
import CryptoKit
@testable import AlcoveControl
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class AgentKeyLinkTests: XCTestCase {
    private let key = String(repeating: "5a", count: 32)
    private let nonce = String(repeating: "c3", count: 32)
    private let sentence = "this alcove-agent serves nothing because the VM's SMBIOS strings lack alcove-hostkey or alcove-token; start the VM with Alcove 0.2 or later"

    func testTheLinkSignsTheTokenAndTheNonceWithTheVMsKey() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce)]
        agent.handler = { m, _ in m["t"]?.stringValue == "auth" ? [["t": "authed"]] : [] }
        let key = self.key
        let link = AgentLink(events: EventBuffer(), isRunning: { true }, endpoint: { (agent.port, "tok") }, agentKey: { key })
        let client = await link.agent(timeout: .seconds(30))
        XCTAssertNotNil(client)
        XCTAssertEqual(agent.received.first?["t"]?.stringValue, "auth")
        let nonce = try XCTUnwrap(linkTestHex(self.nonce))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap(linkTestHex(XCTUnwrap(AgentKey.publicKey(key)))))
        let signature = try XCTUnwrap(linkTestHex(XCTUnwrap(agent.received.first?["signature"]?.stringValue)))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data("alcove-agent-auth-v2tok".utf8) + nonce))
        let refusal = await link.lastRefusal()
        XCTAssertNil(refusal)
    }

    func testTheLinkKeepsTheSentenceForGuestToolsWithoutAuth() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        let key = self.key
        let link = AgentLink(events: EventBuffer(), retryDelay: .milliseconds(10), isRunning: { true },
                             endpoint: { (agent.port, "tok") }, agentKey: { key })
        let client = await link.agent(timeout: .seconds(1))
        XCTAssertNil(client)
        let refusal = await link.lastRefusal()
        XCTAssertEqual(refusal, AgentClient.agentWithoutAuth)
        XCTAssertFalse(agent.received.contains { $0["t"]?.stringValue == "welcome" })
    }

    func testTheLinkKeepsTheSentenceOfAnAgentThatRefusedIt() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce)]
        let sentence = self.sentence
        agent.handler = { m, a in
            guard m["t"]?.stringValue == "auth" else { return [] }
            a.sendLine(["t": "refused", "error": .string(sentence)])
            a.drop()
            return []
        }
        let key = self.key
        let running = LockedBox(true)
        let link = AgentLink(events: EventBuffer(), retryDelay: .milliseconds(10), isRunning: { running.value },
                             endpoint: { (agent.port, "tok") }, agentKey: { key })
        let client = await link.agent(timeout: .seconds(1))
        XCTAssertNil(client)
        let refusal = await link.lastRefusal()
        XCTAssertEqual(refusal, sentence)

        running.value = false
        _ = await link.agent(timeout: .zero)
        let afterTheStop = await link.lastRefusal()
        XCTAssertNil(afterTheStop)
    }

    func testAnOperationOnAVMWhoseAgentRefusedTheHostSaysWhy() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 8, height: 8))
        await t.setRefusal(sentence)
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory)
        do {
            _ = try await h.handle(op: "vm.fs.list", params: ["name": "Win", "path": "/"])
            XCTFail("vm.fs.list succeeded")
        } catch let e as ControlHandler.ControlError {
            XCTAssertEqual(e.description, "the guest tools in 'Win' refused the connection: \(sentence)")
        }
    }

    func testVMStatusNamesTheRefusalOfTheGuestTools() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 8, height: 8))
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory)
        let quiet = try await h.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertEqual(quiet["tools"]?.boolValue, false)
        XCTAssertNil(quiet["toolsRefused"])

        await t.setRefusal(sentence)
        let status = try await h.handle(op: "vm.status", params: ["name": "Win"])
        XCTAssertEqual(status["tools"]?.boolValue, false)
        XCTAssertEqual(status["toolsRefused"]?.stringValue, sentence)
    }

    func testVMDoctorShowsTheRefusalOfTheGuestToolsAndItsFix() async throws {
        let t = FakeTarget(name: "Win", state: .running, png: makePNG(width: 8, height: 8))
        await t.setRefusal(sentence)
        let h = ControlHandler(registry: FakeRegistry(targets: ["Win": t]), hostKind: "test", captureDirectory: scratchCaptureDirectory)
        let doctor = try await h.handle(op: "vm.doctor", params: ["name": "Win"])
        let rows = doctor["checks"]?.arrayValue ?? []
        XCTAssertEqual(rows.last?["id"]?.stringValue, "tools")
        XCTAssertEqual(rows.last?["ok"]?.boolValue, false)
        XCTAssertEqual(rows.last?["detail"]?.stringValue, "the guest tools refused the connection: \(sentence)")
        XCTAssertEqual(rows.last?["hint"]?.stringValue,
                       "start the VM with Alcove 0.2 or later")
    }

    func testTheFixOfARefusalIsTheTextAfterItsFirstSemicolon() {
        XCTAssertEqual(ControlHandler.refusalFix("a; b; c"), "b; c")
        XCTAssertEqual(ControlHandler.refusalFix("no next step"), ControlHandler.refusalFallbackFix)
        XCTAssertEqual(ControlHandler.refusalFix("trailing; "), ControlHandler.refusalFallbackFix)
    }
}

/// The bytes an even number of hexadecimal digits encode, or nil.
private func linkTestHex(_ text: String) -> Data? {
    guard text.count % 2 == 0 else { return nil }
    var out = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        out.append(byte)
        index = next
    }
    return out
}
