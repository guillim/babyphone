import Foundation
import Testing
import TestSupport
@testable import BabyphoneCore

@Suite(.timeLimit(.minutes(1))) struct StorageTests {
    @Test func revisionsRiseWithEveryChange() async throws {
        let journal = JournalStore(database: try .inMemory(), role: .baby)
        let started = try await journal.record(.monitoringStarted)
        let noise = try await journal.record(.noise)
        let ended = try await journal.setDuration(8, ofEvent: noise.id)

        #expect(started.revision == 1)
        #expect(noise.revision == 2)
        #expect(ended?.revision == 3)
        #expect(ended?.duration == 8)
        #expect(try await journal.latestRevision(from: .baby) == 3)
        #expect(try await journal.setDuration(1, ofEvent: UUID()) == nil)
    }

    @Test func parentCatchesUpFromItsLastRevision() async throws {
        let baby = JournalStore(database: try .inMemory(), role: .baby)
        let parent = JournalStore(database: try .inMemory(), role: .parent)

        try await baby.record(.monitoringStarted)
        let noise = try await baby.record(.noise)
        try await parent.merge(try await baby.events(from: .baby, afterRevision: parent.latestRevision(from: .baby)))
        #expect(try await parent.latestRevision(from: .baby) == 2)

        // The noise ends and something new happens while the parent unit is away.
        try await baby.setDuration(30, ofEvent: noise.id)
        try await baby.record(.linkLost)
        let missed = try await baby.events(from: .baby, afterRevision: parent.latestRevision(from: .baby))
        #expect(missed.map(\.kind) == [.noise, .linkLost])
        try await parent.merge(missed)

        let copy = try await parent.events(since: .distantPast)
        #expect(copy.count == 3)
        #expect(copy.first { $0.id == noise.id }?.duration == 30)
    }

    @Test func eachPhoneNumbersItsOwnEvents() async throws {
        let parent = JournalStore(database: try .inMemory(), role: .parent)
        try await parent.merge([JournalEvent(kind: .noise, origin: .baby, date: Date(), revision: 40)])
        let own = try await parent.record(.linkLost)

        #expect(own.revision == 1)
        #expect(own.origin == .parent)
        #expect(try await parent.latestRevision(from: .baby) == 40)

        try await parent.deleteEvents(from: .baby)
        #expect(try await parent.events(since: .distantPast).map(\.origin) == [.parent])
    }

    @Test func listsRecentEventsNewestFirstAndPrunesOldOnes() async throws {
        let journal = JournalStore(database: try .inMemory(), role: .baby)
        let now = Date()
        try await journal.record(.monitoringStarted, at: now.addingTimeInterval(-JournalStore.retention - 60))
        try await journal.record(.noise, at: now.addingTimeInterval(-120), duration: 5)
        try await journal.record(.monitoringStopped, at: now.addingTimeInterval(-60))

        #expect(try await journal.events(since: now.addingTimeInterval(-3600)).map(\.kind) == [.monitoringStopped, .noise])
        try await journal.prune(now: now)
        #expect(try await journal.events(since: .distantPast).count == 2)
    }

    @Test func datesSurviveStorage() async throws {
        let journal = JournalStore(database: try .inMemory(), role: .baby)
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        let recorded = try await journal.record(.noise, at: date)
        let stored = try await journal.events(since: .distantPast)
        #expect(stored == [recorded])
        #expect(abs(stored[0].date.timeIntervalSince(date)) < 0.001)
    }

    @Test func nightsRunFromNoonToNoon() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        func date(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        }
        #expect(Night.start(containing: date(21, 22), calendar: calendar) == date(21, 12))
        #expect(Night.start(containing: date(22, 3), calendar: calendar) == date(21, 12))
        #expect(Night.start(containing: date(22, 11), calendar: calendar) == date(21, 12))
        #expect(Night.start(containing: date(22, 12), calendar: calendar) == date(22, 12))
    }

    @Test func settingsAreStoredReplacedAndRemoved() async throws {
        let settings = SettingsStore(database: try .inMemory())
        #expect(try await settings.string(for: .role) == nil)
        try await settings.set("baby", for: .role)
        try await settings.set("parent", for: .role)
        #expect(try await settings.string(for: .role) == "parent")
        try await settings.set(nil, for: .role)
        #expect(try await settings.string(for: .role) == nil)
    }

    @Test func databaseReopensWithItsContent() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nuzzlecam.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await SettingsStore(database: try AppDatabase(url: url)).set("Chambre", for: .roomName)
        #expect(try await SettingsStore(database: try AppDatabase(url: url)).string(for: .roomName) == "Chambre")
    }

    @Test func healthLogExportsCSV() async throws {
        let log = HealthLog(database: try .inMemory())
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try await log.append(HealthSample(
            date: date, role: .baby, batteryLevel: 0.826, isCharging: true,
            thermal: .fair, link: "local", isInBackground: false
        ))
        try await log.append(HealthSample(
            date: date.addingTimeInterval(60), role: .baby, batteryLevel: nil, isCharging: false,
            thermal: .nominal, link: "waiting", isInBackground: true
        ))
        let csv = try await log.csv(since: .distantPast)
        #expect(csv == """
        date,role,battery,charging,thermal,link,background
        2027-01-15T08:00:00Z,baby,83,1,fair,local,0
        2027-01-15T08:01:00Z,baby,,0,nominal,waiting,1

        """)
    }
}
