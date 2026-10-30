import AVFoundation
import Codec
import CryptoKit
import Foundation
import OSLog
import RTC
import SessionManager
import VADGate

extension IntercomViewModel {
    func selectGroup(_ group: IntercomGroup) {
        groupErrorMessage = nil
        if selectedGroup?.id == group.id {
            return
        }

        if activeGroupID == group.id {
            if let activeGroup = groups.first(where: { $0.id == group.id }) {
                selectedGroup = activeGroup
            } else {
                selectedGroup = group.withMemberAuthenticationState(.open)
            }
            inviteStatusMessage = nil

            if hasAnyActiveGroupConnection {
                return
            }
        }

        if let activeGroupID,
           activeGroupID != group.id,
           hasAnyActiveGroupConnection {
            selectedGroup = makeInactiveDisplayGroup(from: group)
            inviteStatusMessage = nil
            return
        }

        selectedGroup = group.withMemberAuthenticationState(.open)
        inviteStatusMessage = nil
        connectLocal()
    }

    func showGroupSelection() {
        groupErrorMessage = nil
        selectedGroup = nil
        inviteStatusMessage = nil
    }


    var hasAnyActiveGroupConnection: Bool {
        guard activeGroupID != nil else { return false }
        return connectionState != .idle || isAudioReady || !authenticatedPeerIDs.isEmpty || localNetworkStatus != .idle
    }

    var presentedConnectionState: CallConnectionState {
        guard selectedGroup?.id == activeGroupID else { return .idle }
        return connectionState
    }

    var presentedLocalNetworkStatus: LocalNetworkStatus {
        guard selectedGroup?.id == activeGroupID else { return .idle }
        return localNetworkStatus
    }

    var hasPresentedAuthenticatedConnection: Bool {
        guard selectedGroup?.id == activeGroupID else { return false }
        return !authenticatedPeerIDs.isEmpty
    }

    func resetConnectionRuntimeState() {
        connectionState = .idle
        isVoiceActive = false
        connectedPeerIDs = []
        authenticatedPeerIDs = []
        localNetworkStatus = .idle
        lastLocalNetworkPeerID = nil
        lastLocalNetworkEventAt = nil
        resetVoiceLevelWindows()
        resetAudioDebugCounters()
    }

    func makeInactiveDisplayGroup(from group: IntercomGroup) -> IntercomGroup {
        var group = group
        group.members = group.members.map { member in
            var updated = member
            updated.connectionState = .offline
            updated.authenticationState = member.id == localMemberIdentity.memberID ? .open : .offline
            updated.isTalking = false
            updated.voiceLevel = 0
            updated.voicePeakLevel = 0
            updated.queuedAudioFrameCount = 0
            return updated
        }
        return group
    }

    func withActiveGroup(_ update: (inout IntercomGroup) -> Void) {
        guard let groupID = activeGroupID ?? selectedGroup?.id,
              let index = groups.firstIndex(where: { $0.id == groupID }) else { return }

        var group = groups[index]
        update(&group)
        groups[index] = group
        if selectedGroup?.id == group.id {
            selectedGroup = group
        }
    }

    func deleteGroup(_ groupID: UUID) {
        let remaining = groups.filter { $0.id != groupID }
        do { try groupRepository.delete(groupID, remaining: remaining) }
        catch { reportGroupStorageError(error); return }
        refreshGroupStorageStatus()
        if activeGroupID == groupID { disconnect() }
        if selectedGroup?.id == groupID { selectedGroup = nil }
        groups = remaining
    }

    func canRemoveMember(_ memberID: String) -> Bool {
        memberID != localMemberIdentity.memberID
    }

    func removeMember(_ memberID: String, from groupID: UUID) {
        guard canRemoveMember(memberID),
              let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }

        var updated = groups
        updated[groupIndex].members.removeAll { $0.id == memberID }
        guard commitGroups(updated) else { return }
        if activeGroupID == groupID {
            connectedPeerIDs.removeAll { $0 == memberID }
            authenticatedPeerIDs.removeAll { $0 == memberID }
            remoteVoiceReceivedAt.removeValue(forKey: memberID)
            remoteVoicePeakWindows.removeValue(forKey: memberID)
            do { try audioPipeline.stopReceivePeer(memberID) }
            catch { audioErrorMessage = "Could not release the rider's audio. Reconnect to reset audio." }
        }

