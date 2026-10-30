import CryptoKit
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct DeviceIdentityProofTests {
    @Test func deviceSignatureBindsMemberPurposeAndInvitationContent() throws {
        let key = P256.Signing.PrivateKey()
        let signer = try DeviceIdentitySigner(memberID: "friend", key: key)
        let message = Data("unique-invitation-and-recipient".utf8)
        let proof = try signer.sign(message, purpose: .acceptInvitation)
        let verified = try proof.verify(message, purpose: .acceptInvitation, memberID: "friend")
        #expect(verified.publicKey == signer.publicKey)
        #expect(verified.principal == nil)
        #expect(throws: (any Error).self) { try proof.verify(message, purpose: .issueInvitation, memberID: "friend") }
        #expect(throws: (any Error).self) { try proof.verify(message, purpose: .acceptInvitation, memberID: "other") }
        #expect(throws: (any Error).self) { try proof.verify(Data("another-invitation".utf8), purpose: .acceptInvitation, memberID: "friend") }
    }

    @Test func certificateIsTrustedOnlyFromOurServiceAndCannotBeCopiedToAnotherKey() throws {
        let key = P256.Signing.PrivateKey(), issuer = P256.Signing.PrivateKey()
        let origin = URL(string: "https://account.test")!
        let certificate = try testIdentityCertificate(signer: issuer, memberID: "friend", deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation))
        let identity = try certificate.verify(origin: origin, trustedIssuerKey: certificate.issuerKey)
        let trust = DeviceIdentityTrust(origin: origin, issuerKey: certificate.issuerKey)
        let signer = try DeviceIdentitySigner(memberID: "friend", key: key, identity: identity)
        let message = Data("accepted-invitation".utf8)
        let proof = try signer.sign(message, purpose: .acceptInvitation)
        #expect(try proof.verify(message, purpose: .acceptInvitation, memberID: "friend").principal == nil)
        let verified = try proof.verify(message, purpose: .acceptInvitation, memberID: "friend", trust: trust)
        #expect(verified.principal == AccountPrincipal(issuer: "https://account.test", userID: identity.userID))
        #expect(throws: (any Error).self) { try DeviceIdentitySigner(memberID: "friend", key: P256.Signing.PrivateKey(), identity: identity) }
        #expect(throws: (any Error).self) { try DeviceIdentitySigner(memberID: "other", key: key, identity: identity) }
        var copied = try DeviceIdentitySigner(memberID: "friend", key: P256.Signing.PrivateKey()).sign(message, purpose: .acceptInvitation)
        copied.certificate = certificate
        #expect(throws: (any Error).self) { try copied.verify(message, purpose: .acceptInvitation, memberID: "friend", trust: trust) }
    }
}
