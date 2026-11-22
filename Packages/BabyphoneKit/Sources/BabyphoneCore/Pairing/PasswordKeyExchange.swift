import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Turns a short pairing credential into a strong shared key.
///
/// This is a balanced password-authenticated key exchange in the style of
/// CPace, built on X25519. Both sides derive a secret curve point from the
/// credential and run Diffie-Hellman from that point instead of the standard
/// base point. Consequences:
///
/// - Someone listening to the exchange learns nothing they can test codes against.
/// - Someone taking part in the exchange gets exactly one guess per attempt.
/// - The resulting key has full strength even though the code has six digits.
///
/// Known simplification: the generator is the hash of the credential used
/// directly as a curve coordinate, without the Elligator map of the CPace
/// draft. A listener can therefore learn one bit about the one-time code
/// (whether its generator lies on the curve or on its twist). The code is
/// discarded after pairing and the derived key is unaffected.
enum PasswordKeyExchange {
    static let protocolLabel = "nid-pake-v1"

    struct Share {
        fileprivate let scalar: Curve25519.KeyAgreement.PrivateKey
        /// The value sent to the peer.
        let publicValue: Data
    }

    struct SessionKeys {
        let initiatorConfirmation: Data
        let responderConfirmation: Data
        let pairingKey: PairingKey
    }

    enum Failure: Error {
        case invalidPeerShare
    }

    static func makeShare(for credential: PairingCredential) throws -> Share {
        let scalar = Curve25519.KeyAgreement.PrivateKey()
        let publicValue = try multiply(scalar, generator(for: credential))
        return Share(scalar: scalar, publicValue: publicValue)
    }

    static func sessionKeys(
        share: Share,
        peerPublicValue: Data,
        transcript: Data
    ) throws -> SessionKeys {
        let secret = try multiply(share.scalar, peerPublicValue)
        let salt = Data(SHA256.hash(data: transcript))

        func expand(_ purpose: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: secret),
                salt: salt,
                info: Data("\(protocolLabel)/\(purpose)".utf8),
                outputByteCount: 32
            )
        }
        func confirmation(_ purpose: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: transcript, using: expand(purpose)))
        }

        return SessionKeys(
            initiatorConfirmation: confirmation("confirm-initiator"),
            responderConfirmation: confirmation("confirm-responder"),
            pairingKey: PairingKey(symmetricKey: expand("pairing-key"))
        )
    }

    /// Binds every value both sides exchanged, so neither can be swapped in transit.
    static func transcript(
        kind: PairingCredential.Kind,
        initiatorNonce: Data,
        responderNonce: Data,
        initiatorShare: Data,
        responderShare: Data
    ) -> Data {
        var transcript = Data()
        for field in [Data(protocolLabel.utf8), Data(kind.rawValue.utf8), initiatorNonce, responderNonce, initiatorShare, responderShare] {
            withUnsafeBytes(of: UInt32(field.count).bigEndian) { transcript.append(contentsOf: $0) }
            transcript.append(field)
        }
        return transcript
    }

    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func generator(for credential: PairingCredential) -> Data {
        var input = Data("\(protocolLabel)/generator/\(credential.kind.rawValue)/".utf8)
        input.append(credential.secret)
        return Data(SHA256.hash(data: input))
    }

    /// X25519 scalar multiplication of an arbitrary point.
    private static func multiply(_ scalar: Curve25519.KeyAgreement.PrivateKey, _ point: Data) throws -> Data {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: point),
              let product = try? scalar.sharedSecretFromKeyAgreement(with: peer)
        else { throw Failure.invalidPeerShare }
        let bytes = product.withUnsafeBytes { Data($0) }
        // An all-zero result means the peer sent a low-order point to force a known secret.
        guard bytes.contains(where: { $0 != 0 }) else { throw Failure.invalidPeerShare }
        return bytes
    }
}
