import Foundation

public enum PairingError: Error, Equatable {
    /// The other phone runs an app version that speaks a different pairing protocol.
    case incompatibleVersion
    /// The code or QR token does not match the one shown on the baby unit.
    case wrongCredential
    /// The other phone sent something that makes no sense at this step.
    case unexpectedMessage
}

/// The four messages exchanged over the local link to pair two phones.
enum PairingMessage: Codable, Sendable {
    /// Parent to baby: opens the exchange.
    case hello(version: Int, kind: PairingCredential.Kind, nonce: Data, share: Data)
    /// Baby to parent: its half of the exchange and proof that it knows the credential.
    case challenge(nonce: Data, share: Data, confirmation: Data)
    /// Parent to baby: proof that it knows the credential.
    case proof(confirmation: Data)
    /// Baby to parent: pairing is recorded.
    case done
    /// Baby to parent: the exchange is refused.
    case rejected(RejectionReason)

    enum RejectionReason: String, Codable, Sendable {
        case incompatibleVersion
        case wrongCredential
    }
}

/// Runs the pairing exchange over any reliable channel between the two phones.
public enum PairingProtocol {
    static let version = 1
    private static let nonceByteCount = 16

    /// Parent side. Returns the key both phones now share.
    public static func initiate(
        over channel: any FrameChannel,
        credential: PairingCredential,
        stepTimeout: Duration = .seconds(10)
    ) async throws -> PairingKey {
        let nonce = randomNonce()
        let share = try PasswordKeyExchange.makeShare(for: credential)
        try await channel.send(PairingMessage.hello(
            version: version, kind: credential.kind, nonce: nonce, share: share.publicValue
        ))

        let reply = try await channel.receive(PairingMessage.self, timeout: stepTimeout)
        guard case .challenge(let peerNonce, let peerShare, let peerConfirmation) = reply else {
            throw error(for: reply)
        }
        let transcript = PasswordKeyExchange.transcript(
            kind: credential.kind,
            initiatorNonce: nonce, responderNonce: peerNonce,
            initiatorShare: share.publicValue, responderShare: peerShare
        )
        let keys = try PasswordKeyExchange.sessionKeys(
            share: share, peerPublicValue: peerShare, transcript: transcript
        )
        guard PasswordKeyExchange.constantTimeEquals(peerConfirmation, keys.responderConfirmation) else {
            throw PairingError.wrongCredential
        }
        try await channel.send(PairingMessage.proof(confirmation: keys.initiatorConfirmation))

        let outcome = try await channel.receive(PairingMessage.self, timeout: stepTimeout)
        guard case .done = outcome else { throw error(for: outcome) }
        return keys.pairingKey
    }

    /// Baby side. Returns the key both phones now share.
    public static func respond(
        over channel: any FrameChannel,
        invitation: PairingInvitation,
        stepTimeout: Duration = .seconds(10)
    ) async throws -> PairingKey {
        let opening = try await channel.receive(PairingMessage.self, timeout: stepTimeout)
        guard case .hello(let peerVersion, let kind, let peerNonce, let peerShare) = opening else {
            throw PairingError.unexpectedMessage
        }
        guard peerVersion == version else {
            try? await channel.send(PairingMessage.rejected(.incompatibleVersion))
            throw PairingError.incompatibleVersion
        }

        let nonce = randomNonce()
        let share = try PasswordKeyExchange.makeShare(for: invitation.credential(for: kind))
        let transcript = PasswordKeyExchange.transcript(
            kind: kind,
            initiatorNonce: peerNonce, responderNonce: nonce,
            initiatorShare: peerShare, responderShare: share.publicValue
        )
        let keys: PasswordKeyExchange.SessionKeys
        do {
            keys = try PasswordKeyExchange.sessionKeys(
                share: share, peerPublicValue: peerShare, transcript: transcript
            )
        } catch {
            try? await channel.send(PairingMessage.rejected(.wrongCredential))
            throw PairingError.wrongCredential
        }
        try await channel.send(PairingMessage.challenge(
            nonce: nonce, share: share.publicValue, confirmation: keys.responderConfirmation
        ))

        // A parent unit that typed a wrong code detects it on the challenge and hangs up here.
        guard
            let reply = try? await channel.receive(PairingMessage.self, timeout: stepTimeout),
            case .proof(let peerConfirmation) = reply,
            PasswordKeyExchange.constantTimeEquals(peerConfirmation, keys.initiatorConfirmation)
        else {
            try? await channel.send(PairingMessage.rejected(.wrongCredential))
            throw PairingError.wrongCredential
        }
        try await channel.send(PairingMessage.done)
        return keys.pairingKey
    }

    private static func error(for message: PairingMessage) -> PairingError {
        switch message {
        case .rejected(.incompatibleVersion): .incompatibleVersion
        case .rejected(.wrongCredential): .wrongCredential
        default: .unexpectedMessage
        }
    }

    private static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<nonceByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
