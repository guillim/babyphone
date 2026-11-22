import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// What a device publishes so its peer can reach it: where it is and how to connect to it.
public struct EndpointAdvertisement: Codable, Sendable, Equatable {
    /// Identifies one offer. A baby unit publishes a new identifier with every offer.
    public var sessionID: UUID
    /// On an answer, the offer it replies to.
    public var inReplyTo: UUID?
    /// Session description listing the device's current addresses. Nil when the
    /// device is not accepting a connection right now.
    public var description: String?
    public var publishedAt: Date

    public init(sessionID: UUID = UUID(), inReplyTo: UUID? = nil, description: String?, publishedAt: Date = Date()) {
        self.sessionID = sessionID
        self.inReplyTo = inReplyTo
        self.description = description
        self.publishedAt = publishedAt
    }
}

/// Encrypts advertisements with the pairing key and exchanges them through a provider.
///
/// The provider only ever sees ciphertext stored under an identifier that
/// reveals nothing about the pair.
public struct RendezvousClient: Sendable {
    private let provider: any RendezvousProvider
    private let key: PairingKey
    private let role: DeviceRole

    public init(provider: any RendezvousProvider, key: PairingKey, role: DeviceRole) {
        self.provider = provider
        self.key = key
        self.role = role
    }

    public func availability() async -> RendezvousAvailability {
        await provider.availability()
    }

    public func publish(_ advertisement: EndpointAdvertisement) async throws {
        let slot = RendezvousSlot(pairID: key.rendezvousID, role: role)
        let plaintext = try WireCoding.encode(advertisement)
        // The slot name is authenticated, so a record cannot be replayed into the other role's slot.
        let sealed = try ChaChaPoly.seal(plaintext, using: key.sealingKey, authenticating: Data(slot.name.utf8))
        try await provider.publish(sealed.combined, to: slot)
    }

    /// Reads the peer's advertisement. Returns nil when there is none, or when it cannot be decrypted.
    public func fetchPeer() async throws -> EndpointAdvertisement? {
        let slot = RendezvousSlot(pairID: key.rendezvousID, role: role.peer)
        guard let record = try await provider.fetch(slot) else { return nil }
        guard
            let box = try? ChaChaPoly.SealedBox(combined: record),
            let plaintext = try? ChaChaPoly.open(box, using: key.sealingKey, authenticating: Data(slot.name.utf8))
        else { return nil }
        return try? WireCoding.decode(EndpointAdvertisement.self, from: plaintext)
    }
}
