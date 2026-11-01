import AppIntents
import Foundation
import Observation
import Synchronization
import Testing
@testable import RideIntercom

@MainActor struct WatchMicrophoneBoundaryTests {
    @Test func watchSnapshotDoesNotObserveRecordingProgressButPublishesFinalStateAndSession() throws {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let session = UUID(), now = Date(timeIntervalSince1970: 1_000)
        vm.audioCheckWatchSessionID = session
        vm.audioCheckPhase = .recording
        vm.audioCheckRecordedFrameCount = 480
        vm.audioCheckRecordedNonzeroSamples = 100
        let notifications = Mutex(0)
        let initial = withObservationTracking {
            owner.watchSnapshot(now: now)
        } onChange: {
            notifications.withLock { $0 += 1 }
        }
        let initialCheck = try #require(initial.audioCheck)
        #expect(initialCheck.sessionID == session && initialCheck.phase == .recording)
        #expect(initialCheck.recordedFrames == 0 && initialCheck.nonzeroSamples == 0)

        vm.audioCheckRecordedFrameCount = 240_000
        vm.audioCheckRecordedNonzeroSamples = 12_345
        let progress = owner.watchSnapshot(now: now)
        #expect(notifications.withLock { $0 } == 0, "Recording progress must not invalidate the real snapshot observation")
        #expect(progress == initial)
        #expect(!progress.needsPublication(after: initial))
        #expect(vm.audioCheckRecordedFrameCount == 240_000 && vm.audioCheckRecordedNonzeroSamples == 12_345,
                "The phone retains its actual recording counters")

        vm.audioCheckPhase = .preparing
        #expect(notifications.withLock { $0 } == 1, "The phase transition must invalidate the snapshot observation")
        let completedRecording = owner.watchSnapshot(now: now)
        let finalCheck = try #require(completedRecording.audioCheck)
        #expect(finalCheck.recordedFrames == 240_000 && finalCheck.nonzeroSamples == 12_345)
        #expect(completedRecording.needsPublication(after: progress))

        let phaseNotifications = Mutex(0)
        _ = withObservationTracking { owner.watchSnapshot(now: now) } onChange: {
            phaseNotifications.withLock { $0 += 1 }
        }
        vm.audioCheckRecordedNonzeroSamples = 12_346
        #expect(phaseNotifications.withLock { $0 } == 1, "Final counters are observable outside recording")
        let updatedFinal = owner.watchSnapshot(now: now)
        #expect(updatedFinal.audioCheck?.nonzeroSamples == 12_346)
        #expect(updatedFinal.needsPublication(after: completedRecording))

        vm.audioCheckWatchSessionID = UUID()
        let nextSession = owner.watchSnapshot(now: now)
        #expect(nextSession.needsPublication(after: updatedFinal))
    }
    @Test func toggleRemainsOnThroughInactiveAndExplicitOffAlwaysWorks() {
        var state = WatchMicrophoneIntent()
        state.setMode(.toggle)
        state.request(true)
        #expect(state.isOn)
        state.setScene(.inactive)
        #expect(state.isOn, "Wrist dimming must not cancel an explicitly enabled microphone")
        state.setScene(.active)
        #expect(state.isOn, "Returning active retains the existing toggle state")
        state.setScene(.inactive)
        state.request(false)
        #expect(!state.isOn, "An explicit off request works even while inactive")
        state.request(true)
        #expect(!state.isOn, "Inactive state cannot initiate a new transmission")
        state.setScene(.active)
        #expect(!state.isOn, "Returning active must not turn the microphone on")
    }

    @Test func holdClosesOnInactiveAndCannotResumeWithoutNewPress() {
        var state = WatchMicrophoneIntent()
        #expect(state.mode == .hold && !state.isOn)
        state.request(true)
        #expect(state.isOn)
        state.setScene(.inactive)
        #expect(!state.isOn)
        state.setScene(.active)
        #expect(!state.isOn)
        state.request(true)
        #expect(state.isOn)
        state.request(false)
        #expect(!state.isOn)
    }

    @Test func backgroundAndForceCloseDoNotRestoreToggleOn() {
        var state = WatchMicrophoneIntent()
        state.setMode(.toggle)
        state.request(true)
        state.setScene(.background)
        #expect(!state.isOn)
        state.request(true)
        #expect(!state.isOn)
        state.setScene(.active)
        #expect(!state.isOn)
        state.request(true)
        #expect(state.isOn)
        state.close()
        #expect(!state.isOn)
        state.setScene(.inactive)
        state.setScene(.active)
        #expect(!state.isOn)
    }

    @Test func changingModeClosesButReselectingItDoesNot() {
        var state = WatchMicrophoneIntent()
        state.setMode(.toggle)
        state.request(true)
        state.setMode(.toggle)
        #expect(state.isOn)
        state.setMode(.hold)
        #expect(!state.isOn)
        state.request(true)
        state.setMode(.toggle)
        #expect(!state.isOn)
    }

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
