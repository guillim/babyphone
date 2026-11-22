import Foundation

/// What the baby unit leaves in the rendezvous provider for a parent unit that
/// cannot reach it directly: whether it is monitoring, how it is doing, and what
/// happened recently.
///
/// It is a fallback, not a link. It travels through a third party that promises
/// no delay and no delivery, so the parent unit shows it as such.
public struct AlertDigest: Codable, Sendable, Equatable {
    /// How many recent journal events a digest carries.
    public static let eventLimit = 12
    /// Events older than this are history, not news.
    public static let eventWindow: TimeInterval = 3600

    /// Identifies one monitoring session of the baby unit.
    public var sessionID: UUID
    /// Rises with every digest of a session, so a reader can tell a new one from one it has seen.
    public var sequence: Int
    public var publishedAt: Date
    /// False once monitoring was stopped on purpose.
    public var isMonitoring: Bool
    public var status: MonitorStatus?
    /// The most recent journal events of the baby unit, oldest first.
    public var events: [JournalEvent]

    public init(
        sessionID: UUID,
        sequence: Int,
        publishedAt: Date = Date(),
        isMonitoring: Bool,
        status: MonitorStatus? = nil,
        events: [JournalEvent] = []
    ) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.publishedAt = publishedAt
        self.isMonitoring = isMonitoring
        self.status = status
        self.events = events
    }
}
