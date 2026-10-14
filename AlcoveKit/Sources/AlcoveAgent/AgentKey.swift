import Foundation
import CryptoKit

/// The Ed25519 key of a VM's `agentKey` (docs/agent-protocol.md, Host key): `agentKey` is the 32-byte seed as 64
/// hexadecimal digits; the agent stores its public key and verifies signatures of `authContext` followed by the
/// hello's nonce.
public enum AgentKey {
    /// The bytes that come before the nonce in the signed message.
    public static let authContext = "alcove-agent-auth-v1"

    /// The private key whose seed `agentKey` encodes; nil when it is not 64 hexadecimal digits.
    static func privateKey(_ agentKey: String) -> Curve25519.Signing.PrivateKey? {
        guard let seed = AgentClient.hexBytes(agentKey), seed.count == 32 else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    /// The public key of `agentKey` as 64 lower-case hexadecimal digits; nil when `agentKey` is not 64 hexadecimal
    /// digits.
    public static func publicKey(_ agentKey: String) -> String? {
        privateKey(agentKey).map { hex($0.publicKey.rawRepresentation) }
    }

    /// The Ed25519 signature by `agentKey` of `authContext` followed by `nonce`, as 128 lower-case hexadecimal digits;
    /// nil when `agentKey` is not 64 hexadecimal digits or signing fails.
    public static func signature(_ agentKey: String, nonce: Data) -> String? {
        guard let key = privateKey(agentKey),
              let signature = try? key.signature(for: Data(authContext.utf8) + nonce) else { return nil }
        return hex(signature)
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
