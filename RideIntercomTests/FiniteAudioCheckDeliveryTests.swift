import AudioCore
import Codec
import DynamicsProcessor
import RTC
import SessionManager
import Foundation
import Testing
@testable import RideIntercom

@Suite(.serialized)
@MainActor
struct FiniteAudioCheckDeliveryTests {
    private func blockActorBeyondLiveDeadline() { Thread.sleep(forTimeInterval: 0.15) }

    @Test func finiteRecordingSurvivesActorDelayAndTrimsAtFiveSeconds() async {
        var received: [PCMFrame] = []
        let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
        let delivery = AudioFrameDelivery(finiteRecordingDuration: 5) { received.append($0) }
        defer { delivery.finish() }
        for index in 0..<236 {
            delivery.yield(PCMFrame(sequenceNumber: UInt64(index), format: format,
                                    capturedAt: Double(index * 1024) / 48_000,
                                    samples: [Float](repeating: Float(index), count: 1024)))
        }
        blockActorBeyondLiveDeadline()
        await AppTestSupport.waitUntil { received.reduce(0) { $0 + $1.frameCount } == 240_000 }
        #expect(received.map(\.sequenceNumber) == Array(0..<235).map(UInt64.init))
        #expect(received.reduce(0) { $0 + $1.frameCount } == 240_000)
        #expect(received.last?.frameCount == 384)
        #expect(delivery.droppedFrameCount == 0)
    }

    @Test func viewModelRecordsAllFiveSecondsAndCanRestartAfterPlayback() async {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel
        for cycle in 0..<2 {
            vm.startAudioCheck()
            await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
            let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
            for index in 0..<236 {
                h.inputBackend.emit(.init(sequenceNumber: UInt64(index), format: format,
                    capturedAt: Double(cycle * 10) + Double(index * 1024) / 48_000,
                    samples: [Float](repeating: 0.2, count: 1024)))
            }
            blockActorBeyondLiveDeadline()
            await AppTestSupport.waitUntil { vm.audioCheckPhase == .playing }
            #expect(vm.audioCheckRecordedFrameCount == 240_000)
            #expect(vm.inputFrameDelivery?.droppedFrameCount == 0)
            vm.completeAudioCheckPlayback()
            #expect(vm.audioCheckPhase == .completed && vm.canStartAudioCheck)
        }
    }

    @Test func delayedFirstInputGetsItsOwnBoundedWindowForAllFiveSeconds() async throws {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel
        defer { vm.cancelAudioCheck() }
        #expect(vm.startAudioCheck(recordDuration: .milliseconds(200)))
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        try #require(vm.audioCheckPhase == .recording)
        try await Task.sleep(for: .milliseconds(650))
        let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
        h.inputBackend.emit(.init(sequenceNumber: 0, format: format, capturedAt: 0,
                                  samples: Array(repeating: 0.2, count: 1024)))
        await AppTestSupport.waitUntil { vm.audioCheckRecordedFrameCount > 0 }
        try #require(vm.audioCheckRecordedFrameCount > 0)
        // The old preparation-relative 1.2 s deadline expires before these
        // remaining samples; the new first-input-relative deadline has not.
        try await Task.sleep(for: .milliseconds(650))
        try #require(vm.audioCheckPhase == .recording)
        for index in 1..<236 {
            h.inputBackend.emit(.init(sequenceNumber: UInt64(index), format: format,
                capturedAt: Double(index * 1024) / 48_000, samples: Array(repeating: 0.2, count: 1024)))
        }
        await AppTestSupport.waitUntil(timeout: .seconds(3)) { vm.audioCheckPhase == .playing || vm.audioCheckPhase == .failed }
        #expect(vm.audioCheckPhase == .playing)
        #expect(vm.audioCheckRecordedFrameCount == 240_000, "The shortened watchdog never shortens the five-second sample budget")
    }

    @Test func noInputAndInvalidInputStillFailWithinTheInitialDeadline() async throws {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel
        defer { vm.cancelAudioCheck() }
        #expect(vm.startAudioCheck(recordDuration: .milliseconds(200)))
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        try #require(vm.audioCheckPhase == .recording)
        vm.processAudioCheckInput(level: 0, frame: .init(sequenceNumber: 1, samples: []))
        vm.processAudioCheckInput(level: 0, frame: .init(sequenceNumber: 2, samples: [.nan]))
        #expect(vm.audioCheckRecordedFrameCount == 0, "Empty and invalid PCM cannot start recording")
        await AppTestSupport.waitUntil(timeout: .seconds(2)) { vm.audioCheckPhase == .failed }
        #expect(vm.audioCheckPhase == .failed)
        #expect(vm.audioCheckStatusMessage == "Incomplete microphone recording")
    }

