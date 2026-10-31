import Foundation
import RTC

extension IntercomViewModel {
    func setCallNotificationsAllowed(_ allowed: Bool, for userID: UUID) async {
        if await notifications.setIncomingAllowed(allowed, contactID: userID) { sendNotificationPermissions() }
    }
    /// Application data is a broadcast API. Personal grants therefore use only
    /// an account-bound direct call with exactly its intended peer connected.
    private func notificationExchangeContext() -> (peerID: String, group: IntercomGroup)? {
        guard canStartCalls, let local = localAccountPrincipal, let activeGroupID,
              let group = groups.first(where: { $0.id == activeGroupID }), group.kind == .direct,
              group.accountDevices[localMemberIdentity.memberID]?.principal == local,
              authenticatedPeerIDs.count == 1, connectedPeerIDs.count == 1,
              let peerID = authenticatedPeerIDs.first, connectedPeerIDs.first == peerID,
              let profile = peerProfiles[peerID]?.verified, profile.identity.memberID == peerID,
              let user = savedRemoteUsers.first(where: { $0.memberIDs.contains(peerID) }), let peer = user.principal,
              peer != local, peer.issuer == local.issuer, group.accountPair?.other(than: local) == peer,
              group.accountDevices[peerID]?.principal == peer,
              group.accountDevices[peerID]?.publicKey == profile.identity.publicKey,
              user.deviceKeys?[peerID] == profile.identity.publicKey,
              profile.identity.principal == nil || profile.identity.principal == peer else { return nil }
        return (peerID, group)
    }
    func sendNotificationPermissions() {
        guard notifications.hasPermissionsToShare, let context = notificationExchangeContext(),
              let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID),
              context.group.accountDevices[localMemberIdentity.memberID]?.publicKey == signer.publicKey,
              let value = try? notifications.permissionMessage(for: context.peerID, signer: signer),
              let payload = try? JSONEncoder().encode(value), payload.count <= 8192 else { return }
        callSession.sendApplicationData(.init(namespace: CallNotificationPermissionMessage.namespace, payload: payload))
    }
    func receiveNotificationPermission(peerID: String, message: ApplicationDataMessage) {
        guard message.namespace == CallNotificationPermissionMessage.namespace, message.payload.count <= 8192,
              notificationExchangeContext()?.peerID == peerID,
              let value = try? JSONDecoder().decode(CallNotificationPermissionMessage.self, from: message.payload) else { return }
        do { try notifications.receivePermission(value, peerID: peerID) }
        catch { /* Untrusted or unrelated capabilities cannot authorize a call. */ }
    }
}
