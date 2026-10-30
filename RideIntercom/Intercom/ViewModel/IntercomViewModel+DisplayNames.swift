import Foundation
import RTC

nonisolated struct SharedDisplayName: Codable, Sendable {
    static let namespace = "rideintercom.display-name.v1"
    let groupID: UUID
    let displayName: String
    let requestsReply: Bool
}

extension IntercomViewModel {
    @discardableResult
    func setLocalDisplayName(_ value: String) -> Bool {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canStartCalls, IntercomGroup.isValidName(name) else {
            groupErrorMessage = "Enter a valid display name."; return false
        }
        localMemberIdentityStore.saveDisplayName(name)
        localMemberIdentity.displayName = name
        applySavedUserNames()
        sendSharedDisplayName()
        groupErrorMessage = nil
        return true
    }

    func sendSharedDisplayName(requestsReply: Bool = false) {
        guard let groupID = activeGroupID, !authenticatedPeerIDs.isEmpty else { return }
        let value = SharedDisplayName(groupID: groupID, displayName: localMemberIdentity.displayName, requestsReply: requestsReply)
        guard let payload = try? JSONEncoder().encode(value) else { return }
        callSession.sendApplicationData(.init(namespace: SharedDisplayName.namespace, payload: payload))
    }

    func receiveSharedDisplayName(peerID: String, message: ApplicationDataMessage) {
        guard message.namespace == SharedDisplayName.namespace, message.payload.count <= 2048,
              authenticatedPeerIDs.contains(peerID), canEditSavedGroups,
              let value = try? JSONDecoder().decode(SharedDisplayName.self, from: message.payload),
              value.groupID == activeGroupID, IntercomGroup.isValidName(value.displayName) else { return }
        do {
            try groupRepository.receiveDisplayName(value.displayName, from: peerID, in: value.groupID)
            refreshGroupStorageStatus()
            if value.requestsReply { sendSharedDisplayName() }
        } catch { reportGroupStorageError(error) }
    }

    @discardableResult
    func resetSavedUserName(_ id: UUID) -> Bool {
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        do { try groupRepository.resetUserName(id) }
        catch { reportGroupStorageError(error); return false }
        refreshGroupStorageStatus(); groupErrorMessage = nil
        return true
    }

    @discardableResult
    func renameGroupMember(_ memberID: String, in groupID: UUID, displayName: String) -> Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IntercomGroup.isValidName(name) else { groupErrorMessage = "Enter a valid display name."; return false }
        return setGroupMemberName(memberID, in: groupID, localName: name)
    }

    @discardableResult
    func resetGroupMemberName(_ memberID: String, in groupID: UUID) -> Bool {
        setGroupMemberName(memberID, in: groupID, localName: nil)
    }

    private func setGroupMemberName(_ memberID: String, in groupID: UUID, localName: String?) -> Bool {
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        do { try groupRepository.setMemberName(memberID, in: groupID, localName: localName) }
        catch { reportGroupStorageError(error); return false }
        refreshGroupStorageStatus(); groupErrorMessage = nil
        return true
    }
}
