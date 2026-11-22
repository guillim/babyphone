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

    private var database: CKDatabase { CKContainer.default().publicCloudDatabase }

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
        // `.allKeys` overwrites the previous record without fetching it first.
        let (saved, _) = try await database.modifyRecords(saving: [cloudRecord], deleting: [], savePolicy: .allKeys)
        _ = try saved[cloudRecord.recordID]?.get()
    }

    func fetch(_ slot: RendezvousSlot) async throws -> Data? {
        do {
            let cloudRecord = try await database.record(for: CKRecord.ID(recordName: slot.name))
            return cloudRecord[Self.payloadField] as? Data
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
}
