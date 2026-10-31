import CryptoKit
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct NotificationPermissionTests {
    let owner = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "a", count: 64))
    let local = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "b", count: 64))

    @Test func permissionRequiresTheSavedDirectContactKeyAndBothAccounts() throws {
        let signer = try DeviceIdentitySigner(memberID: "friend", key: .init())
        let grant = try testCallNotificationGrant(owner: owner, allowedSender: local)
        let message = try CallNotificationPermissionMessage.make(owner: owner, allowedSender: local, revision: 1, grant: grant, signer: signer)
        let user = SavedUser(displayName: "Local only name", memberIDs: ["friend"], deviceKeys: ["friend": signer.publicKey], principal: owner)
        #expect(try message.verifiedGrant(peerID: "friend", savedUser: user, local: local) == grant)
        let groupOnly = SavedUser(displayName: "Group only", memberIDs: ["friend"], principal: nil)
        #expect(throws: (any Error).self) { try message.verifiedGrant(peerID: "friend", savedUser: groupOnly, local: local) }
        var changed = message; changed.allowedSender = owner
        #expect(throws: (any Error).self) { try changed.verifiedGrant(peerID: "friend", savedUser: user, local: local) }
        let otherKey = try DeviceIdentitySigner(memberID: "friend", key: .init())
        var impersonated = user; impersonated.deviceKeys = ["friend": otherKey.publicKey]
        #expect(throws: (any Error).self) { try message.verifiedGrant(peerID: "friend", savedUser: impersonated, local: local) }
    }

    @Test func signedRevocationCannotBeChangedIntoAnOldGrant() throws {
        let signer = try DeviceIdentitySigner(memberID: "friend", key: .init())
        let user = SavedUser(displayName: "Friend", memberIDs: ["friend"], deviceKeys: ["friend": signer.publicKey], principal: owner)
        var revoked = try CallNotificationPermissionMessage.make(owner: owner, allowedSender: local, revision: 2, grant: nil, signer: signer)
        #expect(try revoked.verifiedGrant(peerID: "friend", savedUser: user, local: local) == nil)
        revoked.grant = try testCallNotificationGrant(owner: owner, allowedSender: local)
        #expect(throws: (any Error).self) { try revoked.verifiedGrant(peerID: "friend", savedUser: user, local: local) }
    }

    @Test func notificationTapContainsRoutingOnlyAndRejectsUnknownVersionsAndMalformedIDs() {
        let requestID = UUID()
        let payload: [AnyHashable: Any] = ["version": 1, "requestID": requestID.uuidString, "recipientID": local.userID]
        #expect(CallNotificationTap(payload: payload) == .init(requestID: requestID, recipientID: local.userID))
        #expect(CallNotificationTap(payload: ["version": 2, "requestID": requestID.uuidString, "recipientID": local.userID]) == nil)
        #expect(CallNotificationTap(payload: ["version": 1, "requestID": "bad", "recipientID": local.userID]) == nil)
        #expect(CallNotificationTap(payload: ["version": 1, "requestID": requestID.uuidString, "recipientID": "other-user"]) == nil)
    }

    @Test func requestExpiryUsesTheOriginalServerDateAndCancelledRequestsNeverStart() {
        let now = Date()
        let value = CallNotificationReply(requestID: UUID(), expiresAt: now.addingTimeInterval(120).timeIntervalSince1970 * 1000, status: .accepted)
        #expect(value.isLive(at: now.addingTimeInterval(119.999)))
        #expect(!value.isLive(at: now.addingTimeInterval(120)))
        let cancelled = CallNotificationReply(requestID: value.requestID, expiresAt: value.expiresAt, status: .cancelled)
        #expect(!cancelled.isLive(at: now))
    }
}
