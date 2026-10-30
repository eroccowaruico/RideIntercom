import Foundation
@testable import RideIntercom

@MainActor
func testInvitationAuthority(keychain: KeychainSecretStoring? = nil) -> DirectInvitationAuthority {
    DirectInvitationAuthority(keychain: keychain ?? InternetTestKeychain(), namespace: "RideIntercom.InvitationTests")
}

@MainActor
func testInvitationReceipt(groupID: UUID, inviter: GroupMember, invitee: String = "local",
                           authority: DirectInvitationAuthority? = nil) throws -> DirectInvitationReceipt {
    let grant = try (authority ?? testInvitationAuthority()).issue(.init(groupID: groupID, inviterMemberID: inviter.id,
                                         expiresAt: Date().timeIntervalSince1970 + 3600))
    return try .make(grant: grant, inviteeMemberID: invitee, displayName: "Rider")
}
