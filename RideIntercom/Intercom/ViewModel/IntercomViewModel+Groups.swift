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
        selectedGroup = nil
        inviteStatusMessage = nil
    }

    var hasActiveConversationConnection: Bool {
        isAudioReady || connectionState == .localConnected || connectionState == .internetConnected || !authenticatedPeerIDs.isEmpty
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
        persistGroups()
    }

    func deleteGroup(_ groupID: UUID) {
        if activeGroupID == groupID { disconnect() }
        if selectedGroup?.id == groupID { selectedGroup = nil }
        groups.removeAll { $0.id == groupID }
        persistGroups()
    }

    func canRemoveMember(_ memberID: String) -> Bool {
        memberID != localMemberIdentity.memberID
    }

    func removeMember(_ memberID: String, from groupID: UUID) {
        guard canRemoveMember(memberID),
              let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }

        groups[groupIndex].members.removeAll { $0.id == memberID }
        connectedPeerIDs.removeAll { $0 == memberID }
        authenticatedPeerIDs.removeAll { $0 == memberID }
        remoteVoiceReceivedAt.removeValue(forKey: memberID)
        remoteVoicePeakWindows.removeValue(forKey: memberID)

        if selectedGroup?.id == groupID {
            selectedGroup = groups[groupIndex]
        }
        persistGroups()
    }

    func createTalkGroup() {
        let groupID = UUID()
        let newGroup = try? IntercomGroup(
            id: groupID,
            name: "Talk Group",
            members: [
                GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName)
            ]
        )

        guard let newGroup else { return }
        groups.insert(newGroup, at: 0)
        persistGroups()
        selectGroup(newGroup)
    }

    func addPendingMember(displayName: String? = nil) {
        guard var group = selectedGroup,
              group.members.count < IntercomGroup.maximumMemberCount else { return }

        let nextNumber = group.members.count
        let memberID = "\(Self.pendingMemberPrefix)\(group.id.uuidString.prefix(8).lowercased())-\(nextNumber)"
        let name = displayName ?? "Rider \(nextNumber)"
        group.members.append(GroupMember(id: memberID, displayName: name))
        selectedGroup = group
        replaceSelectedGroup(group)
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
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    func acceptInviteURL(_ url: URL, now: TimeInterval = Date().timeIntervalSince1970) throws {
        let token = try GroupInviteTokenCodec.decodeJoinURL(url)
        guard !token.isExpired(now: now) else {
            throw GroupInviteTokenError.expired
        }

        credentialStore.save(GroupAccessCredential(groupID: token.groupID, secret: token.groupSecret))

        let group = try IntercomGroup(
            id: token.groupID,
            name: token.groupName,
            members: [
                GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName),
                GroupMember(id: token.inviterMemberID, displayName: "Inviter")
            ]
        )

        if let existingIndex = groups.firstIndex(where: { $0.id == group.id }) {
            groups[existingIndex] = group
        } else {
            groups.insert(group, at: 0)
        }

        persistGroups()
        selectGroup(group)
        inviteStatusMessage = "JOINED \(token.groupName)"
    }
}
