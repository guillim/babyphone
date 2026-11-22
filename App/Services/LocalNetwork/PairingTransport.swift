import BabyphoneCore
import Foundation
@preconcurrency import Network

/// Baby side: advertises the pairing service while the pairing screen is open.
final class PairingListener: @unchecked Sendable {
    private let host: PairingHost
    private let onPaired: @Sendable (PairingKey) -> Void
    private let onUnavailable: @Sendable () -> Void
    private var listener: NWListener?

    /// - Parameter onUnavailable: called when the service cannot be advertised, which
    ///   in practice means the local network permission is off.
    init(
        host: PairingHost,
        onPaired: @escaping @Sendable (PairingKey) -> Void,
        onUnavailable: @escaping @Sendable () -> Void
    ) {
        self.host = host
        self.onPaired = onPaired
        self.onUnavailable = onUnavailable
    }

    func start() throws {
        let listener = try NWListener(using: LocalTransport.pairingParameters)
        listener.service = NWListener.Service(type: LocalTransport.pairingService)
        listener.stateUpdateHandler = { [onUnavailable] state in
            switch state {
            case .failed, .waiting: onUnavailable()
            default: break
            }
        }
        listener.newConnectionHandler = { [host, onPaired] connection in
            let channel = NetworkFrameChannel(connection: connection)
            Task {
                guard (try? await channel.open(timeout: .seconds(5))) != nil else {
                    channel.close()
                    return
                }
                if let key = await host.serve(channel) {
                    onPaired(key)
                }
            }
        }
        listener.start(queue: LocalTransport.queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// Parent side: finds a baby unit in pairing mode nearby and runs the pairing exchange with it.
enum PairingClient {
    static func pair(using credential: PairingCredential) async throws -> PairingKey {
        let parameters = LocalTransport.pairingParameters
        let endpoints = try await LocalDiscovery.endpoints(
            of: LocalTransport.pairingService,
            tag: nil,
            parameters: parameters,
            timeout: .seconds(8),
            settle: .milliseconds(400)
        )
        // Several baby units may be pairing at once, in a nursery for instance. Only ours accepts the credential.
        var lastError: any Error = LocalNetworkError.notFound
        for endpoint in endpoints {
            let channel = NetworkFrameChannel(connection: NWConnection(to: endpoint, using: parameters))
            defer { channel.close() }
            do {
                try await channel.open(timeout: .seconds(5))
                return try await PairingProtocol.initiate(over: channel, credential: credential)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
