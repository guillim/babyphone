import Foundation

/// Watches the baby unit's power and reports what a parent must know:
/// the charger came out, or the battery is running low.
public struct PowerWatch: Sendable {
    public enum Event: Sendable, Equatable {
        case unplugged
        case batteryLow
    }

    /// Battery level under which an unplugged phone is reported as low.
    static let lowLevel = 0.2
    /// Level the battery must climb back to before a new low-battery report.
    static let recoveredLevel = 0.25

    private var wasCharging: Bool?
    private var hasReportedLow = false

    public init() {}

    /// Feeds the current power state. Each event is reported once per occurrence.
    public mutating func ingest(batteryLevel: Double?, isCharging: Bool) -> [Event] {
        var events: [Event] = []
        if wasCharging == true, !isCharging {
            events.append(.unplugged)
        }
        wasCharging = isCharging

        if let batteryLevel {
            if isCharging || batteryLevel >= Self.recoveredLevel {
                hasReportedLow = false
            } else if batteryLevel < Self.lowLevel, !hasReportedLow {
                hasReportedLow = true
                events.append(.batteryLow)
            }
        }
        return events
    }
}
