import Foundation

/// One line of the night journal.
public struct JournalEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case monitoringStarted
        case monitoringStopped
        /// Noise in the room. `duration` is nil while it is still going on.
        case noise
        case linkLost
        case linkRestored
        /// The baby unit's charger was disconnected.
        case unplugged
        /// The baby unit is running on a low battery.
        case batteryLow
    }

    public var id: UUID
    public var kind: Kind
    /// The phone that observed the event.
    public var origin: DeviceRole
    public var date: Date
    public var duration: TimeInterval?
    /// Position in the origin's sequence of changes. Rises with every insert
    /// and update, so "everything after revision N" is a complete sync request.
    public var revision: Int64

    public init(
        id: UUID = UUID(),
        kind: Kind,
        origin: DeviceRole,
        date: Date,
        duration: TimeInterval? = nil,
        revision: Int64 = 0
    ) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.date = date
        self.duration = duration
        self.revision = revision
    }
}

/// Groups journal events by night: a night runs from noon to noon.
public enum Night {
    /// The calendar day on which the night containing `date` began.
    public static func start(containing date: Date, calendar: Calendar = .current) -> Date {
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        if date >= noon { return noon }
        return calendar.date(byAdding: .day, value: -1, to: noon) ?? noon
    }
}
