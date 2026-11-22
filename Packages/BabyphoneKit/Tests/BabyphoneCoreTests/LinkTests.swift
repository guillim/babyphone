import Foundation
import Testing
@testable import BabyphoneCore

@Suite struct PeerLinkTests {
    private let network = FakeNetwork()

    private func connectedPair() async throws -> (PeerLink, PeerLink, FakeSession, FakeSession) {
        let offerer = try #require(try network.factory() as? FakeSession)
        let answerer = try #require(try network.factory() as? FakeSession)
        let first = PeerLink(session: offerer, route: .local, timings: .fast)
        let second = PeerLink(session: answerer, route: .local, timings: .fast)
        let answer = try await answerer.makeAnswer(to: try await offerer.makeOffer())
        try await offerer.accept(answer: answer)
        #expect(await first.waitUntilConnected(timeout: .seconds(1)))
        #expect(await second.waitUntilConnected(timeout: .seconds(1)))
        return (first, second, offerer, answerer)
    }

    @Test func deliversPayloadsBothWays() async throws {
        let (first, second, _, _) = try await connectedPair()
        await first.send(Data("ping".utf8))
        await second.send(Data("pong".utf8))

        var received = second.payloads.makeAsyncIterator()
        #expect(await received.next() == Data("ping".utf8))
        var replied = first.payloads.makeAsyncIterator()
        #expect(await replied.next() == Data("pong".utf8))
    }

    @Test func staysUpWhileKeepalivesFlow() async throws {
        let (first, second, _, _) = try await connectedPair()
        // Several silence timeouts pass with no application traffic at all.
        try await Task.sleep(for: .milliseconds(700))
        await first.send(Data([1]))
        var received = second.payloads.makeAsyncIterator()
        #expect(await received.next() == Data([1]))
    }

    @Test func endsWhenThePeerGoesSilent() async throws {
        let (first, second, _, _) = try await connectedPair()
        network.isReachable = false
        #expect(await first.waitUntilEnded() == .silent)
        #expect(await second.waitUntilEnded() == .silent)
    }

    @Test func endsWhenTheSessionFails() async throws {
        let (first, _, offerer, _) = try await connectedPair()
        offerer.fail()
        #expect(await first.waitUntilEnded() == .failed)
        #expect(offerer.isClosed)
    }

    @Test func connectionAttemptTimesOut() async throws {
        let session = try network.factory()
        let link = PeerLink(session: session, route: .remote, timings: .fast)
        #expect(await link.waitUntilConnected(timeout: .milliseconds(50)) == false)
        await link.close()
        #expect(await link.waitUntilEnded() == .closed)
        #expect(await link.waitUntilConnected(timeout: .milliseconds(50)) == false)
    }
}

/// The two phones' connection logic, run against each other over a simulated network.
@Suite struct ConnectionTests {
    private let media = FakeNetwork()
    private let localNetwork = FakeLocalNetwork()
    private let cloud = MemoryRendezvous()
    private let key = PairingKey.random()

    private func makeHost(remote: Bool = true) -> BabyHost {
        BabyHost(
            makeSession: media.factory,
            listener: localNetwork,
            rendezvous: remote ? RendezvousClient(provider: cloud, key: key, role: .baby) : nil,
            timings: .fast
        )
    }

    private func makeConnector(remote: Bool = true) -> ParentConnector {
        ParentConnector(
            makeSession: media.factory,
            local: localNetwork,
            rendezvous: remote ? RendezvousClient(provider: cloud, key: key, role: .parent) : nil,
            timings: .fast
        )
    }

    @Test func connectsOnTheLocalNetworkWithoutAnyRendezvous() async throws {
        let host = makeHost(remote: false), connector = makeConnector(remote: false)
        let hostStates = Recorder(host.states), parentStates = Recorder(connector.states)
        await host.start()
        await connector.start()

        #expect(await parentStates.waitFor { $0 == .connected(.local) })
        #expect(await hostStates.waitFor { $0 == .connected(.local) })
        #expect(cloud.publishCount.current == 0)

        await connector.stop()
        await host.stop()
    }

    @Test func connectsRemotelyWhenThePhonesAreOnDifferentNetworks() async throws {
        localNetwork.arePhonesOnSameNetwork = false
        let host = makeHost(), connector = makeConnector()
        let hostStates = Recorder(host.states), parentStates = Recorder(connector.states)
        let access = Recorder(host.remoteAccessChanges)
        await host.start()
        #expect(await access.waitFor { $0 == .ready })
        await connector.start()

        #expect(await parentStates.waitFor { $0 == .connected(.remote) })
        #expect(await hostStates.waitFor { $0 == .connected(.remote) })
        #expect(parentStates.all.contains(.connecting(.remote)))

        await connector.stop()
        await host.stop()
    }

    @Test func messagesFlowBothWaysOnceConnected() async throws {
        let host = makeHost(), connector = makeConnector()
        let parentStates = Recorder(connector.states), hostStates = Recorder(host.states)
        await host.start()
        await connector.start()
        #expect(await parentStates.waitFor { $0 == .connected(.local) })
        #expect(await hostStates.waitFor { $0 == .connected(.local) })

        await connector.send(Data("hello".utf8))
        await host.send(Data("status".utf8))
        var atHost = host.payloads.makeAsyncIterator()
        var atParent = connector.payloads.makeAsyncIterator()
        #expect(await atHost.next() == Data("hello".utf8))
        #expect(await atParent.next() == Data("status".utf8))

        await connector.stop()
        await host.stop()
    }

