import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The 256-bit secret two phones share once paired.
///
/// It never leaves the two devices. Everything that travels outside the
/// phones is protected by a key derived from it, one key per purpose, so a
/// leak in one use does not expose the others.
public struct PairingKey: Sendable, Equatable {
    public static let byteCount = 32

    public let rawValue: Data

    public init?(rawValue: Data) {
        guard rawValue.count == Self.byteCount else { return nil }
        self.rawValue = rawValue
    }

    public static func random() -> PairingKey {
        PairingKey(symmetricKey: SymmetricKey(size: .bits256))
    }

    init(symmetricKey: SymmetricKey) {
        rawValue = symmetricKey.withUnsafeBytes { Data($0) }
    }

    /// Identifier of the pair in the rendezvous provider. Public, reveals nothing about the key.
    public var rendezvousID: String {
        derive("rendezvous-id", byteCount: 16).hexString
    }

    /// Short tag advertised over Bonjour so a parent unit finds its own baby unit.
    public var localNetworkTag: String {
        derive("local-network-tag", byteCount: 8).hexString
    }

    /// Pre-shared key for the TLS channel that carries signaling on the local network.
    public var localTransportKey: Data {
        derive("local-transport", byteCount: 32)
    }

    /// Key that encrypts the records written to the rendezvous provider.
    var sealingKey: SymmetricKey {
        SymmetricKey(data: derive("rendezvous-seal", byteCount: 32))
    }

    private func derive(_ purpose: String, byteCount: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: rawValue),
            salt: Data("nid/v1".utf8),
            info: Data(purpose.utf8),
            outputByteCount: byteCount
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

extension Data {
    var hexString: String {
        map { byte in
            let digits = String(byte, radix: 16)
            return byte < 16 ? "0" + digits : digits
        }.joined()
    }
}
