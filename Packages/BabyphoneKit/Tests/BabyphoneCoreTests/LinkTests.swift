import Foundation
import Testing
import TestSupport
@testable import BabyphoneCore

@Suite(.timeLimit(.minutes(1))) struct PeerLinkTests {
    private let network = FakeNetwork()

    private func connectedPair(timings: LinkTimings = .fast) async throws -> (PeerLink, PeerLink, FakeSession, FakeSession) {
        let offerer = try #require(try network.factory() as? FakeSession)
        let answerer = try #require(try network.factory() as? FakeSession)
        let first = PeerLink(session: offerer, route: .local, timings: timings)
        let second = PeerLink(session: answerer, route: .local, timings: timings)
        let answer = try await answerer.makeAnswer(to: try await offerer.makeOffer())
        try await offerer.accept(answer: answer)
        #expect(await first.waitUntilConnected(timeout: .seconds(1)))
        #expect(await second.waitUntilConnected(timeout: .seconds(1)))
        return (first, second, offerer, answerer)
    }

    /// A silence timeout a busy test machine cannot miss by accident: the fast one,
    /// 200 ms, was sometimes exceeded by a scheduling pause alone, and the link then
    /// ended as silent before the test had done anything. For every test that is not
    /// about silence itself.
    private var patientTimings: LinkTimings {
        var timings = LinkTimings.fast
        timings.silenceTimeout = .seconds(1)
        return timings
    }

    @Test func deliversPayloadsBothWays() async throws {
        let (first, second, _, _) = try await connectedPair(timings: patientTimings)
        await first.send(Data("ping".utf8))
        await second.send(Data("pong".utf8))

        #expect(await next(of: second.payloads) == Data("ping".utf8))
        #expect(await next(of: first.payloads) == Data("pong".utf8))
    }

    @Test func staysUpWhileKeepalivesFlow() async throws {
        let (first, second, _, _) = try await connectedPair(timings: patientTimings)
        // Several silence timeouts pass with no application traffic at all.
        try await Task.sleep(for: .seconds(3))
        await first.send(Data([1]))
        #expect(await next(of: second.payloads) == Data([1]))
    }

    @Test func endsWhenThePeerGoesSilent() async throws {
        let (first, second, _, _) = try await connectedPair()
        network.isReachable = false
        #expect(await value { await first.waitUntilEnded() } == .silent)
        #expect(await value { await second.waitUntilEnded() } == .silent)
    }

    @Test func endsWhenTheSessionFails() async throws {
        let (first, _, offerer, _) = try await connectedPair(timings: patientTimings)
        offerer.fail()
        #expect(await value { await first.waitUntilEnded() } == .failed)
        #expect(offerer.isClosed)
    }

    @Test func connectionAttemptTimesOut() async throws {
        let session = try network.factory()
        let link = PeerLink(session: session, route: .remote, timings: .fast)
        #expect(await link.waitUntilConnected(timeout: .milliseconds(50)) == false)
        await link.close()
        #expect(await value { await link.waitUntilEnded() } == .closed)
        #expect(await link.waitUntilConnected(timeout: .milliseconds(50)) == false)
    }
}

