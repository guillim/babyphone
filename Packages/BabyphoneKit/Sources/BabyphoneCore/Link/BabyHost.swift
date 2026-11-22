import Foundation

/// Baby-side hub: accepts the parent unit on the local network and through the rendezvous provider.
///
/// One parent unit is supported. A new connection from it replaces the previous one,
/// which is how the parent unit recovers after changing network.
public actor BabyHost {
    public enum State: Sendable, Equatable {
        case stopped
        /// Monitoring, no parent unit connected.
        case waiting
        case connected(LinkRoute)
    }

    /// Whether a parent unit outside the local network can reach this phone.
    public enum RemoteAccess: Sendable, Equatable {
        /// No rendezvous provider is configured.
        case disabled
        /// No account is signed in, so this phone cannot publish its addresses.
        case noAccount
        /// The provider cannot be reached right now. Retried automatically.
        case unavailable
        /// The current addresses are published.
        case ready
    }

    public nonisolated let states: AsyncStream<State>
    public nonisolated let remoteAccessChanges: AsyncStream<RemoteAccess>
    /// Messages received from the parent unit.
    public nonisolated let payloads: AsyncStream<Data>

    private let stateContinuation: AsyncStream<State>.Continuation
    private let remoteAccessContinuation: AsyncStream<RemoteAccess>.Continuation
    private let payloadContinuation: AsyncStream<Data>.Continuation
    private let makeSession: PeerSessionFactory
    private let listener: any LocalSignalingListening
    private let rendezvous: RendezvousClient?
    private let portMapper: (any PortMapper)?
    private let timings: LinkTimings

    private var state = State.stopped
    private var remoteAccess = RemoteAccess.disabled
    private var tasks: [Task<Void, Never>] = []
    private var link: PeerLink?
    private var addressesChanged = false
    /// The router port opened for each link that has one, by link.
    private var routerPorts: [ObjectIdentifier: PortMapping] = [:]

    public init(
        makeSession: @escaping PeerSessionFactory,
        listener: any LocalSignalingListening,
        rendezvous: RendezvousClient?,
        portMapper: (any PortMapper)? = nil,
        timings: LinkTimings = LinkTimings()
    ) {
        self.makeSession = makeSession
        self.listener = listener
        self.rendezvous = rendezvous
        self.portMapper = portMapper
        self.timings = timings
        (states, stateContinuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(8))
        (remoteAccessChanges, remoteAccessContinuation) = AsyncStream.makeStream(
            of: RemoteAccess.self, bufferingPolicy: .bufferingNewest(1)
        )
        (payloads, payloadContinuation) = AsyncStream.makeStream(of: Data.self)
    }

    public func start() {
        guard state == .stopped else { return }
        set(.waiting)
        tasks = [
            Task { await acceptLocalConnections() },
            Task { await offerRemoteConnections() },
        ]
    }

    public func stop() async {
        guard state != .stopped else { return }
        tasks.forEach { $0.cancel() }
        tasks = []
        await listener.stop()
        await link?.close()
        link = nil
        set(.stopped)
        for link in Array(routerPorts.keys) {
            await closeRouterPort(of: link)
        }
        // Tells a parent unit away from home that nobody is monitoring any more.
        try? await rendezvous?.publish(EndpointAdvertisement(description: nil))
    }

    public func send(_ payload: Data) async {
        await link?.send(payload)
    }

    /// Call when this phone's network changes, so the published addresses are replaced.
    public func networkDidChange() {
        addressesChanged = true
    }

    // MARK: Local network

    private func acceptLocalConnections() async {
        guard let channels = try? await listener.start() else { return }
        for await channel in channels {
            Task { await self.serveLocally(channel) }
        }
    }

    private func serveLocally(_ channel: any FrameChannel) async {
        defer { channel.close() }
        LinkLog.note("baby unit: a parent unit asks to connect on the local network")
        guard state != .stopped, let session = try? makeSession() else { return }
        let link = PeerLink(session: session, route: .local, timings: timings)
        do {
            try await channel.send(SignalingMessage.offer(try await session.makeOffer()))
            guard case .answer(let answer) = try await channel.receive(SignalingMessage.self, timeout: timings.signalingStep) else {
                await link.close()
                return
            }
            try await session.accept(answer: answer)
        } catch {
            await link.close()
            return
        }
        guard await link.waitUntilConnected(timeout: timings.localConnect) else {
            await link.close()
            return
        }
        await adopt(link)
    }

    // MARK: Remote

    private func offerRemoteConnections() async {
        guard let rendezvous else { return }
        while !Task.isCancelled {
            guard link == nil else {
                try? await Task.sleep(for: timings.rendezvousPoll)
                continue
            }
            switch await rendezvous.availability() {
            case .available:
                break
            case .noAccount:
                set(.noAccount)
                try? await Task.sleep(for: timings.rendezvousErrorPause)
                continue
            case .unavailable:
                set(.unavailable)
                try? await Task.sleep(for: timings.rendezvousErrorPause)
                continue
            }
            do {
                try await offerOnce(through: rendezvous)
            } catch {
                set(.unavailable)
                try? await Task.sleep(for: timings.rendezvousErrorPause)
            }
        }
    }

    /// Publishes one offer and waits for the parent unit to answer it, or for the offer to go stale.
    ///
    /// Every write to the rendezvous provider while monitoring happens here, one after
    /// the other, so a late write can never overwrite a newer one.
    private func offerOnce(through rendezvous: RendezvousClient) async throws {
        let session = try makeSession()
        let link = PeerLink(session: session, route: .remote, timings: timings)
        let offerID = UUID()
        do {
            var offer = try await session.makeOffer()
            // On an IPv4 line the router can forward a port to this session: one more address to offer.
            if let port = await openRouterPort(for: offer), state != .stopped {
                routerPorts[ObjectIdentifier(link)] = port
                offer = SessionDescriptionInspector.adding(port, to: offer)
            }
            try await rendezvous.publish(EndpointAdvertisement(sessionID: offerID, description: offer))
        } catch {
            await discard(link)
            throw error
        }
        set(.ready)
        addressesChanged = false

        if await waitForAnswer(to: offerID, on: session, link: link, through: rendezvous) {
            await adopt(link)
        } else {
            await discard(link)
        }
        // A parent unit is connected, so the offer is spent: say so rather than let it be tried again.
        // An offer that merely went stale is replaced by the next one, with no write in between.
        if self.link != nil, !Task.isCancelled {
            try? await rendezvous.publish(EndpointAdvertisement(description: nil))
        }
    }

    /// Returns true once the parent unit answered the offer and the direct connection is up.
    private func waitForAnswer(
        to offerID: UUID,
        on session: any PeerSession,
        link: PeerLink,
        through rendezvous: RendezvousClient
    ) async -> Bool {
        let publishedAt = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: timings.rendezvousPoll)
            let isStale = addressesChanged || ContinuousClock.now - publishedAt > timings.offerRefresh
            guard !Task.isCancelled, self.link == nil, !isStale else { return false }
            guard
                let reply = try? await rendezvous.fetchPeer(),
                reply.inReplyTo == offerID,
                let answer = reply.description
            else { continue }
            // From here both phones send to each other at the same time, which opens the firewalls on each side.
            guard (try? await session.accept(answer: answer)) != nil else { return false }
            return await link.waitUntilConnected(timeout: timings.remoteConnect)
        }
        return false
    }

    // MARK: Router port

    private func openRouterPort(for offer: String) async -> PortMapping? {
        guard let portMapper, let candidate = SessionDescriptionInspector.mappableCandidate(in: offer) else { return nil }
        let outcome = await portMapper.open(internalAddress: candidate.address, internalPort: candidate.port)
        LinkLog.note("baby unit: router port for \(candidate.address):\(candidate.port): \(outcome)")
        guard case .mapped(let mapping) = outcome else { return nil }
        // Opened too late, while monitoring was being stopped: give it back at once.
        guard state != .stopped else {
            await portMapper.close(mapping)
            return nil
        }
        return mapping
    }

    private func closeRouterPort(of link: ObjectIdentifier) async {
        guard let mapping = routerPorts.removeValue(forKey: link) else { return }
        await portMapper?.close(mapping)
    }

    /// Closes a link that never carried anything, and gives back its router port.
    private func discard(_ link: PeerLink) async {
        await link.close()
        await closeRouterPort(of: ObjectIdentifier(link))
    }

    // MARK: Active link

    private func adopt(_ newLink: PeerLink) async {
        guard state != .stopped else {
            await newLink.close()
            return
        }
        let previous = link
        if previous != nil {
            LinkLog.note("baby unit: a new connection replaces the current one")
        }
        link = newLink
        set(.connected(newLink.route))
        await previous?.close()
        Task { await self.relay(newLink) }
    }

    private func relay(_ activeLink: PeerLink) async {
        for await payload in activeLink.payloads {
            payloadContinuation.yield(payload)
        }
        _ = await activeLink.waitUntilEnded()
        await closeRouterPort(of: ObjectIdentifier(activeLink))
        if link === activeLink {
            link = nil
            if state != .stopped { set(.waiting) }
        }
    }

    private func set(_ newState: State) {
        guard newState != state else { return }
        LinkLog.note("baby unit: \(newState)")
        state = newState
        stateContinuation.yield(newState)
    }

    private func set(_ access: RemoteAccess) {
        guard access != remoteAccess else { return }
        remoteAccess = access
        remoteAccessContinuation.yield(access)
    }
}
