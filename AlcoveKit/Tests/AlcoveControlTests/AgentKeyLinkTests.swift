import XCTest
@testable import AlcoveControl
import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class AgentKeyLinkTests: XCTestCase {
    private let key = String(repeating: "5a", count: 32)
    private let nonce = String(repeating: "c3", count: 32)
    private let sentence = "this alcove-agent is already paired with another host key; run alcove-agent --forget-host-key as an administrator in the guest and connect again"

    func testTheLinkPairsTheAgentWithThePublicKeyOfTheVMsKey() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce), "paired": false]
        agent.handler = { m, _ in m["t"]?.stringValue == "pair" ? [["t": "authed"]] : [] }
        let key = self.key
        let link = AgentLink(events: EventBuffer(), isRunning: { true }, endpoint: { (agent.port, "tok") }, agentKey: { key })
        let client = await link.agent(timeout: .seconds(30))
        XCTAssertNotNil(client)
        XCTAssertEqual(agent.received.first?["t"]?.stringValue, "pair")
        XCTAssertEqual(agent.received.first?["publicKey"]?.stringValue, AgentKey.publicKey(key))
        let refusal = await link.lastRefusal()
        XCTAssertNil(refusal)
    }

    func testTheLinkKeepsTheSentenceOfAnAgentThatRefusedIt() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce), "paired": false]
        let sentence = self.sentence
        agent.handler = { m, a in
            guard m["t"]?.stringValue == "pair" else { return [] }
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
                       "run alcove-agent --forget-host-key as an administrator in the guest and connect again")
    }

    func testTheFixOfARefusalIsTheTextAfterItsFirstSemicolon() {
        XCTAssertEqual(ControlHandler.refusalFix("a; b; c"), "b; c")
        XCTAssertEqual(ControlHandler.refusalFix("no next step"), ControlHandler.refusalFallbackFix)
        XCTAssertEqual(ControlHandler.refusalFix("trailing; "), ControlHandler.refusalFallbackFix)
    }
}
