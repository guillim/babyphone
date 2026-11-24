import Foundation

/// What a parent wants to be alerted about.
public enum AlertTrigger: String, Codable, Sendable, CaseIterable {
    /// Any sound above the room's background level.
    case anyNoise
    /// Crying only. Other sounds still go to the journal.
    case cryOnly
    /// Nothing about the room. A lost link and a power problem still ring.
    case nothing
}

/// Something the parent unit may alert about.
public enum AlertKind: Sendable, Equatable {
    case noise
    case cry
    /// The baby unit lost its charger, or its battery is low.
    case power
    case linkLost
}

/// One parent's choices about alerts: about what, and whether they are paused.
///
/// A pause only quietens what a parent can decide to let be: noise and crying.
/// A lost link and a baby unit running out of power always ring, because
/// nobody chooses to stop watching by accident.
public struct AlertPolicy: Sendable, Equatable {
    /// Lengths of pause offered to the parent, in minutes.
    public static let snoozeChoices = [10, 30, 60]

    public var trigger: AlertTrigger
    /// End of the current pause, or nil when alerts are not paused.
    public private(set) var snoozedUntil: Date?

    public init(trigger: AlertTrigger = .anyNoise) {
        self.trigger = trigger
    }

    public mutating func snooze(minutes: Int, from now: Date) {
        snoozedUntil = now.addingTimeInterval(TimeInterval(minutes * 60))
    }

    public mutating func resume() {
        snoozedUntil = nil
    }

    public func isSnoozed(at now: Date) -> Bool {
        snoozedUntil.map { now < $0 } ?? false
    }

    /// Whether an alert of this kind is shown to the parent at all.
    ///
    /// "Crying only" is honoured only while the baby unit says it can recognise
    /// crying. Otherwise it would silence every alert.
    public func shows(_ kind: AlertKind, isCryDetectionActive: Bool) -> Bool {
        switch kind {
        case .power, .linkLost: true
        case .cry: trigger != .nothing
        case .noise: trigger == .anyNoise || (trigger == .cryOnly && !isCryDetectionActive)
        }
    }

    /// Whether an alert of this kind makes a sound now.
    public func rings(_ kind: AlertKind, at now: Date, isCryDetectionActive: Bool) -> Bool {
        switch kind {
        case .power, .linkLost: true
        case .noise, .cry: shows(kind, isCryDetectionActive: isCryDetectionActive) && !isSnoozed(at: now)
        }
    }
}
