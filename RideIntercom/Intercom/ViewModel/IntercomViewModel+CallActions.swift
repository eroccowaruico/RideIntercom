import Foundation

nonisolated enum CallDestination: Codable, Equatable, Sendable {
    case group(UUID)
    case user(UUID)
}

/// A snapshot of the account and connection being controlled, including idle mute intent.
nonisolated struct CallReference: Equatable, Sendable {
    let accountAccessID: UUID
    let connectionGeneration: UUID
    let groupID: UUID?
}

extension IntercomViewModel {
    var recentCallDestination: CallDestination? {
        guard canStartCalls, groupStorageIssue == nil, let destination = storedRecentCallDestination else { return nil }
        switch destination {
        case .user(let id): return savedRemoteUsers.contains { $0.id == id } ? destination : nil
        case .group(let id): return regularGroups.contains { $0.id == id } ? destination : nil
        }
    }

    var recentCallTitle: String? {
        switch recentCallDestination {
        case .user(let id): savedRemoteUsers.first { $0.id == id }?.resolvedDisplayName
        case .group(let id): regularGroups.first { $0.id == id }?.name
        case nil: nil
        }
    }

    @discardableResult
    func startRecentCall(accountAccessID: UUID) -> Bool {
        guard let destination = recentCallDestination else {
            groupErrorMessage = groupStorageNotice ?? "No recent call is available. Choose a saved user or group."
            return false
        }
        return startCall(to: destination, accountAccessID: accountAccessID)
    }

    /// Transport connection alone is insufficient: the current participant proof
    /// and the local media pipeline must both be ready.
    func recordEstablishedCall() {
        guard canStartCalls, isAudioReady, !enforceCallAccess || callAccessState.isEstablished,
              authenticatedPeerIDs.contains(where: { peerProfiles[$0]?.verified != nil }),
              let group = groups.first(where: { $0.id == activeGroupID }) else { return }
        let destination: CallDestination?
        if group.kind == .group {
            destination = .group(group.id)
        } else if let principal = directCallAccountRecipient(for: group) {
            destination = savedRemoteUsers.first { $0.principal == principal }.map { .user($0.id) }
        } else if let memberID = directCallRecipient(for: group) {
            destination = savedRemoteUsers.first { $0.memberIDs.contains(memberID) }.map { .user($0.id) }
        } else { destination = nil }
        guard let destination, destination != storedRecentCallDestination else { return }
        storedRecentCallDestination = destination
        saveAppSettings()
    }

    func discardUnavailableRecentCall() {
        // A read failure is not evidence that the destination was removed.
        guard canStartCalls, groupStorageIssue == nil,
              storedRecentCallDestination != nil, recentCallDestination == nil else { return }
        storedRecentCallDestination = nil
        saveAppSettings()
    }

    var currentCallReference: CallReference {
        .init(accountAccessID: accountAccessID, connectionGeneration: connectionGeneration, groupID: activeGroupID)
    }

    /// Resolve a durable destination again when the action runs, not when a screen
    /// or external control originally displayed it.
    @discardableResult
    func startCall(to destination: CallDestination, accountAccessID requestedAccess: UUID, allowSwitchingCall: Bool = true) -> Bool {
        guard canStartCalls, requestedAccess == accountAccessID else {
            groupErrorMessage = groupStorageNotice ?? "This sign-in has ended. Open your current account to continue."
            return false
        }
        let previousSelection = selectedGroup
        switch destination {
        case .group(let id):
            guard let group = groups.first(where: { $0.id == id }) else {
                groupErrorMessage = "This saved group is no longer available."
                return false
            }
            // A retained individual call is not a way around removing its contact.
            // Keep its existing ID and key when reconnecting a still-saved contact.
            guard group.kind != .direct || directCallAccountRecipient(for: group) != nil || directCallRecipient(for: group) != nil else {
                groupErrorMessage = "This saved user is no longer available for an individual call."
                return false
            }
            selectGroup(group, connectIfIdle: false)
        case .user(let id):
            guard selectUser(id, connectIfIdle: false) else { return false }
        }
        guard let selectedGroup else { return false }
        if !allowSwitchingCall, hasAnyActiveGroupConnection, activeGroupID != selectedGroup.id {
            self.selectedGroup = previousSelection
            groupErrorMessage = "End the current call before starting a different call."
            return false
        }
        if activeGroupID == selectedGroup.id, hasAnyActiveGroupConnection { return true }
        connectSelectedGroup()
        return activeGroupID == selectedGroup.id && hasAnyActiveGroupConnection
    }

    @discardableResult
    func endCall(_ reference: CallReference) -> Bool {
        guard reference.groupID != nil, matchesCurrentCall(reference) else { return false }
        disconnect()
        return true
    }

    @discardableResult
    func setCallMuted(_ muted: Bool, for reference: CallReference) -> Bool {
        guard canStartCalls, matchesCurrentCall(reference) else { return false }
        applyLocalMute(muted)
        return true
    }

    private func matchesCurrentCall(_ reference: CallReference) -> Bool {
        hasCurrentAccountAccess && currentCallReference == reference
    }
}
