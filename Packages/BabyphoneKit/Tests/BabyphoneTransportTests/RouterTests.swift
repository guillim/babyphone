import BabyphoneCore
@testable import BabyphoneTransport
import Foundation
@preconcurrency import Network
import Testing
import TestSupport

/// A home router on the loopback interface. It answers NAT-PMP, the UPnP search and the UPnP commands,
/// and keeps the list of the ports it forwards.
final class FakeRouter: @unchecked Sendable {
    /// Forwarded ports: external port to internal port.
    let forwarded = Locked([UInt16: UInt16]())
    /// External ports already given to another device.
    let taken = Locked(Set<UInt16>())
    private let externalAddress: String
    private let speaksNATPMP: Bool
    private let speaksUPnP: Bool
    private let queue = DispatchQueue(label: "nid.fake-router")
    private var listeners: [NWListener] = []
    private var httpPort: UInt16 = 0

    /// A port on which nothing listens.
    private static let silentPort: UInt16 = 9

    private(set) var natPMPPort = FakeRouter.silentPort
    private(set) var searchPort = FakeRouter.silentPort

    init(externalAddress: String = "82.64.10.20", speaksNATPMP: Bool = true, speaksUPnP: Bool = true) {
        self.externalAddress = externalAddress
        self.speaksNATPMP = speaksNATPMP
        self.speaksUPnP = speaksUPnP
    }

    func start() async throws {
        if speaksNATPMP {
            natPMPPort = try await listen(.udp) { [self] connection in
                answerDatagrams(on: connection, with: natPMPReply)
            }
        }
        if speaksUPnP {
            httpPort = try await listen(.tcp) { [self] connection in
                serve(connection, received: Data())
            }
            searchPort = try await listen(.udp) { [self] connection in
                answerDatagrams(on: connection, with: searchReply)
            }
        }
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners = []
    }

    /// The mapper that talks to this router.
    func makeMapper() -> RouterPortMapper {
        RouterPortMapper(gateway: "127.0.0.1", natPMPPort: natPMPPort, searchPort: searchPort, searchesGroup: false)
    }

