import Foundation
import Observation

extension AppCallOwner {
    var isMenuBarInserted: Bool { viewModel?.canStartCalls == true && viewModel?.menuBarEnabled == true }

    @discardableResult
    func setCallSurfaceMuted(_ muted: Bool, reference: CallSurfaceReference) -> Bool {
        viewModel?.setCallMuted(muted, for: .init(accountAccessID: reference.accountAccessID,
            connectionGeneration: reference.connectionGeneration, groupID: reference.groupID)) == true
    }

    var currentLivePresentation: CallLivePresentation? {
        guard let vm = viewModel, vm.canStartCalls, vm.hasAnyActiveGroupConnection,
              let groupID = vm.activeGroupID else { return nil }
        let reference = vm.currentCallReference
        return .init(reference: .init(accountAccessID: reference.accountAccessID,
            connectionGeneration: reference.connectionGeneration, groupID: groupID),
            status: vm.callStatus(for: groupID), isMuted: vm.isMuted)
    }
    func observeSystemSurfaces() {
        let input = withObservationTracking {
            (currentLivePresentation, viewModel?.liveActivityEnabled == true, systemSurfaceIsForeground)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeSystemSurfaces() }
        }
        liveActivities.setPresentation(input.0, enabled: input.1, isForeground: input.2)
    }
    func performCallSurfaceAction(_ action: CallSurfaceAction, reference: CallSurfaceReference?) throws {
        let vm = try callModel()
        switch action {
        case .calls: break
        case .saved: try startWidgetCall(id: "")
        case .recent:
            guard let destination = vm.recentCallDestination else {
                throw CallIntentError.unavailable("No recent call is available. Choose a saved user or group in RideIntercom.")
            }
            guard vm.startCall(to: destination, accountAccessID: vm.accountAccessID, allowSwitchingCall: false) else {
                throw CallIntentError.unavailable(vm.groupErrorMessage ?? "The call could not be started.")
            }
        case .end:
            guard let reference, vm.endCall(.init(accountAccessID: reference.accountAccessID,
                connectionGeneration: reference.connectionGeneration, groupID: reference.groupID)) else {
                throw CallIntentError.unavailable("The displayed call has ended or changed. Open RideIntercom to check your current call.")
            }
        }
        callPresentationID = UUID()
    }
}

extension IntercomViewModel {
    func setMenuBarEnabled(_ enabled: Bool) {
        guard canStartCalls else { return }
        menuBarEnabled = enabled
        saveAppSettings()
    }

    func setLiveActivityEnabled(_ enabled: Bool) {
        guard canStartCalls else { return }
        liveActivityEnabled = enabled
        saveAppSettings()
    }
}
