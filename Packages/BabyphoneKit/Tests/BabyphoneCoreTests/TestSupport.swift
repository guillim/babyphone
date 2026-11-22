import Foundation
import TestSupport
@testable import BabyphoneCore

/// Timings a thousand times shorter than the real ones, so link tests run in milliseconds.
extension LinkTimings {
    static var fast: LinkTimings {
        var timings = LinkTimings()
        timings.keepaliveInterval = .milliseconds(20)
        timings.silenceTimeout = .milliseconds(200)
        timings.localDiscovery = .milliseconds(100)
        timings.signalingStep = .milliseconds(300)
        timings.localConnect = .milliseconds(300)
        timings.remoteConnect = .milliseconds(400)
        timings.remoteWindow = .milliseconds(1500)
        timings.remoteRetryPause = .milliseconds(30)
        timings.rendezvousPoll = .milliseconds(30)
        timings.offerRefresh = .seconds(30)
        timings.rendezvousErrorPause = .milliseconds(100)
        timings.retryBackoff = [.milliseconds(50)]
        return timings
    }
}

/// One end of an in-memory frame channel.
final class MemoryChannel: FrameChannel, @unchecked Sendable {
    private struct State {
        var inbox: [Data] = []
        var waiter: CheckedContinuation<Data, any Error>?
        var isClosed = false
    }

    private let state = Locked(State())
    private weak var peer: MemoryChannel?

    static func pair() -> (MemoryChannel, MemoryChannel) {
        let first = MemoryChannel(), second = MemoryChannel()
        first.peer = second
        second.peer = first
        return (first, second)
    }

    func send(_ frame: Data) async throws {
        guard !state.current.isClosed, let peer else { throw FrameChannelError.closed }
        peer.deliver(frame)
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                if !state.inbox.isEmpty {
                    continuation.resume(returning: state.inbox.removeFirst())
                } else if state.isClosed {
                    continuation.resume(throwing: FrameChannelError.closed)
                } else {
                    state.waiter = continuation
                }
            }
        }
    }

    func close() {
        let (waiter, peer) = state.withLock { state -> (CheckedContinuation<Data, any Error>?, MemoryChannel?) in
            guard !state.isClosed else { return (nil, nil) }
            state.isClosed = true
            defer { state.waiter = nil }
            return (state.waiter, self.peer)
        }
        waiter?.resume(throwing: FrameChannelError.closed)
        peer?.close()
    }

    private func deliver(_ frame: Data) {
        let waiter = state.withLock { state -> CheckedContinuation<Data, any Error>? in
            guard !state.isClosed else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.inbox.append(frame)
            return nil
        }
        waiter?.resume(returning: frame)
    }
}

/// Stands in for the network between two phones: decides whether sessions can connect and exchange data.
final class FakeNetwork: @unchecked Sendable {
    private let sessions = Locked([String: FakeSession]())
    private let reachable = Locked(true)
    let createdSessions = Locked(0)

    /// When false, new sessions never connect and connected ones stop delivering.
    var isReachable: Bool {
        get { reachable.current }
        set { reachable.withLock { $0 = newValue } }
    }

    var factory: PeerSessionFactory {
        { [self] in
            let session = FakeSession(network: self)
            sessions.withLock { $0[session.id] = session }
            createdSessions.withLock { $0 += 1 }
            return session
        }
    }

    func session(_ id: String) -> FakeSession? {
        sessions.current[id]
    }
}

final class FakeSession: PeerSession, @unchecked Sendable {
    enum Failure: Error { case malformedDescription }

    let id = UUID().uuidString
    let events: AsyncStream<PeerSessionEvent>
    private let continuation: AsyncStream<PeerSessionEvent>.Continuation
    private let network: FakeNetwork
    private let peer = Locked<FakeSession?>(nil)
    private let closed = Locked(false)

    init(network: FakeNetwork) {
        self.network = network
        (events, continuation) = AsyncStream.makeStream(of: PeerSessionEvent.self)
    }

    var isClosed: Bool { closed.current }

    func makeOffer() async throws -> String { "offer:\(id)" }

    func makeAnswer(to offer: String) async throws -> String {
        guard offer.hasPrefix("offer:") else { throw Failure.malformedDescription }
        return "answer:\(id)"
    }

    func accept(answer: String) async throws {
        guard answer.hasPrefix("answer:"),
              let other = network.session(String(answer.dropFirst("answer:".count)))
        else { throw Failure.malformedDescription }
        guard network.isReachable, !isClosed, !other.isClosed else { return }
        peer.withLock { $0 = other }
        other.peer.withLock { $0 = self }
        continuation.yield(.connected)
        other.continuation.yield(.connected)
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        guard network.isReachable, !isClosed, let other = peer.current, !other.isClosed else { return false }
        other.continuation.yield(.message(data))
        return true
    }

    func close() {
        closed.withLock { $0 = true }
        continuation.finish()
    }

    func fail() {
        continuation.yield(.failed)
    }
}

/// The local network as both phones see it: a listener on the baby side, a connector on the parent side.
final class FakeLocalNetwork: LocalSignalingListening, LocalSignalingConnecting, @unchecked Sendable {
    enum Failure: Error { case babyNotFound }

    private let listenerContinuation = Locked<AsyncStream<any FrameChannel>.Continuation?>(nil)
    private let sameNetwork = Locked(true)

    /// When false, the parent unit does not find the baby unit, as if they were on different networks.
    var arePhonesOnSameNetwork: Bool {
        get { sameNetwork.current }
        set { sameNetwork.withLock { $0 = newValue } }
    }

    func start() async throws -> AsyncStream<any FrameChannel> {
        let (stream, continuation) = AsyncStream.makeStream(of: (any FrameChannel).self)
        listenerContinuation.withLock { $0 = continuation }
        return stream
    }

    func stop() async {
        listenerContinuation.withLock { continuation in
            continuation?.finish()
            continuation = nil
        }
    }

    func connect(timeout: Duration) async throws -> any FrameChannel {
        // Like Bonjour, keeps looking until the baby unit shows up or the time is over.
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if arePhonesOnSameNetwork, let listener = listenerContinuation.current {
                let (parentEnd, babyEnd) = MemoryChannel.pair()
                listener.yield(babyEnd)
                return parentEnd
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        throw Failure.babyNotFound
    }
}
