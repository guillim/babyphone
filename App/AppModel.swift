import BabyphoneCore
import Foundation

/// What this phone is and whether it is paired: decides which screen the app shows.
@MainActor
final class AppModel: ObservableObject {
    enum Stage: Equatable {
        case loading
        case choosingRole
        case pairing(DeviceRole)
        case monitoring(DeviceRole, PairingKey)
        /// The local database cannot be opened. Nothing else can work without it.
        case broken
    }

    @Published private(set) var stage = Stage.loading

    let media = MediaEngine()
    private(set) var database: AppDatabase?

    var settings: SettingsStore? { database.map(SettingsStore.init) }

    func load() async {
        guard stage == .loading else { return }
        do {
            let folder = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            database = try AppDatabase(url: folder.appendingPathComponent("Nid/nid.sqlite"))
        } catch {
            stage = .broken
            return
        }
        let role = (try? await settings?.string(for: .role)).flatMap(DeviceRole.init(rawValue:))
        stage = stage(for: role)
    }

    func choose(_ role: DeviceRole) async {
        try? await settings?.set(role.rawValue, for: .role)
        stage = stage(for: role)
    }

    func completePairing(as role: DeviceRole, with key: PairingKey) async {
        PairingKeychain.save(key)
        try? await settings?.set(ISO8601DateFormatter().string(from: Date()), for: .pairedAt)
        stage = .monitoring(role, key)
    }

    /// Forgets the other phone. Both phones must pair again afterwards.
    func unpair() async {
        guard case .monitoring(let role, _) = stage else { return }
        await forgetPairing()
        stage = .pairing(role)
    }

    /// Returns to the role choice. Changing role also drops the pairing.
    func resetRole() async {
        await forgetPairing()
        try? await settings?.set(nil, for: .role)
        stage = .choosingRole
    }

    private func stage(for role: DeviceRole?) -> Stage {
        guard let role else { return .choosingRole }
        guard let key = PairingKeychain.load() else { return .pairing(role) }
        return .monitoring(role, key)
    }

    private func forgetPairing() async {
        PairingKeychain.delete()
        try? await settings?.set(nil, for: .pairedAt)
        guard let database else { return }
        // The journal belongs to the pairing it was recorded under.
        for origin in DeviceRole.allCases {
            try? await JournalStore(database: database, role: origin).deleteEvents(from: origin)
        }
    }
}
