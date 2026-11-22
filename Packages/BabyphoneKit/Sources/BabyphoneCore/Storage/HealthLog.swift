import Foundation
import GRDB

/// One periodic measurement of how a phone is coping with a night of monitoring.
public struct HealthSample: Codable, Sendable, Equatable {
    public var date: Date
    public var role: DeviceRole
    public var batteryLevel: Double?
    public var isCharging: Bool
    public var thermal: ThermalLevel
    /// Connection state at the time, as free text ("local", "remote", "waiting", ...).
    public var link: String
    public var isInBackground: Bool

    public init(
        date: Date = Date(),
        role: DeviceRole,
        batteryLevel: Double?,
        isCharging: Bool,
        thermal: ThermalLevel,
        link: String,
        isInBackground: Bool
    ) {
        self.date = date
        self.role = role
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.thermal = thermal
        self.link = link
        self.isInBackground = isInBackground
    }
}

extension HealthSample: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "healthSample"
}

/// Records battery, temperature and link state once a minute.
///
/// The overnight test decides whether the project is viable. This log is its
/// evidence: a gap in the samples means the app was suspended, and the
/// thermal column shows whether the baby unit overheated.
public struct HealthLog: Sendable {
    /// Samples older than this are deleted.
    public static let retention: TimeInterval = 7 * 24 * 3600

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func append(_ sample: HealthSample) async throws {
        try await database.writer.write { db in
            try sample.insert(db)
            try HealthSample.filter(Column("date") < sample.date.addingTimeInterval(-Self.retention)).deleteAll(db)
        }
    }

    public func samples(since date: Date) async throws -> [HealthSample] {
        try await database.writer.read { db in
            try HealthSample.filter(Column("date") >= date).order(Column("date")).fetchAll(db)
        }
    }

    /// The samples since `date` as CSV text, ready to share.
    public func csv(since date: Date) async throws -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["date,role,battery,charging,thermal,link,background"]
        for sample in try await samples(since: date) {
            let battery = sample.batteryLevel.map { String(Int(($0 * 100).rounded())) } ?? ""
            lines.append([
                formatter.string(from: sample.date),
                sample.role.rawValue,
                battery,
                sample.isCharging ? "1" : "0",
                sample.thermal.rawValue,
                sample.link,
                sample.isInBackground ? "1" : "0",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
