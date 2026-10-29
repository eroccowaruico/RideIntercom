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
struct AudioPipelineTests {
    @Test func receivingSpeechChangesDuckingLevelWithoutChangingInputIOMode() {
        let harness = AppTestSupport.makeHarness()
        let viewModel = harness.viewModel
        let idle = viewModel.currentVoiceProcessingConfiguration()
        viewModel.setOtherAudioDuckingActive(true)
        let speaking = viewModel.currentVoiceProcessingConfiguration()
        viewModel.setOtherAudioDuckingActive(false)
        let quiet = viewModel.currentVoiceProcessingConfiguration()
        #expect(idle.voiceProcessingEnabled)
        #expect(speaking.voiceProcessingEnabled == idle.voiceProcessingEnabled)
        #expect(quiet.voiceProcessingEnabled == idle.voiceProcessingEnabled)
        #expect(idle.duckingLevel == .minimum)
        #expect(speaking.duckingLevel == .medium)
        #expect(quiet.duckingLevel == .minimum)
        viewModel.setDuckOthersEnabled(false)
        #expect(!viewModel.currentVoiceProcessingConfiguration().voiceProcessingEnabled)
    }

    @Test func appDecodeRejectsUnknownCodecAndInvalidFormatBeforeConversion() throws {
        let valid = RTCAudioPacket(sequenceNumber: 0, codec: .pcm16, capturedAt: 0,
                                   sampleCount: 1, payload: Data([0, 0]))
        var unknown = valid
        unknown.codec = "unknown-codec"
        #expect(throws: (any Error).self) { try AppAudioCodecBridge.decode(unknown) }
        for format in [RTCAudioFormat(sampleRate: 0), RTCAudioFormat(channelCount: 0),
                       RTCAudioFormat(sampleRate: .infinity), RTCAudioFormat(channelCount: 3)] {
            var invalid = valid
            invalid.format = format
            #expect(throws: (any Error).self) { try AppAudioCodecBridge.decode(invalid) }
        }
        #expect(try AppAudioCodecBridge.decode(valid).samples == [0])
    }

