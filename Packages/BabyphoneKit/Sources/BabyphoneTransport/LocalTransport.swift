import BabyphoneCore
import dnssd
import Foundation
@preconcurrency import Network

/// Names and transport settings of the two Bonjour services the app uses.
enum LocalTransport {
    /// Advertised by a baby unit while it monitors. Signaling for the paired parent unit.
    static let monitorService = "_nid-monitor._tcp"
    /// Advertised by a baby unit while its pairing screen is open.
    static let pairingService = "_nid-pair._tcp"
    /// Bonjour TXT key carrying the pair's tag, so a parent unit only contacts its own baby unit.
    static let tagKey = "tag"

    static let queue = DispatchQueue(label: "nid.local-network")

    /// TLS secured by the pairing key: only the paired phone can complete the handshake.
    static func monitorParameters(key: PairingKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let identity = Data("nid-monitor".utf8)
        let secret = key.localTransportKey.withUnsafeBytes { DispatchData(bytes: $0) }
        let hint = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secret as __DispatchData, hint as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        return NWParameters(tls: tls, tcp: tcpOptions)
    }

    /// Plain TCP. The pairing exchange protects itself, and it may run over
    /// peer-to-peer Wi-Fi so two phones can pair without a shared network.
    static var pairingParameters: NWParameters {
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        return parameters
    }

    private static var tcpOptions: NWProtocolTCP.Options {
        let options = NWProtocolTCP.Options()
        options.enableKeepalive = true
        options.keepaliveIdle = 2
        options.noDelay = true
        return options
    }
}

public enum LocalNetworkError: Error {
    /// No matching baby unit answered on the local network in time.
    case notFound
    /// The user refused the local network permission, so nothing can be discovered.
    case permissionDenied
}

/// Completes an async continuation exactly once, from whichever callback gets there first.
final class SingleResume<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func callAsFunction(_ result: Result<Value, any Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Value, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

/// Finds Bonjour services on the local network.
enum LocalDiscovery {
    /// `kDNSServiceErr_PolicyDenied`: the local network permission is off.
    private static let policyDenied: DNSServiceErrorType = -65570

    /// Returns the endpoints advertising `service`, as soon as at least one matches.
    ///
    /// - Parameters:
    ///   - tag: when set, only services advertising this pair tag match.
    ///   - settle: extra time left for other services to show up after the first match.
    static func endpoints(
        of service: String,
        tag: String?,
        parameters: NWParameters,
        timeout: Duration,
        settle: Duration = .zero
    ) async throws -> [NWEndpoint] {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: service, domain: nil), using: parameters)
        defer { browser.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let finish = SingleResume(continuation)

            @Sendable func matches(_ results: Set<NWBrowser.Result>) -> [NWEndpoint] {
                results.filter { result in
                    guard let tag else { return true }
                    guard case .bonjour(let record) = result.metadata else { return false }
                    return record[LocalTransport.tagKey] == tag
                }.map(\.endpoint)
            }

            browser.browseResultsChangedHandler = { results, _ in
                guard !matches(results).isEmpty else { return }
                LocalTransport.queue.asyncAfter(deadline: .now() + settle.timeInterval) {
                    finish(.success(matches(browser.browseResults)))
                }
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(.dns(policyDenied)), .failed(.dns(policyDenied)):
                    finish(.failure(LocalNetworkError.permissionDenied))
                case .failed:
                    finish(.failure(LocalNetworkError.notFound))
                default:
                    break
                }
            }
            LocalTransport.queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                finish(.failure(LocalNetworkError.notFound))
            }
            browser.start(queue: LocalTransport.queue)
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
