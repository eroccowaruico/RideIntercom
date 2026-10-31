import AppIntents
import Foundation

struct StartSavedCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a call"
    static let description = IntentDescription("Connect to a saved user or group in RideIntercom.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Call destination") var target: CallTargetEntity
    @AppDependency var owner: AppCallOwner
    static var parameterSummary: some ParameterSummary { Summary("Start a call with \(\.$target)") }
    init() {}
    init(target: CallTargetEntity) { self.target = target }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let vm = try owner.callModel()
        guard let destination = owner.callTargets.first(where: { $0.entity.id == target.id })?.destination else {
            throw CallIntentError.unavailable("This saved call destination is no longer available. Choose it again in RideIntercom.")
        }
        guard vm.startCall(to: destination, accountAccessID: vm.accountAccessID, allowSwitchingCall: false) else {
            throw CallIntentError.unavailable(vm.groupErrorMessage ?? "The call could not be started.")
        }
        owner.callPresentationID = UUID()
        return .result(dialog: "Connection started. The other person must also join the call.")
    }
}

struct StartRecentCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume recent call"
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @AppDependency var owner: AppCallOwner

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let vm = try owner.callModel()
        guard let destination = vm.recentCallDestination else {
            throw CallIntentError.unavailable("No recent call is available. Choose a saved user or group in RideIntercom.")
        }
        guard vm.startCall(to: destination, accountAccessID: vm.accountAccessID, allowSwitchingCall: false) else {
            throw CallIntentError.unavailable(vm.groupErrorMessage ?? "The call could not be started.")
        }
        owner.callPresentationID = UUID()
        return .result(dialog: "Connection started. The other person must also join the call.")
    }
}

struct EndCurrentCallIntent: AppIntent {
    static let title: LocalizedStringResource = "End current call"
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @AppDependency var owner: AppCallOwner

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let vm = try owner.callModel()
        let reference = vm.currentCallReference
        guard vm.endCall(reference) else { return .result(dialog: "There is no current call to end.") }
        owner.callPresentationID = UUID()
        return .result(dialog: "Call ended.")
    }
}

struct SetCallMutedIntent: AppIntent {
    static let title: LocalizedStringResource = "Set microphone mute"
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Mute", requestValueDialog: "Should the microphone be muted?") var muted: Bool
    @AppDependency var owner: AppCallOwner
    static var parameterSummary: some ParameterSummary { Summary("Set microphone mute to \(\.$muted)") }
    init() {}
    init(muted: Bool) { self.muted = muted }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let vm = try owner.callModel()
        let reference = vm.currentCallReference
        guard vm.setCallMuted(muted, for: reference) else {
            throw CallIntentError.unavailable(vm.groupStorageNotice ?? "The microphone could not be changed. Open RideIntercom and try again.")
        }
        owner.callPresentationID = UUID()
        if muted { return .result(dialog: "Microphone muted.") }
        return .result(dialog: "Microphone unmuted.")
    }
}

nonisolated struct RideIntercomShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartSavedCallIntent(), phrases: ["Start a call with \(.applicationName)"],
                    shortTitle: "Start a call", systemImageName: "phone")
        AppShortcut(intent: StartRecentCallIntent(), phrases: ["Resume my call in \(.applicationName)"],
                    shortTitle: "Resume recent call", systemImageName: "arrow.clockwise")
        AppShortcut(intent: EndCurrentCallIntent(), phrases: ["End my call in \(.applicationName)"],
                    shortTitle: "End current call", systemImageName: "phone.down")
        AppShortcut(intent: SetCallMutedIntent(), phrases: ["Set microphone mute in \(.applicationName)"],
                    shortTitle: "Set microphone mute", systemImageName: "mic.slash")
    }
}
