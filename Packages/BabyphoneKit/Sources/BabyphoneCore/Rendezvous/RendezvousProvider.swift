import Foundation

/// Where a device's record lives in the rendezvous provider.
public struct RendezvousSlot: Sendable, Equatable {
    /// Identifier of the pair, derived from the pairing key.
    public let pairID: String
    /// The device that writes this record.
    public let role: DeviceRole

    public init(pairID: String, role: DeviceRole) {
        self.pairID = pairID
        self.role = role
    }

    /// Stable name of the record.
    public var name: String { "\(pairID).\(role.rawValue)" }
}

public enum RendezvousAvailability: Sendable, Equatable {
    /// This device can publish its record and read the peer's.
    case available
    /// No account is signed in on this phone, so it cannot publish.
    case noAccount
    /// The provider cannot be used right now, for another reason.
    case unavailable
}

/// The one service that lets two phones on different networks find each other.
///
/// It does exactly two things: publish this device's record and read the
/// peer's. Records are opaque and already encrypted when they reach a
/// provider. CloudKit is the provider today. Another one, such as a DHT, only
/// has to implement this protocol.
public protocol RendezvousProvider: Sendable {
    func availability() async -> RendezvousAvailability
    /// Writes, or replaces, this device's record.
    func publish(_ record: Data, to slot: RendezvousSlot) async throws
    /// Reads a record. Returns nil when the slot is empty.
    func fetch(_ slot: RendezvousSlot) async throws -> Data?
}
