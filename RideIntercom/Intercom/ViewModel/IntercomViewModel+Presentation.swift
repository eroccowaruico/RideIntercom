import Foundation

extension IntercomViewModel {
    var standardCallStatus: StandardCallStatus { callStatus(for: selectedGroup?.id) }

    func callStatus(for groupID: UUID?) -> StandardCallStatus {
        guard let groupID else { return .chooseDestination }
        guard groupID == activeGroupID, hasAnyActiveGroupConnection else { return .ready }
        if isAudioPausedForDeviceChange { return .audioPaused }
        if !isAudioReady, audioErrorMessage != nil { return .audioUnavailable }
        return isAudioReady && !authenticatedPeerIDs.isEmpty && (!enforceCallAccess || callAccessState.isEstablished) ? .inCall : .connecting
    }

    func setInterfaceMode(_ mode: InterfaceMode) {
        guard canStartCalls, interfaceMode != mode else { return }
        interfaceMode = mode
        saveAppSettings()
    }
}
