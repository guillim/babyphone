import BabyphoneCore
import CloudKit
import Foundation

/// Rendezvous through the CloudKit public database.
///
/// Each phone writes one small record: its current addresses, encrypted with
/// the pairing key before they reach this type. The public database is used
/// because it does not count against the user's iCloud storage. Nothing else
/// ever goes through CloudKit, and no media passes through it.
struct CloudKitRendezvous: RendezvousProvider {
    private static let recordType = "Rendezvous"
    private static let payloadField = "payload"

    /// Requests run at once, even from the background, and give up quickly: a
    /// parent waiting for the picture is better served by a fast retry than by a long wait.
    private static var configuration: CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return configuration
    }

    private func withDatabase<Result>(_ body: (CKDatabase) async throws -> Result) async throws -> Result {
        try await CKContainer.default().publicCloudDatabase.configuredWith(configuration: Self.configuration, body: body)
    }

    func availability() async -> RendezvousAvailability {
        switch try? await CKContainer.default().accountStatus() {
        case .available: .available
        case .noAccount: .noAccount
        default: .unavailable
        }
    }

    func publish(_ record: Data, to slot: RendezvousSlot) async throws {
        let cloudRecord = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: slot.name))
        cloudRecord[Self.payloadField] = record
        try await withDatabase { database in
            // `.allKeys` overwrites the previous record without fetching it first.
            let (saved, _) = try await database.modifyRecords(saving: [cloudRecord], deleting: [], savePolicy: .allKeys)
            _ = try saved[cloudRecord.recordID]?.get()
        }
    }

    func fetch(_ slot: RendezvousSlot) async throws -> Data? {
        do {
            return try await withDatabase { database in
                try await database.record(for: CKRecord.ID(recordName: slot.name))[Self.payloadField] as? Data
            }
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
}
