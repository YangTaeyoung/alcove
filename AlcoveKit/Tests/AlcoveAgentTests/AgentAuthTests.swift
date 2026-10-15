import XCTest
import CryptoKit
@testable import AlcoveAgent
import AlcoveQMP
import AlcoveTestSupport

final class AgentAuthTests: XCTestCase {
    private let key = String(repeating: "a5", count: 32)
    private let nonce = String(repeating: "0f", count: 32)
    /// The token of the vector.
    private let vectorToken = "6f1c2d3e-4a5b-4c6d-8e7f-0123456789ab"

    private func bytes(_ hex: String) -> Data { hexData(hex) }

    /// The vector of seed 0xA5 x 32, token `vectorToken` and nonce 0x0F x 32 that auth_test.go checks too.
    private let vectorPublicKey = "29e5833a915a6429a4e3a7948475c338ef436eb82be89c92f059704403db9d55"
    /// A signature CryptoKit produced for the vector; auth_test.go verifies it with crypto/ed25519.
    private let vectorCryptoKitSignature = "0037298425146c70bd7cd31220376c19c0ce2168d7be15b7fea0625a60f3bfd7f58a4a6fbdb3b7b8771165ff5935d143d795c269049001dcdd4a8da57500ae02"
    /// The signature Go's ed25519.Sign produces for the vector.
    private let vectorGoSignature = "9f85de9d08926c99e4e61d5005737259169e804fd6e6da71a875682255b1d7fbcaca02d777c3d091b800b781fa396bb9b66984a1bb0cd167dd900d2c8a670d03"

    private func verifies(_ signature: String, publicKey: String, token: String, nonce: String) -> Bool {
        signatureVerifies(signature, publicKey: publicKey, token: token, nonce: nonce)
    }

    /// Whether a line the agent received holds the agentKey.
    private func carriesTheKey(_ agent: FakeAgent) -> Bool {
        agent.received.contains { line in (try? line.serialized()).map { String(decoding: $0, as: UTF8.self).contains(key) } ?? true }
    }

    private func types(_ agent: FakeAgent) -> [String] { agent.received.compactMap { $0["t"]?.stringValue } }

    func testTheKeyOfTheVectorSignsWhatTheAgentVerifies() throws {
        XCTAssertEqual(AgentKey.authContext, "alcove-agent-auth-v2")
        XCTAssertEqual(AgentKey.publicKey(key), vectorPublicKey)
        let signature = try XCTUnwrap(AgentKey.signature(key, token: vectorToken, nonce: bytes(nonce)))
        XCTAssertEqual(signature.count, 128)
        XCTAssertTrue(verifies(signature, publicKey: vectorPublicKey, token: vectorToken, nonce: nonce))
        XCTAssertTrue(verifies(vectorCryptoKitSignature, publicKey: vectorPublicKey, token: vectorToken, nonce: nonce))
        XCTAssertTrue(verifies(vectorGoSignature, publicKey: vectorPublicKey, token: vectorToken, nonce: nonce))
        XCTAssertFalse(verifies(signature, publicKey: vectorPublicKey, token: vectorToken, nonce: String(repeating: "0e", count: 32)))
        XCTAssertFalse(verifies(signature, publicKey: vectorPublicKey, token: "another token", nonce: nonce))
        XCTAssertNil(AgentKey.publicKey("abc"))
        XCTAssertNil(AgentKey.publicKey(String(repeating: "g", count: 64)))
        XCTAssertNil(AgentKey.signature(String(repeating: "a5", count: 31), token: vectorToken, nonce: bytes(nonce)))
        XCTAssertNil(AgentKey.signature(key, token: "", nonce: bytes(nonce)))
        XCTAssertEqual(AgentClient.hexBytes("0aFf"), Data([0x0A, 0xFF]))
        XCTAssertNil(AgentClient.hexBytes("0g"))
        XCTAssertNil(AgentClient.hexBytes("abc"))
    }

    func testAgentSignPrintsTheSignatureThePublicKeyAndTheToken() throws {
        let all = try AgentKey.signLines(agentKey: key, agentToken: vectorToken, nonce: nonce, publicKey: true, token: true)
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(verifies(all[0], publicKey: vectorPublicKey, token: vectorToken, nonce: nonce))
        XCTAssertEqual(Array(all.dropFirst()), [vectorPublicKey, vectorToken])
        let signature = try AgentKey.signLines(agentKey: key, agentToken: vectorToken, nonce: nonce.uppercased(), publicKey: false, token: false)
        XCTAssertEqual(signature.count, 1)
        XCTAssertTrue(verifies(signature[0], publicKey: vectorPublicKey, token: vectorToken, nonce: nonce))
        XCTAssertEqual(try AgentKey.signLines(agentKey: key, agentToken: vectorToken, nonce: nil, publicKey: true, token: false), [vectorPublicKey])
        XCTAssertEqual(try AgentKey.signLines(agentKey: key, agentToken: vectorToken, nonce: nil, publicKey: true, token: true), [vectorPublicKey, vectorToken])

        let failures: [(String?, String?, String?, Bool, String)] = [
            (key, vectorToken, nil, false, AgentKey.signUsage),
            (key, vectorToken, "abc", false, AgentKey.badSignNonce),
            (key, vectorToken, String(repeating: "0", count: 62), true, AgentKey.badSignNonce),
            (String(repeating: "a5", count: 31), vectorToken, nonce, false, AgentClient.badAgentKey),
            (nil, vectorToken, nonce, false, AgentClient.badAgentKey),
            (key, nil, nonce, false, AgentClient.noAgentToken),
            (key, "", nonce, false, AgentClient.noAgentToken),
        ]
        for (agentKey, agentToken, nonce, publicKey, sentence) in failures {
            XCTAssertThrowsError(try AgentKey.signLines(agentKey: agentKey, agentToken: agentToken, nonce: nonce, publicKey: publicKey, token: false)) {
                XCTAssertEqual(($0 as? AgentKey.Failure)?.sentence, sentence)
            }
        }
    }

