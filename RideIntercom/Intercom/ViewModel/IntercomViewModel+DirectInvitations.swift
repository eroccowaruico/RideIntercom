import Foundation
import RTC

extension IntercomViewModel {
    // Presentation must not load keys or issue an invitation.
    var canShareSelectedGroup: Bool {
        guard canEditSavedGroups, let group = selectedGroup,
              groups.contains(where: { $0.id == group.id }),
              group.members.contains(where: { $0.id == localMemberIdentity.memberID }),
              !groupsMissingKeys.contains(group.id) || group.accessSecret != nil else { return false }
        guard group.kind == .direct || canManageRegularGroups else { return false }
        return group.kind != .direct || directCallRecipient(for: group) != nil || directCallAccountRecipient(for: group) != nil
    }

    func makeSelectedGroupInviteURL(expectedGroupID: UUID? = nil) -> URL? {
        guard canShareSelectedGroup, let group = selectedGroup,
              expectedGroupID == nil || expectedGroupID == group.id else { return nil }
        do {
            guard let credential = try credential(for: group) else {
                groupErrorMessage = "This group has no saved key. Ask a member for a new invitation."
                return nil
            }
            let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
            let token = try GroupInviteToken.make(authority: invitationAuthority, signer: signer,
                groupID: group.id, groupName: group.name, groupSecret: credential.secret,
                inviterMemberID: localMemberIdentity.memberID, inviterDisplayName: localMemberIdentity.displayName,
                recipientMemberID: directCallRecipient(for: group), recipientAccount: directCallAccountRecipient(for: group))
            return try GroupInviteTokenCodec.joinURL(for: token)
        } catch GroupInviteTokenError.accountVerificationRequired {
            groupErrorMessage = "Verify your account in Internet Connection before sharing a new individual call invitation."
            return nil
        } catch { reportGroupStorageError(error); return nil }
    }

    func sendPendingInvitationReceipt() {
        guard canEditSavedGroups, let groupID = activeGroupID,
              var receipt = groupRepository.pendingInvitation(for: groupID),
              let invitation = receipt.invitation, invitation.expiresAt > Date().timeIntervalSince1970, receipt.proof != nil, receipt.acceptanceProof != nil,
              receipt.inviteeMemberID == localMemberIdentity.memberID, let expectedKey = receipt.inviteeDeviceKey,
              authenticatedPeerIDs.contains(receipt.inviterMemberID) else { return }
        receipt.displayName = localMemberIdentity.displayName
        guard let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: expectedKey),
              let proof = try? signer.sign(receipt.identityMessage(), purpose: .acceptInvitation) else { return }
        receipt.acceptanceProof = proof
        sendInvitationReceipt(receipt)
    }

    private func sendInvitationReceipt(_ receipt: DirectInvitationReceipt) {
        guard let payload = try? JSONEncoder().encode(receipt) else { return }
        callSession.sendApplicationData(.init(namespace: DirectInvitationReceipt.namespace, payload: payload))
    }

    func receiveInvitationReceipt(peerID: String, message: ApplicationDataMessage) {
        guard canEditSavedGroups, message.namespace == DirectInvitationReceipt.namespace, message.payload.count <= 8192,
              authenticatedPeerIDs.contains(peerID),
              let receipt = try? JSONDecoder().decode(DirectInvitationReceipt.self, from: message.payload),
              receipt.isValid, receipt.groupID == activeGroupID else { return }
        do {
            switch receipt.kind {
            case .accepted:
                guard receipt.inviterMemberID == localMemberIdentity.memberID, receipt.inviteeMemberID == peerID else { return }
                guard let verified = try invitationAuthority.verify(receipt, trust: internetSettingsStore.identityTrust()) else { return }
                try groupRepository.receiveInvitation(verified)
                refreshGroupStorageStatus()
                guard let expectedKey = receipt.invitation?.inviterDeviceKey else { return }
                let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: expectedKey)
                sendInvitationReceipt(try receipt.acknowledged(by: signer))
            case .acknowledged:
                guard receipt.inviterMemberID == peerID, receipt.inviteeMemberID == localMemberIdentity.memberID else { return }
                try groupRepository.acknowledgeInvitation(receipt)
            }
        } catch { reportGroupStorageError(error) }
    }
}
