import AVFAudio
import Foundation
import AudioCore
import AudioMixer
import Codec
import RTC
import SessionManager
import Testing
import VADGate
import SoundIsolation
import PeakLimiter
@testable import RideIntercom

extension AppTests {
@MainActor
struct CallLifecycleTests {
    @Test func browsingPreservesCallButConnectingRejectsQueuedOldEvents() async {
        let harness = AppTestSupport.makeHarness()
        let a = IntercomSeedData.recentGroups[0]
        let b = IntercomSeedData.recentGroups[1]
        harness.viewModel.selectGroup(a)
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        let oldHandler = harness.callSession.onEvent
        harness.viewModel.selectGroup(b)
        #expect(harness.viewModel.activeGroupID == a.id)
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.callSession.disconnectCallCount == 0)
        harness.viewModel.connectLocal()
        oldHandler?(.authenticated(peerIDs: ["old-peer"]))
        oldHandler?(.routeMetrics(RTC.RouteMetrics(route: .multipeer, receivedAudioFrameCount: 999)))
        oldHandler?(.networkDiagnostics(.init(generatedAt: 123)))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.viewModel.activeGroupID == b.id)
        #expect(harness.callSession.connectedGroup?.id == b.id)
        #expect(harness.viewModel.authenticatedPeerIDs.isEmpty)
        #expect(harness.viewModel.receivedVoicePacketCount == 0)
        #expect(harness.viewModel.networkDiagnostics?.generatedAt != 123)
        #expect(!harness.viewModel.isAudioReady)
        harness.viewModel.disconnect()
    }

    @Test func lastPeerDisconnectStopsMediaAndAllowsAuthenticatedReconnect() async {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108", "member-215"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.handleTransportEvent(.connected(peerIDs: ["member-215"]))
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.viewModel.authenticatedPeerIDs == ["member-215"])
        harness.viewModel.handleTransportEvent(.connected(peerIDs: []))
        #expect(!harness.viewModel.isAudioReady)
        #expect(harness.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(harness.viewModel.activeGroupID != nil)
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        #expect(harness.viewModel.isAudioReady)
        harness.viewModel.disconnect()
    }

    @Test func outputRestartFailureReleasesInputAndAllowsRetry() async {
        let h = AppTestSupport.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        h.outputBackend.startError = AudioStreamError.engineOperationFailed("removed")
        h.viewModel.refreshAudioDevicesIfNeeded()
        #expect(!h.viewModel.isAudioReady)
        #expect(h.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(h.inputBackend.stopCount > 0)
        #expect(h.viewModel.audioErrorMessage != nil)
        h.outputBackend.startError = nil
        #expect(h.viewModel.startAudioPipelineIfNeeded())
        h.viewModel.disconnect()
    }

    @Test func internetConflictKeepsLocalAudioAndExplainsManualRecovery() async {
        let h = AppTestSupport.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        h.viewModel.handleTransportEvent(.serviceBlocked("End the existing Internet call, then reconnect here."))
        #expect(h.viewModel.isAudioReady)
        #expect(h.viewModel.audioErrorMessage == nil)
        #expect(h.viewModel.connectivityNotice?.contains("End the existing Internet call") == true)
        #expect(h.viewModel.connectivityNotice?.contains("automatically") == false)
        #expect(h.viewModel.internetFailureDetail != nil)
        h.viewModel.disconnect()
        #expect(h.viewModel.internetFailureDetail == nil)
    }

    @Test func blockedInternetOnlyCallOffersConnectInsteadOfClaimingAutomaticRecovery() {
        let h = AppTestSupport.makeHarness()
        h.viewModel.enabledRTCTransportRoutes = [.webRTC]
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.viewModel.handleTransportEvent(.serviceBlocked("End the existing Internet call, then try again."))
        h.viewModel.handleTransportEvent(.linkFailed(willRetry: false))
        #expect(h.viewModel.connectionState == .idle)
        #expect(!h.viewModel.canDisconnectCall)
        #expect(h.viewModel.connectivityNotice != nil)
        h.viewModel.connectLocal()
        #expect(h.viewModel.internetFailureDetail == nil)
        #expect(h.viewModel.connectivityNotice == nil)
        #expect(h.viewModel.connectionState != .idle)
        h.viewModel.disconnect()
    }

    @Test func blockedInternetDoesNotSuppressIndependentLocalRecovery() {
        let h = AppTestSupport.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.viewModel.handleTransportEvent(.serviceBlocked("Reconnect Internet manually."))
        h.viewModel.handleTransportEvent(.linkFailed(willRetry: true))
        #expect(h.viewModel.connectionState == .reconnectingOffline)
        #expect(h.viewModel.internetFailureDetail != nil)
        h.viewModel.disconnect()
    }

    @Test func internetFailureDoesNotMisreportHealthyLocalAudio() async {
        let h = AppTestSupport.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        h.viewModel.handleTransportEvent(.serviceError("quota"))
        #expect(h.viewModel.isAudioReady)
        #expect(h.viewModel.audioErrorMessage == nil)
        h.viewModel.disconnect()
    }

    @Test func deviceResumeRetriesFailureAndPreservesMuteIntent() async {
        let h = AppTestSupport.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        h.viewModel.toggleMute()
        h.viewModel.toggleOutputMute()
        h.viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .routeChanged(.oldDeviceUnavailable), snapshot: h.audioSessionBackend.current)))
        #expect(h.viewModel.isAudioPausedForDeviceChange)
        #expect(h.viewModel.callPresenceLabel == "Connected / Audio Paused")
        h.inputBackend.startError = AudioStreamError.engineOperationFailed("missing")
        h.viewModel.resumeAudioAfterDeviceChange()
        #expect(h.viewModel.isAudioPausedForDeviceChange)
        #expect(!h.viewModel.isAudioReady)
        h.inputBackend.startError = nil
        h.viewModel.resumeAudioAfterDeviceChange()
        #expect(h.viewModel.isAudioReady)
        #expect(!h.viewModel.isAudioPausedForDeviceChange)
        #expect(h.viewModel.isMuted && h.viewModel.isOutputMuted)
        #expect(h.viewModel.audioRouteNotice == nil)
        h.viewModel.disconnect()
        #expect(h.viewModel.availableCallRoutes.isEmpty)
    }

    @Test func actualDefaultDeviceChangeRestartsBothStreamsAndInterruptsAudioCheck() async {
        let h = AppTestSupport.makeHarness()
        h.viewModel.startAudioCheck()
        h.viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .routeChanged(.oldDeviceUnavailable), snapshot: h.audioSessionBackend.current)))
        #expect(h.viewModel.audioCheckPhase == .idle)
        #expect(!h.viewModel.audioCheckOwnsAudioPipeline)
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        let starts = h.inputBackend.startCount
        var snapshot = h.audioSessionBackend.current
        snapshot.currentOutput = .builtInSpeaker
        h.viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .defaultOutputChanged, snapshot: snapshot)))
        #expect(h.viewModel.isAudioReady)
        #expect(h.inputBackend.startCount == starts + 1)
        h.viewModel.disconnect()
    }

}
}