    @Test func laterFramesDoNotExtendTheFirstInputDeadline() async throws {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel
        defer { vm.cancelAudioCheck() }
        #expect(vm.startAudioCheck(recordDuration: .milliseconds(200)))
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        try #require(vm.audioCheckPhase == .recording)
        h.inputBackend.emit(.init(sequenceNumber: 0, capturedAt: 0, samples: Array(repeating: 0.2, count: 1024)))
        await AppTestSupport.waitUntil { vm.audioCheckRecordedFrameCount > 0 }
        try #require(vm.audioCheckRecordedFrameCount > 0)
        try await Task.sleep(for: .milliseconds(700))
        h.inputBackend.emit(.init(sequenceNumber: 1, capturedAt: 1024.0 / 48_000, samples: Array(repeating: 0.2, count: 1024)))
        try await Task.sleep(for: .milliseconds(650))
        #expect(vm.audioCheckPhase == .failed, "A later frame must not restart the first-input watchdog")
    }

    @Test func cancelledWatchdogCannotStopTheNextRecordingGeneration() async throws {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel
        defer { vm.cancelAudioCheck() }
        #expect(vm.startAudioCheck(recordDuration: .milliseconds(200)))
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        try #require(vm.audioCheckPhase == .recording)
        h.inputBackend.emit(.init(sequenceNumber: 0, capturedAt: 0, samples: Array(repeating: 0.2, count: 1024)))
        await AppTestSupport.waitUntil { vm.audioCheckRecordedFrameCount > 0 }
        try #require(vm.audioCheckRecordedFrameCount > 0)
        try await Task.sleep(for: .milliseconds(650))
        vm.cancelAudioCheck()
        #expect(vm.startAudioCheck(recordDuration: .milliseconds(200)))
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        try #require(vm.audioCheckPhase == .recording)
        let newGeneration = vm.audioCheckGeneration
        try await Task.sleep(for: .milliseconds(700))
        #expect(vm.audioCheckGeneration == newGeneration)
        #expect(vm.audioCheckPhase == .recording, "The cancelled generation's deadline must not stop its successor")
    }

    @Test func finitePlaybackRetainsItsBoundedStartupAndDrainObservations() async {
        var count = 0
        let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
        let delivery = AudioFrameDelivery(finiteRecordingDuration: 6) { count += $0.frameCount }
        defer { delivery.finish() }
        for index in 0..<301 {
            delivery.yield(.init(sequenceNumber: UInt64(index), format: format,
                capturedAt: Double(index) * 0.02, samples: [Float](repeating: 0.2, count: 960)))
        }
        blockActorBeyondLiveDeadline()
        await AppTestSupport.waitUntil { count == 288_000 }
        #expect(count == 288_000)
        #expect(delivery.droppedFrameCount == 0)
    }

    #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
    @Test func recordingObservationComparesNativeStereoOutputAfterRouteNegotiation() {
        let input = PCMFrame(sequenceNumber: 0, format: .intercomMixer, samples: [Float](repeating: 0.2, count: 240_000))
        var observation = AudioCheckValidationObservation(generation: UUID())
        observation.setInput([input])
        observation.appendOutput(.init(sequenceNumber: 0, format: .init(sampleRate: 48_000, channelCount: 2),
            samples: (0..<480_000).map { $0.isMultiple(of: 2) ? Float(0.3) : Float(0.1) }))
        let report = observation.record(phase: "Audio Check Complete", drops: 0, inputDrops: 0,
            inputStopped: true, outputStopped: true, nativeBackends: true, watchRoute: false, engineRunning: false)
        #expect(report["comparison"] as? String == "measured")
        #expect(report["fullCoverage"] as? Bool == true)
        #expect(report["outputFrames"] as? Int == 240_000)
    }
    #endif

