import AppIntents
import Testing
@testable import RideIntercom

@MainActor struct WatchMicrophoneBoundaryTests {
    @Test func watchRouteIgnoresSavedPhoneMuteAndRejectsPhoneControls() async throws {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel
        defer { vm.disconnect() }
        vm.applyLocalMute(true)
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID))
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        vm.selectWatchAudioRoute()
        let reference = vm.currentCallReference
        let surface = try #require(owner.currentLivePresentation)
        #expect(!surface.canControlMicrophone)
        #expect(!surface.isMuted, "The saved phone mute is not the Watch microphone state")
        #expect(h.callSession.localMuteValues.last == false, "RTC must accept Watch audio despite the saved phone mute")
        #expect(!vm.setCallMuted(false, for: reference))
        #expect(!owner.setCallSurfaceMuted(false, reference: surface.reference))
        let intent = SetCallMutedIntent(muted: false); intent.owner = owner
        await #expect(throws: CallIntentError.self) { _ = try await intent.perform() }
        #expect(vm.isMuted, "The phone preference must survive Watch use")
        vm.disconnect()
        #expect(vm.isMuted && !vm.isUsingWatchAudio)
        #expect(vm.setCallMuted(false, for: vm.currentCallReference))
        #expect(!vm.isMuted)
    }

    @Test func initialWatchStartRejectsStaleWidgetMuteWithoutOpeningPhoneInput() throws {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel
        defer { vm.disconnect() }
        #expect(vm.startCall(to: .group(vm.groups[0].id), accountAccessID: vm.accountAccessID, usingWatch: true))
        #expect(!vm.setCallMuted(true, for: vm.currentCallReference))
        #expect(h.inputBackend.startCount == 0)
        #expect(!vm.isMuted)
    }
}
