import Foundation

/// Baby-side pairing desk: owns the invitation on screen and serves parent units that answer it.
///
/// A six-digit code only resists guessing if guesses are counted, so the
/// invitation is replaced after a few wrong attempts.
public actor PairingHost {
    public static let maxFailedAttempts = 5

    /// The invitation to display. A new value arrives each time it is replaced.
    public nonisolated let invitations: AsyncStream<PairingInvitation>
    private let invitationContinuation: AsyncStream<PairingInvitation>.Continuation

    public private(set) var invitation: PairingInvitation
    private var failedAttempts = 0

    public init() {
        let invitation = PairingInvitation.random()
        self.invitation = invitation
        (invitations, invitationContinuation) = AsyncStream.makeStream(
            of: PairingInvitation.self, bufferingPolicy: .bufferingNewest(1)
        )
        invitationContinuation.yield(invitation)
    }

    /// Runs one pairing attempt. Returns the shared key on success, nil otherwise.
    public func serve(_ channel: any FrameChannel) async -> PairingKey? {
        defer { channel.close() }
        do {
            return try await PairingProtocol.respond(over: channel, invitation: invitation)
        } catch PairingError.wrongCredential {
            failedAttempts += 1
            if failedAttempts >= Self.maxFailedAttempts {
                replaceInvitation()
            }
            return nil
        } catch {
            return nil
        }
    }

    public func finish() {
        invitationContinuation.finish()
    }

    private func replaceInvitation() {
        failedAttempts = 0
        invitation = .random()
        invitationContinuation.yield(invitation)
    }
}
