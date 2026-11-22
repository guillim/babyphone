import BabyphoneCore
import Foundation

/// Baby side of pairing: shows an invitation and waits for the parent unit to answer it.
@MainActor
final class BabyPairingModel: ObservableObject {
    @Published private(set) var invitation: PairingInvitation?
    /// True when the phone cannot be found by the parent unit, usually because
    /// the local network permission was refused.
    @Published private(set) var isUnreachable = false

    private let host = PairingHost()
    private var listener: PairingListener?
    private var invitationUpdates: Task<Void, Never>?

    func start(onPaired: @escaping @MainActor (PairingKey) -> Void) {
        guard listener == nil else { return }
        invitationUpdates = Task { [weak self, host] in
            for await invitation in host.invitations {
                self?.invitation = invitation
            }
        }
        let listener = PairingListener(
            host: host,
            onPaired: { key in Task { @MainActor in onPaired(key) } },
            onUnavailable: { [weak self] in Task { @MainActor in self?.isUnreachable = true } }
        )
        do {
            try listener.start()
            self.listener = listener
        } catch {
            isUnreachable = true
        }
    }

    func stop() {
        listener?.stop()
        listener = nil
        invitationUpdates?.cancel()
    }
}
