import Foundation

/// Turns a stream of sound levels into noise episodes.
///
/// The detector calibrates itself to the room: it tracks the steady background
/// level and alerts on sounds that rise a set margin above it. A fan or a
/// white-noise machine therefore raises the bar instead of ringing all night.
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
    /// The background estimate follows a room that gets quieter within seconds…
    static let ambientFallTime: TimeInterval = 3
    /// …and one that gets louder only over minutes, so crying is not mistaken for background.
    static let ambientRiseTime: TimeInterval = 90
    /// The threshold never leaves this range, whatever the room sounds like.
    static let thresholdRange = -55.0 ... -12.0

    public var sensitivity: Sensitivity
    /// The room's steady background level in dBFS, or nil before the first measurement.
    public private(set) var ambientDecibels: Double?
    private var lastMeasurement: Date?
    private var loudSince: Date?
    private var episode: (startedAt: Date, lastLoudAt: Date)?

    public init(sensitivity: Sensitivity) {
        self.sensitivity = sensitivity
    }

    public var isNoiseActive: Bool { episode != nil }

    /// Level, in dBFS, at or above which a sound counts as noise right now.
    public var thresholdDecibels: Double {
        let threshold = (ambientDecibels ?? SoundLevel.floorDecibels) + sensitivity.marginDecibels
        return min(max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
    }

    /// Feeds one measurement.
    ///
    /// - Parameter isMasked: true while the phone plays a changing sound itself
    ///   (lullaby, talk-back), which must neither count as noise nor as background.
    public mutating func ingest(decibels: Double, at time: Date, isMasked: Bool = false) -> Output {
        if !isMasked {
            calibrate(with: decibels, at: time)
        }
        lastMeasurement = time
        let threshold = thresholdDecibels

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

    /// Forgets the background level, so the next measurements set it afresh.
    /// Call when the phone itself starts or stops a steady sound, such as white noise.
    public mutating func recalibrate() {
        ambientDecibels = nil
    }

    private mutating func calibrate(with decibels: Double, at time: Date) {
        guard let ambient = ambientDecibels, let last = lastMeasurement else {
            ambientDecibels = decibels
            return
        }
        let elapsed = max(0, time.timeIntervalSince(last))
        let timeConstant = decibels < ambient ? Self.ambientFallTime : Self.ambientRiseTime
        ambientDecibels = ambient + (decibels - ambient) * (1 - exp(-elapsed / timeConstant))
    }
}
