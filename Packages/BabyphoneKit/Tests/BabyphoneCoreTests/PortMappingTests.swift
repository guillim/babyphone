import Foundation
import Testing
import TestSupport
@testable import BabyphoneCore

/// A router that opens every port asked of it, and remembers which are open.
final class FakePortMapper: PortMapper, @unchecked Sendable {
    let open = Locked([PortMapping]())
    let openedCount = Locked(0)
    let outcome = Locked<PortMappingOutcome?>(nil)
    /// The only local address this router knows, when set.
    let ownNetwork = Locked<String?>(nil)

    func open(internalAddress: String, internalPort: UInt16) async -> PortMappingOutcome {
        if let outcome = outcome.current { return outcome }
        if let ownNetwork = ownNetwork.current, ownNetwork != internalAddress { return .noRouter }
        let mapping = PortMapping(
            method: .upnp, externalAddress: "82.64.10.20", externalPort: 40_000 + UInt16(openedCount.current),
            internalAddress: internalAddress, internalPort: internalPort, lifetime: 3600
        )
        open.withLock { $0.append(mapping) }
        openedCount.withLock { $0 += 1 }
        return .mapped(mapping)
    }

    func close(_ mapping: PortMapping) async {
        open.withLock { $0.removeAll { $0 == mapping } }
    }
}

