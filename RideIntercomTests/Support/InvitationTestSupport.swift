import Foundation
import CryptoKit
@testable import RideIntercom

@MainActor
func testInvitationAuthority(keychain: KeychainSecretStoring? = nil) -> DirectInvitationAuthority {
    DirectInvitationAuthority(keychain: keychain ?? InternetTestKeychain(), namespace: "RideIntercom.InvitationTests")
}

@MainActor
func testInvitationReceipt(groupID: UUID, inviter: GroupMember, invitee: String = "local",
                           authority: DirectInvitationAuthority? = nil) throws -> DirectInvitationReceipt {
    let grant = try (authority ?? testInvitationAuthority()).issue(.init(groupID: groupID, inviterMemberID: inviter.id, inviterDeviceKey: testIdentitySigner(inviter.id).publicKey,
                                         expiresAt: Date().timeIntervalSince1970 + 3600))
    return try .make(grant: grant, signer: testIdentitySigner(invitee), inviteeMemberID: invitee, displayName: "Rider")
}

@MainActor enum TestDeviceIdentities {
    static var keys: [String: P256.Signing.PrivateKey] = [:]
    static func key(_ memberID: String) -> P256.Signing.PrivateKey {
        if let key = keys[memberID] { return key }
        let key = P256.Signing.PrivateKey(); keys[memberID] = key; return key
    }
}
@MainActor func testIdentitySigner(_ memberID: String) -> DeviceIdentitySigner {
    try! DeviceIdentitySigner(memberID: memberID, key: TestDeviceIdentities.key(memberID))
}
@MainActor func testAcceptedInvitation(groupID: UUID, inviter: GroupMember, invitee: String = "local") throws -> AcceptedDirectInvitation {
    let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner(inviter.id),
        groupID: groupID, groupName: "Friends", groupSecret: "test-key", inviterMemberID: inviter.id, inviterDisplayName: inviter.displayName)
    return try token.accept(signer: testIdentitySigner(invitee), displayName: "Rider")
}
