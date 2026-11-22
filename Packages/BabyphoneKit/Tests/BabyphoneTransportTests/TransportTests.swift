import BabyphoneCore
@testable import BabyphoneTransport
import Foundation
@preconcurrency import Network
import Testing
@preconcurrency import WebRTC

/// These tests run the real WebRTC stack and real TCP and TLS connections, inside one process.
///
/// Each has a time limit: a deadlock between threads shows up as a test that never ends,
/// and it must fail rather than hold the whole run.
@Suite(.serialized, .timeLimit(.minutes(2))) struct TransportTests {
    // MARK: WebRTC

    @Test func descriptionsListHostAddressesOnly() async throws {
        let session = try WebRTCSession(factory: TestMedia.factory)
        defer { session.close() }
        let offer = try await session.makeOffer()

        let candidates = offer.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("a=candidate:") }
        // The offer must be complete when it is returned: there is no second message to add addresses later.
        #expect(!candidates.isEmpty)
        // No STUN and no TURN: nothing but the phone's own addresses.
        #expect(candidates.allSatisfy { $0.contains(" typ host") })
        #expect(!SessionDescriptionInspector.candidateAddresses(in: offer).isEmpty)
    }

    @Test func twoSessionsConnectDirectlyAndExchangeMessages() async throws {
        let offerer = try WebRTCSession(factory: TestMedia.factory)
        let answerer = try WebRTCSession(factory: TestMedia.factory)
        let first = PeerLink(session: offerer, route: .local, timings: .quick)
        let second = PeerLink(session: answerer, route: .local, timings: .quick)

        let answer = try await answerer.makeAnswer(to: try await offerer.makeOffer())
        try await offerer.accept(answer: answer)
        #expect(await first.waitUntilConnected(timeout: .seconds(20)))
        #expect(await second.waitUntilConnected(timeout: .seconds(20)))

        await first.send(Data("from the baby unit".utf8))
        await second.send(Data("from the parent unit".utf8))
        var atParent = second.payloads.makeAsyncIterator()
        var atBaby = first.payloads.makeAsyncIterator()
        #expect(await atParent.next() == Data("from the baby unit".utf8))
        #expect(await atBaby.next() == Data("from the parent unit".utf8))

        // Statistics trail the connection by a moment.
        var path: WebRTCSession.Path?
        for _ in 0..<50 where path == nil {
            path = await offerer.selectedPath()
            if path == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(path != nil)

        // Closing one end is noticed by the other at once, without waiting for the silence timeout.
        await first.close()
        #expect(await second.waitUntilEnded() == .failed)
    }

    @Test func anOfferMadeLongBeforeItsAnswerStillConnects() async throws {
        // Away from home, the baby unit publishes its offer and may wait a long time for a parent unit.
        let offerer = try WebRTCSession(factory: TestMedia.factory)
        let answerer = try WebRTCSession(factory: TestMedia.factory)
        let first = PeerLink(session: offerer, route: .remote, timings: .quick)
        let second = PeerLink(session: answerer, route: .remote, timings: .quick)

        let offer = try await offerer.makeOffer()
        try await Task.sleep(for: .seconds(3))
        try await offerer.accept(answer: try await answerer.makeAnswer(to: offer))

        #expect(await first.waitUntilConnected(timeout: .seconds(20)))
        #expect(await second.waitUntilConnected(timeout: .seconds(20)))
        await first.close()
        await second.close()
    }

    // MARK: Secured channel

    @Test func framesCrossTheSecuredChannelInOrder() async throws {
        let key = PairingKey.random()
        let listener = try LoopbackListener(using: LocalTransport.monitorParameters(key: key))
        let port = try await listener.start()
        defer { listener.stop() }

        let client = try await LoopbackListener.connect(to: port, using: LocalTransport.monitorParameters(key: key))
        var accepted = listener.channels.makeAsyncIterator()
        let server = try #require(await accepted.next())

        let frames = [Data("first".utf8), Data(), Data(repeating: 7, count: 100_000)]
        for frame in frames {
            try await client.send(frame)
        }
        for frame in frames {
            #expect(try await server.receive(timeout: .seconds(5)) == frame)
        }
        try await server.send(Data("reply".utf8))
        #expect(try await client.receive(timeout: .seconds(5)) == Data("reply".utf8))

        client.close()
        await #expect(throws: (any Error).self) { try await server.receive(timeout: .seconds(5)) }
    }

    @Test func aPhoneWithAnotherKeyCannotOpenTheChannel() async throws {
        let listener = try LoopbackListener(using: LocalTransport.monitorParameters(key: .random()))
        let port = try await listener.start()
        defer { listener.stop() }

        await #expect(throws: (any Error).self) {
            _ = try await LoopbackListener.connect(to: port, using: LocalTransport.monitorParameters(key: .random()))
        }
    }

    // MARK: Pairing

    @Test func pairingRunsOverARealConnection() async throws {
        let host = PairingHost()
        let invitation = await host.invitation
        let listener = try LoopbackListener(using: LocalTransport.pairingParameters)
        let port = try await listener.start()
        defer { listener.stop() }

        @Sendable func servePairing() async -> PairingKey? {
            var accepted = listener.channels.makeAsyncIterator()
            guard let channel = await accepted.next() else { return nil }
            return await host.serve(channel)
        }
        async let babyKey = servePairing()
        let channel = try await LoopbackListener.connect(to: port, using: LocalTransport.pairingParameters)
        let parentKey = try await PairingProtocol.initiate(over: channel, credential: .code(invitation.code))

        #expect(await babyKey == parentKey)
    }

    // MARK: Both phones, end to end

    @Test func parentAndBabyConnectOnTheLocalNetwork() async throws {
        let key = PairingKey.random()
        let network = LoopbackSignaling(babyKey: key, parentKey: key)
        let host = BabyHost(makeSession: TestMedia.sessionFactory, listener: network, rendezvous: nil, timings: .quick)
        let connector = ParentConnector(makeSession: TestMedia.sessionFactory, local: network, rendezvous: nil, timings: .quick)
        await host.start()
        await connector.start()

        async let babyConnected = waitFor(host.states) { $0 == .connected(.local) }
        #expect(await waitFor(connector.states) { $0 == .connected(.local) })
        #expect(await babyConnected)

        // The same messages the app exchanges, through the real data channel.
        await connector.send(try WireCoding.encode(ParentMessage.setLullaby(true)))
        await host.send(try WireCoding.encode(BabyMessage.status(MonitorStatus(roomName: "Chambre"))))
        var atBaby = host.payloads.makeAsyncIterator()
        var atParent = connector.payloads.makeAsyncIterator()
        let command = try #require(await atBaby.next())
        let status = try #require(await atParent.next())
        #expect(try WireCoding.decode(ParentMessage.self, from: command) == .setLullaby(true))
        #expect(try WireCoding.decode(BabyMessage.self, from: status) == .status(MonitorStatus(roomName: "Chambre")))

        await connector.stop()
        await host.stop()
    }

    @Test func parentAndBabyConnectThroughTheRendezvous() async throws {
        let key = PairingKey.random()
        let cloud = MemoryRendezvous()
        let host = BabyHost(
            makeSession: TestMedia.sessionFactory, listener: NoLocalNetwork(),
            rendezvous: RendezvousClient(provider: cloud, key: key, role: .baby), timings: .quick
        )
        let connector = ParentConnector(
            makeSession: TestMedia.sessionFactory, local: NoLocalNetwork(),
            rendezvous: RendezvousClient(provider: cloud, key: key, role: .parent), timings: .quick
        )
        await host.start()
        await connector.start()

        async let babyConnected = waitFor(host.states) { $0 == .connected(.remote) }
        #expect(await waitFor(connector.states) { $0 == .connected(.remote) })
        #expect(await babyConnected)

        await connector.stop()
        await host.stop()
    }

    @Test func twoParentsFollowTheSameBabyUnit() async throws {
        // The baby unit runs one host per paired parent, each with its own key.
        let keys = [PairingKey.random(), PairingKey.random()]
        var hosts: [BabyHost] = [], connectors: [ParentConnector] = []
        for key in keys {
            let network = LoopbackSignaling(babyKey: key, parentKey: key)
            hosts.append(BabyHost(makeSession: TestMedia.sessionFactory, listener: network, rendezvous: nil, timings: .quick))
            connectors.append(ParentConnector(makeSession: TestMedia.sessionFactory, local: network, rendezvous: nil, timings: .quick))
        }
        for host in hosts { await host.start() }
        for connector in connectors { await connector.start() }

        for connector in connectors {
            #expect(await waitFor(connector.states) { $0 == .connected(.local) })
        }
        // Both are served at once, each over its own connection.
        for (index, host) in hosts.enumerated() {
            await host.send(Data("for parent \(index)".utf8))
        }
        for (index, connector) in connectors.enumerated() {
            var received = connector.payloads.makeAsyncIterator()
            #expect(await received.next() == Data("for parent \(index)".utf8))
        }

        for connector in connectors { await connector.stop() }
        for host in hosts { await host.stop() }
    }

    @Test func aParentWithAnotherKeyNeverConnects() async throws {
        let network = LoopbackSignaling(babyKey: .random(), parentKey: .random())
        let host = BabyHost(makeSession: TestMedia.sessionFactory, listener: network, rendezvous: nil, timings: .quick)
        let connector = ParentConnector(makeSession: TestMedia.sessionFactory, local: network, rendezvous: nil, timings: .quick)
        await host.start()
        await connector.start()

        #expect(await waitFor(connector.states) { if case .unreachable = $0 { true } else { false } })

        await connector.stop()
        await host.stop()
    }
}

