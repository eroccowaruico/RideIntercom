import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct ContactInvitationPurposeTests {
    private func token(contact: Bool? = nil, issuedAt: TimeInterval = Date().timeIntervalSince1970,
                       expiresAt: TimeInterval? = nil) throws -> GroupInviteToken {
        try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("purpose-author"),
            groupID: UUID(), groupName: "Invitation", groupSecret: "purpose-test-key",
            inviterMemberID: "purpose-author", inviterDisplayName: "Author", contactBootstrap: contact,
            issuedAt: issuedAt, expiresAt: expiresAt)
    }

    @Test func ordinaryGroupInvitationKeepsItsOriginalPurposeAndAcceptance() throws {
        let original = try token()
        #expect(original.directInvitation?.context.contactBootstrap == nil)
        let url = try GroupInviteTokenCodec.joinURL(for: original)
        let decoded = try GroupInviteTokenCodec.decodeJoinURL(url)
        #expect(decoded == original)
        let accepted = try decoded.accept(signer: testIdentitySigner("purpose-friend"), displayName: "Friend")
        #expect(accepted.inviter.memberID == "purpose-author")
    }

    @Test func contactAndOrdinaryGroupEntrypointsRejectEachOthersPurpose() throws {
        let contact = try token(contact: true)
        let contactURL = try GroupInviteTokenCodec.joinURL(for: contact, contactBootstrap: true)
        #expect(throws: GroupInviteTokenError.invalidURL) {
            try GroupInviteTokenCodec.decodeJoinURL(contactURL)
        }
        #expect(throws: GroupInviteTokenError.invalidTokenEncoding) {
            try contact.accept(signer: testIdentitySigner("purpose-friend"), displayName: "Friend")
        }
        let ordinary = try token()
        #expect(throws: GroupInviteTokenError.invalidTokenEncoding) {
            try ordinary.accept(signer: testIdentitySigner("purpose-friend"), displayName: "Friend", contactBootstrap: true)
        }
        var rewritten = URLComponents(url: contactURL, resolvingAgainstBaseURL: false)!
        rewritten.host = "join"
        #expect(throws: GroupInviteTokenError.invalidTokenEncoding) {
            try GroupInviteTokenCodec.decodeJoinURL(#require(rewritten.url))
        }
    }

    @Test func removingContactPurposeCannotConvertASignedContactIntoAGroupInvitation() throws {
        let original = try token(contact: true)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var grant = try #require(object["directInvitation"] as? [String: Any])
        var context = try #require(grant["context"] as? [String: Any])
        context.removeValue(forKey: "contactBootstrap")
        grant["context"] = context; object["directInvitation"] = grant
        let changed = try JSONDecoder().decode(GroupInviteToken.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: GroupInviteTokenError.invalidSignature) {
            try changed.accept(signer: testIdentitySigner("purpose-friend"), displayName: "Friend")
        }
    }

    @Test func expiredContactCannotBeAcceptedAndDefaultLifetimeMatchesGroupInvitations() throws {
        let expired = try token(contact: true, issuedAt: 0, expiresAt: 10)
        #expect(throws: GroupInviteTokenError.expired) {
            try expired.accept(signer: testIdentitySigner("purpose-friend"), displayName: "Friend", now: 10, contactBootstrap: true)
        }
        let ordinary = try token(issuedAt: 100)
        let contact = try token(contact: true, issuedAt: 100)
        #expect(contact.expiresAt == ordinary.expiresAt)
        #expect(try #require(contact.expiresAt) == TimeInterval(100 + 7 * 24 * 60 * 60))
    }
}
