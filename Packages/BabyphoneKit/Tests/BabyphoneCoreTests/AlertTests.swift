import Foundation
import Testing
import TestSupport
@testable import BabyphoneCore

@Suite(.timeLimit(.minutes(1))) struct AlertTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Alert policy

    @Test func aPauseQuietensNoiseAndCryingForItsLength() {
        var policy = AlertPolicy()
        #expect(policy.rings(.noise, at: start, isCryDetectionActive: false))

        policy.snooze(minutes: 10, from: start)
        #expect(policy.isSnoozed(at: start.addingTimeInterval(599)))
        #expect(!policy.rings(.noise, at: start.addingTimeInterval(599), isCryDetectionActive: false))
        #expect(!policy.rings(.cry, at: start.addingTimeInterval(599), isCryDetectionActive: true))
        // The banner still shows: only the sound is paused.
        #expect(policy.shows(.noise, isCryDetectionActive: false))

        #expect(!policy.isSnoozed(at: start.addingTimeInterval(600)))
        #expect(policy.rings(.noise, at: start.addingTimeInterval(600), isCryDetectionActive: false))
    }

    @Test func aPauseNeverQuietensALostLinkOrAPowerProblem() {
        var policy = AlertPolicy()
        policy.snooze(minutes: 60, from: start)
        #expect(policy.rings(.linkLost, at: start, isCryDetectionActive: false))
        #expect(policy.rings(.power, at: start, isCryDetectionActive: false))
    }

    @Test func resumingEndsThePause() {
        var policy = AlertPolicy()
        policy.snooze(minutes: 30, from: start)
        policy.resume()
        #expect(policy.snoozedUntil == nil)
        #expect(policy.rings(.cry, at: start, isCryDetectionActive: true))
    }

    @Test func cryingOnlyHidesOtherNoise() {
        let policy = AlertPolicy(trigger: .cryOnly)
        #expect(!policy.shows(.noise, isCryDetectionActive: true))
        #expect(!policy.rings(.noise, at: start, isCryDetectionActive: true))
        #expect(policy.rings(.cry, at: start, isCryDetectionActive: true))
    }

    @Test func cryingOnlyFallsBackToAnyNoiseWhenTheBabyUnitCannotRecogniseCrying() {
        let policy = AlertPolicy(trigger: .cryOnly)
        #expect(policy.shows(.noise, isCryDetectionActive: false))
        #expect(policy.rings(.noise, at: start, isCryDetectionActive: false))
    }

    // MARK: Cry detector

    @Test func oneConfidentReadingIsNotACry() {
        var detector = CryDetector()
        #expect(detector.ingest(confidence: 0.9, at: start) == nil)
        #expect(detector.ingest(confidence: 0.1, at: start.addingTimeInterval(0.5)) == nil)
        #expect(detector.ingest(confidence: 0.9, at: start.addingTimeInterval(3)) == nil)
        #expect(!detector.isCrying)
    }

    @Test func confidenceThatHoldsStartsACryDatedFromItsFirstReading() {
        var detector = CryDetector()
        #expect(detector.ingest(confidence: 0.7, at: start) == nil)
        #expect(detector.ingest(confidence: 0.8, at: start.addingTimeInterval(0.5)) == nil)
        #expect(detector.ingest(confidence: 0.8, at: start.addingTimeInterval(1)) == .started(at: start))
        #expect(detector.isCrying)
    }

    @Test func breathsBetweenSobsStayInTheSameCry() {
        var detector = CryDetector()
        _ = detector.ingest(confidence: 0.9, at: start)
        _ = detector.ingest(confidence: 0.9, at: start.addingTimeInterval(1))
        // Five quiet seconds, then crying again.
        #expect(detector.ingest(confidence: 0.05, at: start.addingTimeInterval(6)) == nil)
        #expect(detector.ingest(confidence: 0.5, at: start.addingTimeInterval(7)) == nil)
        #expect(detector.isCrying)
    }

    @Test func aLongQuietEndsTheCryAtItsLastSound() {
        var detector = CryDetector()
        _ = detector.ingest(confidence: 0.9, at: start)
        _ = detector.ingest(confidence: 0.9, at: start.addingTimeInterval(1))
        _ = detector.ingest(confidence: 0.4, at: start.addingTimeInterval(20))
        #expect(detector.ingest(confidence: 0.1, at: start.addingTimeInterval(24)) == nil)
        #expect(detector.ingest(confidence: 0.1, at: start.addingTimeInterval(28)) == .ended(startedAt: start, duration: 20))
        #expect(!detector.isCrying)
    }

    @Test func finishClosesACryInProgress() {
        var detector = CryDetector()
        #expect(detector.finish() == nil)
        _ = detector.ingest(confidence: 0.9, at: start)
        _ = detector.ingest(confidence: 0.9, at: start.addingTimeInterval(2))
        #expect(detector.finish() == .ended(startedAt: start, duration: 2))
        #expect(detector.finish() == nil)
    }

    // MARK: Alerts through the rendezvous provider

    private let provider = MemoryRendezvous()
    private let key = PairingKey.random()

    private func event(_ kind: JournalEvent.Kind, secondsAgo: TimeInterval, from now: Date) -> JournalEvent {
        JournalEvent(kind: kind, origin: .baby, date: now.addingTimeInterval(-secondsAgo))
    }

    @Test func theParentUnitReadsTheBabyUnitsDigest() async throws {
        let beacon = AlertBeacon(rendezvous: RendezvousClient(provider: provider, key: key, role: .baby))
        let parent = RendezvousClient(provider: provider, key: key, role: .parent)
        let noise = event(.noise, secondsAgo: 5, from: start)

        await beacon.publish(isMonitoring: true, status: MonitorStatus(roomName: "Chambre"), events: [noise], now: start)
        await beacon.flush()

        let digest = try #require(try await parent.fetchPeerAlerts())
        #expect(digest.isMonitoring)
        #expect(digest.status?.roomName == "Chambre")
        #expect(digest.events == [noise])
        #expect(digest.publishedAt == start)
    }

    @Test func theDigestIsEncryptedAndKeptApartFromTheAddresses() async throws {
        let baby = RendezvousClient(provider: provider, key: key, role: .baby)
        try await baby.publish(EndpointAdvertisement(description: "offer"))
        let beacon = AlertBeacon(rendezvous: baby)
        await beacon.publish(isMonitoring: true, status: MonitorStatus(roomName: "Chambre de Lou"), events: [], now: start)
        await beacon.flush()

        let records = provider.records.current
        #expect(Set(records.keys) == ["\(key.rendezvousID).baby", "\(key.rendezvousID).baby.alerts"])
        #expect(records.values.allSatisfy { $0.range(of: Data("Lou".utf8)) == nil })
        // One record cannot be passed off as the other.
        provider.records.withLock { $0["\(key.rendezvousID).baby.alerts"] = $0["\(key.rendezvousID).baby"] }
        #expect(try await RendezvousClient(provider: provider, key: key, role: .parent).fetchPeerAlerts() == nil)
    }

    @Test func aDigestOnlyCarriesRecentEventsAndTheLatestOfThem() async throws {
        let beacon = AlertBeacon(rendezvous: RendezvousClient(provider: provider, key: key, role: .baby))
        let old = event(.noise, secondsAgo: AlertDigest.eventWindow + 1, from: start)
        let recent = (0..<AlertDigest.eventLimit + 3).map { event(.noise, secondsAgo: TimeInterval(600 - $0), from: start) }

        await beacon.publish(isMonitoring: true, status: nil, events: [old] + recent, now: start)
        await beacon.flush()

        let digest = try #require(try await RendezvousClient(provider: provider, key: key, role: .parent).fetchPeerAlerts())
        #expect(digest.events == Array(recent.suffix(AlertDigest.eventLimit)))
    }

    @Test func theLastDigestHandedOverIsTheOneThatStays() async throws {
        let beacon = AlertBeacon(rendezvous: RendezvousClient(provider: provider, key: key, role: .baby))
        for round in 1...20 {
            await beacon.publish(isMonitoring: round < 20, status: nil, events: [], now: start.addingTimeInterval(TimeInterval(round)))
        }
        await beacon.flush()

        let digest = try #require(try await RendezvousClient(provider: provider, key: key, role: .parent).fetchPeerAlerts())
        #expect(digest.sequence == 20)
        #expect(!digest.isMonitoring)
    }

    @Test func theWatchReportsEachNewDigestOnce() async throws {
        let beacon = AlertBeacon(rendezvous: RendezvousClient(provider: provider, key: key, role: .baby))
        let watch = AlertWatch(
            rendezvous: RendezvousClient(provider: provider, key: key, role: .parent), interval: .milliseconds(20)
        )
        let digests = Recorder(watch.digests)
        let states = Recorder(watch.states)

        await watch.start()
        // Nothing published yet: the watch says so and keeps looking.
        #expect(await states.waitFor { $0 == .unavailable })

        await beacon.publish(isMonitoring: true, status: nil, events: [], now: start)
        #expect(await states.waitFor { $0 == .receiving })
        #expect(await digests.waitForCount(1) { _ in true })

        // The same digest read again and again is not news.
        try await Task.sleep(for: .milliseconds(150))
        #expect(digests.all.count == 1)

        await beacon.publish(isMonitoring: false, status: nil, events: [], now: start.addingTimeInterval(60))
        #expect(await digests.waitForCount(2) { _ in true })
        #expect(digests.all.last?.isMonitoring == false)

        await watch.stop()
        #expect(await states.waitFor { $0 == .off })
    }

    @Test func aStoppedWatchReadsNothingMore() async throws {
        let beacon = AlertBeacon(rendezvous: RendezvousClient(provider: provider, key: key, role: .baby))
        let watch = AlertWatch(
            rendezvous: RendezvousClient(provider: provider, key: key, role: .parent), interval: .milliseconds(20)
        )
        let digests = Recorder(watch.digests)
        await watch.start()
        await watch.stop()

        await beacon.publish(isMonitoring: true, status: nil, events: [], now: start)
        await beacon.flush()
        try await Task.sleep(for: .milliseconds(150))
        #expect(digests.all.isEmpty)
    }
}
