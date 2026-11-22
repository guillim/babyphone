import BabyphoneCore
@testable import BabyphoneTransport
import Foundation
@preconcurrency import Network
@preconcurrency import WebRTC

enum TestMedia {
    /// A factory that also gathers loopback addresses, so two sessions in one
    /// process can reach each other on a machine with no usable network.
    nonisolated(unsafe) static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory()
        let options = RTCPeerConnectionFactoryOptions()
        options.ignoreLoopbackNetworkAdapter = false
        factory.setOptions(options)
        return factory
    }()

    static let sessionFactory: PeerSessionFactory = { try WebRTCSession(factory: factory) }
}

extension LinkTimings {
    /// Real stacks need real time, but nothing here should wait as long as a phone would.
    static var quick: LinkTimings {
        var timings = LinkTimings()
        timings.localDiscovery = .seconds(5)
        timings.remoteRetryPause = .milliseconds(200)
        timings.rendezvousPoll = .milliseconds(200)
        timings.retryBackoff = [.milliseconds(500)]
        return timings
    }
}

/// Waits until `stream` produces a value satisfying `predicate`. Returns false on timeout.
func waitFor<Value: Sendable>(
    _ stream: AsyncStream<Value>,
    timeout: Duration = .seconds(30),
    _ predicate: @escaping @Sendable (Value) -> Bool
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await value in stream where predicate(value) { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

/// A TCP listener on the loopback interface that hands out frame channels.
final class LoopbackListener: @unchecked Sendable {
    let channels: AsyncStream<any FrameChannel>
    private let continuation: AsyncStream<any FrameChannel>.Continuation
    private let listener: NWListener

    init(using parameters: NWParameters) throws {
        listener = try NWListener(using: parameters)
        (channels, continuation) = AsyncStream.makeStream(of: (any FrameChannel).self)
    }

    /// Starts listening and returns the port to connect to.
    func start() async throws -> NWEndpoint.Port {
        listener.newConnectionHandler = { [continuation] connection in
            let channel = NetworkFrameChannel(connection: connection)
            Task {
                do {
                    try await channel.open(timeout: .seconds(5))
                    continuation.yield(channel)
                } catch {
                    channel.close()
                }
            }
        }
        try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Void, any Error>) in
            let ready = SingleResume(waiting)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready(.success(()))
                case .failed(let error): ready(.failure(error))
                default: break
                }
            }
            listener.start(queue: LocalTransport.queue)
        }
        guard let port = listener.port else { throw LocalNetworkError.notFound }
        return port
    }

    func stop() {
        listener.cancel()
        continuation.finish()
    }

    static func connect(to port: NWEndpoint.Port, using parameters: NWParameters, timeout: Duration = .seconds(5)) async throws -> NetworkFrameChannel {
        let channel = NetworkFrameChannel(connection: NWConnection(host: "127.0.0.1", port: port, using: parameters))
        do {
            try await channel.open(timeout: timeout)
        } catch {
            channel.close()
            throw error
        }
        return channel
    }
}

/// Local signaling over real TCP and TLS on the loopback interface.
///
/// It replaces Bonjour discovery only. The secured channel underneath is the one the app uses.
final class LoopbackSignaling: LocalSignalingListening, LocalSignalingConnecting, @unchecked Sendable {
    private let babyKey: PairingKey
    private let parentKey: PairingKey
    private let lock = NSLock()
    private var listener: LoopbackListener?
    private var port: NWEndpoint.Port?

    init(babyKey: PairingKey, parentKey: PairingKey) {
        self.babyKey = babyKey
        self.parentKey = parentKey
    }

    func start() async throws -> AsyncStream<any FrameChannel> {
        let listener = try LoopbackListener(using: LocalTransport.monitorParameters(key: babyKey))
        let port = try await listener.start()
        lock.withLock {
            self.listener = listener
            self.port = port
        }
        return listener.channels
    }

    func stop() async {
        lock.withLock { listener }?.stop()
    }

    func connect(timeout: Duration) async throws -> any FrameChannel {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let port = lock.withLock({ port }) {
                return try await LoopbackListener.connect(to: port, using: LocalTransport.monitorParameters(key: parentKey), timeout: timeout)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw LocalNetworkError.notFound
    }
}

/// A local network on which the two phones never see each other.
struct NoLocalNetwork: LocalSignalingListening, LocalSignalingConnecting {
    func start() async throws -> AsyncStream<any FrameChannel> {
        AsyncStream { _ in }
    }

    func stop() async {}

    func connect(timeout: Duration) async throws -> any FrameChannel {
        try? await Task.sleep(for: .milliseconds(100))
        throw LocalNetworkError.notFound
    }
}

/// A rendezvous provider that keeps records in memory.
final class MemoryRendezvous: RendezvousProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]

    func availability() async -> RendezvousAvailability { .available }

    func publish(_ record: Data, to slot: RendezvousSlot) async throws {
        lock.withLock { records[slot.name] = record }
    }

    func fetch(_ slot: RendezvousSlot) async throws -> Data? {
        lock.withLock { records[slot.name] }
    }
}
