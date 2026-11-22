import BabyphoneCore
import Foundation

/// Parent side of pairing: sends the scanned token or the typed code to the baby unit nearby.
@MainActor
final class ParentPairingModel: ObservableObject {
    enum Failure: Equatable {
        case wrongCode
        case babyNotFound
        case localNetworkDenied
        case incompatibleVersion
    }

    @Published var code = ""
    @Published private(set) var isPairing = false
    @Published private(set) var failure: Failure?

    var canSubmitCode: Bool {
        PairingInvitation.isWellFormedCode(code) && !isPairing
    }

    func submitCode(onPaired: @escaping @MainActor (PairingKey) -> Void) {
        guard canSubmitCode else { return }
        pair(using: .code(code), onPaired: onPaired)
    }

    func handleScan(_ payload: String, onPaired: @escaping @MainActor (PairingKey) -> Void) {
        // The camera keeps reporting the same code many times a second.
        guard !isPairing, let credential = PairingInvitation.credential(fromQRPayload: payload) else { return }
        pair(using: credential, onPaired: onPaired)
    }

    private func pair(using credential: PairingCredential, onPaired: @escaping @MainActor (PairingKey) -> Void) {
        isPairing = true
        failure = nil
        Task {
            do {
                onPaired(try await PairingClient.pair(using: credential))
            } catch PairingError.wrongCredential {
                failure = .wrongCode
            } catch PairingError.incompatibleVersion {
                failure = .incompatibleVersion
            } catch LocalNetworkError.permissionDenied {
                failure = .localNetworkDenied
            } catch {
                failure = .babyNotFound
            }
            isPairing = false
        }
    }
}
