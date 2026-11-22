import Foundation
import GRDB

/// The SQLite database of one phone.
///
/// On the baby unit it is the source of truth for the journal and settings.
/// On the parent unit it holds a copy of the journal for offline reading,
/// plus that phone's own settings.
public final class AppDatabase: Sendable {
    let writer: any DatabaseWriter

    /// Opens, and migrates if needed, the database stored at `url`.
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try self.init(writer: DatabasePool(path: url.path))
    }

    /// A database that lives in memory, for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue())
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "journalEvent") { table in
                table.primaryKey("id", .text)
                table.column("kind", .text).notNull()
                table.column("origin", .text).notNull()
                table.column("date", .datetime).notNull().indexed()
                table.column("duration", .double)
                table.column("revision", .integer).notNull()
            }
            try db.create(indexOn: "journalEvent", columns: ["origin", "revision"])

            try db.create(table: "setting") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }

            try db.create(table: "healthSample") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("date", .datetime).notNull().indexed()
                table.column("role", .text).notNull()
                table.column("batteryLevel", .double)
                table.column("isCharging", .boolean).notNull()
                table.column("thermal", .text).notNull()
                table.column("link", .text).notNull()
                table.column("isInBackground", .boolean).notNull()
            }
        }
        return migrator
    }
}
