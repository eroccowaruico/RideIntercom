import Foundation

extension IntercomViewModel {
    var standardCallStatus: StandardCallStatus { callStatus(for: selectedGroup?.id) }

    func callStatus(for groupID: UUID?) -> StandardCallStatus {
        guard let groupID else { return .chooseDestination }
        guard groupID == activeGroupID, hasAnyActiveGroupConnection else { return .ready }
        if isAudioPausedForDeviceChange { return .audioPaused }
        if !isAudioReady, audioErrorMessage != nil { return .audioUnavailable }
        return isAudioReady && currentRepresentativeProfiles.values.contains { $0.verified != nil && $0.membershipID != nil } && (!enforceCallAccess || callAccessState.isEstablished) ? .inCall : .connecting
    }

    func setInterfaceMode(_ mode: InterfaceMode) {
        guard canStartCalls, interfaceMode != mode else { return }
        interfaceMode = mode
        saveAppSettings()
    }

    /// Advanced always shows Groups; Standard only when the person has turned the tab on.
    var isGroupsTabVisible: Bool { interfaceMode == .advanced || showsGroupsTab }

    func setShowsGroupsTab(_ shows: Bool) {
        guard canStartCalls, showsGroupsTab != shows else { return }
        showsGroupsTab = shows
        saveAppSettings()
    }
}
