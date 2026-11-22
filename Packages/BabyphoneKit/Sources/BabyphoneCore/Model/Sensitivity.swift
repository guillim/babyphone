import Foundation

/// Noise alert sensitivity. A higher sensitivity alerts on quieter sounds.
public enum Sensitivity: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high

    /// Sound level, in dBFS, at or above which a sound counts as noise.
    ///
    /// These values are a starting point and need calibrating on real devices:
    /// a quiet room sits near -55 dBFS, speech at one metre near -30 dBFS.
    public var thresholdDecibels: Double {
        switch self {
        case .low: -25
        case .medium: -35
        case .high: -45
        }
    }
}