    private func listen(_ parameters: NWParameters, handle: @escaping @Sendable (NWConnection) -> Void) async throws -> UInt16 {
        let listener = try NWListener(using: parameters)
        listeners.append(listener)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            handle(connection)
        }
        return try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<UInt16, any Error>) in
            let ready = SingleResume(waiting)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready(.success(listener.port?.rawValue ?? 0))
                case .failed(let error): ready(.failure(error))
                default: break
                }
            }
            listener.start(queue: queue)
            // A listener that never becomes ready must not hold the test.
            queue.asyncAfter(deadline: .now() + 5) { ready(.failure(LocalNetworkError.notFound)) }
        }
    }

    // MARK: Datagrams

    private func answerDatagrams(on connection: NWConnection, with reply: @escaping @Sendable (Data) -> Data?) {
        connection.receiveMessage { [self] data, _, _, error in
            guard error == nil, let data else {
                connection.cancel()
                return
            }
            if let answer = reply(data) {
                connection.send(content: answer, completion: .contentProcessed { _ in })
            }
            answerDatagrams(on: connection, with: reply)
        }
    }

    private func natPMPReply(to request: Data) -> Data? {
        let bytes = [UInt8](request)
        if bytes == [0, 0] {
            return Data([0, 128, 0, 0, 0, 0, 0, 1] + externalAddress.split(separator: ".").compactMap { UInt8($0) })
        }
        guard bytes.count == 12, bytes[0] == 0, bytes[1] == 1 else { return nil }
        let internalPort = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        var externalPort = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let lifetime = Array(bytes[8..<12])
        if lifetime == [0, 0, 0, 0] {
            forwarded.withLock { ports in ports = ports.filter { $0.value != internalPort } }
            externalPort = 0
        } else {
            forwarded.withLock { $0[externalPort] = internalPort }
        }
        return Data([0, 129, 0, 0, 0, 0, 0, 1, bytes[4], bytes[5], UInt8(externalPort >> 8), UInt8(externalPort & 0xff)] + lifetime)
    }

    private func searchReply(to request: Data) -> Data? {
        guard String(decoding: request, as: UTF8.self).hasPrefix("M-SEARCH") else { return nil }
        return Data("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nLOCATION: http://127.0.0.1:\(httpPort)/rootDesc.xml\r\nST: upnp:rootdevice\r\n\r\n".utf8)
    }

    // MARK: HTTP

    private func serve(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            let all = received + (data ?? Data())
            guard let request = Self.request(in: all) else {
                if isComplete || error != nil { connection.cancel() } else { serve(connection, received: all) }
                return
            }
            let (status, body) = respond(toPath: request.path, body: request.body)
            let head = "HTTP/1.1 \(status)\r\nContent-Type: text/xml\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// The path and body of a request, once all of it has arrived.
    private static func request(in data: Data) -> (path: String, body: String)? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
        let body = data[separator.upperBound...]
        let length = head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        guard body.count >= length else { return nil }
        let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return (path, String(decoding: body, as: UTF8.self))
    }

    private func respond(toPath path: String, body: String) -> (status: String, body: String) {
        if path == "/rootDesc.xml" {
            return ("200 OK", """
                <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device><deviceList><device><deviceList><device>
                <serviceList><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
                <controlURL>/ctl/IPConn</controlURL></service></serviceList></device></deviceList></device></deviceList></device></root>
                """)
        }
        guard path == "/ctl/IPConn" else { return ("404 Not Found", "") }
        func number(_ tag: String) -> UInt16 {
            guard let start = body.range(of: "<\(tag)>"), let end = body.range(of: "</\(tag)>") else { return 0 }
            return UInt16(body[start.upperBound..<end.lowerBound]) ?? 0
        }
        func envelope(_ content: String) -> String {
            "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body>\(content)</s:Body></s:Envelope>"
        }
        if body.contains("GetExternalIPAddress") {
            return ("200 OK", envelope("<u:GetExternalIPAddressResponse><NewExternalIPAddress>\(externalAddress)</NewExternalIPAddress></u:GetExternalIPAddressResponse>"))
        }
        if body.contains("AddPortMapping") {
            let externalPort = number("NewExternalPort")
            guard !taken.current.contains(externalPort) else {
                return ("500 Internal Server Error", envelope("<s:Fault><detail><UPnPError><errorCode>718</errorCode></UPnPError></detail></s:Fault>"))
            }
            forwarded.withLock { $0[externalPort] = number("NewInternalPort") }
            return ("200 OK", envelope("<u:AddPortMappingResponse/>"))
        }
        if body.contains("DeletePortMapping") {
            forwarded.withLock { $0[number("NewExternalPort")] = nil }
            return ("200 OK", envelope("<u:DeletePortMappingResponse/>"))
        }
        return ("500 Internal Server Error", envelope("<s:Fault><detail><UPnPError><errorCode>401</errorCode></UPnPError></detail></s:Fault>"))
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) struct RouterTests {
    @Test func theDefaultRouterIsTheOneTheSystemUses() throws {
        // `route` prints the default route as the system sees it.
        let route = Process()
        route.executableURL = URL(fileURLWithPath: "/sbin/route")
        route.arguments = ["-n", "get", "default"]
        let output = Pipe()
        route.standardOutput = output
        route.standardError = Pipe()
        try route.run()
        route.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let expected = text.components(separatedBy: "\n")
            .first { $0.contains("gateway:") }?
            .components(separatedBy: "gateway:").last?
            .trimmingCharacters(in: .whitespaces)

        let found = DefaultGateway.current()
        if let expected, AddressScope.of(expected) != .unknown, !expected.contains(":") {
            #expect(found == expected)
        } else {
            // A machine with no IPv4 router: nothing to find, and nothing made up.
            #expect(found == nil || AddressScope.of(found ?? "") != .unknown)
        }
    }

    @Test func aRouterThatSpeaksNATPMPOpensAndClosesAPort() async throws {
        let router = FakeRouter()
        try await router.start()
        defer { router.stop() }
        let mapper = router.makeMapper()

        let outcome = try #require(await value(within: .seconds(20)) {
            await mapper.open(internalAddress: "192.168.1.20", internalPort: 50_000)
        })
        guard case .mapped(let mapping) = outcome else {
            Issue.record("No port was opened: \(outcome)")
            return
        }
        #expect(mapping.method == .natPMP)
        #expect(mapping.externalAddress == "82.64.10.20")
        #expect(mapping.externalPort == 50_000)
        #expect(router.forwarded.current == [50_000: 50_000])

        #expect(await finishes(within: .seconds(20)) { await mapper.close(mapping) })
        #expect(router.forwarded.current.isEmpty)
    }

    @Test func aRouterThatOnlySpeaksUPnPOpensAndClosesAPort() async throws {
        let router = FakeRouter(speaksNATPMP: false)
        try await router.start()
        defer { router.stop() }
        let mapper = router.makeMapper()

        let outcome = try #require(await value(within: .seconds(30)) {
            await mapper.open(internalAddress: "192.168.1.20", internalPort: 50_000)
        })
        guard case .mapped(let mapping) = outcome else {
            Issue.record("No port was opened: \(outcome)")
            return
        }
        #expect(mapping.method == .upnp)
        #expect(mapping.externalAddress == "82.64.10.20")
        #expect(router.forwarded.current == [50_000: 50_000])

        #expect(await finishes(within: .seconds(20)) { await mapper.close(mapping) })
        #expect(router.forwarded.current.isEmpty)
    }

    @Test func anotherPortIsTakenWhenTheFirstChoiceIsNotFree() async throws {
        let router = FakeRouter(speaksNATPMP: false)
        router.taken.withLock { $0 = [50_000] }
        try await router.start()
        defer { router.stop() }

        let outcome = try #require(await value(within: .seconds(30)) {
            await router.makeMapper().open(internalAddress: "192.168.1.20", internalPort: 50_000)
        })
        guard case .mapped(let mapping) = outcome else {
            Issue.record("No port was opened: \(outcome)")
            return
        }
        #expect(mapping.externalPort != 50_000)
        #expect(router.forwarded.current == [mapping.externalPort: 50_000])
    }

    @Test func aRouterBehindASharedAddressIsReportedAndLeftAlone() async throws {
        for speaksNATPMP in [true, false] {
            let router = FakeRouter(externalAddress: "100.64.1.2", speaksNATPMP: speaksNATPMP)
            try await router.start()
            defer { router.stop() }

            let outcome = await value(within: .seconds(30)) {
                await router.makeMapper().open(internalAddress: "192.168.1.20", internalPort: 50_000)
            }
            #expect(outcome == .sharedAddress("100.64.1.2"))
            #expect(router.forwarded.current.isEmpty)
        }
    }

    @Test func aRouterThatSpeaksNeitherIsGivenUpOnQuickly() async throws {
        let router = FakeRouter(speaksNATPMP: false, speaksUPnP: false)
        let mapper = router.makeMapper()

        let first = await value(within: .seconds(15)) { await mapper.open(internalAddress: "192.168.1.20", internalPort: 50_000) }
        #expect(first == .unsupported)
        // It is not asked again for a while: the answer comes at once.
        let second = await value(within: .seconds(1)) { await mapper.open(internalAddress: "192.168.1.20", internalPort: 50_001) }
        #expect(second == .unsupported)
    }
}
