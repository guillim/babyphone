import BabyphoneCore
import Foundation

/// What this device is and what it is paired with: decides which screen the app shows.
@MainActor
final class AppModel: ObservableObject {
    enum Stage: Equatable {
        case loading
        case choosingRole
        case pairing(DeviceRole)
        /// A parent unit holds one key. A baby unit holds one per paired parent unit.
        case monitoring(DeviceRole, [PairingKey])
        /// The local database cannot be opened. Nothing else can work without it.
        case broken
    }

    /// How many parent units one baby unit serves.
    static let maxParents = 2

    @Published private(set) var stage = Stage.loading

    /// Each role has its own media, built on first use: the parent unit plays and records through its own audio.
    private(set) lazy var babyMedia = MediaEngine()
    private(set) lazy var parentAudio = ParentAudio()
    private(set) lazy var parentMedia = MediaEngine(audioDevice: parentAudio)
    private(set) var database: AppDatabase?

    var settings: SettingsStore? { database.map(SettingsStore.init) }

    /// Whether leaving the pairing screen returns to monitoring, because a pairing already exists.
    var canCancelPairing: Bool { !PairingKeychain.load().isEmpty }

    func load() async {
        guard stage == .loading else { return }
        do {
            let folder = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            database = try AppDatabase(url: folder.appendingPathComponent("NuzzleCam/nuzzlecam.sqlite"))
        } catch {
            stage = .broken
            return
        }
        #if DEBUG
        await applyUITestState()
        #endif
        let role = (try? await settings?.string(for: .role)).flatMap(DeviceRole.init(rawValue:))
        stage = stage(for: role)
    }

    func choose(_ role: DeviceRole) async {
        try? await settings?.set(role.rawValue, for: .role)
        stage = stage(for: role)
    }

    func completePairing(as role: DeviceRole, with key: PairingKey) async {
        // A parent unit follows one baby unit. A baby unit adds the new parent to those it has.
        let keys = role == .baby ? Array((PairingKeychain.load() + [key]).suffix(Self.maxParents)) : [key]
        let isSaved = PairingKeychain.save(keys)
        LinkLog.note("pairing: \(keys.count) key(s) saved in the Keychain: \(isSaved)")
        try? await settings?.set(ISO8601DateFormatter().string(from: Date()), for: .pairedAt)
        stage = .monitoring(role, keys)
    }

    /// Baby unit: opens the pairing screen to link one more parent unit.
    func addParent() {
        guard case .monitoring(.baby, let keys) = stage, keys.count < Self.maxParents else { return }
        stage = .pairing(.baby)
    }

    /// Leaves the pairing screen without pairing.
    func cancelPairing() async {
        guard case .pairing(let role) = stage else { return }
        let keys = PairingKeychain.load()
        if keys.isEmpty {
            await resetRole()
        } else {
            stage = .monitoring(role, keys)
        }
    }

    /// Baby unit: forgets one parent unit. The other one stays paired.
    func removeParent(_ key: PairingKey) {
        guard case .monitoring(.baby, let keys) = stage else { return }
        let remaining = keys.filter { $0 != key }
        PairingKeychain.save(remaining)
        stage = remaining.isEmpty ? .pairing(.baby) : .monitoring(.baby, remaining)
    }

    /// Forgets every paired device. The devices must pair again afterwards.
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

    #if DEBUG
    /// UI tests start the app in a known state, named by the `NUZZLECAM_UI_TEST_STATE`
    /// environment variable: "fresh", or a role, optionally followed by "-paired".
    private func applyUITestState() async {
        guard let state = ProcessInfo.processInfo.environment["NUZZLECAM_UI_TEST_STATE"] else { return }
        await forgetPairing()
        let parts = state.split(separator: "-")
        let role = parts.first.flatMap { DeviceRole(rawValue: String($0)) }
        try? await settings?.set(role?.rawValue, for: .role)
        try? await settings?.set(nil, for: .isMonitoring)
        if parts.contains("paired") {
            PairingKeychain.save([.random()])
        }
    }
    #endif

    private func stage(for role: DeviceRole?) -> Stage {
        guard let role else { return .choosingRole }
        let keys = PairingKeychain.load()
        LinkLog.note("launch: role \(role), \(keys.count) key(s) in the Keychain")
        return keys.isEmpty ? .pairing(role) : .monitoring(role, keys)
    }

    private func forgetPairing() async {
        PairingKeychain.save([])
        try? await settings?.set(nil, for: .pairedAt)
        guard let database else { return }
        // The journal belongs to the pairing it was recorded under.
        for origin in DeviceRole.allCases {
            try? await JournalStore(database: database, role: origin).deleteEvents(from: origin)
        }
    }
}
