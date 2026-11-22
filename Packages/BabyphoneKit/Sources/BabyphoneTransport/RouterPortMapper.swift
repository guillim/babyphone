import BabyphoneCore
import Foundation

/// Asks the home router to forward a port, with whichever of NAT-PMP and UPnP it speaks.
///
/// Everything happens on the local network, between this device and its
/// router. A port stays open for an hour and is renewed for as long as it is
/// in use, so a device that disappears leaves nothing open for long.
public actor RouterPortMapper: PortMapper {
    /// How long the router keeps a port without a renewal, in seconds.
    private static let lifetime: UInt32 = 3600
    /// How long a router that could not help is left alone.
    private static let retryAfterFailure: TimeInterval = 600

    private let fixedGateway: String?
    private let natPMPPort: UInt16
    private let searchPort: UInt16
    private let searchesGroup: Bool
    private let label: String

    private struct Lease {
        let gateway: String
        let service: UPnP.Service?
        let renewal: Task<Void, Never>?
    }

    private var leases: [UInt16: Lease] = [:]
    private var services: [String: UPnP.Service] = [:]
    private var unhelpfulUntil: [String: Date] = [:]

    /// - Parameters:
    ///   - label: The name the router shows for the port in its own settings.
    ///   - gateway: The router's address. Found by itself when nil.
    public init(
        label: String = "Baby monitor",
        gateway: String? = nil,
        natPMPPort: UInt16 = NATPMP.port,
        searchPort: UInt16 = UPnP.searchPort,
        searchesGroup: Bool = true
    ) {
        self.label = label
        fixedGateway = gateway
        self.natPMPPort = natPMPPort
        self.searchPort = searchPort
        self.searchesGroup = searchesGroup
    }

    public func open(internalAddress: String, internalPort: UInt16) async -> PortMappingOutcome {
        guard let gateway = fixedGateway ?? DefaultGateway.current() else { return .noRouter }
        if let until = unhelpfulUntil[gateway], Date() < until { return .unsupported }

        let outcome: PortMappingOutcome
        if let viaNATPMP = await openWithNATPMP(gateway: gateway, internalAddress: internalAddress, internalPort: internalPort) {
            outcome = viaNATPMP
        } else if let viaUPnP = await openWithUPnP(gateway: gateway, internalAddress: internalAddress, internalPort: internalPort) {
            outcome = viaUPnP
        } else {
            outcome = .unsupported
        }
        if case .mapped = outcome {
            unhelpfulUntil[gateway] = nil
        } else {
            unhelpfulUntil[gateway] = Date().addingTimeInterval(Self.retryAfterFailure)
        }
        return outcome
    }

    public func close(_ mapping: PortMapping) async {
        guard let lease = leases.removeValue(forKey: mapping.externalPort) else { return }
        lease.renewal?.cancel()
        if let service = lease.service {
            _ = await LocalHTTP.send(UPnP.deleteMappingRequest(to: service, externalPort: mapping.externalPort))
        } else {
            _ = await requestNATPMPMapping(gateway: lease.gateway, internalPort: mapping.internalPort, externalPort: 0, lifetime: 0)
        }
    }

    /// Forgets what was learnt about the routers. Call when the device changes network.
    public func networkDidChange() {
        services = [:]
        unhelpfulUntil = [:]
    }

    // MARK: NAT-PMP

    private func openWithNATPMP(gateway: String, internalAddress: String, internalPort: UInt16) async -> PortMappingOutcome? {
        let address = await Datagram.request(
            NATPMP.externalAddressRequest(), to: [(gateway, natPMPPort)], waits: [0.25, 0.5]
        ) { reply -> String? in
            if case .externalAddress(let address) = NATPMP.parse(reply) { address } else { nil }
        }
        guard let address else { return nil }
        guard AddressScope.of(address) == .publicIPv4 else { return .sharedAddress(address) }
        guard let granted = await requestNATPMPMapping(
            gateway: gateway, internalPort: internalPort, externalPort: internalPort, lifetime: Self.lifetime
        ) else { return nil }
        let mapping = PortMapping(
            method: .natPMP, externalAddress: address, externalPort: granted.externalPort,
            internalAddress: internalAddress, internalPort: internalPort, lifetime: TimeInterval(granted.lifetime)
        )
        keep(mapping, gateway: gateway, service: nil)
        return .mapped(mapping)
    }

    private func requestNATPMPMapping(
        gateway: String, internalPort: UInt16, externalPort: UInt16, lifetime: UInt32
    ) async -> (externalPort: UInt16, lifetime: UInt32)? {
        await Datagram.request(
            NATPMP.mappingRequest(internalPort: internalPort, externalPort: externalPort, lifetime: lifetime),
            to: [(gateway, natPMPPort)], waits: [0.25, 0.5, 1]
        ) { reply -> (externalPort: UInt16, lifetime: UInt32)?? in
            switch NATPMP.parse(reply) {
            case .mapping(internalPort, let externalPort, let lifetime): .some((externalPort, lifetime))
            case .refused: .some(nil)
            default: nil
            }
        } ?? nil
    }

    // MARK: UPnP

    private func openWithUPnP(gateway: String, internalAddress: String, internalPort: UInt16) async -> PortMappingOutcome? {
        guard
            let service = await upnpService(gateway: gateway),
            let addressResponse = await LocalHTTP.send(UPnP.externalAddressRequest(to: service)),
            let address = try? UPnP.externalAddress(in: addressResponse)
        else { return nil }
        guard AddressScope.of(address) == .publicIPv4 else { return .sharedAddress(address) }

        // The same port outside as inside when it is free, then a few others.
        var lifetime = Self.lifetime
        var externalPort = internalPort
        for _ in 0..<5 {
            let request = UPnP.addMappingRequest(
                to: service, externalPort: externalPort, internalAddress: internalAddress, internalPort: internalPort,
                lifetime: lifetime, description: label
            )
            guard let response = await LocalHTTP.send(request) else { return nil }
            do {
                try UPnP.check(response)
                let mapping = PortMapping(
                    method: .upnp, externalAddress: address, externalPort: externalPort,
                    internalAddress: internalAddress, internalPort: internalPort, lifetime: TimeInterval(lifetime)
                )
                keep(mapping, gateway: gateway, service: service)
                return .mapped(mapping)
            } catch UPnP.Failure.refused(code: UPnP.conflictCode) {
                externalPort = UInt16.random(in: 20_000...60_000)
            } catch UPnP.Failure.refused(code: UPnP.permanentLeaseOnlyCode) where lifetime != 0 {
                lifetime = 0
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Finds where the router takes commands: a search datagram, then its description.
    private func upnpService(gateway: String) async -> UPnP.Service? {
        if let known = services[gateway] { return known }
        // Straight to the router, and to the group every UPnP device listens to. On iOS the
        // second needs a permission from Apple that the app may not have: the first does not.
        var destinations = [(host: gateway, port: searchPort)]
        if searchesGroup { destinations.append((UPnP.searchGroup, searchPort)) }
        let location = await Datagram.request(UPnP.searchRequest(), to: destinations, waits: [1, 1.5]) { reply -> URL? in
            guard let url = UPnP.descriptionURL(inSearchResponse: reply), let host = url.host else { return nil }
            // A router describes itself from the local network. Anything else is not followed.
            let scope = AddressScope.of(host)
            return scope == .privateNetwork || scope == .loopback ? url : nil
        }
        guard
            let location,
            let response = await LocalHTTP.send(HTTPRequest(url: location)), response.status == 200,
            let service = UPnP.portMappingService(inDescription: String(decoding: response.body, as: UTF8.self), at: location)
        else { return nil }
        services[gateway] = service
        return service
    }

    // MARK: Leases

    /// Remembers an open port, and renews it at half its lifetime for as long as it is kept.
    private func keep(_ mapping: PortMapping, gateway: String, service: UPnP.Service?) {
        leases[mapping.externalPort]?.renewal?.cancel()
        var renewal: Task<Void, Never>?
        if mapping.lifetime > 0 {
            renewal = Task { [weak self] in
                while (try? await Task.sleep(for: .seconds(mapping.lifetime / 2))) != nil {
                    await self?.renew(mapping, gateway: gateway, service: service)
                }
            }
        }
        leases[mapping.externalPort] = Lease(gateway: gateway, service: service, renewal: renewal)
    }

    private func renew(_ mapping: PortMapping, gateway: String, service: UPnP.Service?) async {
        guard leases[mapping.externalPort] != nil else { return }
        if let service {
            _ = await LocalHTTP.send(UPnP.addMappingRequest(
                to: service, externalPort: mapping.externalPort, internalAddress: mapping.internalAddress,
                internalPort: mapping.internalPort, lifetime: UInt32(mapping.lifetime), description: label
            ))
        } else {
            _ = await requestNATPMPMapping(
                gateway: gateway, internalPort: mapping.internalPort, externalPort: mapping.externalPort, lifetime: UInt32(mapping.lifetime)
            )
        }
    }
}