/// The two phones' connection logic, run against each other over a simulated network.
@Suite(.timeLimit(.minutes(1))) struct ConnectionTests {
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

        #expect(await finishes { await connector.stop() })
        #expect(await finishes { await host.stop() })
    }

    @Test func findsABabyUnitThatStartsAfterTheParentOnTheLocalNetwork() async throws {
        // The parent unit waits for an offer that never comes: only the local network can bring the baby unit.
        var timings = LinkTimings.fast
        timings.remoteWindow = .seconds(30)
        let host = makeHost(remote: false)
        let connector = ParentConnector(
            makeSession: media.factory,
            local: localNetwork,
            rendezvous: RendezvousClient(provider: cloud, key: key, role: .parent),
            timings: timings
        )
        let parentStates = Recorder(connector.states)
        // The parent unit starts first: its first look on the local network finds nobody.
        await connector.start()
        try await Task.sleep(for: .milliseconds(300))
        await host.start()

        // Long before the 30-second remote window ends: the parent unit did not wait for it.
        #expect(await parentStates.waitFor { $0 == .connected(.local) }, "parent: \(parentStates.all)")
        #expect(!parentStates.all.contains { if case .unreachable = $0 { true } else { false } })

        #expect(await finishes { await connector.stop() })
        #expect(await finishes { await host.stop() })
    }

    @Test func findsTheBabyUnitLocallyBetweenTwoRounds() async throws {
        var timings = LinkTimings.fast
        timings.retryBackoff = [.seconds(30)]
        let connector = ParentConnector(makeSession: media.factory, local: localNetwork, rendezvous: nil, timings: timings)
        let parentStates = Recorder(connector.states)
        await connector.start()
        #expect(await parentStates.waitFor { $0 == .unreachable(.rendezvousUnavailable) })

        // The next round is 30 seconds away and no retry is requested:
        // only the pause itself, looking on the local network, can find the baby unit.
        let host = makeHost(remote: false)
        await host.start()
        #expect(await parentStates.waitFor { $0 == .connected(.local) }, "parent: \(parentStates.all)")

        #expect(await finishes { await connector.stop() })
        #expect(await finishes { await host.stop() })
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

        #expect(await finishes { await connector.stop() })
        #expect(await finishes { await host.stop() })
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
        #expect(await next(of: host.payloads) == Data("hello".utf8))
        #expect(await next(of: connector.payloads) == Data("status".utf8))

        #expect(await finishes { await connector.stop() })
        #expect(await finishes { await host.stop() })
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

        #expect(await finishes { await connector.stop() })
        #expect(await finishes { await host.stop() })
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

        #expect(await finishes { await connector.stop() })
        #expect(await finishes { await host.stop() })
    }

    @Test func reportsBabyOfflineWhenNothingIsPublished() async throws {
        localNetwork.arePhonesOnSameNetwork = false
        let connector = makeConnector()
        let parentStates = Recorder(connector.states)
        await connector.start()

        #expect(await parentStates.waitFor(timeout: .seconds(10)) { $0 == .unreachable(.babyOffline) })
        #expect(await finishes { await connector.stop() })
    }

    @Test func reportsBabyOfflineAfterMonitoringStops() async throws {
        localNetwork.arePhonesOnSameNetwork = false
        let host = makeHost()
        let access = Recorder(host.remoteAccessChanges)
        await host.start()
        #expect(await access.waitFor { $0 == .ready })
        #expect(await finishes { await host.stop() })

        let connector = makeConnector()
        let parentStates = Recorder(connector.states)
        await connector.start()
        #expect(await parentStates.waitFor(timeout: .seconds(10)) { $0 == .unreachable(.babyOffline) })
        #expect(!parentStates.all.contains(.connecting(.remote)))
        #expect(await finishes { await connector.stop() })
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
        #expect(await finishes { await connector.stop() })
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

        #expect(await finishes { await connector.stop() })
        #expect(await finishes { await host.stop() })
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
        #expect(await finishes { await host.stop() })
    }

    @Test func reconnectsOnRequest() async throws {
        let host = makeHost(remote: false), connector = makeConnector(remote: false)
        let parentStates = Recorder(connector.states), hostStates = Recorder(host.states)
        await host.start()
        await connector.start()
        #expect(await parentStates.waitFor { $0 == .connected(.local) })
        #expect(await hostStates.waitFor { $0 == .connected(.local) })

        // The link answers but the picture is frozen: the app asks for a fresh connection.
        await connector.reconnect()
        #expect(await parentStates.waitForCount(2) { $0 == .connected(.local) })
        #expect(media.createdSessions.current == 4)

        #expect(await finishes { await connector.stop() })
        #expect(await finishes { await host.stop() })
    }

    @Test func twoParentsFollowTheSameBabyUnit() async throws {
        // Each parent unit has its own key, its own listener and its own connection.
        let firstNetwork = FakeLocalNetwork(), secondNetwork = FakeLocalNetwork()
        let firstHost = BabyHost(makeSession: media.factory, listener: firstNetwork, rendezvous: nil, timings: .fast)
        let secondHost = BabyHost(makeSession: media.factory, listener: secondNetwork, rendezvous: nil, timings: .fast)
        let firstParent = ParentConnector(makeSession: media.factory, local: firstNetwork, rendezvous: nil, timings: .fast)
        let secondParent = ParentConnector(makeSession: media.factory, local: secondNetwork, rendezvous: nil, timings: .fast)
        let firstStates = Recorder(firstParent.states), secondStates = Recorder(secondParent.states)
        let firstHostStates = Recorder(firstHost.states), secondHostStates = Recorder(secondHost.states)
        await firstHost.start()
        await secondHost.start()
        await firstParent.start()
        await secondParent.start()
        #expect(await firstStates.waitFor { $0 == .connected(.local) })
        #expect(await secondStates.waitFor { $0 == .connected(.local) })
        #expect(await firstHostStates.waitFor { $0 == .connected(.local) })
        #expect(await secondHostStates.waitFor { $0 == .connected(.local) })

        // One parent leaves. The other is not disturbed.
        #expect(await finishes { await firstParent.stop() })
        #expect(await firstHostStates.waitForLatest { $0 == .waiting })
        await secondHost.send(Data("still here".utf8))
        #expect(await next(of: secondParent.payloads) == Data("still here".utf8))
        #expect(secondStates.all.last == .connected(.local))

        #expect(await finishes { await secondParent.stop() })
        #expect(await finishes { await firstHost.stop() })
        #expect(await finishes { await secondHost.stop() })
    }

    @Test func stoppingTheHostDisconnectsTheParent() async throws {
        let host = makeHost(), connector = makeConnector()
        let parentStates = Recorder(connector.states), hostStates = Recorder(host.states)
        await host.start()
        await connector.start()
        #expect(await parentStates.waitFor { $0 == .connected(.local) })
        #expect(await hostStates.waitFor { $0 == .connected(.local) })

        #expect(await finishes { await host.stop() })
        #expect(await hostStates.waitForLatest { $0 == .stopped })
        #expect(await parentStates.waitForLatest(timeout: .seconds(10)) {
            if case .unreachable = $0 { true } else { false }
        })
        #expect(await finishes { await connector.stop() })
    }
}
