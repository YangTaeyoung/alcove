import XCTest
import CryptoKit
@testable import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class AgentAuthTests: XCTestCase {
    private let key = String(repeating: "a5", count: 32)
    private let nonce = String(repeating: "0f", count: 32)

    private func bytes(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private func mac(key: String, nonce: String) -> String {
        HMAC<SHA256>.authenticationCode(for: bytes(nonce), using: SymmetricKey(data: bytes(key)))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func types(_ agent: FakeAgent) -> [String] { agent.received.compactMap { $0["t"]?.stringValue } }

    func testAnUnpairedAgentIsPairedWithTheKeyBeforeTheConnectionIsReady() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce), "paired": false]
        agent.handler = { m, _ in m["t"]?.stringValue == "pair" ? [["t": "authed"]] : [] }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: "tok", agentKey: key)
        let connected = await client.isConnected
        XCTAssertTrue(connected)
        let authenticated = await client.hello?.authenticated
        XCTAssertEqual(authenticated, true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Array(types(agent).prefix(2)), ["pair", "welcome"])
        XCTAssertEqual(agent.received.first?["key"]?.stringValue, key)
    }

    func testAPairedAgentGetsTheMACOfItsNonce() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce), "paired": true]
        let expected = mac(key: key, nonce: nonce)
        agent.handler = { m, _ in
            guard m["t"]?.stringValue == "auth" else { return [] }
            return m["mac"]?.stringValue == expected ? [["t": "authed"]] : [["t": "refused", "error": "wrong mac"]]
        }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: "tok", agentKey: key)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Array(types(agent).prefix(2)), ["auth", "welcome"])
        XCTAssertNil(agent.received.first?["key"], "the key itself was sent to a paired agent")
    }

    func testTheRefusedSentenceIsTheErrorOfConnect() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce), "paired": true]
        let sentence = "the host did not prove the key this alcove-agent is paired with; run alcove-agent --forget-host-key"
        agent.handler = { m, a in
            guard m["t"]?.stringValue == "auth" else { return [] }
            a.sendLine(["t": "refused", "error": .string(sentence)])
            a.drop()
            return []
        }
        let client = AgentClient()
        do {
            try await client.connect(port: agent.port, expectedToken: "tok", agentKey: key)
            XCTFail("connect succeeded")
        } catch AgentClient.AgentError.refused(let text) {
            XCTAssertEqual(text, sentence)
        }
        let connected = await client.isConnected
        XCTAssertFalse(connected)
        XCTAssertFalse(types(agent).contains("welcome"))
        XCTAssertEqual(AgentClient.AgentError.refused(sentence).errorDescription,
                       "the guest tools refused the connection: \(sentence)")
    }

    func testTheConnectionIsNotReadyWhileTheAgentHasNotAnsweredTheAuth() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce), "paired": true]
        let client = AgentClient()
        do {
            try await client.connect(port: agent.port, expectedToken: "tok", agentKey: key, timeout: .milliseconds(300))
            XCTFail("connect succeeded without authed")
        } catch AgentClient.AgentError.timeout(let what) {
            XCTAssertEqual(what, "authed")
        }
        let connected = await client.isConnected
        XCTAssertFalse(connected)
        XCTAssertFalse(types(agent).contains("welcome"))
    }

    func testAnAgentWithoutKeySupportIsUsedWithoutPairing() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: "tok", agentKey: key)
        let authenticated = await client.hello?.authenticated
        XCTAssertEqual(authenticated, false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(types(agent).first, "welcome")
        XCTAssertFalse(types(agent).contains("pair") || types(agent).contains("auth"))
    }

    func testAnAgentThatAsksForTheKeyWhenNoneIsGivenIsLeft() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce), "paired": false]
        let client = AgentClient()
        do {
            try await client.connect(port: agent.port, expectedToken: "tok")
            XCTFail("connect succeeded")
        } catch AgentClient.AgentError.handshake(let reason) {
            XCTAssertEqual(reason, AgentClient.noAgentKey)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(types(agent).contains("pair") || types(agent).contains("welcome"))
    }

    func testAPeerRefusalInPlaceOfTheHelloIsTheErrorOfConnect() async throws {
        let agent = FakeAgent()
        agent.sendsHello = false
        _ = agent.start(); defer { agent.stop() }
        agent.onConnect = { a in
            a.sendLine(["t": "refused", "error": "alcove-agent serves only connections from 10.0.2.2/32"])
            a.drop()
        }
        let client = AgentClient()
        do {
            try await client.connect(port: agent.port, expectedToken: "tok", agentKey: key)
            XCTFail("connect succeeded")
        } catch AgentClient.AgentError.refused(let text) {
            XCTAssertEqual(text, "alcove-agent serves only connections from 10.0.2.2/32")
        }
    }

    func testARefusalAfterTheConnectionWasReadyFailsTheWaitingCallsWithItsSentence() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: nil)
        let pending = Task { try await client.call("ping", timeout: .seconds(10)) }
        while agent.receivedCount() < 2 { try await Task.sleep(for: .milliseconds(10)) }
        agent.sendLine(["t": "refused", "error": "this alcove-agent serves only a host that pairs with it"])
        agent.drop()
        do {
            _ = try await pending.value
            XCTFail("the call succeeded")
        } catch AgentClient.AgentError.refused(let text) {
            XCTAssertEqual(text, "this alcove-agent serves only a host that pairs with it")
        }
    }
}
