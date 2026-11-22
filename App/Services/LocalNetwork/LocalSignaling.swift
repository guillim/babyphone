import BabyphoneCore
import Foundation
@preconcurrency import Network

/// Baby side: advertises the monitor on the local network and accepts the paired parent unit.
final class BonjourSignalingListener: LocalSignalingListening, @unchecked Sendable {
    private static let handshakeTimeout: Duration = .seconds(5)
    private static let restartDelay: TimeInterval = 2

    private let key: PairingKey
    // Only touched on `LocalTransport.queue`.
    private var listener: NWListener?
    private var channels: AsyncStream<any FrameChannel>.Continuation?

    init(key: PairingKey) {
        self.key = key
    }

    func start() async throws -> AsyncStream<any FrameChannel> {
        let (stream, continuation) = AsyncStream.makeStream(of: (any FrameChannel).self)
        LocalTransport.queue.async { [self] in
            channels = continuation
            listen()
        }
        return stream
    }

    func stop() async {
        LocalTransport.queue.async { [self] in
            channels?.finish()
            channels = nil
            listener?.cancel()
            listener = nil
        }
    }

    private func listen() {
        guard channels != nil, let listener = try? NWListener(using: LocalTransport.monitorParameters(key: key)) else { return }
        self.listener = listener
        listener.service = NWListener.Service(
            type: LocalTransport.monitorService,
            txtRecord: NWTXTRecord([LocalTransport.tagKey: key.localNetworkTag])
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            // A listener fails when its network goes away. Start a fresh one once things settle.
            guard case .failed = state else { return }
            listener.cancel()
            LocalTransport.queue.asyncAfter(deadline: .now() + Self.restartDelay) {
                self?.listen()
            }
        }
        listener.start(queue: LocalTransport.queue)
    }

    private func accept(_ connection: NWConnection) {
        let channel = NetworkFrameChannel(connection: connection)
        Task { [weak self] in
            // Handing over the channel only once the handshake passed keeps strangers
            // on the network from making the baby unit do any work.
            do {
                try await channel.open(timeout: Self.handshakeTimeout)
            } catch {
                channel.close()
                return
            }
            LocalTransport.queue.async {
                if let channels = self?.channels {
                    channels.yield(channel)
                } else {
                    channel.close()
                }
            }
        }
    }
}

/// Parent side: finds the paired baby unit on the local network and opens a secured channel to it.
struct BonjourSignalingConnector: LocalSignalingConnecting {
    let key: PairingKey

    func connect(timeout: Duration) async throws -> any FrameChannel {
        let parameters = LocalTransport.monitorParameters(key: key)
        let endpoints = try await LocalDiscovery.endpoints(
            of: LocalTransport.monitorService,
            tag: key.localNetworkTag,
            parameters: parameters,
            timeout: timeout
        )
        guard let endpoint = endpoints.first else { throw LocalNetworkError.notFound }
        let channel = NetworkFrameChannel(connection: NWConnection(to: endpoint, using: parameters))
        do {
            try await channel.open(timeout: timeout)
        } catch {
            channel.close()
            throw error
        }
        return channel
    }
}
