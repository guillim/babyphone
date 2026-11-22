import Foundation

/// Decides when the baby is crying, from a sound classifier's confidence over time.
///
/// The classifier gives a number between 0 and 1 a few times a second. One
/// confident reading is not a cry, and one doubtful reading is not its end: a
/// cry starts once the confidence has held for a moment, and ends after a
/// longer quiet spell, so sobs and breaths stay in the same event.
public struct CryDetector: Sendable {
    public enum Event: Sendable, Equatable {
        case started(at: Date)
        case ended(startedAt: Date, duration: TimeInterval)
    }

    /// Confidence from which a reading counts towards the start of a cry.
    public static let startConfidence = 0.6
    /// Confidence under which a reading counts as quiet.
    public static let stopConfidence = 0.3
    /// How long the confidence must hold before a cry starts.
    public static let startDelay: TimeInterval = 1
    /// How long the quiet must last before a cry ends.
    public static let stopDelay: TimeInterval = 8

    private var firstConfidentAt: Date?
    private var startedAt: Date?
    private var lastHeardAt: Date?

    public init() {}

    public var isCrying: Bool { startedAt != nil }

    public mutating func ingest(confidence: Double, at now: Date) -> Event? {
        if let startedAt {
            if confidence >= Self.stopConfidence {
                lastHeardAt = now
            } else if let lastHeardAt, now.timeIntervalSince(lastHeardAt) >= Self.stopDelay {
                return end(startedAt: startedAt, lastHeardAt: lastHeardAt)
            }
            return nil
        }
        guard confidence >= Self.startConfidence else {
            firstConfidentAt = nil
            return nil
        }
        guard let firstConfidentAt else {
            self.firstConfidentAt = now
            return nil
        }
        guard now.timeIntervalSince(firstConfidentAt) >= Self.startDelay else { return nil }
        startedAt = firstConfidentAt
        lastHeardAt = now
        self.firstConfidentAt = nil
        return .started(at: firstConfidentAt)
    }

    /// Closes the cry in progress, if any. Call when monitoring stops.
    public mutating func finish() -> Event? {
        guard let startedAt, let lastHeardAt else { return nil }
        return end(startedAt: startedAt, lastHeardAt: lastHeardAt)
    }

    private mutating func end(startedAt: Date, lastHeardAt: Date) -> Event {
        self.startedAt = nil
        self.lastHeardAt = nil
        firstConfidentAt = nil
        return .ended(startedAt: startedAt, duration: lastHeardAt.timeIntervalSince(startedAt))
    }
}
