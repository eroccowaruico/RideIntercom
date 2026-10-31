import AVFoundation
import Codec
import CryptoKit
import Foundation
import OSLog
import RTC
import SessionManager
import VADGate

extension IntercomViewModel {
    func selectGroup(_ group: IntercomGroup, connectIfIdle: Bool = true) {
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
        if connectIfIdle { connectLocal() }
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
        callAccessState = CallAccessState()
        lastCallAccessSaveAttempt = nil
        connectionState = .idle
        isVoiceActive = false
        connectedPeerIDs = []
        authenticatedPeerIDs = []
        peerProfiles.removeAll()
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
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return }
        let remaining = groups.filter { $0.id != groupID }
        do { try groupRepository.delete(groupID, remaining: remaining) }
        catch { reportGroupStorageError(error); return }
        refreshGroupStorageStatus()
        if activeGroupID == groupID { disconnect() }
        if selectedGroup?.id == groupID { selectedGroup = nil }
        groups = remaining
        discardUnavailableRecentCall()
    }

    func canRemoveMember(_ memberID: String) -> Bool {
        memberID != localMemberIdentity.memberID
    }

    func removeMember(_ memberID: String, from groupID: UUID) {
        guard canRemoveMember(memberID),
              let groupIndex = groups.firstIndex(where: { $0.id == groupID }), groups[groupIndex].kind == .group else { return }

        var updated = groups
        updated[groupIndex].members.removeAll { $0.id == memberID }
        updated[groupIndex].accountDevices.removeValue(forKey: memberID)
        guard commitGroups(updated) else { return }
        if activeGroupID == groupID {
            connectedPeerIDs.removeAll { $0 == memberID }
            authenticatedPeerIDs.removeAll { $0 == memberID }
            peerProfiles.removeValue(forKey: memberID)
            callSession.setAudioPolicy(currentCallAudioPolicy())
            refreshCallAccess()
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
        guard requireGroupAccess() else { return false }
        guard let remoteMembers = membersForSavedUsers(userIDs) else { return false }
        guard remoteMembers.count < IntercomGroup.maximumMemberCount, IntercomGroup.isValidName(name), !name.contains("|") else {
            groupErrorMessage = "Enter a group name without | and choose up to 7 other members."
            return false
        }
        let groupID = UUID()
        let members = [GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName)] + remoteMembers
        let newGroup = try? IntercomGroup(
            id: groupID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            members: members, accountDevices: groupAccountDevices(for: members)
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
        guard requireGroupAccess() else { return }
        guard var group = selectedGroup,
              group.kind == .group,
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
        guard canStartCalls else { throw IntercomGroupError.storageUnavailable }
        groupErrorMessage = nil
        let token = try GroupInviteTokenCodec.decodeJoinURL(url)
        guard !token.isExpired(now: now) else {
            throw GroupInviteTokenError.expired
        }
        if let recipient = token.recipientMemberID, recipient != localMemberIdentity.memberID {
            groupErrorMessage = "This call invitation is addressed to another rider."
            throw GroupInviteTokenError.wrongRecipient
        }
        if let recipient = token.recipientAccount, recipient != localAccountPrincipal {
            groupErrorMessage = "This call invitation is addressed to another rider."
            throw GroupInviteTokenError.wrongRecipient
        }
        let kind: IntercomGroup.Kind = token.recipientMemberID == nil && token.accountPair == nil ? .group : .direct
        if let existing = groups.first(where: { $0.id == token.groupID }), (existing.kind != kind || existing.accountPair != token.accountPair) {
            groupErrorMessage = "This invitation cannot change an individual call into a group."
            throw GroupInviteTokenError.incompatibleCall
        }

        let accepted = try token.accept(signer: internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID),
                                        displayName: localMemberIdentity.displayName, trust: try internetSettingsStore.identityTrust(), now: now)
        let previous = try groupRepository.credential(for: token.groupID)
        // Account calls converge by principal, independently of which device invited.
        // Do not replace a call that has already connected; reconnect explicitly.
        let keepsLocalKey = token.accountPair.map { $0.first == localAccountPrincipal }
            ?? (localMemberIdentity.memberID < token.inviterMemberID)
        if kind == .direct, let previous, previous.secret != token.groupSecret,
           let existing = groups.first(where: { $0.id == token.groupID }),
           keepsLocalKey {
            selectGroup(existing)
            groupErrorMessage = "You both created a call invitation. Share this call's invitation so you use the same call."
            return
        }
        if let existing = groups.first(where: { $0.id == token.groupID }), previous?.secret == token.groupSecret {
            let name = token.inviterDisplayName ?? savedUsers.first { $0.memberIDs.contains(token.inviterMemberID) }?.displayName ?? "Inviter"
            do {
                try groupRepository.acceptInvitation(accepted, inviterName: name, retainingMemberIDs: Set(currentRepresentativeProfiles.keys))
                refreshStoredAccountCall(token.groupID)
                refreshGroupStorageStatus()
            } catch { reportGroupStorageError(error); throw error }
            selectGroup(groups.first { $0.id == existing.id } ?? existing)
            inviteStatusMessage = "JOINED \(existing.name)"
            return
        }
        guard activeGroupID != token.groupID else {
            groupErrorMessage = "This invitation changes the active group key. Disconnect before opening it again."
            throw GroupInviteTokenError.activeGroupKeyChanged
        }
        var members = [GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName)]
        let ownOtherDevice = accepted.inviter.principal != nil && accepted.inviter.principal == localAccountPrincipal
        if token.inviterMemberID != localMemberIdentity.memberID && !ownOtherDevice {
            let name = token.inviterDisplayName ?? savedUsers.first { $0.memberIDs.contains(token.inviterMemberID) }?.displayName ?? "Inviter"
            members.append(GroupMember(id: token.inviterMemberID, displayName: name))
        }
        var devices: [String: AccountDeviceBinding] = [:]
        if token.accountPair != nil || kind == .group {
            if let local = localAccountPrincipal {
                let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
                devices[signer.memberID] = .init(principal: local, publicKey: signer.publicKey)
            }
            if let remote = accepted.inviter.principal, !ownOtherDevice {
                devices[token.inviterMemberID] = .init(principal: remote, publicKey: accepted.inviter.publicKey)
            }
        }
        let group = try IntercomGroup(
            id: token.groupID,
            name: token.groupName,
            members: members,
            kind: kind, accountPair: token.accountPair, accountDevices: devices
        )
        var updated = groups
        if let existingIndex = updated.firstIndex(where: { $0.id == group.id }) {
            updated[existingIndex] = group
        } else {
            updated.insert(group, at: 0)
        }
        do {
            try groupRepository.save(updated, credential: .init(groupID: token.groupID, secret: token.groupSecret), acceptedInvitation: accepted, inviterName: token.inviterDisplayName ?? "Inviter")
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
