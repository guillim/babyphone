import Foundation

/// Every delay that shapes how the two phones find, keep and recover their link.
public struct LinkTimings: Sendable {
    /// How often each side tells the other it is alive.
    public var keepaliveInterval: Duration = .seconds(2)
    /// Silence after which the link counts as lost.
    public var silenceTimeout: Duration = .seconds(10)

    /// How long the parent unit looks for the baby unit on the local network.
    public var localDiscovery: Duration = .seconds(3)
    /// How long either side waits for the next signaling message.
    public var signalingStep: Duration = .seconds(8)
    /// How long a connection on the local network may take.
    public var localConnect: Duration = .seconds(10)

    /// How long a connection across the internet may take once both sides have each other's addresses.
    public var remoteConnect: Duration = .seconds(20)
    /// Total time the parent unit spends trying to connect remotely before reporting a failure.
    public var remoteWindow: Duration = .seconds(60)
    /// Pause between two reads of the baby unit's record while the parent unit waits for a fresh offer.
    public var remoteRetryPause: Duration = .seconds(3)
    /// How often the baby unit checks whether a parent unit answered its offer.
    public var rendezvousPoll: Duration = .seconds(5)
    /// How often the baby unit replaces its offer, so its addresses stay current.
    public var offerRefresh: Duration = .seconds(300)
    /// Age after which the parent unit treats an offer as abandoned.
    public var offerLifetime: Duration = .seconds(720)
    /// Pause before the baby unit publishes again after a rendezvous error.
    public var rendezvousErrorPause: Duration = .seconds(30)

    /// Pauses between full connection attempts on the parent unit. The last one repeats.
    public var retryBackoff: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(30)]

    public init() {}

    func retryDelay(afterFailures failures: Int) -> Duration {
        guard !retryBackoff.isEmpty else { return .zero }
        return retryBackoff[min(max(failures, 1), retryBackoff.count) - 1]
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
