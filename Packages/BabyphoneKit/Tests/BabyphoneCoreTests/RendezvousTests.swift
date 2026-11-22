import Foundation
import Testing
import TestSupport
@testable import BabyphoneCore

@Suite struct RendezvousTests {
    private let provider = MemoryRendezvous()
    private let key = PairingKey.random()

    @Test func peerReadsWhatTheOtherPublished() async throws {
        let baby = RendezvousClient(provider: provider, key: key, role: .baby)
        let parent = RendezvousClient(provider: provider, key: key, role: .parent)
        let offer = EndpointAdvertisement(description: "v=0 a=candidate 2a01::1", publishedAt: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(try await parent.fetchPeer() == nil)
        try await baby.publish(offer)
        #expect(try await parent.fetchPeer() == offer)
        #expect(try await baby.fetchPeer() == nil)
    }

    @Test func providerOnlySeesCiphertextUnderAnOpaqueName() async throws {
        let baby = RendezvousClient(provider: provider, key: key, role: .baby)
        try await baby.publish(EndpointAdvertisement(description: "2a01:e0a:1:2::3"))

        let (name, record) = try #require(provider.records.current.first)
        #expect(name == "\(key.rendezvousID).baby")
        #expect(record.range(of: Data("2a01".utf8)) == nil)
        #expect(!name.contains(key.rawValue.hexString))
    }

    @Test func recordsFromAnotherPairAreIgnored() async throws {
        let stranger = RendezvousClient(provider: provider, key: .random(), role: .baby)
        try await stranger.publish(EndpointAdvertisement(description: "offer"))

        // Same slot name as ours, encrypted with someone else's key.
        let ours = RendezvousSlot(pairID: key.rendezvousID, role: .baby)
        provider.records.withLock { records in
            records[ours.name] = records.values.first
        }
        let parent = RendezvousClient(provider: provider, key: key, role: .parent)
        #expect(try await parent.fetchPeer() == nil)
    }

    @Test func aRecordCannotBeReplayedIntoTheOtherSlot() async throws {
        let baby = RendezvousClient(provider: provider, key: key, role: .baby)
        try await baby.publish(EndpointAdvertisement(description: "offer"))

        // Someone copies the baby unit's record into the parent unit's slot.
        let babySlot = RendezvousSlot(pairID: key.rendezvousID, role: .baby)
        let parentSlot = RendezvousSlot(pairID: key.rendezvousID, role: .parent)
        provider.records.withLock { $0[parentSlot.name] = $0[babySlot.name] }

        #expect(try await baby.fetchPeer() == nil)
    }
}