@Suite(.timeLimit(.minutes(1))) struct PortMappingTests {
    // MARK: NAT-PMP

    @Test func natPMPRequestsAreTheBytesOfTheStandard() {
        #expect(NATPMP.externalAddressRequest() == Data([0, 0]))
        #expect(
            NATPMP.mappingRequest(internalPort: 50_000, externalPort: 50_000, lifetime: 3600)
                == Data([0, 1, 0, 0, 0xc3, 0x50, 0xc3, 0x50, 0, 0, 0x0e, 0x10])
        )
        // Giving a port back: no lifetime, and no external port either.
        #expect(
            NATPMP.mappingRequest(internalPort: 50_000, externalPort: 50_000, lifetime: 0)
                == Data([0, 1, 0, 0, 0xc3, 0x50, 0, 0, 0, 0, 0, 0])
        )
    }

    @Test func natPMPResponsesAreRead() {
        #expect(NATPMP.parse(Data([0, 128, 0, 0, 0, 0, 0, 9, 82, 64, 10, 20])) == .externalAddress("82.64.10.20"))
        #expect(
            NATPMP.parse(Data([0, 129, 0, 0, 0, 0, 0, 9, 0xc3, 0x50, 0x9c, 0x40, 0, 0, 0x0e, 0x10]))
                == .mapping(internalPort: 50_000, externalPort: 40_000, lifetime: 3600)
        )
        #expect(NATPMP.parse(Data([0, 129, 0, 2, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0])) == .refused(code: 2))
        // Too short, a request rather than a response, another protocol version.
        #expect(NATPMP.parse(Data([0, 128, 0, 0])) == nil)
        #expect(NATPMP.parse(Data([0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])) == nil)
        #expect(NATPMP.parse(Data([2, 129, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])) == nil)
    }

    // MARK: HTTP

    @Test func httpRequestsAskForTheConnectionToBeClosed() throws {
        let url = try #require(URL(string: "http://192.168.1.1:5000/ctl/IPConn?x=1"))
        let get = String(decoding: HTTPRequest(url: url).serialized, as: UTF8.self)
        #expect(get == "GET /ctl/IPConn?x=1 HTTP/1.1\r\nHost: 192.168.1.1:5000\r\nConnection: close\r\n\r\n")

        let post = String(decoding: HTTPRequest(method: "POST", url: url, headers: [("A", "b")], body: Data("abc".utf8)).serialized, as: UTF8.self)
        #expect(post.hasPrefix("POST /ctl/IPConn?x=1 HTTP/1.1\r\n"))
        #expect(post.hasSuffix("A: b\r\nContent-Length: 3\r\n\r\nabc"))
    }

    @Test func httpResponsesAreReadWhateverTheirFraming() throws {
        let plain = try #require(HTTPResponse(parsing: Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nServer: x\r\n\r\nhello".utf8)))
        #expect(plain.status == 200)
        #expect(plain.headers["server"] == "x")
        #expect(plain.body == Data("hello".utf8))

        let chunked = try #require(HTTPResponse(parsing: Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nhel\r\n2\r\nlo\r\n0\r\n\r\n".utf8)))
        #expect(chunked.body == Data("hello".utf8))

        let untilClose = try #require(HTTPResponse(parsing: Data("HTTP/1.0 500 Internal Server Error\r\n\r\noops".utf8)))
        #expect(untilClose.status == 500)
        #expect(untilClose.body == Data("oops".utf8))

        #expect(HTTPResponse(parsing: Data("not http".utf8)) == nil)
    }

    @Test func aReaderKnowsWhenAResponseIsWhole() {
        #expect(!HTTPResponse.isComplete(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel".utf8)))
        #expect(HTTPResponse.isComplete(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)))
        #expect(!HTTPResponse.isComplete(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nhel\r\n".utf8)))
        #expect(HTTPResponse.isComplete(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nhel\r\n0\r\n\r\n".utf8)))
        // No length given: only the end of the connection tells.
        #expect(!HTTPResponse.isComplete(Data("HTTP/1.0 200 OK\r\n\r\nhello".utf8)))
    }

    // MARK: UPnP

    private let location = URL(string: "http://192.168.1.1:5000/rootDesc.xml")!

    private let description = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
        <device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
        <serviceList><service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
        <controlURL>/ctl/L3F</controlURL></service></serviceList>
        <deviceList><device><deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType>
        <deviceList><device><deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:1</deviceType>
        <serviceList><service>
        <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>
        <controlURL>/ctl/IPConn</controlURL>
        <eventSubURL>/evt/IPConn</eventSubURL>
        </service></serviceList></device></deviceList></device></deviceList></device></root>
        """

    @Test func theSearchAsksForARouterAndItsAnswerSaysWhereToRead() throws {
        let search = String(decoding: UPnP.searchRequest(), as: UTF8.self)
        #expect(search.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
        #expect(search.contains("ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n"))
        #expect(search.hasSuffix("\r\n\r\n"))

        let answer = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nLocation: http://192.168.1.1:5000/rootDesc.xml\r\nST: x\r\n\r\n"
        #expect(UPnP.descriptionURL(inSearchResponse: Data(answer.utf8)) == location)
        #expect(UPnP.descriptionURL(inSearchResponse: Data("NOTIFY * HTTP/1.1\r\nLOCATION: http://x/\r\n\r\n".utf8)) == nil)
    }

    @Test func theServiceThatOpensPortsIsFoundInTheDescription() throws {
        let service = try #require(UPnP.portMappingService(inDescription: description, at: location))
        #expect(service.type == "urn:schemas-upnp-org:service:WANIPConnection:1")
        #expect(service.controlURL.absoluteString == "http://192.168.1.1:5000/ctl/IPConn")
    }

    @Test func otherShapesOfDescriptionAreUnderstoodToo() throws {
        // A base address given apart, a connection over PPP, and an absolute command address.
        let withBase = """
            <root><URLBase>http://192.168.1.254:80/</URLBase><device><serviceList>
            <service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
            <controlURL>upnp/control/wanppp</controlURL></service></serviceList></device></root>
            """
        let ppp = try #require(UPnP.portMappingService(inDescription: withBase, at: location))
        #expect(ppp.controlURL.absoluteString == "http://192.168.1.254:80/upnp/control/wanppp")

        let absolute = """
            <root><device><serviceList><service>
            <serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType>
            <controlURL>http://10.0.0.1:49152/control</controlURL></service></serviceList></device></root>
            """
        #expect(UPnP.portMappingService(inDescription: absolute, at: location)?.controlURL.absoluteString == "http://10.0.0.1:49152/control")

        #expect(UPnP.portMappingService(inDescription: "<root><device/></root>", at: location) == nil)
    }

    @Test func commandsNameTheServiceAndCarryTheirArguments() throws {
        let service = try #require(UPnP.portMappingService(inDescription: description, at: location))
        let request = UPnP.addMappingRequest(
            to: service, externalPort: 40_000, internalAddress: "192.168.1.20", internalPort: 50_000,
            lifetime: 3600, description: "NuzzleCam <baby>"
        )
        #expect(request.method == "POST")
        #expect(request.url == service.controlURL)
        #expect(request.headers.contains { $0.name == "SOAPAction" && $0.value == "\"urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping\"" })
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(body.contains("<u:AddPortMapping xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\">"))
        #expect(body.contains("<NewExternalPort>40000</NewExternalPort><NewProtocol>UDP</NewProtocol><NewInternalPort>50000</NewInternalPort>"))
        #expect(body.contains("<NewInternalClient>192.168.1.20</NewInternalClient>"))
        #expect(body.contains("<NewPortMappingDescription>NuzzleCam &lt;baby&gt;</NewPortMappingDescription>"))
        #expect(body.contains("<NewLeaseDuration>3600</NewLeaseDuration>"))

        let delete = String(decoding: UPnP.deleteMappingRequest(to: service, externalPort: 40_000).body, as: UTF8.self)
        #expect(delete.contains("<u:DeletePortMapping"))
        #expect(delete.contains("<NewExternalPort>40000</NewExternalPort>"))
    }

    @Test func theRoutersAnswersAreRead() throws {
        let address = HTTPResponse(status: 200, body: Data("""
            <s:Envelope><s:Body><u:GetExternalIPAddressResponse xmlns:u="x">
            <NewExternalIPAddress>82.64.10.20</NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body></s:Envelope>
            """.utf8))
        #expect(try UPnP.externalAddress(in: address) == "82.64.10.20")

        let conflict = HTTPResponse(status: 500, body: Data("""
            <s:Envelope><s:Body><s:Fault><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
            <errorCode>718</errorCode><errorDescription>ConflictInMappingEntry</errorDescription>
            </UPnPError></detail></s:Fault></s:Body></s:Envelope>
            """.utf8))
        #expect(throws: UPnP.Failure.refused(code: UPnP.conflictCode)) { try UPnP.check(conflict) }
        #expect(throws: UPnP.Failure.unreadableResponse) { try UPnP.check(HTTPResponse(status: 404)) }
        #expect(throws: UPnP.Failure.unreadableResponse) { try UPnP.externalAddress(in: HTTPResponse(status: 200)) }
    }

    // MARK: Session descriptions

    private let offer = [
        "v=0",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111",
        "a=candidate:1 1 udp 2122260223 192.168.1.20 50000 typ host generation 0 ufrag abcd network-id 1",
        "a=candidate:2 1 udp 2122194687 2a01:e0a:1:2::3 50001 typ host generation 0 ufrag abcd network-id 2",
        "a=candidate:3 1 tcp 1518280447 192.168.1.20 9 typ host tcptype active generation 0",
        "a=end-of-candidates",
        "",
    ].joined(separator: "\r\n")

    private let mapping = PortMapping(
        method: .natPMP, externalAddress: "82.64.10.20", externalPort: 40_000,
        internalAddress: "192.168.1.20", internalPort: 50_000, lifetime: 3600
    )

    @Test func theLocalAddressesARouterCouldForwardToAreFound() throws {
        // A second private address, as on a device that is also on a mobile network, listed twice.
        let cellular = "a=candidate:4 1 udp 2122129151 10.20.30.40 50002 typ host generation 0"
        let candidates = SessionDescriptionInspector.mappableCandidates(in: offer + cellular + "\r\n" + cellular + "\r\n")
        #expect(candidates.map(\.address) == ["192.168.1.20", "10.20.30.40"])
        #expect(candidates.map(\.port) == [50_000, 50_002])
        // Nothing to forward to: an IPv6 address needs no router's help, and TCP is not used.
        let withoutIPv4 = offer.replacingOccurrences(of: "192.168.1.20 50000", with: "2a01:e0a::9 50000")
        #expect(SessionDescriptionInspector.mappableCandidates(in: withoutIPv4).isEmpty)
    }

    @Test func theForwardedPortIsAddedNextToItsLocalAddress() {
        let extended = SessionDescriptionInspector.adding(mapping, to: offer)
        let lines = extended.components(separatedBy: "\r\n")
        #expect(lines.count == offer.components(separatedBy: "\r\n").count + 1)
        #expect(lines[3] == "a=candidate:40000 1 udp 1694498815 82.64.10.20 40000 typ srflx raddr 192.168.1.20 rport 50000 generation 0 ufrag abcd network-id 1")
        // Everything else is untouched.
        #expect(lines.filter { $0 != lines[3] } == offer.components(separatedBy: "\r\n"))
        #expect(!SessionDescriptionInspector.offersRemotePath(offer.replacingOccurrences(of: "2a01:e0a:1:2::3", with: "fe80::1")))
        #expect(SessionDescriptionInspector.offersRemotePath(extended.replacingOccurrences(of: "2a01:e0a:1:2::3", with: "fe80::1")))
    }

    @Test func aMappingForAnotherAddressChangesNothing() {
        var other = mapping
        other.internalPort = 50_009
        #expect(SessionDescriptionInspector.adding(other, to: offer) == offer)
    }

    // MARK: Baby unit

    private let media = FakeNetwork()
    private let cloud = MemoryRendezvous()
    private let key = PairingKey.random()
    private let router = FakePortMapper()

    private func makeHost() -> BabyHost {
        media.offerCandidates.withLock { $0 = "\r\na=candidate:1 1 udp 2122260223 192.168.1.20 50000 typ host generation 0" }
        return BabyHost(
            makeSession: media.factory,
            listener: NoLocalListener(),
            rendezvous: RendezvousClient(provider: cloud, key: key, role: .baby),
            portMapper: router,
            timings: .fast
        )
    }

    @Test func thePublishedOfferCarriesTheRoutersPort() async throws {
        let host = makeHost()
        let access = Recorder(host.remoteAccessChanges)
        await host.start()
        #expect(await access.waitFor { $0 == .ready })

        let published = try #require(try await RendezvousClient(provider: cloud, key: key, role: .parent).fetchPeer()?.description)
        #expect(published.contains("82.64.10.20 40000 typ srflx raddr 192.168.1.20 rport 50000"))
        #expect(router.open.current.count == 1)

        // Stopping gives the port back.
        #expect(await finishes { await host.stop() })
        #expect(await eventually { router.open.current.isEmpty })
    }

    @Test func aReplacedOfferGivesItsPortBack() async throws {
        let host = makeHost()
        let access = Recorder(host.remoteAccessChanges)
        await host.start()
        #expect(await access.waitFor { $0 == .ready })

        // The network changed: the offer is replaced, and so is the port.
        await host.networkDidChange()
        #expect(await eventually { router.openedCount.current == 2 })
        #expect(await eventually { router.open.current.map(\.externalPort) == [40_001] })

        #expect(await finishes { await host.stop() })
        #expect(await eventually { router.open.current.isEmpty })
    }

    @Test func theRouterIsAskedAboutEachLocalAddressUntilOneIsItsOwn() async throws {
        router.ownNetwork.withLock { $0 = "192.168.1.20" }
        let host = makeHost()
        // The mobile network's address comes first in the offer.
        media.offerCandidates.withLock {
            $0 = "\r\na=candidate:4 1 udp 2122129151 10.20.30.40 50002 typ host generation 0" + $0
        }
        let access = Recorder(host.remoteAccessChanges)
        await host.start()
        #expect(await access.waitFor { $0 == .ready })

        let published = try #require(try await RendezvousClient(provider: cloud, key: key, role: .parent).fetchPeer()?.description)
        #expect(published.contains("82.64.10.20 40000 typ srflx raddr 192.168.1.20 rport 50000"))
        #expect(!published.contains("raddr 10.20.30.40"))
        #expect(await finishes { await host.stop() })
    }

    @Test func aRouterThatCannotHelpChangesNothing() async throws {
        router.outcome.withLock { $0 = .unsupported }
        let host = makeHost()
        let access = Recorder(host.remoteAccessChanges)
        await host.start()
        #expect(await access.waitFor { $0 == .ready })

        let published = try #require(try await RendezvousClient(provider: cloud, key: key, role: .parent).fetchPeer()?.description)
        #expect(!published.contains("srflx"))
        #expect(await finishes { await host.stop() })
    }
}

/// A local network on which no parent unit ever shows up.
struct NoLocalListener: LocalSignalingListening {
    func start() async throws -> AsyncStream<any FrameChannel> { AsyncStream { _ in } }
    func stop() async {}
}
