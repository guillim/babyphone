import Foundation

/// Which side of the monitor a phone plays.
public enum DeviceRole: String, Codable, Sendable, CaseIterable {
    /// Stays in the baby's room: camera, microphone, database, hub.
    case baby
    /// Stays with the parent: shows the stream and raises alerts.
    case parent

    public var peer: DeviceRole {
        switch self {
        case .baby: .parent
        case .parent: .baby
        }
    }
}

/// How the two phones reached each other.
public enum LinkRoute: String, Codable, Sendable {
    /// Same network, found through Bonjour.
    case local
    /// Different networks, found through the rendezvous provider.
    case remote
}
