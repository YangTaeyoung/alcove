import XCTest
import CryptoKit
@testable import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class AgentAuthTests: XCTestCase {
    private let key = String(repeating: "a5", count: 32)
    private let nonce = String(repeating: "0f", count: 32)

    private func bytes(_ hex: String) -> Data { hexData(hex) }

    /// The vector of seed 0xA5 x 32 and nonce 0x0F x 32 that auth_test.go checks too.
    private let vectorPublicKey = "29e5833a915a6429a4e3a7948475c338ef436eb82be89c92f059704403db9d55"
    /// A signature CryptoKit produced for the vector; auth_test.go verifies it with crypto/ed25519.
    private let vectorCryptoKitSignature = "c3bc0953d4da7bb790c3907a80bae91023e0298463dde222ef8e1f1a6b312b4a7c0766deee90601af5cd25772c061db0ac171014a97fcea1fdaa3b64dd8e2d09"
    /// The signature Go's ed25519.Sign produces for the vector.
    private let vectorGoSignature = "34e3a451b7da207d9d86cdc48cc5a9bf8bab364fe35faa83a551117d64e3fe003ab06eef28d3d682b612f24473dd06b74d3fdd5f377a647487ad3e6505015c02"

    private func verifies(_ signature: String, publicKey: String, nonce: String) -> Bool {
        signatureVerifies(signature, publicKey: publicKey, nonce: nonce)
    }

    /// Whether a line the agent received holds the agentKey.
    private func carriesTheKey(_ agent: FakeAgent) -> Bool {
        agent.received.contains { line in (try? line.serialized()).map { String(decoding: $0, as: UTF8.self).contains(key) } ?? true }
    }

    private func types(_ agent: FakeAgent) -> [String] { agent.received.compactMap { $0["t"]?.stringValue } }

    func testTheKeyOfTheVectorSignsWhatTheAgentVerifies() throws {
        XCTAssertEqual(AgentKey.authContext, "alcove-agent-auth-v1")
        XCTAssertEqual(AgentKey.publicKey(key), vectorPublicKey)
        let signature = try XCTUnwrap(AgentKey.signature(key, nonce: bytes(nonce)))
        XCTAssertEqual(signature.count, 128)
        XCTAssertTrue(verifies(signature, publicKey: vectorPublicKey, nonce: nonce))
        XCTAssertTrue(verifies(vectorCryptoKitSignature, publicKey: vectorPublicKey, nonce: nonce))
        XCTAssertTrue(verifies(vectorGoSignature, publicKey: vectorPublicKey, nonce: nonce))
        XCTAssertFalse(verifies(signature, publicKey: vectorPublicKey, nonce: String(repeating: "0e", count: 32)))
        XCTAssertNil(AgentKey.publicKey("abc"))
        XCTAssertNil(AgentKey.publicKey(String(repeating: "g", count: 64)))
        XCTAssertNil(AgentKey.signature(String(repeating: "a5", count: 31), nonce: bytes(nonce)))
        XCTAssertEqual(AgentClient.hexBytes("0aFf"), Data([0x0A, 0xFF]))
        XCTAssertNil(AgentClient.hexBytes("0g"))
        XCTAssertNil(AgentClient.hexBytes("abc"))
    }

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
        XCTAssertEqual(agent.received.first?["publicKey"]?.stringValue, vectorPublicKey)
        XCTAssertFalse(carriesTheKey(agent), "a line carried the agentKey")
    }

    func testAPairedAgentGetsTheSignatureOfItsNonce() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce), "paired": true]
        let publicKey = vectorPublicKey, nonce = self.nonce
        let valid: @Sendable (String) -> Bool = { signatureVerifies($0, publicKey: publicKey, nonce: nonce) }
        agent.handler = { m, _ in
            guard m["t"]?.stringValue == "auth" else { return [] }
            return valid(m["signature"]?.stringValue ?? "") ? [["t": "authed"]] : [["t": "refused", "error": "wrong signature"]]
        }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: "tok", agentKey: key)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Array(types(agent).prefix(2)), ["auth", "welcome"])
        XCTAssertFalse(carriesTheKey(agent), "a line carried the agentKey")
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

/// The bytes that `hex`, an even number of hexadecimal digits, encodes.
private func hexData(_ hex: String) -> Data {
    var out = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

/// Whether `signature` is the signature by the private key of `publicKey` of the auth context and `nonce`.
private func signatureVerifies(_ signature: String, publicKey: String, nonce: String) -> Bool {
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: hexData(publicKey)) else { return false }
    return key.isValidSignature(hexData(signature), for: Data("alcove-agent-auth-v1".utf8) + hexData(nonce))
}
