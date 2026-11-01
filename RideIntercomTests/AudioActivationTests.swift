import Foundation
import AudioMixer
import SessionManager
import Testing
@testable import RideIntercom

@MainActor
struct AudioActivationTests {
    @Test func audioCheckInitialRouteResolutionDoesNotCancelPreparation() async {
        let h = AppTestSupport.makeHarness(groups: []), gate = ManualAsyncGate()
        let vm = h.viewModel
        h.audioSessionBackend.activationGate = gate
        vm.startAudioCheck()
        await gate.waitForEntry()
        var resolved = h.audioSessionBackend.current
        resolved.currentInput = resolved.availableInputs[1]
        h.audioSessionBackend.current = resolved
        vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(reason: .routeChanged(.categoryChanged), snapshot: resolved)))
        #expect(vm.audioCheckPhase == .preparing && vm.audioCheckOwnsAudioPipeline)
        await gate.release()
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording || vm.audioCheckPhase == .idle }
        #expect(vm.audioCheckPhase == .recording)
        vm.cancelAudioCheck()
    }

    @Test func audioCheckUsesActualStartedRouteBeforeDelayedSetupNotification() async {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel
        let backend = h.audioSessionBackend
        var resolved = backend.current
        resolved.currentInput = resolved.availableInputs[1]
        resolved.isActive = true
        h.inputBackend.onStart = { [weak backend] in backend?.current = resolved }
        vm.startAudioCheck()
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(reason: .routeChanged(.routeConfigurationChanged), snapshot: backend.current)))
        #expect(vm.audioCheckPhase == .recording && vm.audioCheckOwnsAudioPipeline)
        vm.cancelAudioCheck()
    }

    @Test func staleRouteAfterStopCannotCancelTheNextAudioCheck() async {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel, backend = h.audioSessionBackend
        var old = backend.current
        old.currentInput = old.availableInputs[1]
        var current = backend.current
        current.currentOutput = .builtInSpeaker
        current.isActive = true
        h.inputBackend.onStart = { [weak backend] in backend?.current = current }
        vm.startAudioCheck()
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        vm.cancelAudioCheck()
        vm.startAudioCheck()
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(reason: .routeChanged(.categoryChanged), snapshot: old)))
        #expect(vm.audioCheckPhase == .recording)
        #expect(vm.audioSessionSnapshot.currentInput.id == backend.current.currentInput.id)
        #expect(vm.audioSessionSnapshot.currentOutput.id == backend.current.currentOutput.id)
        vm.cancelAudioCheck()
    }

    @Test func ordinaryAudioCheckCannotStartThroughAWatchOwnedRoute() {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel
        vm.selectWatchAudioRoute()
        #expect(!vm.canStartAudioCheck)
        vm.startAudioCheck()
        #expect(vm.audioCheckPhase == .idle && !vm.audioCheckOwnsAudioPipeline)
        #expect(h.inputBackend.startCount == 0 && h.outputBackend.startCount == 0)
        #expect(vm.isUsingWatchAudio, "A normal start cannot silently replace another route owner")
        vm.disconnect()
    }

    @Test func actualPortSwitchDuringRecordingStillStopsAudioCheck() async {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel
        vm.startAudioCheck()
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        var changed = h.audioSessionBackend.current
        changed.currentInput = changed.availableInputs[1]
        h.audioSessionBackend.current = changed
        vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(reason: .defaultInputChanged, snapshot: changed)))
        #expect(vm.audioCheckPhase == .idle && !vm.audioCheckOwnsAudioPipeline)
    }

    @Test func configurationReportCannotHideActualPortSwitchDuringRecording() async throws {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel
        vm.startAudioCheck()
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        var changed = h.audioSessionBackend.current
        changed.currentInput = changed.availableInputs[1]
        h.audioSessionBackend.current = changed
        var report = try #require(vm.lastAudioSessionConfigurationReport)
        report.snapshot = changed
        vm.handleAudioSessionRuntimeEvent(.configuration(report))
        vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(reason: .defaultInputChanged, snapshot: changed)))
        #expect(vm.audioCheckPhase == .idle && !vm.audioCheckOwnsAudioPipeline)
        vm.cancelAudioCheck()
    }

    @Test func callWaitsForActivationBeforeOpeningMedia() async {
        let h = AppTestSupport.makeHarness(), gate = ManualAsyncGate()
        h.audioSessionBackend.activationGate = gate
        h.viewModel.setSoundIsolationEnabled(false)
        h.viewModel.selectGroup(h.viewModel.groups[0])
        h.callSession.authenticate(["member-108"])
        await gate.waitForEntry()
        #expect(!h.viewModel.isAudioReady)
        #expect(h.inputBackend.startCount == 0)
        #expect(h.outputBackend.startCount == 0)
        #expect(h.callSession.startMediaCallCount == 0)
        await gate.release()
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        #expect(h.viewModel.isAudioReady)
        h.viewModel.disconnect()
        _ = await h.viewModel.audioSessionManager.requestActive(false).value
    }

    @Test func audioCheckWaitsForActivationAndCanCancelBeforeRecording() async {
        let h = AppTestSupport.makeHarness(), gate = ManualAsyncGate()
        h.audioSessionBackend.activationGate = gate
        h.viewModel.startAudioCheck()
        await gate.waitForEntry()
        #expect(h.viewModel.audioCheckPhase != .recording)
        #expect(h.inputBackend.startCount == 0)
        #expect(h.outputBackend.startCount == 0)
        #expect(!h.viewModel.canStartAudioCheck)
        h.viewModel.cancelAudioCheck()
        await gate.release()
        _ = await h.viewModel.audioSessionManager.requestActive(false).value
        #expect(h.viewModel.audioCheckPhase == .idle)
        #expect(h.inputBackend.startCount == 0)
    }

    @Test(arguments: ["disconnect", "signout", "deadline", "peerLoss"])
    func endedOrUnauthorizedCallCannotStartAfterLateActivation(ending: String) async {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let h = AppTestSupport.makeHarness(callAccessNow: { now }), gate = ManualAsyncGate()
        h.audioSessionBackend.activationGate = gate
        h.viewModel.setCallDisconnectInterval(.oneMinute)
        h.viewModel.selectGroup(h.viewModel.groups[0])
        h.callSession.authenticate(["member-108"])
        await gate.waitForEntry()
        switch ending {
        case "signout": h.viewModel.accountSession.signOut()
        case "deadline": now = now.addingTimeInterval(60) // completion must check before the next tick
        case "peerLoss": h.viewModel.handleTransportEvent(.connected(peerIDs: []))
        default: h.viewModel.disconnect()
        }
        await gate.release()
        await AppTestSupport.waitUntil { h.viewModel.audioStartTask == nil }
        _ = await h.viewModel.audioSessionManager.requestActive(false).value
        #expect(!h.viewModel.isAudioReady)
        #expect(h.inputBackend.startCount == 0 && h.outputBackend.startCount == 0)
        #expect(h.callSession.startMediaCallCount == 0)
        #expect(!h.audioSessionBackend.current.isActive)
        if ending == "deadline" { #expect(h.viewModel.groupErrorMessage?.contains("timer") == true) }
        h.viewModel.disconnect()
    }

    @Test func oldCallFailureCannotReplaceNewCallAndDuplicateRequestsShareOneStart() async {
        let h = AppTestSupport.makeHarness(), gate = ManualAsyncGate(), vm = h.viewModel
        vm.setSoundIsolationEnabled(false)
        h.audioSessionBackend.activationGate = gate
        h.audioSessionBackend.activationError = NSError(domain: "OldActivation", code: 1)
        vm.selectGroup(vm.groups[0]); h.callSession.authenticate(["member-108"])
        await gate.waitForEntry()
        vm.selectGroup(vm.groups[1]); vm.connectLocal()
        h.audioSessionBackend.activationError = nil
        h.callSession.authenticate(["member-215"])
        let deadline = vm.callDisconnectDeadline
        h.callSession.authenticate(["member-215"])
        vm.startAudioPipelineIfNeeded()
        vm.setSpeakerOutputEnabled(true)
        await gate.release()
        await AppTestSupport.waitUntil { vm.isAudioReady }
        #expect(vm.isAudioReady && vm.audioErrorMessage == nil)
        #expect(vm.activeGroupID == vm.groups[1].id && vm.callDisconnectDeadline == deadline)
        #expect(h.inputBackend.startCount == 1 && h.outputBackend.startCount == 1)
        #expect(h.callSession.startMediaCallCount == 1)
        #expect(h.audioSessionBackend.appliedConfigurations.last?.options.contains(.defaultToSpeaker) == true)
        let requests = h.audioSessionBackend.activeValues
        vm.setAudioSessionProfile(.voiceChat)
        await Task.yield()
        #expect(h.audioSessionBackend.activeValues == requests)
        vm.disconnect()
        _ = await vm.audioSessionManager.requestActive(false).value
    }

    @Test func cancellingPreparingCheckCannotStopTheFollowingCall() async {
        let h = AppTestSupport.makeHarness(), gate = ManualAsyncGate(), vm = h.viewModel
        vm.setSoundIsolationEnabled(false)
        h.audioSessionBackend.activationGate = gate
        vm.startAudioCheck(recordDuration: .milliseconds(1))
        await gate.waitForEntry()
        #expect(vm.audioCheckPhase == .preparing)
        vm.selectGroup(vm.groups[0]); h.callSession.authenticate(["member-108"])
        await gate.release()
        await AppTestSupport.waitUntil { vm.isAudioReady }
        #expect(vm.audioCheckPhase == .idle && !vm.audioCheckOwnsAudioPipeline)
        #expect(h.inputBackend.startCount == 1 && h.outputBackend.startCount == 1)
        #expect(h.audioSessionBackend.current.isActive)
        vm.disconnect()
        _ = await vm.audioSessionManager.requestActive(false).value
    }

    @Test func deviceLossCancelsPreparingCheckAndPendingCall() async {
        for checking in [true, false] {
            let h = AppTestSupport.makeHarness(), gate = ManualAsyncGate(), vm = h.viewModel
            h.audioSessionBackend.activationGate = gate
            if checking { vm.startAudioCheck() }
            else { vm.selectGroup(vm.groups[0]); h.callSession.authenticate(["member-108"]) }
            await gate.waitForEntry()
            vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
                reason: .routeChanged(.oldDeviceUnavailable), snapshot: h.audioSessionBackend.current)))
            await gate.release()
            _ = await vm.audioSessionManager.requestActive(false).value
            #expect(h.inputBackend.startCount == 0 && h.outputBackend.startCount == 0)
            #expect(vm.audioCheckPhase == .idle && !vm.isAudioReady)
            if !checking { #expect(vm.isAudioPausedForDeviceChange) }
            vm.disconnect()
        }
    }

    @Test func accountModelsShareNativeActivationOrderingWithoutSharingCallState() async {
        let old = AppTestSupport.makeHarness(), gate = ManualAsyncGate()
        old.audioSessionBackend.activationGate = gate
        old.viewModel.selectGroup(old.viewModel.groups[0]); old.callSession.authenticate(["member-108"])
        await gate.waitForEntry()
        old.viewModel.endAccountAccess()
        let current = AppTestSupport.makeHarness(audioSessionManager: old.viewModel.audioSessionManager)
        current.viewModel.setSoundIsolationEnabled(false)
        current.viewModel.selectGroup(current.viewModel.groups[0]); current.callSession.authenticate(["member-108"])
        await gate.release()
        await AppTestSupport.waitUntil { current.viewModel.isAudioReady }
        #expect(old.inputBackend.startCount == 0 && old.callSession.startMediaCallCount == 0)
        #expect(current.viewModel.isAudioReady && old.audioSessionBackend.current.isActive)
        current.viewModel.disconnect()
        _ = await current.viewModel.audioSessionManager.requestActive(false).value
        #expect(!old.audioSessionBackend.current.isActive)
    }

    @Test func supersededActivationDoesNotOpenMediaButUnsupportedPlatformCan() async {
        let h = AppTestSupport.makeHarness(), gate = ManualAsyncGate(), vm = h.viewModel
        h.audioSessionBackend.activationGate = gate
        vm.selectGroup(vm.groups[0]); h.callSession.authenticate(["member-108"])
        await gate.waitForEntry()
        let stopped = vm.audioSessionManager.requestActive(false)
        await gate.release()
        _ = await stopped.value
        await AppTestSupport.waitUntil { vm.audioStartTask == nil }
        #expect(h.inputBackend.startCount == 0 && !vm.isAudioReady)
        h.audioSessionBackend.activationError = AudioSessionManagerError.operationUnsupportedOnCurrentPlatform
        vm.setSoundIsolationEnabled(false)
        vm.startAudioPipelineIfNeeded()
        await AppTestSupport.waitUntil { vm.isAudioReady }
        #expect(vm.isAudioReady)
        vm.disconnect()
        _ = await vm.audioSessionManager.requestActive(false).value
    }

    @Test(arguments: [AudioSessionSnapshotChangeReason.interruptionBegan, .mediaServicesReset])
    func nativeInterruptionPausesActiveCallUntilExplicitResume(reason: AudioSessionSnapshotChangeReason) async {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel
        vm.setSoundIsolationEnabled(false)
        vm.selectGroup(vm.groups[0]); h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { vm.isAudioReady }
        let deadline = vm.callDisconnectDeadline, group = vm.activeGroupID
        let starts = h.inputBackend.startCount
        vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(reason: reason, snapshot: h.audioSessionBackend.current)))
        #expect(!vm.isAudioReady && vm.isAudioPausedForDeviceChange)
        #expect(vm.audioRouteNotice?.contains("interrupted") == true)
        #expect(vm.activeGroupID == group && vm.callDisconnectDeadline == deadline)
        #expect(h.inputBackend.stopCount > 0 && h.outputBackend.stopCount > 0)
        #expect(vm.audioPipeline.snapshot.busIDs.isEmpty)
        var restored = h.audioSessionBackend.current
        restored.currentOutput = .builtInSpeaker
        vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(reason: .interruptionEnded(shouldResume: true), snapshot: restored)))
        h.callSession.authenticate(["member-108"])
        await Task.yield()
        #expect(!vm.isAudioReady && vm.audioStartTask == nil)
        #expect(h.inputBackend.startCount == starts)
        vm.resumeAudioAfterDeviceChange()
        await AppTestSupport.waitUntil { vm.isAudioReady }
        #expect(vm.isAudioReady && !vm.isAudioPausedForDeviceChange && vm.audioRouteNotice == nil)
        #expect(vm.callDisconnectDeadline == deadline)
        vm.disconnect()
        _ = await vm.audioSessionManager.requestActive(false).value
    }

    @Test(arguments: [AudioSessionSnapshotChangeReason.interruptionBegan, .mediaServicesReset], [true, false])
    func nativeInterruptionCancelsPendingActivation(reason: AudioSessionSnapshotChangeReason, checking: Bool) async {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel, gate = ManualAsyncGate()
        vm.setSoundIsolationEnabled(false)
        h.audioSessionBackend.activationGate = gate
        if checking { vm.startAudioCheck() }
        else { vm.selectGroup(vm.groups[0]); h.callSession.authenticate(["member-108"]) }
        await gate.waitForEntry()
        vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(reason: reason, snapshot: h.audioSessionBackend.current)))
        #expect(vm.audioCheckPhase == .idle && vm.audioStartTask == nil)
        if checking { #expect(vm.audioCheckStatusMessage.contains("interrupted")) }
        else { #expect(vm.isAudioPausedForDeviceChange && vm.audioRouteNotice?.contains("interrupted") == true) }
        vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(reason: .interruptionEnded(shouldResume: true), snapshot: h.audioSessionBackend.current)))
        await gate.release()
        await AppTestSupport.waitUntil { vm.audioStartTask == nil }
        _ = await vm.audioSessionManager.requestActive(false).value
        #expect(h.inputBackend.startCount == 0 && h.outputBackend.startCount == 0)
        #expect(h.callSession.startMediaCallCount == 0 && !vm.isAudioReady)
        #expect(vm.audioCheckPhase == .idle && !vm.audioCheckOwnsAudioPipeline)
        vm.disconnect()
    }

    @Test(arguments: [AudioSessionSnapshotChangeReason.interruptionBegan, .mediaServicesReset])
    func nativeInterruptionStopsRecordingCheckWithoutAutomaticRestart(reason: AudioSessionSnapshotChangeReason) async {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel
        vm.startAudioCheck()
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        #expect(h.inputBackend.startCount == 1 && h.outputBackend.startCount == 1)
        vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(reason: reason, snapshot: h.audioSessionBackend.current)))
        #expect(vm.audioCheckPhase == .idle && !vm.audioCheckOwnsAudioPipeline)
        #expect(h.inputBackend.stopCount == 1 && h.outputBackend.stopCount == 1)
        #expect(vm.audioCheckStatusMessage.contains("interrupted"))
        vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(reason: .interruptionEnded(shouldResume: true), snapshot: h.audioSessionBackend.current)))
        _ = await vm.audioSessionManager.requestActive(false).value
        #expect(vm.audioCheckPhase == .idle)
        #expect(h.inputBackend.startCount == 1 && h.outputBackend.startCount == 1)
        vm.cancelAudioCheck()
    }

    @Test func interruptionBeforePeerAuthenticationRequiresExplicitResume() async {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel
        vm.setSoundIsolationEnabled(false)
        vm.selectGroup(vm.groups[0])
        vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(reason: .interruptionBegan, snapshot: h.audioSessionBackend.current)))
        vm.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(reason: .interruptionEnded(shouldResume: true), snapshot: h.audioSessionBackend.current)))
        h.callSession.authenticate(["member-108"])
        await Task.yield()
        #expect(vm.isAudioPausedForDeviceChange && !vm.isAudioReady && vm.audioStartTask == nil)
        #expect(h.inputBackend.startCount == 0 && h.callSession.startMediaCallCount == 0)
        vm.resumeAudioAfterDeviceChange()
        await AppTestSupport.waitUntil { vm.isAudioReady }
        #expect(vm.isAudioReady)
        vm.disconnect()
        _ = await vm.audioSessionManager.requestActive(false).value
    }
}
