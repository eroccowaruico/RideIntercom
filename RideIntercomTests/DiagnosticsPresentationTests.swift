import RTC
import Testing
@testable import RideIntercom

extension AppTests {
@MainActor
struct DiagnosticsPresentationTests {
    @Test func transmitProjectionPreservesFailureMuteAndFallbackWithoutReadingLiveState() {
        let h = AppTestSupport.makeHarness()
        var input = DiagnosticsInput(h.viewModel)
        input.audioErrorMessage = "failed"
        input.isMuted = true
        input.isAudioReady = true
        input.preferredTransmitCodec = .opus
        input.selectedTransmitCodec = .pcm16
        let presentation = TransmitPipelinePresentation(input: input)
        h.viewModel.audioErrorMessage = nil
        h.viewModel.isMuted = false
        #expect(presentation.sessionStep.state == .blocked)
        #expect(presentation.inputStreamStep.state == .waiting)
        #expect(presentation.codecStep.state == .waiting)
        #expect(presentation.codecStep.detail.contains("Fallback"))
        #expect(presentation.rtcStep.accessibilityIdentifier == "pipeline-rtc-step")
    }
    @Test func receiveProjectionPreservesUnknownCodecAndFallbackPeerDetails() {
        let h = AppTestSupport.makeHarness(groups: [])
        var input = DiagnosticsInput(h.viewModel)
        input.authenticatedPeerIDs = ["new-peer"]
        input.peerVolumes = ["new-peer": 0.25]
        let presentation = ReceivePipelinePresentation(input: input)
        #expect(presentation.receivePeerBuses.count == 1)
        #expect(presentation.receivePeerBuses[0].id == "new-peer")
        #expect(presentation.receivePeerBuses[0].activeCodec == nil)
        #expect(presentation.receivePeerBuses[0].outputVolume == 0.25)
        #expect(presentation.outputStep.accessibilityIdentifier == "receive-pipeline-output-step")
        #expect(presentation.masterEffectStages.isEmpty)
    }
}
}
