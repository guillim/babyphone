import Foundation

/// Session descriptions exchanged to set up the direct media connection.
///
/// Each description already lists every address of its sender, so one
/// message each way is enough.
public enum SignalingMessage: Codable, Sendable, Equatable {
    case offer(String)
    case answer(String)
}

/// What the baby unit sends to the parent unit over the live link.
public enum BabyMessage: Codable, Sendable, Equatable {
    case status(MonitorStatus)
    /// New or updated journal events, to insert or replace by identifier.
    case journal([JournalEvent])
    /// Monitoring is being stopped on purpose: the silence that follows is not a lost link.
    case stopping
}

/// What the parent unit sends to the baby unit over the live link.
public enum ParentMessage: Codable, Sendable, Equatable {
    /// Sent once connected. The baby unit answers with every journal event after this revision.
    case hello(lastJournalRevision: Int64)
    case setNightLight(Bool)
    case setLullaby(Bool)
    /// Plays white noise for this many minutes, or stops it when nil.
    case setWhiteNoise(minutes: Int?)
    case setLowLight(Bool)
    case setVideoEnabled(Bool)
    case setSensitivity(Sensitivity)
    /// The parent is holding the talk button.
    case talking(Bool)
}
