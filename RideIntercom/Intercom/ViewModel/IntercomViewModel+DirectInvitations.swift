import Foundation
import RTC

extension IntercomViewModel {
    func sendPendingInvitationReceipt() {
        guard canEditSavedGroups, let groupID = activeGroupID,
              let receipt = groupRepository.pendingInvitation(for: groupID),
              receipt.inviteeMemberID == localMemberIdentity.memberID,
              authenticatedPeerIDs.contains(receipt.inviterMemberID) else { return }
        sendInvitationReceipt(receipt)
    }

    private func sendInvitationReceipt(_ receipt: DirectInvitationReceipt) {
        guard let payload = try? JSONEncoder().encode(receipt) else { return }
        callSession.sendApplicationData(.init(namespace: DirectInvitationReceipt.namespace, payload: payload))
    }

    func receiveInvitationReceipt(peerID: String, message: ApplicationDataMessage) {
        guard message.namespace == DirectInvitationReceipt.namespace, message.payload.count <= 2048,
              authenticatedPeerIDs.contains(peerID),
              let receipt = try? JSONDecoder().decode(DirectInvitationReceipt.self, from: message.payload),
              receipt.isValid, receipt.groupID == activeGroupID else { return }
        do {
            switch receipt.kind {
            case .accepted:
                guard receipt.inviterMemberID == localMemberIdentity.memberID, receipt.inviteeMemberID == peerID else { return }
                try groupRepository.receiveInvitation(receipt)
                refreshGroupStorageStatus()
                var acknowledgement = receipt
                acknowledgement.kind = .acknowledged
                sendInvitationReceipt(acknowledgement)
            case .acknowledged:
                guard receipt.inviterMemberID == peerID, receipt.inviteeMemberID == localMemberIdentity.memberID else { return }
                try groupRepository.acknowledgeInvitation(receipt)
            }
        } catch { reportGroupStorageError(error) }
    }
}