    func testTheAgentGetsTheSignatureOfTheVMsTokenAndItsNonce() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.token = vectorToken
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce)]
        let publicKey = vectorPublicKey, nonce = self.nonce, token = vectorToken
        let valid: @Sendable (String) -> Bool = { signatureVerifies($0, publicKey: publicKey, token: token, nonce: nonce) }
        agent.handler = { m, _ in
            guard m["t"]?.stringValue == "auth" else { return [] }
            return valid(m["signature"]?.stringValue ?? "") ? [["t": "authed"]] : [["t": "refused", "error": "wrong signature"]]
        }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: vectorToken, agentKey: key)
        let connected = await client.isConnected
        XCTAssertTrue(connected)
        let authenticated = await client.hello?.authenticated
        XCTAssertEqual(authenticated, true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Array(types(agent).prefix(2)), ["auth", "welcome"])
        XCTAssertFalse(carriesTheKey(agent), "a line carried the agentKey")
    }

    func testACapsLineBeforeTheHandshakeEndsReplacesTheHelloCapabilities() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.token = vectorToken
        agent.caps = ["files", "exec"]
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce)]
        agent.handler = { m, _ in
            m["t"]?.stringValue == "auth" ? [["t": "caps", "caps": ["files", "clipboard", "exec"]], ["t": "authed"]] : []
        }
        let client = AgentClient()
        try await client.connect(port: agent.port, expectedToken: vectorToken, agentKey: key)
        let caps = await client.hello?.capabilities
        XCTAssertEqual(caps, ["files", "clipboard", "exec"])
    }

    func testAHelloWithAnotherTokenGetsNoSignature() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.token = "the token of another VM"
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce)]
        let client = AgentClient()
        do {
            try await client.connect(port: agent.port, expectedToken: vectorToken, agentKey: key)
            XCTFail("connect succeeded")
        } catch AgentClient.AgentError.tokenMismatch {}
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(types(agent).contains("auth"))
    }

    func testAHelloWithoutAuthIsRefusedByAHostWithTheVMsKey() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        let client = AgentClient()
        do {
            try await client.connect(port: agent.port, expectedToken: "tok", agentKey: key)
            XCTFail("connect succeeded")
        } catch AgentClient.AgentError.refused(let text) {
            XCTAssertEqual(text, AgentClient.agentWithoutAuth)
        }
        let connected = await client.isConnected
        XCTAssertFalse(connected)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(types(agent), [])
        XCTAssertEqual(AgentClient.agentWithoutAuth,
                       "the guest tools do not ask the host for the VM's key, so the host does not use them; reinstall the guest tools from this version of Alcove (scripts/test/install-agent.py)")
    }

    func testAnAgentThatAsksForTheKeyWhenNoneOrNoTokenIsGivenIsLeft() async throws {
        for (token, agentKey, reason) in [("tok", nil, AgentClient.noAgentKey), (nil, key, AgentClient.noAgentToken)] as [(String?, String?, String)] {
            let agent = FakeAgent().start(); defer { agent.stop() }
            agent.helloExtra = ["auth": "key", "nonce": .string(nonce)]
            let client = AgentClient()
            do {
                try await client.connect(port: agent.port, expectedToken: token, agentKey: agentKey)
                XCTFail("connect succeeded")
            } catch AgentClient.AgentError.handshake(let text) {
                XCTAssertEqual(text, reason)
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(types(agent).contains("auth") || types(agent).contains("welcome"))
        }
    }

    func testTheRefusedSentenceIsTheErrorOfConnect() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce)]
        let sentence = "the host's signature does not match this VM's alcove-hostkey and alcove-token; restart the VM with Alcove"
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
        XCTAssertEqual(AgentClient.AgentError.refused(sentence).refusal, sentence)
        XCTAssertNil(AgentClient.AgentError.disconnected.refusal)
        XCTAssertNil(AgentClient.AgentError.timeout("authed").refusal)
    }

    func testTheConnectionIsNotReadyWhileTheAgentHasNotAnsweredTheAuth() async throws {
        let agent = FakeAgent().start(); defer { agent.stop() }
        agent.helloExtra = ["auth": "key", "nonce": .string(nonce)]
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
        agent.sendLine(["t": "refused", "error": "this alcove-agent serves only a host that proves the VM's key"])
        agent.drop()
        do {
            _ = try await pending.value
            XCTFail("the call succeeded")
        } catch AgentClient.AgentError.refused(let text) {
            XCTAssertEqual(text, "this alcove-agent serves only a host that proves the VM's key")
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

/// Whether `signature` is the signature by the private key of `publicKey` of the auth context, `token` and `nonce`.
private func signatureVerifies(_ signature: String, publicKey: String, token: String, nonce: String) -> Bool {
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: hexData(publicKey)) else { return false }
    return key.isValidSignature(hexData(signature), for: Data("alcove-agent-auth-v2".utf8) + Data(token.utf8) + hexData(nonce))
}
