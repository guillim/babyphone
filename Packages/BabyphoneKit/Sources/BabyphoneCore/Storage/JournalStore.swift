import Foundation
import GRDB

extension JournalEvent: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "journalEvent"
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
}

/// Reads and writes the night journal.
public struct JournalStore: Sendable {
    /// Events older than this are deleted.
    public static let retention: TimeInterval = 14 * 24 * 3600

    private let database: AppDatabase
    /// The phone this store runs on. Events recorded here carry it as their origin.
    private let role: DeviceRole

    public init(database: AppDatabase, role: DeviceRole) {
        self.database = database
        self.role = role
    }

    /// Records an event observed by this phone.
    @discardableResult
    public func record(
        _ kind: JournalEvent.Kind,
        at date: Date = Date(),
        duration: TimeInterval? = nil
    ) async throws -> JournalEvent {
        try await database.writer.write { [role] db in
            var event = JournalEvent(kind: kind, origin: role, date: date, duration: duration)
            event.revision = try Self.nextRevision(db, origin: role)
            try event.insert(db)
            return event
        }
    }

    /// Sets the duration of an event recorded earlier, typically when a noise episode ends.
    @discardableResult
    public func setDuration(_ duration: TimeInterval, ofEvent id: UUID) async throws -> JournalEvent? {
        try await database.writer.write { [role] db in
            guard var event = try JournalEvent.fetchOne(db, key: id.uuidString) else { return nil }
            event.duration = duration
            event.revision = try Self.nextRevision(db, origin: role)
            try event.update(db)
            return event
        }
    }

    /// Stores events received from the other phone, replacing older versions of the same events.
    public func merge(_ events: [JournalEvent]) async throws {
        guard !events.isEmpty else { return }
        try await database.writer.write { db in
            for event in events {
                try event.save(db)
            }
        }
    }

    /// Events recorded by `origin` after `revision`, oldest change first.
    public func events(from origin: DeviceRole, afterRevision revision: Int64) async throws -> [JournalEvent] {
        try await database.writer.read { db in
            try JournalEvent
                .filter(Column("origin") == origin.rawValue && Column("revision") > revision)
                .order(Column("revision"))
                .fetchAll(db)
        }
    }

    /// The highest revision stored for `origin`, or 0 when there is none.
    public func latestRevision(from origin: DeviceRole) async throws -> Int64 {
        try await database.writer.read { db in
            try Self.latestRevision(db, origin: origin)
        }
    }

    /// Events since `date`, most recent first.
    public func events(since date: Date) async throws -> [JournalEvent] {
        try await database.writer.read { db in
            try JournalEvent
                .filter(Column("date") >= date)
                .order(Column("date").desc)
                .fetchAll(db)
        }
    }

    /// Deletes the events recorded by `origin`. Used when a pairing is removed.
    public func deleteEvents(from origin: DeviceRole) async throws {
        _ = try await database.writer.write { db in
            try JournalEvent.filter(Column("origin") == origin.rawValue).deleteAll(db)
        }
    }

    /// Deletes events past the retention period.
    public func prune(now: Date = Date()) async throws {
        _ = try await database.writer.write { db in
            try JournalEvent.filter(Column("date") < now.addingTimeInterval(-Self.retention)).deleteAll(db)
        }
    }

    private static func nextRevision(_ db: Database, origin: DeviceRole) throws -> Int64 {
        try latestRevision(db, origin: origin) + 1
    }

    private static func latestRevision(_ db: Database, origin: DeviceRole) throws -> Int64 {
        try Int64.fetchOne(
            db,
            sql: "SELECT MAX(revision) FROM journalEvent WHERE origin = ?",
            arguments: [origin.rawValue]
        ) ?? 0
    }
}
