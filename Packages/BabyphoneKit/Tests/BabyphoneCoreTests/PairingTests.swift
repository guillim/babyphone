import Foundation
import Testing
import TestSupport
@testable import BabyphoneCore

@Suite(.timeLimit(.minutes(1))) struct PairingTests {
    @Test func invitationCodeHasSixDigits() {
        for _ in 0..<200 {
            let invitation = PairingInvitation.random()
            #expect(PairingInvitation.isWellFormedCode(invitation.code))
        }
    }

    @Test func rejectsMalformedCodes() {
        #expect(!PairingInvitation.isWellFormedCode("12345"))
        #expect(!PairingInvitation.isWellFormedCode("1234567"))
        #expect(!PairingInvitation.isWellFormedCode("12a456"))
        #expect(!PairingInvitation.isWellFormedCode("١٢٣٤٥٦"))
    }

    @Test func qrPayloadRoundTrips() {
        let invitation = PairingInvitation.random()
        #expect(PairingInvitation.credential(fromQRPayload: invitation.qrPayload) == .token(invitation.token))
    }

    @Test func ignoresForeignQRCodes() {
        #expect(PairingInvitation.credential(fromQRPayload: "https://example.com") == nil)
        #expect(PairingInvitation.credential(fromQRPayload: "nid://pair?v=2&t=AAAA") == nil)
        #expect(PairingInvitation.credential(fromQRPayload: "nid://pair?v=1&t=AAAA") == nil)
        #expect(PairingInvitation.credential(fromQRPayload: "") == nil)
    }

    @Test(arguments: [PairingCredential.Kind.code, .token])
    func bothPhonesDeriveTheSameKey(kind: PairingCredential.Kind) async throws {
        let invitation = PairingInvitation.random()
        let (parentEnd, babyEnd) = MemoryChannel.pair()

        async let babyKey = PairingProtocol.respond(over: babyEnd, invitation: invitation)
        let parentKey = try await PairingProtocol.initiate(over: parentEnd, credential: invitation.credential(for: kind))

        #expect(try await babyKey == parentKey)
    }

    @Test func eachPairingProducesADifferentKey() async throws {
        let invitation = PairingInvitation.random()
        var keys: [PairingKey] = []
        for _ in 0..<2 {
            let (parentEnd, babyEnd) = MemoryChannel.pair()
            async let babyKey = PairingProtocol.respond(over: babyEnd, invitation: invitation)
            keys.append(try await PairingProtocol.initiate(over: parentEnd, credential: .code(invitation.code)))
            _ = try await babyKey
        }
        #expect(keys[0] != keys[1])
    }

    @Test func wrongCodeFailsOnBothPhones() async throws {
        let invitation = PairingInvitation(code: "123456", token: Data(repeating: 7, count: 16))
        let (parentEnd, babyEnd) = MemoryChannel.pair()

        async let babyOutcome: PairingKey? = try? PairingProtocol.respond(
            over: babyEnd, invitation: invitation, stepTimeout: .milliseconds(300)
        )
        await #expect(throws: PairingError.wrongCredential) {
            try await PairingProtocol.initiate(over: parentEnd, credential: .code("654321"))
        }
        parentEnd.close()
        #expect(await babyOutcome == nil)
    }

    @Test func aParentThatSkipsTheProofIsRejected() async throws {
        // An attacker that cannot compute the confirmation may still send one.
        let invitation = PairingInvitation.random()
        let (parentEnd, babyEnd) = MemoryChannel.pair()
        async let babyOutcome: PairingKey? = try? PairingProtocol.respond(over: babyEnd, invitation: invitation)

        let share = try PasswordKeyExchange.makeShare(for: .code("000000"))
        try await parentEnd.send(PairingMessage.hello(
            version: PairingProtocol.version, kind: .code, nonce: Data(count: 16), share: share.publicValue
        ))
        _ = try await parentEnd.receive(PairingMessage.self, timeout: .seconds(1))
        try await parentEnd.send(PairingMessage.proof(confirmation: Data(count: 32)))

        #expect(await babyOutcome == nil)
    }

    @Test func lowOrderSharesAreRejected() async throws {
        let invitation = PairingInvitation.random()
        let (parentEnd, babyEnd) = MemoryChannel.pair()
        async let babyOutcome: PairingKey? = try? PairingProtocol.respond(over: babyEnd, invitation: invitation)

        // The all-zero point would force a shared secret the attacker knows.
        try await parentEnd.send(PairingMessage.hello(
            version: PairingProtocol.version, kind: .code, nonce: Data(count: 16), share: Data(count: 32)
        ))
        #expect(await babyOutcome == nil)
    }

    @Test func hostReplacesTheInvitationAfterRepeatedFailures() async {
        let host = PairingHost()
        let first = await host.invitation
        let wrongCode = first.code == "000000" ? "111111" : "000000"

        for _ in 0..<PairingHost.maxFailedAttempts {
            let (parentEnd, babyEnd) = MemoryChannel.pair()
            async let served = host.serve(babyEnd)
            _ = try? await PairingProtocol.initiate(over: parentEnd, credential: .code(wrongCode))
            parentEnd.close()
            #expect(await served == nil)
        }

        #expect(await host.invitation != first)
    }

    @Test func hostPairsWithTheRightCode() async throws {
        let host = PairingHost()
        let invitation = await host.invitation
        let (parentEnd, babyEnd) = MemoryChannel.pair()

        async let served = host.serve(babyEnd)
        let parentKey = try await PairingProtocol.initiate(over: parentEnd, credential: .code(invitation.code))

        #expect(await served == parentKey)
    }

    @Test func derivedValuesDifferPerPurposeAndPerKey() {
        let key = PairingKey.random(), other = PairingKey.random()
        #expect(key.rendezvousID.count == 32)
        #expect(key.localNetworkTag.count == 16)
        #expect(key.localTransportKey.count == 32)
        #expect(key.rendezvousID != other.rendezvousID)
        #expect(key.localTransportKey != key.rawValue)
        #expect(!key.rendezvousID.hasPrefix(key.localNetworkTag))
        #expect(PairingKey(rawValue: key.rawValue) == key)
        #expect(PairingKey(rawValue: Data(count: 31)) == nil)
    }
}
