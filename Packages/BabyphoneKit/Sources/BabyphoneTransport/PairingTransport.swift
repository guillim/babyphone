import BabyphoneCore
import Foundation
@preconcurrency import Network

/// Baby side: advertises the pairing service while the pairing screen is open.
public final class PairingListener: @unchecked Sendable {
    private let host: PairingHost
    private let onPaired: @Sendable (PairingKey) -> Void
    private let onUnavailable: @Sendable () -> Void
    private var listener: NWListener?
    private let lock = NSLock()
    /// One pairing per pairing screen. A second parent unit is added from Réglages, on a new screen.
    private var isPaired = false

    /// - Parameter onUnavailable: called when the service cannot be advertised, which
    ///   in practice means the local network permission is off.
    public init(
        host: PairingHost,
        onPaired: @escaping @Sendable (PairingKey) -> Void,
        onUnavailable: @escaping @Sendable () -> Void
    ) {
        self.host = host
        self.onPaired = onPaired
        self.onUnavailable = onUnavailable
    }

    public func start() throws {
        let listener = try NWListener(using: LocalTransport.pairingParameters)
        listener.service = NWListener.Service(type: LocalTransport.pairingService)
        listener.stateUpdateHandler = { [onUnavailable] state in
            LinkLog.note("pairing listener: \(state)")
            switch state {
            case .failed, .waiting: onUnavailable()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self, host, onPaired] connection in
            LinkLog.note("pairing listener: connection from \(connection.endpoint)")
            // Refused before the exchange, so the parent unit does not end up with a key this device dropped.
            guard let self, !self.lock.withLock({ self.isPaired }) else {
                LinkLog.note("pairing listener: already paired, connection refused")
                connection.cancel()
                return
            }
            let channel = NetworkFrameChannel(connection: connection)
            Task {
                do {
                    try await channel.open(timeout: .seconds(5))
                } catch {
                    LinkLog.note("pairing listener: connection not opened: \(error)")
                    channel.close()
                    return
                }
                if let key = await host.serve(channel) {
                    let isFirst = self.lock.withLock { () -> Bool in
                        defer { self.isPaired = true }
                        return !self.isPaired
                    }
                    guard isFirst else { return }
                    LinkLog.note("pairing listener: paired")
                    self.stop()
                    onPaired(key)
                } else {
                    LinkLog.note("pairing listener: exchange failed")
                }
            }
        }
        listener.start(queue: LocalTransport.queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// Parent side: finds a baby unit in pairing mode nearby and runs the pairing exchange with it.
public enum PairingClient {
    public static func pair(using credential: PairingCredential) async throws -> PairingKey {
        let parameters = LocalTransport.pairingParameters
        let endpoints: [NWEndpoint]
        do {
            endpoints = try await LocalDiscovery.endpoints(
                of: LocalTransport.pairingService,
                tag: nil,
                parameters: parameters,
                timeout: .seconds(8),
                settle: .milliseconds(400)
            )
        } catch {
            LinkLog.note("pairing: no baby unit found: \(error)")
            throw error
        }
        LinkLog.note("pairing: found \(endpoints)")
        // Several baby units may be pairing at once, in a nursery for instance. Only ours accepts the credential.
        var lastError: any Error = LocalNetworkError.notFound
        for endpoint in endpoints {
            let connection = NWConnection(to: endpoint, using: parameters)
            let channel = NetworkFrameChannel(connection: connection)
            defer { channel.close() }
            do {
                try await channel.open(timeout: .seconds(5))
                LinkLog.note("pairing: connected to \(endpoint) through \(connection.currentPath?.availableInterfaces.first?.name ?? "?")")
                return try await PairingProtocol.initiate(over: channel, credential: credential)
            } catch {
                LinkLog.note("pairing: \(endpoint) failed: \(error), path \(String(describing: connection.currentPath))")
                lastError = error
            }
        }
        throw lastError
    }
}
