import Foundation

enum GroupStorageIssue: Equatable {
    case unavailable, corrupted, unsupportedVersion, invalidChange
    static func classify(_ error: Error) -> Self {
        if error as? GroupStorageError == .unsupportedVersion { return .unsupportedVersion }
        if error as? GroupStorageError == .invalidUpdate { return .invalidChange }
        if error is DecodingError || error as? IntercomGroupError == .invalidStoredGroups { return .corrupted }
        if error as? IntercomGroupError == .invalidIdentity || error as? IntercomGroupError == .invalidMemberCount { return .invalidChange }
        return .unavailable
    }
    var message: String {
        switch self {
        case .unavailable: "Saved groups could not be accessed. Unlock this device or close another running copy, then reload."
        case .corrupted: "Saved groups could not be read. Reload to retry, or reset saved groups after preserving the unreadable data."
        case .unsupportedVersion: "Saved groups were created by a newer app. Open them with that version."
        case .invalidChange: "The group changes were invalid. Saved groups have been preserved. Reload before trying again."
        }
    }
}

extension IntercomViewModel {
    var canEditSavedGroups: Bool { groupStorageIssue == nil }
    var groupStorageNotice: String? {
        if let groupStorageIssue { return groupStorageIssue.message }
        if groupKeyCleanupPending { return "Groups were saved. Unused group keys will be removed on the next reload." }
        if !groupsMissingKeys.isEmpty { return "Some groups have no saved key. Ask a member for a new invitation to those groups." }
        return nil
    }
    func refreshGroupStorageStatus() {
        savedUsers = groupRepository.users
        applySavedUserNames()
        groupsMissingKeys = groupRepository.missingCredentialGroupIDs
        groupKeyCleanupPending = groupRepository.needsCleanup
    }
    func reportGroupStorageError(_ error: Error) {
        groupStorageIssue = .classify(error)
        groupErrorMessage = groupStorageIssue?.message
    }
    func reloadSavedGroups() {
        // The persisted identity list must not overwrite active runtime state.
        guard activeGroupID == nil else {
            groupErrorMessage = "Disconnect before reloading saved groups."
            return
        }
        do {
            groups = try groupRepository.load(localMemberID: localMemberIdentity.memberID)
            selectedGroup = nil; groupStorageIssue = nil; groupErrorMessage = nil
            refreshGroupStorageStatus()
        } catch { reportGroupStorageError(error) }
    }
    func resetSavedGroups() {
        guard groupStorageIssue != .unsupportedVersion else { return }
        disconnect()
        do {
            try groupRepository.reset()
            groups = []; selectedGroup = nil; groupStorageIssue = nil; groupErrorMessage = nil
            refreshGroupStorageStatus()
        } catch { reportGroupStorageError(error) }
    }
}
