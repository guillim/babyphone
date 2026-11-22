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
        try await publish(advertisement, as: .endpoint)
    }

    /// Reads the peer's advertisement. Returns nil when there is none, or when it cannot be decrypted.
    public func fetchPeer() async throws -> EndpointAdvertisement? {
        try await fetchPeer(EndpointAdvertisement.self, from: .endpoint)
    }

    /// Publishes this device's latest alerts, for a peer that has no direct link to it.
    public func publish(_ digest: AlertDigest) async throws {
        try await publish(digest, as: .alerts)
    }

    /// Reads the peer's latest alerts. Returns nil when there are none, or when they cannot be decrypted.
    public func fetchPeerAlerts() async throws -> AlertDigest? {
        try await fetchPeer(AlertDigest.self, from: .alerts)
    }

    private func publish(_ value: some Encodable, as content: RendezvousSlot.Content) async throws {
        let slot = RendezvousSlot(pairID: key.rendezvousID, role: role, content: content)
        let plaintext = try WireCoding.encode(value)
        // The slot name is authenticated, so a record cannot be replayed into another slot.
        let sealed = try ChaChaPoly.seal(plaintext, using: key.sealingKey, authenticating: Data(slot.name.utf8))
        try await provider.publish(sealed.combined, to: slot)
    }

    private func fetchPeer<Value: Decodable>(_ type: Value.Type, from content: RendezvousSlot.Content) async throws -> Value? {
        let slot = RendezvousSlot(pairID: key.rendezvousID, role: role.peer, content: content)
        guard let record = try await provider.fetch(slot) else { return nil }
        guard
            let box = try? ChaChaPoly.SealedBox(combined: record),
            let plaintext = try? ChaChaPoly.open(box, using: key.sealingKey, authenticating: Data(slot.name.utf8))
        else { return nil }
        return try? WireCoding.decode(type, from: plaintext)
    }
}
