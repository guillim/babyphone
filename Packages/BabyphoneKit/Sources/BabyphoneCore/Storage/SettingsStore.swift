import Foundation
import GRDB

/// The settings of one phone, stored in its database.
public struct SettingsStore: Sendable {
    public enum Key: String, Sendable {
        case role
        case roomName
        case sensitivity
        case usesFrontCamera
        case pairedAt
        /// Parent unit: how loud the alarm and the chime play.
        case alarmVolume
        /// Parent unit: alert on any noise, or on crying only.
        case alertTrigger
    }

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func string(for key: Key) async throws -> String? {
        try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key.rawValue])
        }
    }

    /// Stores a value, or removes the setting when `value` is nil.
    public func set(_ value: String?, for key: Key) async throws {
        try await database.writer.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key.rawValue, value]
                )
            } else {
                try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key.rawValue])
            }
        }
    }
}