        if selectedGroup?.id == groupID {
            selectedGroup = groups[groupIndex]
        }
    }

    @discardableResult
    func createTalkGroup(name: String = "Talk Group", userIDs: Set<UUID> = []) -> Bool {
        groupErrorMessage = nil
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        guard let remoteMembers = membersForSavedUsers(userIDs) else { return false }
        guard remoteMembers.count < IntercomGroup.maximumMemberCount, IntercomGroup.isValidName(name), !name.contains("|") else {
            groupErrorMessage = "Enter a group name without | and choose up to 7 other members."
            return false
        }
        let groupID = UUID()
        let newGroup = try? IntercomGroup(
            id: groupID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            members: [
                GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName)
            ] + remoteMembers
        )

        guard let newGroup else {
            groupErrorMessage = "Could not create the group because the saved rider identity is invalid. Saved groups have not been changed."
            return false
        }
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        do { try groupRepository.save([newGroup] + groups, credential: .init(groupID: groupID, secret: secret)); refreshGroupStorageStatus() }
        catch {
            reportGroupStorageError(error)
            return false
        }
        groups.insert(newGroup, at: 0)
        selectGroup(newGroup)
        return true
    }

    func reserveInviteMemberSlot(displayName: String? = nil) {
        guard var group = selectedGroup,
              group.members.count < IntercomGroup.maximumMemberCount else { return }

        let nextNumber = group.members.count
        let memberID = "\(Self.pendingInviteMemberPrefix)\(group.id.uuidString.prefix(8).lowercased())-\(nextNumber)-\(UUID().uuidString.prefix(8).lowercased())"
        let name = displayName ?? "Invited Rider \(nextNumber)"
        group.members.append(
            GroupMember(
                id: memberID,
                displayName: name,
                authenticationState: .pending,
                connectionState: .connecting
            )
        )
        replaceSelectedGroup(group)
    }

    func acceptInviteURL(_ url: URL, now: TimeInterval = Date().timeIntervalSince1970) throws {
        groupErrorMessage = nil
        let token = try GroupInviteTokenCodec.decodeJoinURL(url)
        guard !token.isExpired(now: now) else {
            throw GroupInviteTokenError.expired
        }

        let previous = try groupRepository.credential(for: token.groupID)
        if let existing = groups.first(where: { $0.id == token.groupID }), previous?.secret == token.groupSecret {
            let name = savedUsers.first { $0.memberIDs.contains(token.inviterMemberID) }?.displayName ?? "Inviter"
            do {
                try groupRepository.acceptInvitation(from: .init(id: token.inviterMemberID, displayName: name), to: token.groupID)
                refreshGroupStorageStatus()
            } catch { reportGroupStorageError(error); throw error }
            selectGroup(existing)
            inviteStatusMessage = "JOINED \(existing.name)"
            return
        }
        guard activeGroupID != token.groupID else {
            groupErrorMessage = "This invitation changes the active group key. Disconnect before opening it again."
            throw GroupInviteTokenError.activeGroupKeyChanged
        }
        var members = [GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName)]
        if token.inviterMemberID != localMemberIdentity.memberID {
            let name = savedUsers.first { $0.memberIDs.contains(token.inviterMemberID) }?.displayName ?? "Inviter"
            members.append(GroupMember(id: token.inviterMemberID, displayName: name))
        }
        let group = try IntercomGroup(
            id: token.groupID,
            name: token.groupName,
            members: members
        )
        var updated = groups
        if let existingIndex = updated.firstIndex(where: { $0.id == group.id }) {
            updated[existingIndex] = group
        } else {
            updated.insert(group, at: 0)
        }
        do {
            let inviter = members.first { $0.id == token.inviterMemberID && $0.id != localMemberIdentity.memberID }
            try groupRepository.save(updated, credential: .init(groupID: token.groupID, secret: token.groupSecret), acceptedInvitationFrom: inviter)
            refreshGroupStorageStatus()
        }
        catch {
            reportGroupStorageError(error)
            throw error
        }
        groups = updated
        if selectedGroup?.id == group.id { selectedGroup = nil }
        selectGroup(group)
        inviteStatusMessage = "JOINED \(token.groupName)"
    }
}
