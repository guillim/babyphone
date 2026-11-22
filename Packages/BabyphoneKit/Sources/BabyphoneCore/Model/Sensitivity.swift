import Foundation

/// Noise alert sensitivity. A higher sensitivity alerts on quieter sounds.
public enum Sensitivity: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high

    /// How far above the room's steady background level a sound must rise to count as noise.
    ///
    /// These values are a starting point and need tuning on real devices.
    public var marginDecibels: Double {
        switch self {
        case .low: 24
        case .medium: 15
        case .high: 8
        }
    }
}
