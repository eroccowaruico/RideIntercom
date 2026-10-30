import Foundation
import RTC

extension IntercomViewModel {
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
