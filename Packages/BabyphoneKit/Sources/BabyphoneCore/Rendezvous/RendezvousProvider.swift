import Foundation

/// Where a device's record lives in the rendezvous provider.
public struct RendezvousSlot: Sendable, Equatable {
    /// What a record is for. Each device has one record of each kind.
    public enum Content: String, Sendable {
        /// Where the device is and how to connect to it.
        case endpoint
        /// The baby unit's latest alerts, for a parent unit that has no direct link.
        case alerts
    }

    /// Identifier of the pair, derived from the pairing key.
    public let pairID: String
    /// The device that writes this record.
    public let role: DeviceRole
    public let content: Content

    public init(pairID: String, role: DeviceRole, content: Content = .endpoint) {
        self.pairID = pairID
        self.role = role
        self.content = content
    }

    /// Stable name of the record.
    public var name: String {
        switch content {
        case .endpoint: "\(pairID).\(role.rawValue)"
        case .alerts: "\(pairID).\(role.rawValue).alerts"
        }
    }
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
/// It does exactly two things: publish this device's records and read the
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
