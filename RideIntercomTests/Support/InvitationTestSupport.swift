import Foundation
import RTC
import Testing
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

@MainActor
func receiveTestProfileChallenge(_ vm: IntercomViewModel, peerID: String, nonce: UUID = UUID(), now: TimeInterval = Date().timeIntervalSince1970) throws {
    let value = PeerProfileChallenge(groupID: try #require(vm.activeGroupID), recipientMemberID: vm.localMemberIdentity.memberID, nonce: nonce)
    vm.receivePeerProfileChallenge(peerID: peerID, message: .init(namespace: PeerProfileChallenge.namespace, payload: try JSONEncoder().encode(value)), now: now)
}

@MainActor
func testPeerProfile(_ vm: IntercomViewModel, peerID: String, displayName: String, revision: UInt64 = 1,
                     signer: DeviceIdentitySigner? = nil) throws -> SharedDisplayName {
    try SharedDisplayName.make(groupID: #require(vm.activeGroupID), recipientMemberID: vm.localMemberIdentity.memberID,
        challenge: #require(vm.peerProfiles[peerID]).challenge, revision: revision, displayName: displayName,
        signer: signer ?? testIdentitySigner(peerID))
}

@MainActor
func testVerifiedPeerProfile(groupID: UUID, memberID: String, displayName: String) throws -> VerifiedPeerProfile {
    let nonce = UUID()
    return try SharedDisplayName.make(groupID: groupID, recipientMemberID: "local", challenge: nonce,
        revision: 1, displayName: displayName, signer: testIdentitySigner(memberID))
        .verified(peerID: memberID, recipient: "local", groupID: groupID, challenge: nonce)
}
