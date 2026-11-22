import Foundation

/// Parent side of the alerts-only fallback: reads the baby unit's digest at a
/// steady pace while no direct link exists, and reports each new one.
public actor AlertWatch {
    /// What the watch knows about the fallback right now.
    public enum State: Sendable, Equatable {
        /// Not watching: a direct link exists, or monitoring is off.
        case off
        /// Watching, and nothing was read yet.
        case waiting
        /// The baby unit's digest can be read. How fresh it is, the digest itself says.
        case receiving
        /// The provider cannot be read, or the baby unit never published.
        case unavailable
    }

    public nonisolated let states: AsyncStream<State>
    /// Each digest that differs from the one before.
    public nonisolated let digests: AsyncStream<AlertDigest>

    private let stateContinuation: AsyncStream<State>.Continuation
    private let digestContinuation: AsyncStream<AlertDigest>.Continuation
    private let rendezvous: RendezvousClient
    private let interval: Duration
    private var state = State.off
    private var polling: Task<Void, Never>?
    private var lastSeen: (sessionID: UUID, sequence: Int)?

    public init(rendezvous: RendezvousClient, interval: Duration = .seconds(20)) {
        self.rendezvous = rendezvous
        self.interval = interval
        (states, stateContinuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(4))
        (digests, digestContinuation) = AsyncStream.makeStream(of: AlertDigest.self, bufferingPolicy: .bufferingNewest(4))
    }

    public func start() {
        guard polling == nil else { return }
        set(.waiting)
        polling = Task { [weak self] in
            repeat {
                await self?.poll()
            } while (try? await Task.sleep(for: self?.interval ?? .seconds(20))) != nil
        }
    }

    public func stop() {
        polling?.cancel()
        polling = nil
        set(.off)
    }

    private func poll() async {
        let digest = try? await rendezvous.fetchPeerAlerts()
        // Stopped while the read was in flight: its result no longer matters.
        guard polling != nil else { return }
        guard let digest else {
            // One failed read does not undo what was received before.
            if state != .receiving { set(.unavailable) }
            return
        }
        set(.receiving)
        if let lastSeen, lastSeen == (digest.sessionID, digest.sequence) { return }
        lastSeen = (digest.sessionID, digest.sequence)
        digestContinuation.yield(digest)
    }

    private func set(_ newState: State) {
        guard newState != state else { return }
        state = newState
        stateContinuation.yield(newState)
    }
}