    @Test func recordingCheckUsesTheActualTransmitCodecAndDynamicsForAllFiveSeconds() async throws {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel
        vm.setSoundIsolationEnabled(false)
        vm.setRTCAudioFormatPreset(.mono16k)
        vm.setPreferredTransmitCodec(.mpeg4AACELD)
        vm.setVADSensitivity(.lowNoise)
        defer { vm.cancelAudioCheck() }
        for cycle in 0..<2 {
            vm.startAudioCheck()
            await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
            #expect(vm.audioPipeline.codecRuntimeReport.activeConfiguration.codec == .mpeg4AACELD)
            #expect(vm.audioPipeline.dynamicsRuntimeSnapshot != nil)
            let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
            for index in 0..<236 {
                let beginning = index * 1024
                let samples = (0..<1024).map { offset in
                    let sample = beginning + offset
                    if (96_000..<144_000).contains(sample) { return Float(0) }
                    let frequency = sample >= 235_200 ? 997.0 : 440.0
                    return Float(0.8 * sin(Double(sample) * 2 * .pi * frequency / 48_000))
                }
                h.inputBackend.emit(.init(sequenceNumber: UInt64(index), format: format,
                    capturedAt: Double(cycle * 10) + Double(beginning) / 48_000, samples: samples))
            }
            await AppTestSupport.waitUntil(timeout: .seconds(3)) { vm.audioCheckPhase == .playing }
            #expect(vm.audioCheckPhase == .playing)
            #expect(vm.audioCheckRecordedFrameCount == 80_000)
            #expect(vm.audioCheckOutputLevel > 0.02 && vm.audioCheckOutputLevel < 0.5,
                "The real transmit Dynamics unit must change the 0.566 RMS input before recording")
            let recorded = try #require(vm.audioCheckRecording).recordedFrames().flatMap(\.samples)
            let gap = Array(recorded[44_800..<46_400])
            #expect(AudioLevelMeter.rmsLevel(samples: gap) < 0.001,
                "VAD-suppressed time must remain at its original position as silence")
            let tail = Array(recorded.suffix(1600))
            let projection = tail.enumerated().reduce((0.0, 0.0)) { sum, item in
                let phase = 2 * Double.pi * 997 * Double(item.offset) / 16_000
                return (sum.0 + Double(item.element) * cos(phase), sum.1 + Double(item.element) * sin(phase))
            }
            #expect(hypot(projection.0, projection.1) / 1600 > 0.01,
                "The final 997Hz marker must survive both native DSP and codec drain")
            #expect(h.callSession.startMediaCallCount == 0)
            vm.completeAudioCheckPlayback()
        }
    }

    #if os(iOS) || os(macOS)
    @Test func nativeRecordingCheckUsesThePreparedGraphForTwoCycles() async throws {
        let h = AppTestSupport.makeHarness(groups: [])
        let vm = makeNativeViewModel(h)
        defer { vm.cancelAudioCheck(); vm.audioPipeline.onOutputFrame = nil }
        for _ in 0..<2 {
            var renderedFramesByRate: [Double: Int] = [:]
            #expect(vm.startAudioCheck())
            let output = vm.audioPipeline.onOutputFrame
            vm.audioPipeline.onOutputFrame = { frame in
                output?(frame)
                if vm.audioCheckPhase == .playing {
                    renderedFramesByRate[frame.format.sampleRate, default: 0] += frame.frameCount
                }
            }
            // Native device preparation and the five-second sample budget are
            // separate deadlines, as in the production first-input watchdog.
            await AppTestSupport.waitUntil(timeout: .seconds(8)) {
                vm.audioCheckRecordedFrameCount > 0 || vm.audioCheckPhase == .failed
            }
            await AppTestSupport.waitUntil(timeout: .seconds(7)) { vm.audioCheckPhase == .playing || vm.audioCheckPhase == .failed }
            #expect(vm.audioCheckPhase == .playing, "Native capture must reach five seconds: \(vm.audioCheckStatusMessage), input=\(String(describing: vm.lastInputStreamOperationReport?.result)), voice=\(String(describing: vm.lastVoiceProcessingOperationReport?.result))")
            #expect(vm.audioCheckRecordedFrameCount == 240_000)
            await AppTestSupport.waitUntil(timeout: .seconds(7)) { vm.audioCheckPhase == .completed || vm.audioCheckPhase == .failed }
            #expect(vm.audioCheckPhase == .completed)
            let renderedDuration = renderedFramesByRate.reduce(0.0) { $0 + Double($1.value) / $1.key }
            #expect(renderedDuration >= 5, "Native output must render the complete five-second timeline; frames=\(renderedFramesByRate), output=\(String(describing: vm.lastOutputStreamOperationReport))")
            #expect(h.callSession.startMediaCallCount == 0)
        }
    }
    private func makeNativeViewModel(_ h: AppTestSupport.Harness) -> IntercomViewModel {
        IntercomViewModel(accountSession: h.viewModel.accountSession, enforceCallAccess: false,
            callSession: h.callSession, groupRepository: h.viewModel.groupRepository,
            appSettingsStore: InMemoryAppSettingsStore(), internetSettingsStore: h.viewModel.internetSettingsStore,
            localMemberIdentityStore: h.viewModel.localMemberIdentityStore,
            invitationAuthority: h.viewModel.invitationAuthority, callTicker: NoOpCallTicker())
    }
    #endif

    #if os(iOS)
    @Test func nativeCallCaptureContinuesAfterPipelinePreparationAndRestart() async throws {
        // Only account/control/transport use fixtures. Native capture, DSP and
        // the shared hardware engine follow the ordinary call lifecycle.
        let h = AppTestSupport.makeHarness(), vm = makeNativeViewModel(h)
        defer { vm.disconnect() }
        for _ in 0..<2 {
            vm.selectGroup(try #require(vm.groups.first))
            vm.connectLocal()
            h.callSession.authenticate(["member-108"])
            await AppTestSupport.waitUntil(timeout: .seconds(3)) { vm.isAudioReady }
            #expect(vm.isAudioReady == true)
            await AppTestSupport.waitUntil(timeout: .seconds(2)) { vm.localInputObservedAt != nil }
            #expect(vm.localInputObservedAt != nil, "The real native capture callback must survive call graph startup")
            if let first = vm.localInputObservedAt {
                try await Task.sleep(for: .milliseconds(200))
                #expect((vm.localInputObservedAt ?? 0) > first)
            }
            #expect(vm.audioPipeline.transmitEncodingFailureCount == 0)
            vm.disconnect()
            _ = await vm.audioSessionManager.requestActive(false).value
        }
    }
    #endif

    @Test func transmitFailureCannotBecomeSuccessfulSilenceAndMutedRecordingCanRestart() async {
        let h = AppTestSupport.makeHarness(groups: []), vm = h.viewModel
        vm.setSoundIsolationEnabled(false)
        defer { vm.cancelAudioCheck() }
        func emitFiveSeconds(start: Double) {
            for index in 0..<250 {
                h.inputBackend.emit(.init(sequenceNumber: UInt64(index), format: .intercomMixer,
                    capturedAt: start + Double(index) * 0.02, samples: [Float](repeating: 0.2, count: 960)))
            }
        }
        vm.startAudioCheck()
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        let before = vm.audioPipeline.transmitEncodingFailureCount
        vm.audioPipeline.processMicrophoneFrame(.init(sequenceNumber: 0, format: .init(sampleRate: 48_000, channelCount: 2),
            capturedAt: 0, samples: [Float](repeating: 0.8, count: 9601)), level: 1)
        #expect(vm.audioPipeline.transmitEncodingFailureCount > before)
        emitFiveSeconds(start: 10)
        await AppTestSupport.waitUntil(timeout: .seconds(3)) { vm.audioCheckPhase == .playing || vm.audioCheckPhase == .failed }
        #expect(vm.audioCheckPhase == .failed, "A swallowed transmit processing failure must invalidate this recording")
        vm.cancelAudioCheck()
        vm.applyLocalMute(true)
        vm.startAudioCheck()
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        emitFiveSeconds(start: 20)
        await AppTestSupport.waitUntil(timeout: .seconds(3)) { vm.audioCheckPhase == .playing || vm.audioCheckPhase == .failed }
        #expect(vm.audioCheckPhase == .playing, "An intentional transmit mute is a valid silent recording")
        #expect(vm.audioCheckRecordedFrameCount == 240_000)
        #expect(vm.audioCheckOutputLevel == 0)
    }

    #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
    @Test func recordingObservationAlignsSparseSpeechAndMeasuresSilentIntervals() {
        func measure(_ input: [Float], _ output: [Float]) -> [String: Any] {
            var observation = AudioCheckValidationObservation(generation: UUID())
            observation.setInput([.init(sequenceNumber: 0, format: .intercomMixer, capturedAt: 0, samples: input)])
            observation.appendOutput(.init(sequenceNumber: 0, format: .intercomMixer, capturedAt: 0, samples: output))
            return observation.record(phase: "Audio Check Complete", drops: 0, inputDrops: 0,
                inputStopped: true, outputStopped: true, nativeBackends: true, watchRoute: false, engineRunning: false)
        }
        let input = (0..<240_000).map { sample -> Float in
            guard (48_000..<96_000).contains(sample) || (192_000..<201_600).contains(sample) else { return 0 }
            return Float(0.2 * sin(Double(sample) * Double(sample) * 0.000_019))
        }
        let output = [Float](repeating: 0, count: 1440) + input + [Float](repeating: 0, count: 480)
        let report = measure(input, output)
        #expect(report["comparison"] as? String == "measured")
        #expect(report["fullCoverage"] as? Bool == true)
        #expect(abs((report["lagSeconds"] as? Double ?? -1) - 0.03) < 1 / 48_000)
        #expect((report["fullSignalCorrelation"] as? Double ?? -1) > 0.9999)
        #expect((report["silentResidualRMS"] as? Double ?? 1) < 0.00001)
        var corrupt = output
        for index in 131_040..<135_840 { corrupt[index] = 0.1 }
        #expect((measure(input, corrupt)["silentResidualRMS"] as? Double ?? 0) > 0.001)
        let silent = measure([Float](repeating: 0, count: 240_000), [Float](repeating: 0, count: 241_920))
        #expect(silent["comparison"] as? String == "unidentifiable")
        #expect(silent["lagSeconds"] == nil)
    }
    #endif
}
