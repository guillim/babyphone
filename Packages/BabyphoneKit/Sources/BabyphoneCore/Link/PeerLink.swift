import Foundation

/// Supervises one peer session: waits for it to connect, keeps it alive, and notices when it dies.
///
/// A direct connection that stops carrying data gives no reliable signal by
/// itself, so each side sends a small keepalive and treats prolonged silence
/// as a lost link.
public actor PeerLink {
    public enum EndReason: Sendable, Equatable {
        /// The session reported a failure.
        case failed
        /// Nothing was heard from the peer for too long.
        case silent
        /// This side closed the link.
        case closed
    }

    private enum Phase {
        case pending
        case connected
        case ended(EndReason)
    }

    private enum FrameType: UInt8 {
        case keepalive = 0
        case payload = 1
    }

    public nonisolated let route: LinkRoute
    /// Application messages received from the peer. Finishes when the link ends.
    public nonisolated let payloads: AsyncStream<Data>

    private let payloadContinuation: AsyncStream<Data>.Continuation
    private let session: any PeerSession
    private let timings: LinkTimings
    private var phase = Phase.pending
    private var lastHeardFromPeer = ContinuousClock.now
    private var eventPump: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var connectWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var endWaiters: [CheckedContinuation<EndReason, Never>] = []

    public init(session: any PeerSession, route: LinkRoute, timings: LinkTimings) {
        self.session = session
        self.route = route
        self.timings = timings
        (payloads, payloadContinuation) = AsyncStream.makeStream(of: Data.self)
    }

    /// Waits until the session is connected. Returns false if it fails or `timeout` passes first.
    public func waitUntilConnected(timeout: Duration) async -> Bool {
        startEventPump()
        switch phase {
        case .connected: return true
        case .ended: return false
        case .pending: break
        }
        let waiter = UUID()
        let deadline = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            await self?.resolveConnectWaiter(waiter, connected: false)
        }
        defer { deadline.cancel() }
        return await withCheckedContinuation { connectWaiters[waiter] = $0 }
    }

    /// Waits until the link ends, for any reason.
    public func waitUntilEnded() async -> EndReason {
        if case .ended(let reason) = phase { return reason }
        return await withCheckedContinuation { endWaiters.append($0) }
    }

    public func send(_ payload: Data) {
        guard case .connected = phase else {
            LinkLog.note("DIAG \(route.rawValue) link: send dropped, phase not connected")
            return
        }
        LinkLog.note("DIAG \(route.rawValue) link: send \(payload.count) bytes")
        session.send(Data([FrameType.payload.rawValue]) + payload)
    }

    public func close() {
        end(.closed)
    }

    private func startEventPump() {
        guard eventPump == nil, case .pending = phase else { return }
        let events = session.events
        eventPump = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
            await self?.end(.closed)
        }
    }

    private func handle(_ event: PeerSessionEvent) {
        switch event {
        case .connected:
            guard case .pending = phase else { return }
            LinkLog.note("\(route.rawValue) link connected")
            phase = .connected
            lastHeardFromPeer = .now
            startKeepalive()
            for waiter in connectWaiters.keys {
                resolveConnectWaiter(waiter, connected: true)
            }
        case .message(let frame):
            lastHeardFromPeer = .now
            guard frame.first == FrameType.payload.rawValue else { return }
            payloadContinuation.yield(Data(frame.dropFirst()))
        case .failed:
            end(.failed)
        }
    }

    private func startKeepalive() {
        let interval = timings.keepaliveInterval
        keepalive = Task { [weak self] in
            while (try? await Task.sleep(for: interval)) != nil {
                await self?.keepaliveTick()
            }
        }
    }

    private func keepaliveTick() {
        guard case .connected = phase else { return }
        if ContinuousClock.now - lastHeardFromPeer > timings.silenceTimeout {
            end(.silent)
        } else {
            session.send(Data([FrameType.keepalive.rawValue]))
        }
    }

    private func resolveConnectWaiter(_ waiter: UUID, connected: Bool) {
        connectWaiters.removeValue(forKey: waiter)?.resume(returning: connected)
    }

    private func end(_ reason: EndReason) {
        if case .ended = phase { return }
        LinkLog.note("\(route.rawValue) link ended: \(reason)")
        phase = .ended(reason)
        keepalive?.cancel()
        eventPump?.cancel()
        session.close()
        payloadContinuation.finish()
        for waiter in connectWaiters.keys {
            resolveConnectWaiter(waiter, connected: false)
        }
        for waiter in endWaiters {
            waiter.resume(returning: reason)
        }
        endWaiters.removeAll()
    }
}
