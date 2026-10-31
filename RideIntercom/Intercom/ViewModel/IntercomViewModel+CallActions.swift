import Foundation

nonisolated enum CallDestination: Equatable, Sendable {
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
    var currentCallReference: CallReference {
        .init(accountAccessID: accountAccessID, connectionGeneration: connectionGeneration, groupID: activeGroupID)
    }

    /// Resolve a durable destination again when the action runs, not when a screen
    /// or external control originally displayed it.
    @discardableResult
    func startCall(to destination: CallDestination, accountAccessID requestedAccess: UUID) -> Bool {
        guard canStartCalls, requestedAccess == accountAccessID else {
            groupErrorMessage = groupStorageNotice ?? "This sign-in has ended. Open your current account to continue."
            return false
        }
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