    @Test func reconnectsRemotelyAfterLeavingTheLocalNetwork() async throws {
        let host = makeHost(), connector = makeConnector()
        let hostStates = Recorder(host.states), parentStates = Recorder(connector.states)
        await host.start()
        await connector.start()
        #expect(await parentStates.waitFor { $0 == .connected(.local) })
        #expect(await hostStates.waitFor { $0 == .connected(.local) })

        // The parent walks out of the house: the link dies, then the network comes back elsewhere.
        localNetwork.arePhonesOnSameNetwork = false
        media.isReachable = false
        #expect(await hostStates.waitForLatest { $0 == .waiting })
        media.isReachable = true

        #expect(await parentStates.waitForLatest { $0 == .connected(.remote) }, "parent: \(parentStates.all)")
        #expect(await hostStates.waitForLatest { $0 == .connected(.remote) }, "host: \(hostStates.all)")

        await connector.stop()
        await host.stop()
    }

    @Test func reportsNoDirectPathWhenAddressesAreKnownButPacketsDoNotPass() async throws {
        localNetwork.arePhonesOnSameNetwork = false
        media.isReachable = false
        let host = makeHost(), connector = makeConnector()
        let parentStates = Recorder(connector.states), access = Recorder(host.remoteAccessChanges)
        await host.start()
        #expect(await access.waitFor { $0 == .ready })
        await connector.start()

        #expect(await parentStates.waitFor(timeout: .seconds(10)) { $0 == .unreachable(.noDirectPath) })

        // The firewall opens: the next attempt goes through without any user action.
        media.isReachable = true
        #expect(await parentStates.waitFor(timeout: .seconds(10)) { $0 == .connected(.remote) })

        await connector.stop()
        await host.stop()
    }

    @Test func reportsBabyOfflineWhenNothingIsPublished() async throws {
        localNetwork.arePhonesOnSameNetwork = false
        let connector = makeConnector()
        let parentStates = Recorder(connector.states)
        await connector.start()

        #expect(await parentStates.waitFor(timeout: .seconds(10)) { $0 == .unreachable(.babyOffline) })
        await connector.stop()
    }

    @Test func reportsBabyOfflineAfterMonitoringStops() async throws {
        localNetwork.arePhonesOnSameNetwork = false
        let host = makeHost()
        let access = Recorder(host.remoteAccessChanges)
        await host.start()
        #expect(await access.waitFor { $0 == .ready })
        await host.stop()

        let connector = makeConnector()
        let parentStates = Recorder(connector.states)
        await connector.start()
        #expect(await parentStates.waitFor(timeout: .seconds(10)) { $0 == .unreachable(.babyOffline) })
        #expect(!parentStates.all.contains(.connecting(.remote)))
        await connector.stop()
    }

    @Test func ignoresAbandonedOffers() async throws {
        localNetwork.arePhonesOnSameNetwork = false
        // An offer left behind by a baby unit that crashed a long time ago.
        let baby = RendezvousClient(provider: cloud, key: key, role: .baby)
        try await baby.publish(EndpointAdvertisement(
            description: "offer:gone", publishedAt: Date().addingTimeInterval(-3600)
        ))

        let connector = makeConnector()
        let parentStates = Recorder(connector.states)
        await connector.start()
        #expect(await parentStates.waitFor(timeout: .seconds(10)) { $0 == .unreachable(.babyOffline) })
        #expect(media.createdSessions.current == 0)
        await connector.stop()
    }

    @Test func reportsRendezvousUnavailableWithoutAnAccount() async throws {
        localNetwork.arePhonesOnSameNetwork = false
        cloud.currentAvailability = .noAccount
        let host = makeHost(), connector = makeConnector()
        let parentStates = Recorder(connector.states), access = Recorder(host.remoteAccessChanges)
        await host.start()
        await connector.start()

        #expect(await access.waitFor { $0 == .noAccount })
        #expect(await parentStates.waitFor { $0 == .unreachable(.rendezvousUnavailable) })
        #expect(cloud.publishCount.current == 0)

        // Back on the same network, the local path works with no account at all.
        localNetwork.arePhonesOnSameNetwork = true
        await connector.retryNow()
        #expect(await parentStates.waitFor { $0 == .connected(.local) })

        await connector.stop()
        await host.stop()
    }

    @Test func babyUnitReplacesItsOfferWhenItsNetworkChanges() async throws {
        localNetwork.arePhonesOnSameNetwork = false
        let host = makeHost()
        let access = Recorder(host.remoteAccessChanges)
        let parent = RendezvousClient(provider: cloud, key: key, role: .parent)
        await host.start()
        #expect(await access.waitFor { $0 == .ready })
        let first = try #require(try await parent.fetchPeer())

        await host.networkDidChange()
        var second = first
        let deadline = ContinuousClock.now + .seconds(5)
        while second.sessionID == first.sessionID, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            second = try #require(try await parent.fetchPeer())
        }
        #expect(second.sessionID != first.sessionID)
        #expect(second.description != nil)
        await host.stop()
    }

    @Test func stoppingTheHostDisconnectsTheParent() async throws {
        let host = makeHost(), connector = makeConnector()
        let parentStates = Recorder(connector.states), hostStates = Recorder(host.states)
        await host.start()
        await connector.start()
        #expect(await parentStates.waitFor { $0 == .connected(.local) })
        #expect(await hostStates.waitFor { $0 == .connected(.local) })

        await host.stop()
        #expect(await hostStates.waitForLatest { $0 == .stopped })
        #expect(await parentStates.waitForLatest(timeout: .seconds(10)) {
            if case .unreachable = $0 { true } else { false }
        })
        await connector.stop()
    }
}