/// Bonjour needs a real local network and the permission to use it, which a
/// build server may not have. These run on a developer's Mac.
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil)) struct BonjourTests {
    @Test func parentFindsItsOwnBabyUnit() async throws {
        let key = PairingKey.random()
        let ours = BonjourSignalingListener(key: key)
        let neighbour = BonjourSignalingListener(key: .random())
        let channels = try await ours.start()
        _ = try await neighbour.start()

        let channel = try await BonjourSignalingConnector(key: key).connect(timeout: .seconds(8))
        var accepted = channels.makeAsyncIterator()
        let server = try #require(await accepted.next())
        try await channel.send(Data("hello".utf8))
        #expect(try await server.receive(timeout: .seconds(5)) == Data("hello".utf8))

        channel.close()
        await ours.stop()
        await neighbour.stop()
    }

    @Test func pairingFindsTheBabyUnitNearby() async throws {
        let host = PairingHost()
        let paired = AsyncStream.makeStream(of: PairingKey.self)
        let listener = PairingListener(host: host, onPaired: { paired.continuation.yield($0) }, onUnavailable: {})
        try listener.start()
        defer { listener.stop() }

        let code = await host.invitation.code
        let parentKey = try await PairingClient.pair(using: .code(code))
        var keys = paired.stream.makeAsyncIterator()
        #expect(await keys.next() == parentKey)
    }
}
