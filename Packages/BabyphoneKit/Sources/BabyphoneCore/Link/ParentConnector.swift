import Foundation

/// Parent-side connection loop: finds the baby unit, connects, and reconnects for as long as it runs.
///
/// Each round tries the local network first, then the rendezvous provider.
/// There is no relay, so a round can end with no connection at all.
///
/// The local network is looked at again whenever the connector waits: while no
/// offer is published, and between two rounds. A baby unit that starts
/// monitoring a moment after this phone is then found there within seconds,
/// instead of through the rendezvous provider's slower exchange.
public actor ParentConnector {
    public enum State: Sendable, Equatable {
        case idle
        case searching
        case connecting(LinkRoute)
        case connected(LinkRoute)
        case unreachable(UnreachableReason)
    }

    public enum UnreachableReason: Sendable, Equatable {
        /// The baby unit is not on this network and published no offer: it is off, or not monitoring.
        case babyOffline
        /// Both phones know each other's addresses, but no packet gets through.
        case noDirectPath
        /// The baby unit is not on this network and this phone cannot use the rendezvous provider.
        case rendezvousUnavailable
    }

    public nonisolated let states: AsyncStream<State>
    /// Messages received from the baby unit.
    public nonisolated let payloads: AsyncStream<Data>

    private let stateContinuation: AsyncStream<State>.Continuation
    private let payloadContinuation: AsyncStream<Data>.Continuation
    private let makeSession: PeerSessionFactory
    private let local: any LocalSignalingConnecting
    private let rendezvous: RendezvousClient?
    private let timings: LinkTimings

    private var state = State.idle
    private var loop: Task<Void, Never>?
    private var link: PeerLink?
    private var lastAnsweredOffer: UUID?
    private var retryRequested = false

    public init(
        makeSession: @escaping PeerSessionFactory,
        local: any LocalSignalingConnecting,
        rendezvous: RendezvousClient?,
        timings: LinkTimings = LinkTimings()
    ) {
        self.makeSession = makeSession
        self.local = local
        self.rendezvous = rendezvous
        self.timings = timings
        (states, stateContinuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(8))
        (payloads, payloadContinuation) = AsyncStream.makeStream(of: Data.self)
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
    }

    public func stop() async {
        loop?.cancel()
        loop = nil
        await link?.close()
        link = nil
        set(.idle)
    }

    /// Skips the pause before the next attempt.
    public func retryNow() {
        retryRequested = true
    }

    public func send(_ payload: Data) async {
        await link?.send(payload)
    }

    /// Drops the current link and connects again from scratch. For a link that
    /// still answers but no longer carries the stream, and for a manual retry.
    public func reconnect() async {
        LinkLog.note("parent unit: reconnection requested")
        retryRequested = true
        await link?.close()
    }

    private func run() async {
        var failures = 0
        var foundWhilePausing: PeerLink?
        while !Task.isCancelled {
            let outcome: Outcome
            if let link = foundWhilePausing {
                foundWhilePausing = nil
                outcome = .connected(link)
            } else {
                set(.searching)
                outcome = await connect()
            }
            guard !Task.isCancelled else {
                if case .connected(let link) = outcome { await link.close() }
                return
            }
            switch outcome {
            case .connected(let link):
                failures = 0
                self.link = link
                set(.connected(link.route))
                for await payload in link.payloads {
                    payloadContinuation.yield(payload)
                }
                _ = await link.waitUntilEnded()
                self.link = nil
            case .unreachable(let reason):
                failures += 1
                set(.unreachable(reason))
                foundWhilePausing = await pauseBeforeRetry(timings.retryDelay(afterFailures: failures))
            }
        }
    }

    private enum Outcome {
        case connected(PeerLink)
        case unreachable(UnreachableReason)
    }

    private func connect() async -> Outcome {
        if let link = await connectLocally() {
            return .connected(link)
        }
        guard !Task.isCancelled else { return .unreachable(.babyOffline) }
        return await connectRemotely()
    }

    private func connectLocally() async -> PeerLink? {
        guard let channel = try? await local.connect(timeout: timings.localDiscovery) else { return nil }
        defer { channel.close() }
        set(.connecting(.local))
        guard let session = try? makeSession() else { return nil }
        let link = PeerLink(session: session, route: .local, timings: timings)
        do {
            guard case .offer(let offer) = try await channel.receive(SignalingMessage.self, timeout: timings.signalingStep) else {
                await link.close()
                return nil
            }
            let answer = try await session.makeAnswer(to: offer)
            try await channel.send(SignalingMessage.answer(answer))
        } catch {
            await link.close()
            return nil
        }
        guard await link.waitUntilConnected(timeout: timings.localConnect) else {
            await link.close()
            return nil
        }
        return link
    }

    private func connectRemotely() async -> Outcome {
        guard let rendezvous, await rendezvous.availability() == .available else {
            return .unreachable(.rendezvousUnavailable)
        }
        var reason = UnreachableReason.babyOffline
        let deadline = ContinuousClock.now + timings.remoteWindow
        while ContinuousClock.now < deadline, !Task.isCancelled {
            guard let offer = await freshOffer(from: rendezvous) else {
                // No offer yet, or one already answered: the baby unit publishes a new one shortly.
                // It may also be starting on this network, where it is found much sooner.
                if let link = await searchLocally(atLeast: timings.remoteRetryPause) {
                    return .connected(link)
                }
                continue
            }
            lastAnsweredOffer = offer.id
            reason = .noDirectPath
            set(.connecting(.remote))
            if let link = await answer(offer, through: rendezvous) {
                return .connected(link)
            }
        }
        return .unreachable(reason)
    }

    private func freshOffer(from rendezvous: RendezvousClient) async -> (id: UUID, description: String)? {
        guard
            let advertisement = try? await rendezvous.fetchPeer(),
            let description = advertisement.description,
            advertisement.sessionID != lastAnsweredOffer,
            Date().timeIntervalSince(advertisement.publishedAt) < timings.offerLifetime.timeInterval
        else { return nil }
        return (advertisement.sessionID, description)
    }

    private func answer(_ offer: (id: UUID, description: String), through rendezvous: RendezvousClient) async -> PeerLink? {
        guard let session = try? makeSession() else { return nil }
        let link = PeerLink(session: session, route: .remote, timings: timings)
        do {
            let answer = try await session.makeAnswer(to: offer.description)
            try await rendezvous.publish(EndpointAdvertisement(inReplyTo: offer.id, description: answer))
        } catch {
            await link.close()
            return nil
        }
        // From here both phones send to each other at the same time, which opens the firewalls on each side.
        guard await link.waitUntilConnected(timeout: timings.remoteConnect) else {
            await link.close()
            return nil
        }
        return link
    }

    /// Waits before the next round, and returns the link if the baby unit turned up on the local network meanwhile.
    private func pauseBeforeRetry(_ delay: Duration) async -> PeerLink? {
        retryRequested = false
        let deadline = ContinuousClock.now + delay
        while ContinuousClock.now < deadline, !retryRequested, !Task.isCancelled {
            if let link = await searchLocally(atLeast: .milliseconds(200)) {
                return link
            }
        }
        return nil
    }

    /// One look for the baby unit on the local network, taking at least `minimum`:
    /// a search that fails at once, without the local network permission for example, must not spin.
    private func searchLocally(atLeast minimum: Duration) async -> PeerLink? {
        let started = ContinuousClock.now
        if let link = await connectLocally() {
            return link
        }
        let elapsed = ContinuousClock.now - started
        if elapsed < minimum, !Task.isCancelled {
            try? await Task.sleep(for: minimum - elapsed)
        }
        return nil
    }

    private func set(_ newState: State) {
        guard newState != state else { return }
        LinkLog.note("parent unit: \(newState)")
        state = newState
        stateContinuation.yield(newState)
    }
}
