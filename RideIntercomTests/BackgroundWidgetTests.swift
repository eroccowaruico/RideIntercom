#if os(macOS)
import AppIntents
import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct BackgroundWidgetTests {
    @Test func backgroundWidgetControlsUseJapaneseAndEnglishResources() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { Issue.record("BackgroundWidgetTests requires iOS/macOS 27 or newer; exclude this suite on OS 26."); return }
        #expect(try localized(BackgroundCallControlIntent.title, language: "ja") == "通話の操作")
        #expect(try localized(BackgroundCallControlIntent.title, language: "en") == "Call controls")
        #expect(try localized(BackgroundCallSurfaceError.stale.localizedStringResource, language: "ja")
            == "表示していた通話は終了したか、別の通話に変わりました。RideIntercomを開いて現在の通話を確認してください。")
    }

    @Test func backgroundIntentTargetsTheAppWithoutRequiringAnUnlock() {
        guard #available(iOS 27.0, macOS 27.0, *) else { Issue.record("BackgroundWidgetTests requires iOS/macOS 27 or newer; exclude this suite on OS 26."); return }
        #expect(BackgroundCallControlIntent.supportedModes == .background)
        #expect(BackgroundCallControlIntent.allowedExecutionTargets == .main)
        #expect(BackgroundCallControlIntent.authenticationPolicy == .alwaysAllowed)
    }

    @Test func preparesCurrentAccountBeforeStartingSelectedDestination() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { Issue.record("BackgroundWidgetTests requires iOS/macOS 27 or newer; exclude this suite on OS 26."); return }
        let actions = WidgetActionsRecorder()
        let intent = BackgroundCallControlIntent(destinationID: "current-target"); intent.actions = actions
        _ = try await intent.perform()
        #expect(actions.events == ["prepare", "start:current-target"])
    }

    @Test func failedPreparationDoesNotRunAnAction() async {
        guard #available(iOS 27.0, macOS 27.0, *) else { Issue.record("BackgroundWidgetTests requires iOS/macOS 27 or newer; exclude this suite on OS 26."); return }
        let actions = WidgetActionsRecorder(); actions.failPreparation = true
        let intent = BackgroundCallControlIntent(destinationID: "current-target"); intent.actions = actions
        await #expect(throws: WidgetActionsRecorder.Failure.self) { _ = try await intent.perform() }
        #expect(actions.events == ["prepare"])
        let unmute = BackgroundCallControlIntent(action: .unmute,
            reference: .init(accountAccessID: UUID(), connectionGeneration: UUID(), groupID: UUID()))
        unmute.actions = actions
        await #expect(throws: WidgetActionsRecorder.Failure.self) { _ = try await unmute.perform() }
        #expect(actions.events == ["prepare", "prepare"])
        #expect(actions.mutedValues.isEmpty)
    }

    @Test func endAndMuteDoNotWaitForAppleCredentialPreparation() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { Issue.record("BackgroundWidgetTests requires iOS/macOS 27 or newer; exclude this suite on OS 26."); return }
        let actions = WidgetActionsRecorder(); actions.failPreparation = true
        let reference = CallSurfaceReference(accountAccessID: UUID(), connectionGeneration: UUID(), groupID: UUID())
        let end = BackgroundCallControlIntent(action: .end, reference: reference); end.actions = actions
        _ = try await end.perform()
        let mute = BackgroundCallControlIntent(action: .mute, reference: reference); mute.actions = actions
        _ = try await mute.perform()
        #expect(actions.events == ["end"])
        #expect(actions.mutedValues == [true])
        #expect(actions.references == [reference, reference])
    }

    @Test func explicitMuteAndUnmuteCarryTheDisplayedReferenceWithoutToggling() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { Issue.record("BackgroundWidgetTests requires iOS/macOS 27 or newer; exclude this suite on OS 26."); return }
        let actions = WidgetActionsRecorder()
        let reference = CallSurfaceReference(accountAccessID: UUID(), connectionGeneration: UUID(), groupID: UUID())
        let mute = BackgroundCallControlIntent(action: .mute, reference: reference); mute.actions = actions
        _ = try await mute.perform(); _ = try await mute.perform()
        #expect(actions.mutedValues == [true, true])
        #expect(actions.references == [reference, reference])
        let unmute = BackgroundCallControlIntent(action: .unmute, reference: reference); unmute.actions = actions
        _ = try await unmute.perform()
        #expect(actions.mutedValues == [true, true, false])
        let end = BackgroundCallControlIntent(action: .end, reference: reference); end.actions = actions
        _ = try await end.perform()
        #expect(actions.events.last == "end")
        #expect(actions.references.last == reference)
    }

    @Test func missingOrMalformedReferenceNeverControlsTheCurrentCall() async {
        guard #available(iOS 27.0, macOS 27.0, *) else { Issue.record("BackgroundWidgetTests requires iOS/macOS 27 or newer; exclude this suite on OS 26."); return }
        let actions = WidgetActionsRecorder()
        let intent = BackgroundCallControlIntent(action: .end); intent.actions = actions
        await #expect(throws: (any Error).self) { _ = try await intent.perform() }
        intent.displayedReference = "invalid"
        await #expect(throws: (any Error).self) { _ = try await intent.perform() }
        #expect(!actions.events.contains("end"))
    }

    @Test func ownerRejectsStaleMuteAndEndWithoutSwitchingTheCurrentCall() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { Issue.record("BackgroundWidgetTests requires iOS/macOS 27 or newer; exclude this suite on OS 26."); return }
        let h = AppTestSupport.makeHarness(), vm = h.viewModel; defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let start = BackgroundCallControlIntent(destinationID: owner.callTargets[0].entity.id); start.actions = owner
        _ = try await start.perform()
        let stale = try #require(owner.currentLivePresentation?.reference)
        let other = BackgroundCallControlIntent(destinationID: owner.callTargets[1].entity.id); other.actions = owner
        await #expect(throws: CallIntentError.self) { _ = try await other.perform() }
        #expect(owner.currentLivePresentation?.reference == stale)
        #expect(vm.startCall(to: .group(vm.groups[1].id), accountAccessID: vm.accountAccessID))
        let current = vm.currentCallReference
        let mute = BackgroundCallControlIntent(action: .mute, reference: stale); mute.actions = owner
        await #expect(throws: BackgroundCallSurfaceError.self) { _ = try await mute.perform() }
        let end = BackgroundCallControlIntent(action: .end, reference: stale); end.actions = owner
        await #expect(throws: CallIntentError.self) { _ = try await end.perform() }
        #expect(vm.currentCallReference == current)
        let fresh = try #require(owner.currentLivePresentation?.reference)
        let currentMute = BackgroundCallControlIntent(action: .mute, reference: fresh); currentMute.actions = owner
        _ = try await currentMute.perform()
        #expect(vm.isMuted)
        _ = try await currentMute.perform()
        #expect(vm.isMuted)
        let freshEnd = BackgroundCallControlIntent(action: .end, reference: fresh); freshEnd.actions = owner
        _ = try await freshEnd.perform()
        #expect(vm.activeGroupID == nil)
        vm.accountSession.signOut()
        await #expect(throws: CallIntentError.self) { _ = try await start.perform() }
    }
    private func localized(_ resource: LocalizedStringResource, language: String) throws -> String {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        return String(localized: resource.defaultValue, table: resource.table, bundle: bundle, locale: Locale(identifier: language))
    }

}

@MainActor private final class WidgetActionsRecorder: CallSurfaceActions {
    enum Failure: Error { case unavailable }
    var events: [String] = []
    var mutedValues: [Bool] = []
    var references: [CallSurfaceReference] = []
    var failPreparation = false
    func prepareForBackgroundCallAction() async throws {
        events.append("prepare")
        if failPreparation { throw Failure.unavailable }
    }
    func startWidgetCall(id: String) throws { events.append("start:\(id)") }
    func performCallSurfaceAction(_ action: CallSurfaceAction, reference: CallSurfaceReference?) throws {
        events.append(action.rawValue)
        if let reference { references.append(reference) }
    }
    func setCallSurfaceMuted(_ muted: Bool, reference: CallSurfaceReference) -> Bool {
        mutedValues.append(muted); references.append(reference); return true
    }
}

#endif