    @Test func audioTransmissionControllerSendsVoiceAndKeepalive() {
        var controller = AudioTransmissionController(
            vadGate: VADGate(configuration: VADGateConfiguration(
                attackDuration: 0.01,
                releaseDuration: 0.05,
                updateInterval: 0.02,
                speechThresholdOffsetDB: 6,
                silenceThresholdOffsetDB: 3,
                initialNoiseFloorDBFS: -60
            )),
            preRollLimit: 2,
            keepaliveIntervalFrames: 3
        )
        func frame(_ sequenceNumber: UInt64, _ sample: Float) -> PCMFrame {
            PCMFrame(
                sequenceNumber: sequenceNumber,
                format: .intercomPacketAudio,
                capturedAt: TimeInterval(sequenceNumber),
                samples: Array(repeating: sample, count: 960)
            )
        }

        #expect(controller.process(frame: frame(1, 0), level: 0).isEmpty)
        #expect(controller.process(frame: frame(2, 0), level: 0).isEmpty)
        #expect(controller.process(frame: frame(3, 0), level: 0) == [.keepalive])

        let voicePackets = controller.process(frame: frame(4, 0.3), level: 0.3)
        #expect(voicePackets == [
            .voice(frame(3, 0)),
            .voice(frame(4, 0.3))
        ])
    }

    @Test func viewModelConnectsAuthenticatedPeerAndStartsPackageAudioPipeline() async throws {
        let harness = AppTestSupport.makeHarness()
        let group = IntercomSeedData.recentGroups[0]

        harness.viewModel.selectGroup(group)
        await AppTestSupport.waitUntil { harness.callSession.connectedGroup?.id == group.id }
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }

        #expect(harness.callSession.startMediaCallCount == 1)
        #expect(harness.audioSessionBackend.activeValues.contains(true))
        #expect(harness.inputBackend.startCount == 1)
        #expect(harness.outputBackend.startCount == 1)
        #expect(harness.viewModel.connectionState == .localConnected)
    }

    @Test func viewModelSendsVoiceSamplesFromPackageInputFrames() async throws {
        let harness = AppTestSupport.makeHarness()
        let hardwareFormat = AudioFormat(sampleRate: 44_100, channelCount: 2)

        harness.viewModel.setRTCAudioFormatPreset(.mono24k)
        harness.viewModel.setPreferredTransmitCodec(.pcm16)
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        for sequenceNumber in 1...8 {
            harness.inputBackend.emit(PCMFrame(
                sequenceNumber: UInt64(sequenceNumber),
                format: hardwareFormat,
                capturedAt: TimeInterval(100 + sequenceNumber),
                samples: Array(repeating: [Float(0.7), Float(0.8)], count: 2_048).flatMap { $0 }
            ))
        }
        await AppTestSupport.waitUntil(timeout: .seconds(5)) { harness.callSession.sentAudioPackets.isEmpty == false }

        let packet = try #require(harness.callSession.sentAudioPackets.first)
        let decoded = try AppAudioCodecBridge.decode(packet)
        #expect(packet.format == RTC.RTCAudioFormat(audioFormat: RTCAudioFormatPreset.mono24k.audioFormat))
        #expect(decoded.format == RTCAudioFormatPreset.mono24k.audioFormat)
        #expect(harness.callSession.audioPolicies.last?.preferredSendFormat == RTC.RTCAudioFormat(audioFormat: RTCAudioFormatPreset.mono24k.audioFormat))
    }

    @Test func viewModelReceivesRTCFrameAndSchedulesPackageOutput() async throws {
        let harness = AppTestSupport.makeHarness()
        let group = IntercomSeedData.recentGroups[0]
        let frame = PCMFrame(
            sequenceNumber: 7,
            format: .intercomPacketAudio,
            capturedAt: 100,
            samples: Array(repeating: Float(0.2), count: 480) + Array(repeating: Float(-0.2), count: 480)
        )

        harness.viewModel.selectGroup(group)
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        harness.callSession.receive(try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
        await AppTestSupport.waitUntil(timeout: .seconds(5)) {
            harness.outputBackend.scheduledFrames.flatMap(\.samples).contains { abs($0 + 0.2) < 0.001 }
        }

        let remoteMember = try #require(harness.viewModel.selectedGroup?.members.first { $0.id == "member-108" })
        let scheduledFrames = harness.outputBackend.scheduledFrames
        #expect(!scheduledFrames.isEmpty)
        #expect(remoteMember.isTalking)
        #expect(remoteMember.receivedAudioPacketCount == 1)
        #expect(remoteMember.playedAudioFrameCount == 1)
        #expect(harness.viewModel.playedAudioFrameCount == scheduledFrames.count)
        #expect(scheduledFrames.allSatisfy { $0.format == .intercomHardwarePreferred && $0.frameCount <= 960 })
        #expect(scheduledFrames.flatMap(\.samples).contains { abs($0 - 0.2) < 0.001 })
        #expect(scheduledFrames.flatMap(\.samples).contains { abs($0 + 0.2) < 0.001 })
    }

    @Test func viewModelBroadcastsMuteStateAndUpdatesPackageVoiceProcessing() async throws {
        let harness = AppTestSupport.makeHarness()

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.toggleMute()

        #expect(harness.inputBackend.voiceProcessingConfigurations.last?.inputMuted == true)
        #expect(harness.inputBackend.voiceProcessingConfigurations.last?.soundIsolationEnabled == false)
        #expect(harness.callSession.localMuteValues.last == true)
        #expect(harness.callSession.sentControlMessages.contains(.peerMuteState(isMuted: true)))
        #expect(harness.callSession.sentControlMessages.contains(.keepalive))
    }

    @Test func viewModelAudioCheckRecordsAndSchedulesPlaybackThroughPackageOutput() async {
        let harness = AppTestSupport.makeHarness(groups: [])

        harness.viewModel.startAudioCheck(recordDuration: .seconds(5), playbackDuration: .seconds(5))
        harness.inputBackend.emit(PCMFrame(sequenceNumber: 1, format: AudioFormat(sampleRate: 44_100, channelCount: 2), capturedAt: 100, samples: Array(repeating: 0.5, count: 1764)))
        await AppTestSupport.waitUntil { harness.viewModel.audioCheckInputLevel > 0 }
        harness.viewModel.finishAudioCheckRecording(playbackDuration: .seconds(5))
        #expect(harness.outputBackend.configurations.last?.maximumBufferedDuration == 0.1)

        #expect(harness.viewModel.audioCheckPhase == .playing)
        #expect(harness.viewModel.audioCheckInputLevel > 0)
        #expect(harness.viewModel.audioCheckOutputLevel > 0)
        await AppTestSupport.waitUntil { !harness.outputBackend.scheduledFrames.isEmpty }
        #expect(!harness.outputBackend.scheduledFrames.isEmpty)
        if let scheduledFrame = harness.outputBackend.scheduledFrames.first {
            #expect(scheduledFrame.samples.contains { abs($0 - 0.5) < 0.01 })
            #expect(scheduledFrame.format == .intercomHardwarePreferred)
        } else {
            Issue.record("Expected one audio check playback frame")
        }
    }

    @Test func viewModelKeepsParticipantOutputVolumeInsideAppAudioPipeline() async {
        let harness = AppTestSupport.makeHarness()
        let peerID = "member-108"

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate([peerID])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        let policiesBefore = harness.callSession.audioPolicies
        harness.viewModel.setRemoteOutputVolume(peerID: peerID, volume: 0.25)
        let peerSource = harness.viewModel.audioPipeline.snapshot.buses
            .first { $0.id == "rx-peer-\(peerID)" }?
            .sources
            .first { $0.id == "rtc-audio-\(peerID)" }

        #expect(harness.viewModel.remoteOutputVolume(for: peerID) == 0.25)
        #expect(harness.callSession.audioPolicies == policiesBefore)
        #expect(peerSource?.id == "rtc-audio-\(peerID)")
    }

    @Test func viewModelTracksReceiveVoiceIsolationControls() {
        let harness = AppTestSupport.makeHarness()
        let peerID = "member-108"

        #expect(!harness.viewModel.isRemoteSoundIsolationEnabled(peerID: peerID))
        #expect(!harness.viewModel.receiveMasterSoundIsolationEnabled)
        #expect(harness.viewModel.supportsSoundIsolation == VoiceIsolationSupport.isAvailable)
        #expect(harness.viewModel.receivePeerEffectChainSnapshot(peerID: peerID).stages.isEmpty)
        #expect(harness.viewModel.receiveMasterEffectChainSnapshot.stages.isEmpty)
        #expect(harness.viewModel.receiveMasterEffectChainSnapshot.stages.isEmpty)

        harness.viewModel.setRemoteSoundIsolationEnabled(peerID: peerID, enabled: true)
        harness.viewModel.setReceiveMasterSoundIsolationEnabled(true)

        #expect(harness.viewModel.isRemoteSoundIsolationEnabled(peerID: peerID))
        #expect(harness.viewModel.receiveMasterSoundIsolationEnabled)
        #expect(harness.viewModel.receivePeerEffectChainSnapshot(peerID: peerID).stages.isEmpty)
        #expect(harness.viewModel.receiveMasterEffectChainSnapshot.stages.isEmpty)
        #expect(harness.viewModel.remoteOutputVolume(for: peerID) == IntercomViewModel.defaultRemoteOutputVolume)
        #expect(harness.viewModel.masterOutputVolume == IntercomViewModel.defaultMasterOutputVolume)
    }

    @Test func viewModelTracksRemoteCodecMetadataPerPeer() throws {
        let harness = AppTestSupport.makeHarness()
        let peerID = "member-108"

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.viewModel.handleTransportEvent(.connected(peerIDs: [peerID]))
        harness.viewModel.handleTransportEvent(.authenticated(peerIDs: [peerID]))
        harness.viewModel.handleTransportEvent(.remotePeerMetadata(peerID: peerID, activeCodec: .opus))

        let remoteMember = try #require(harness.viewModel.selectedGroup?.members.first { $0.id == peerID })
        #expect(remoteMember.connectionState == .connected)
        #expect(remoteMember.authenticationState == .authenticated)
        #expect(remoteMember.activeCodec == .opus)
    }

    @Test(arguments: [true, false]) func partialAudioStartCleansUpAndRetries(inputFails: Bool) async {
        let harness = AppTestSupport.makeHarness()
        if inputFails { harness.inputBackend.startError = AudioStreamError.engineOperationFailed("input") }
        else { harness.outputBackend.startError = AudioStreamError.engineOperationFailed("output") }
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.audioErrorMessage != nil }
        #expect(!harness.viewModel.isAudioReady)
        #expect(harness.inputBackend.stopCount == 1)
        #expect(harness.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(!(harness.viewModel.callTicker as! NoOpCallTicker).isRunning)
        harness.inputBackend.startError = nil
        harness.outputBackend.startError = nil
        harness.viewModel.startActiveCallAfterAuthenticatedPeer()
        #expect(harness.viewModel.isAudioReady)
        harness.viewModel.disconnect()
    }

    @Test func audioCheckIsCancelledBeforeCallStartsAndCannotStopCallLater() async {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.startAudioCheck(recordDuration: .milliseconds(80), playbackDuration: .milliseconds(50))
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        #expect(harness.viewModel.audioCheckPhase == .idle)
        #expect(!harness.viewModel.audioCheckOwnsAudioPipeline)
        let inputStops = harness.inputBackend.stopCount
        try? await Task.sleep(for: .milliseconds(180))
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.inputBackend.stopCount == inputStops)
        harness.viewModel.startAudioCheck()
        #expect(harness.viewModel.audioCheckPhase == .idle)
        harness.viewModel.disconnect()
    }

    @Test(arguments: [RTC.RouteKind.multipeer, .webRTC])
    func individualVolumeScalesRealPCMThroughEveryRoute(route: RTC.RouteKind) async throws {
        let h = AppTestSupport.makeHarness()
        h.viewModel.setRTCTransportRoute(route == .webRTC ? .multipeer : .webRTC, enabled: false)
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108", "member-109"])
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        defer { h.viewModel.disconnect() }
        h.viewModel.setRemoteOutputVolume(peerID: "member-108", volume: 0.25)
        h.viewModel.setRemoteOutputVolume(peerID: "member-109", volume: 0)
        h.viewModel.setMasterOutputVolume(0.5)
        let wave = (0..<3840).map { Float(sin(Double($0) * 2 * .pi * 400 / 48000)) * 0.4 }
        let frame = PCMFrame(sequenceNumber: 1, format: .intercomMixer, capturedAt: 0, samples: wave)
        for peer in ["member-108", "member-109"] {
            h.callSession.receive(try AppTestSupport.receivedAudioPacket(peerID: peer, frame: frame, codec: .pcm16))
        }
        // Render through the 200 ms playout delay and the complete 80 ms tone.
        // Silent render frames now retain time at the hardware boundary.
        await AppTestSupport.waitUntil { h.outputBackend.scheduledFrames.flatMap(\.samples).count >= 19200 }
        let frames = h.outputBackend.scheduledFrames.filter { $0.samples.contains { abs($0) > 0.000001 } }
        let samples = frames.flatMap(\.samples)
        #expect(samples.count >= 3072)
        let peak = samples.suffix(2048).map { abs($0) }.max() ?? 0
        #expect(peak > 0.045 && peak < 0.055, "Observed peak: \(peak)") // 0.4 × peer 0.25 × master 0.5; the other peer is silent.
    }

    @Test func actualOutputLimiterProtectsCombinedPeersAfterMasterGain() async throws {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let pipeline = AppAudioPipeline(makeEngine: { engine })
        var rendered: [Float] = []
        pipeline.onOutputFrame = { rendered += $0.samples }
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(masterOutputVolume: 2), peerIDs: ["a", "b"])
        defer { pipeline.stop() }
        let wave = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.9 }
        let packet = RTCAudioPacket(sequenceNumber: 0, codec: .pcm16, format: RTCAudioFormat(sampleRate: 48_000, channelCount: 1), capturedAt: 0, sampleCount: wave.count, payload: PCM16Codec.encode(wave))
        for peer in ["a", "b"] {
            _ = try pipeline.processReceivedAudioPacket(ReceivedAudioPacket(peerID: PeerID(rawValue: peer), packet: packet))
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        for _ in 0..<60 {
            _ = try engine.renderOffline(1024, to: buffer)
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!rendered.isEmpty)
        #expect(rendered.allSatisfy { $0.isFinite && abs($0) <= 1.01 })
        #expect(rendered.contains { abs($0) > 0.2 })
        let output = try #require(pipeline.snapshot.buses.first { $0.id == "rx-output" })
        #expect(output.effectChain.last?.id == "peak-limiter")
        #expect(output.sinks.first?.id == "speaker-output")
        #expect(pipeline.snapshot.routes.contains { $0.sourceBusID == "rx-master" && $0.destinationBusID == "rx-output" })
    }

    @Test func actualTransmitDynamicsChangesPCMBeforeEncoding() async throws {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let pipeline = AppAudioPipeline(makeEngine: { engine })
        var rendered: [Float] = []
        pipeline.onTransmitPacket = { packet in
            do { rendered += try AppAudioCodecBridge.decode(packet).samples }
            catch { Issue.record("Effect output could not be decoded: \(error)") }
        }
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(rtcSendFormat: .intercomMixer, transmitSoundIsolationEnabled: false), peerIDs: [])
        defer { pipeline.stop() }
        let wave = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.8 }
        try pipeline.processCapturedFrame(PCMFrame(sequenceNumber: 0, format: .intercomMixer, capturedAt: 0, samples: wave))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        for _ in 0..<60 {
            _ = try engine.renderOffline(1024, to: buffer)
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(rendered.count > 24_000)
        let steady = Array(rendered.dropFirst(12_000).prefix(24_000))
        let rms = AudioLevelMeter.rmsLevel(samples: steady)
        #expect(rms > 0.02)
        #expect(rms < 0.5) // Input RMS is about 0.566; the real Dynamics unit compresses it.
    }

    @Test func effectGraphStartFailureReleasesNodesAndCanRetry() throws {
        let failing = FailingEffectGraphEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try failing.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let working = AVAudioEngine()
        try working.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        var first = true
        let pipeline = AppAudioPipeline(makeEngine: {
            defer { first = false }
            return first ? failing : working
        })
        #expect(throws: (any Error).self) { try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(), peerIDs: ["a"]) }
        #expect(pipeline.snapshot.busIDs.isEmpty)
        #expect(pipeline.isolationRuntimeSnapshots.isEmpty)
        #expect(pipeline.outputLimiterRuntimeSnapshot == nil)
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(), peerIDs: ["a"])
        #expect(pipeline.outputLimiterRuntimeSnapshot?.state == .active)
        pipeline.stop()
        #expect(pipeline.isolationRuntimeSnapshots.isEmpty)
        #expect(pipeline.outputLimiterRuntimeSnapshot == nil)
    }

    @Test func failedMixerRebuildReleasesGraphAndAllowsRetry() throws {
        let driver = OfflineAudioDriver()
        let pipeline = AppAudioPipeline(makeEngine: driver.makeEngine)
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(), peerIDs: [])
        var invalid = AppAudioPipelineConfiguration()
        invalid.mixerFormat.sampleRate = 0
        #expect(throws: (any Error).self) { try pipeline.rebuild(configuration: invalid, peerIDs: []) }
        #expect(pipeline.snapshot.busIDs.isEmpty)
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(), peerIDs: [])
        #expect(!pipeline.snapshot.busIDs.isEmpty)
        pipeline.stop()
    }

    @Test func codecChangesPreserveActiveMixerAndReceiveReservations() async throws {
        let h = AppTestSupport.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        defer { h.viewModel.disconnect() }
        let engines = h.audioDriver.createdEngineCount
        let frame = PCMFrame(sequenceNumber: 0, format: .intercomMixer, capturedAt: 0,
            samples: Array(repeating: 0.1, count: 960))
        h.callSession.receive(try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
        for codec: AudioCodecIdentifier in [.pcm16, .opus, .mpeg4AACELDv2] {
            h.viewModel.setPreferredTransmitCodec(codec)
            h.viewModel.setOpusBitRate(48_000)
            h.viewModel.setAACELDv2BitRate(48_000)
            #expect(h.audioDriver.createdEngineCount == engines, "Packet encoding changes must not reset render clocks")
            let rx = try #require(h.viewModel.audioPipeline.snapshot.buses.first { $0.id == "rx-peer-member-108" }?.sources.first)
            #expect(rx.scheduledFrameCount == 1, "Changing transmit codec must retain already received audio")
            let expected = AppAudioCodecBridge.selectedRTCCodec(codec,
                options: .init(aacELDv2BitRate: 48_000, opusBitRate: 48_000))
            #expect(h.viewModel.audioPipeline.audioPolicy.preferredCodecs.first == expected)
            #expect(h.callSession.audioPolicies.last?.preferredCodecs.first == expected)
        }
    }

    @Test func transmitPlayoutPreservesCaptureClockAcrossJitteredBatches() async throws {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
        let pipeline = AppAudioPipeline(makeEngine: { engine })
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false,
            maximumBufferedDuration: 0.2, transmitPlayoutDelay: 0.1), peerIDs: [])
        defer { pipeline.stop() }
        func capture(_ sequence: UInt64) throws {
            try pipeline.processCapturedFrame(.init(sequenceNumber: sequence, format: .intercomMixer,
                capturedAt: Double(sequence) * 0.1, samples: Array(repeating: 0.03, count: 4800)))
        }
        func pending() throws -> MixerSourceSnapshot {
            try #require(pipeline.snapshot.buses.first { $0.id == "tx-bus" }?.sources.first)
        }
        try capture(0)
        #expect(try pending().bufferedDuration ?? 0 >= 0.1999)
        try await Task.sleep(for: .milliseconds(10))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        #expect(try engine.renderOffline(4800, to: buffer) == .success)
        #expect(try engine.renderOffline(2400, to: buffer) == .success)
        // The next 100 ms batch arrives 50 ms late. Its capture timestamp still
        // reserves [200, 300) ms, retaining the first batch's unplayed tail.
        try capture(1)
        #expect(try pending().bufferedDuration ?? 0 >= 0.1499)
        #expect(try pending().playbackResetCount == 0)
    }

    @Test func liveCallBoundsPCMReservationsWithoutRebuildingEffects() async throws {
        let h = AppTestSupport.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        defer { h.viewModel.disconnect() }
        let engines = h.audioDriver.createdEngineCount
        #expect(h.outputBackend.configurations.last?.maximumBufferedDuration == 0.2)
        for sequence in 0..<20 {
            let frame = PCMFrame(sequenceNumber: UInt64(sequence), format: .intercomMixer, capturedAt: 0,
                samples: Array(repeating: 0.2, count: 960))
            h.callSession.receive(try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
        }
        let peer = try #require(h.viewModel.audioPipeline.snapshot.buses.first { $0.id == "rx-peer-member-108" }?.sources.first)
        #expect((peer.bufferedDuration ?? 1) <= 0.22 + 1 / 48000.0)
        #expect(peer.playbackResetCount > 0)
        #expect(h.audioDriver.createdEngineCount == engines)
    }

    @Test func frameDeliveryBoundsWaitingAudioAndCancelsWithoutLateCallbacks() async {
        var received: [UInt64] = []
        let delivery = AudioFrameDelivery { received.append($0.sequenceNumber) }
        for i in 0..<1000 {
            delivery.yield(PCMFrame(sequenceNumber: UInt64(i), format: .intercomMixer, capturedAt: 0, samples: [0]))
        }
        await AppTestSupport.waitUntil { received.count == 32 }
        #expect(received == Array(968..<1000).map(UInt64.init))
        delivery.yield(PCMFrame(sequenceNumber: 1000, format: .intercomMixer, capturedAt: 0, samples: [0]))
        delivery.finish()
        await Task.yield()
        #expect(received.last == 999)
    }

    @Test func internetUsesSharedCaptureMixerAndDeviceRestart() async {
        let h = AppTestSupport.makeHarness()
        h.viewModel.setRTCTransportRoute(.multipeer, enabled: false)
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        #expect(h.viewModel.isAudioReady)
        #expect(h.audioDriver.createdEngineCount == 1)
        #expect(!h.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        let starts = h.outputBackend.startCount
        h.viewModel.refreshAudioDevicesIfNeeded()
        #expect(h.outputBackend.startCount == starts + 1)
        #expect(h.viewModel.isAudioReady)
        h.viewModel.disconnect()
    }

    @Test func routeChangesPreservePeerVolumesAndEffectInstances() async throws {
        let h = AppTestSupport.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        h.viewModel.setRemoteOutputVolume(peerID: "member-108", volume: 0.25)
        h.viewModel.setRemoteSoundIsolationEnabled(peerID: "member-108", enabled: true)
        h.viewModel.setMasterOutputVolume(0.75)
        let engines = h.audioDriver.createdEngineCount
        let before = h.viewModel.audioPipeline.snapshot
        for routes: Set<RTC.RouteKind> in [[.webRTC], [.webRTC, .multipeer], [.multipeer]] {
            h.viewModel.handleTransportEvent(.routesChanged(.init(activeRoute: routes.contains(.webRTC) ? .webRTC : .multipeer,
                mediaRoute: nil, availableRoutes: routes, isHandoverInProgress: false)))
            #expect(h.viewModel.audioPipeline.snapshot == before)
            #expect(h.viewModel.remoteOutputVolumes["member-108"] == 0.25)
            #expect(h.audioDriver.createdEngineCount == engines)
        }
        h.viewModel.disconnect()
    }

    @Test func connectingCancelsAudioCheckBeforePeerAuthentication() {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.startAudioCheck()
        #expect(harness.viewModel.audioCheckPhase == .recording)
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        #expect(harness.viewModel.audioCheckPhase == .idle)
        #expect(!harness.viewModel.audioCheckOwnsAudioPipeline)
        harness.viewModel.startAudioCheck()
        #expect(harness.viewModel.audioCheckPhase == .idle)
        harness.viewModel.disconnect()
    }

    @Test func mixedRoutesKeepEffectsAndPacketAudioOwnership() async {
        let rtc = FakeRTCCallSession()
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        await AppTestSupport.waitUntil { rtc.hasSubscriber }
        rtc.emit(.routeChanged(.init(activeRoute: .webRTC, mediaRoute: .webRTC,
            availableRoutes: [.webRTC, .multipeer], isHandoverInProgress: false)))
        await AppTestSupport.waitUntil { adapter.activeRouteDebugTypeName.contains("WebRTC") }
        let h = AppTestSupport.makeHarness()
        h.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        let starts = h.inputBackend.startCount
        h.viewModel.handleTransportEvent(.routesChanged(.init(activeRoute: .webRTC, mediaRoute: .webRTC,
            availableRoutes: [.webRTC, .multipeer], isHandoverInProgress: false)))
        #expect(h.viewModel.routeLabel == "Local + Internet / Relay")
        #expect(h.inputBackend.startCount == starts)
        h.viewModel.handleTransportEvent(.routesChanged(.init(activeRoute: .multipeer, mediaRoute: .multipeer,
            availableRoutes: [.multipeer], isHandoverInProgress: false)))
        #expect(h.viewModel.isAudioReady)
        #expect(h.inputBackend.startCount == starts)
        h.viewModel.handleTransportEvent(.routesChanged(.init(activeRoute: .webRTC, mediaRoute: .webRTC,
            availableRoutes: [.webRTC], isHandoverInProgress: false)))
        #expect(h.viewModel.connectionState == .internetConnected)
        #expect(h.viewModel.callPresenceLabel == CallConnectionState.internetConnected.label)
        #expect(h.viewModel.routeLabel == "Internet")
        #expect(h.inputBackend.startCount == starts)
        h.viewModel.disconnect()
    }

    @Test func departedPeerReleasesAudioGraphAndRemoteClockCannotHoldTalkingState() async throws {
        let h = AppTestSupport.makeHarness()
        h.viewModel.selectGroup(h.viewModel.groups[0])
        h.callSession.authenticate(["member-108", "member-215"])
        await AppTestSupport.waitUntil { h.viewModel.isAudioReady }
        let format = AudioFormat.intercomPacketAudio
        let future = Date().timeIntervalSince1970 + 86400
        let frame = PCMFrame(sequenceNumber: 1, format: format, capturedAt: future, samples: Array(repeating: 0.1, count: 480))
        h.callSession.receive(try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
        #expect(h.viewModel.remoteVoiceReceivedAt["member-108"]! < future - 1000)
        h.viewModel.removeDisconnectedAuthenticatedPeers(connectedPeerIDs: ["member-215"])
        #expect(!h.viewModel.audioPipeline.snapshot.busIDs.contains("rx-peer-member-108"))
        #expect(h.viewModel.audioPipeline.snapshot.busIDs.contains("rx-peer-member-215"))
    }

    @Test(arguments: [960, 4800]) func vadPrerollTracksAttackTimeInsteadOfHardwareFrameCount(count: Int) {
        var controller = AudioTransmissionController(vadGate: VADGate(configuration: .init(
            attackDuration: 0.08, releaseDuration: 0.05, speechThresholdOffsetDB: 6, initialNoiseFloorDBFS: -60)))
        func frame(_ id: UInt64, sample: Float) -> PCMFrame {
            .init(sequenceNumber: id, format: .intercomPacketAudio, capturedAt: Double(id) * Double(count) / 48000,
                  samples: Array(repeating: sample, count: count))
        }
        for id in 0..<30 { _ = controller.process(frame: frame(UInt64(id), sample: 0), level: 0) }
        let attackFrames = Int(ceil(0.08 / (Double(count) / 48000)))
        var emitted: [PCMFrame] = []
        for index in 0..<attackFrames {
            emitted += controller.process(frame: frame(UInt64(30 + index), sample: 0.4), level: 0.4)
                .compactMap { if case .voice(let frame) = $0 { frame } else { nil } }
        }
        #expect(emitted.count == attackFrames + 1, "Only the attack window and current frame may be replayed")
        #expect(emitted.first?.sequenceNumber == 29)
        #expect(emitted.last?.sequenceNumber == UInt64(29 + attackFrames))
        #expect(emitted.filter { $0.samples.contains { $0 > 0 } }.count == attackFrames,
                "Preserve every onset frame while excluding old silence")
    }

    @Test func vadUsesCapturedDurationAndDoesNotReplayOldPreroll() {
        var controller = AudioTransmissionController(vadGate: VADGate(configuration: .init(attackDuration: 0.08, releaseDuration: 0.05, speechThresholdOffsetDB: 6, initialNoiseFloorDBFS: -60)), preRollLimit: 2)
        func frame(_ id: UInt64, sample: Float, count: Int) -> PCMFrame {
            .init(sequenceNumber: id, format: .intercomPacketAudio, capturedAt: 0, samples: Array(repeating: sample, count: count))
        }
        for id in 0..<10 { #expect(controller.process(frame: frame(UInt64(id), sample: 0.5, count: 128), level: 0.5).isEmpty) }
        let speech = controller.process(frame: frame(10, sample: 0.5, count: 4800), level: 0.5)
        #expect(!speech.isEmpty)
        _ = controller.process(frame: frame(11, sample: 0, count: 4800), level: 0)
        let next = controller.process(frame: frame(12, sample: 0.5, count: 4800), level: 0.5)
        #expect(next == [.voice(frame(11, sample: 0, count: 4800)), .voice(frame(12, sample: 0.5, count: 4800))])
    }

}
}
