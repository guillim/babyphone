import Foundation

/// Turns a stream of sound levels into noise episodes.
///
/// A sound must stay above the threshold for a short while before it counts,
/// so a single knock does not raise an alert. An episode ends once the room
/// has been quiet again for a few seconds, so a baby catching its breath does
/// not produce a string of separate alerts.
public struct NoiseDetector: Sendable {
    public enum Output: Sendable, Equatable {
        case none
        case started(at: Date)
        case ended(startedAt: Date, duration: TimeInterval)
    }

    /// How long a sound must last before it counts as noise.
    static let attack: TimeInterval = 0.4
    /// How long the room must stay quiet before an episode ends.
    static let release: TimeInterval = 4
    /// Margin below the threshold that still sustains an episode in progress.
    static let hysteresisDecibels = 5.0

    public var sensitivity: Sensitivity
    private var loudSince: Date?
    private var episode: (startedAt: Date, lastLoudAt: Date)?

    public init(sensitivity: Sensitivity) {
        self.sensitivity = sensitivity
    }

    public var isNoiseActive: Bool { episode != nil }

    /// Feeds one measurement.
    ///
    /// - Parameter isMasked: true while the phone plays sound itself (lullaby,
    ///   talk-back), which must not count as noise from the room.
    public mutating func ingest(decibels: Double, at time: Date, isMasked: Bool = false) -> Output {
        let threshold = sensitivity.thresholdDecibels

        if var current = episode {
            if !isMasked, decibels >= threshold - Self.hysteresisDecibels {
                current.lastLoudAt = time
                episode = current
                return .none
            }
            guard time.timeIntervalSince(current.lastLoudAt) >= Self.release else { return .none }
            return finish()
        }

        guard !isMasked, decibels >= threshold else {
            loudSince = nil
            return .none
        }
        let start = loudSince ?? time
        loudSince = start
        guard time.timeIntervalSince(start) >= Self.attack else { return .none }
        loudSince = nil
        episode = (startedAt: start, lastLoudAt: time)
        return .started(at: start)
    }

    /// Closes the episode in progress, if any. Call when monitoring stops.
    public mutating func finish() -> Output {
        guard let current = episode else { return .none }
        episode = nil
        loudSince = nil
        let duration = max(Self.attack, current.lastLoudAt.timeIntervalSince(current.startedAt))
        return .ended(startedAt: current.startedAt, duration: duration)
    }
}
