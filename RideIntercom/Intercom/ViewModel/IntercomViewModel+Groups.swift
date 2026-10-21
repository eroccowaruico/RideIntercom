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
        catch { groupErrorMessage = "Could not delete the group and its key. Try again."; return }
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

    func createTalkGroup() {
        groupErrorMessage = nil
        let groupID = UUID()
        let newGroup = try? IntercomGroup(
            id: groupID,
            name: "Talk Group",
            members: [
                GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName)
            ]
        )

        guard let newGroup else { return }
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        do { try groupRepository.save([newGroup] + groups, credential: .init(groupID: groupID, secret: secret)) }
        catch {
            groupErrorMessage = "Could not save the group and its key. Try again."
            return
        }
        groups.insert(newGroup, at: 0)
        selectGroup(newGroup)
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
            members.append(GroupMember(id: token.inviterMemberID, displayName: "Inviter"))
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
        do { try groupRepository.save(updated, credential: .init(groupID: token.groupID, secret: token.groupSecret)) }
        catch {
            groupErrorMessage = "Could not save the group and its key. Try the invitation again."
            throw error
        }
        groups = updated
        if selectedGroup?.id == group.id { selectedGroup = nil }
        selectGroup(group)
        inviteStatusMessage = "JOINED \(token.groupName)"
    }
}
