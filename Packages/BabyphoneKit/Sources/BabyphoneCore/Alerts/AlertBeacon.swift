import Foundation

/// Baby side of the alerts-only fallback: keeps the baby unit's latest digest published.
///
/// Writes go out one at a time. While one is in flight, only the newest
/// content waits behind it: a digest replaces the previous one, so there is
/// nothing to gain from sending the ones in between.
public actor AlertBeacon {
    private let rendezvous: RendezvousClient
    private let sessionID = UUID()
    private var sequence = 0
    private var pending: AlertDigest?
    private var isWriting = false

    public init(rendezvous: RendezvousClient) {
        self.rendezvous = rendezvous
    }

    /// Publishes the baby unit's state and recent events. Returns at once: the write happens behind.
    public func publish(isMonitoring: Bool, status: MonitorStatus?, events: [JournalEvent], now: Date = Date()) {
        sequence += 1
        let recent = events
            .filter { now.timeIntervalSince($0.date) < AlertDigest.eventWindow }
            .sorted { $0.date < $1.date }
            .suffix(AlertDigest.eventLimit)
        pending = AlertDigest(
            sessionID: sessionID, sequence: sequence, publishedAt: now,
            isMonitoring: isMonitoring, status: status, events: Array(recent)
        )
        guard !isWriting else { return }
        isWriting = true
        Task { await self.drain() }
    }

    /// Waits until everything handed to `publish` has been written, or has failed.
    public func flush() async {
        while isWriting {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func drain() async {
        while let digest = pending {
            pending = nil
            // A failed write is not retried: the next digest is at most a minute away.
            try? await rendezvous.publish(digest)
        }
        isWriting = false
    }
}
