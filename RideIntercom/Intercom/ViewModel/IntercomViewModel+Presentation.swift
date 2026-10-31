import Foundation

enum StandardCallStatus: Equatable {
    case chooseDestination, ready, connecting, inCall, audioPaused, audioUnavailable

    var message: String {
        switch self {
        case .chooseDestination: "Choose someone or a group to call."
        case .ready: "Ready to connect"
        case .connecting: "Connecting — waiting for others"
        case .inCall: "In a call"
        case .audioPaused: "Audio paused — check your audio device"
        case .audioUnavailable: "Audio unavailable — check your settings"
        }
    }
}

extension IntercomViewModel {
    var standardCallStatus: StandardCallStatus {
        guard let selectedGroup else { return .chooseDestination }
        guard selectedGroup.id == activeGroupID, hasAnyActiveGroupConnection else { return .ready }
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
