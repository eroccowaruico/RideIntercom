import AudioCore
import AudioMixer
import AVFAudio
import Codec
import Foundation
import RTC
import Synchronization
import Testing
import VADGate
@testable import RideIntercom

extension AppTests {
@MainActor
struct RealtimeConversationTests {
    @Test func codecChangesFinishTheOldFadeAndCoalesceOnlySettings() throws {
        let transmitter = AppAudioTransmitter()
        let configuration = AppAudioPipelineConfiguration(preferredCodec: .mpeg4AACELD, transmitSoundIsolationEnabled: false)
        let packets = Mutex<[RTCAudioPacket]>([])
        transmitter.onPacket = { packet in packets.withLock { $0.append(packet) } }
        try transmitter.rebuild(configuration: configuration, encoding: configuration.codecRuntimeReport.activeConfiguration)
        defer { transmitter.stop() }
        for index in 0..<130 {
            if index == 100 {
                try transmitter.updateFormat(.init(codec: .mpeg4AACELD, format: .init(sampleRate: 16000, channelCount: 1)))
                try transmitter.updateFormat(.init(codec: .mpeg4AACELD, format: .init(sampleRate: 24000, channelCount: 1)))
            }
            try transmitter.process(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) / 100,
                samples: (0..<480).map { Float(0.15 * sin(Double(index * 480 + $0) * 2 * .pi * 600 / 48000)) }))
        }
        let sent = packets.withLock { $0 }
        #expect(!sent.contains { $0.format.sampleRate == 16000 }, "Only the replaceable setting may coalesce")
        let firstNew = try #require(sent.firstIndex { $0.format.sampleRate == 24000 })
        #expect(firstNew > 0)
        #expect(sent[firstNew].capturedAt < 1.09)
        #expect(zip(sent, sent.dropFirst()).allSatisfy { $1.sequenceNumber == $0.sequenceNumber + 1 })
        let decoder = StreamingCodecDecoder()
        var oldLast: PCMFrame?
        for packet in sent.prefix(firstNew) { oldLast = try AppAudioCodecBridge.decode(packet, using: decoder) }
        #expect(try #require(oldLast).samples.suffix(96).allSatisfy { abs($0) < 0.002 },
            "The already-sent old codec must finish its fade before the new codec fills its first packet")
        #expect(transmitter.failureCount == 0)
    }

    @Test(arguments: [RTCAudioCodecIdentifier.pcm16, .opus, .mpeg4AACELD])
    func silentTransmitterStopsPacketsAndRestartsForBriefReplies(codec: RTCAudioCodecIdentifier) throws {
        let transmitter = AppAudioTransmitter()
        let configuration = AppAudioPipelineConfiguration(preferredCodec: codec, transmitSoundIsolationEnabled: false)
        let packets = Mutex<[RTCAudioPacket]>([])
        transmitter.onPacket = { packet in packets.withLock { $0.append(packet) } }
        try transmitter.rebuild(configuration: configuration, encoding: configuration.codecRuntimeReport.activeConfiguration)
        defer { transmitter.stop() }
        for index in 0..<400 {
            let samples = (0..<480).map { sample in
                (200..<210).contains(index) ? Float(0.03 * sin(Double(sample) * 2 * .pi * 500 / 48000)) : 0
            }
            transmitter.processMicrophone(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) / 100, samples: samples))
        }
        let sent = packets.withLock { $0 }
        #expect(!sent.isEmpty)
        #expect(sent.count < 120, "Silence must avoid encoding and sending, including the VAD release period")
        #expect(sent.filter { (0.3..<1.9).contains($0.capturedAt) || (3..<4).contains($0.capturedAt) }.isEmpty)
        let onset = try #require(sent.first { $0.capturedAt >= 1.9 })
        #expect(onset.capturedAt < 2.03, "A 100 ms acknowledgement must resume immediately")
        #expect(transmitter.failureCount == 0)
    }

    @Test(arguments: [256, 480, 960])
    func transmitIsolationSwitchDoesNotClickWithoutNetworkOrHardware(quantum: Int) throws {
        let transmitter = AppAudioTransmitter()
        let configuration = AppAudioPipelineConfiguration(transmitSoundIsolationEnabled: false)
        let received = Mutex<[Float]>([])
        let failures = Mutex<[String]>([])
        transmitter.onPacket = { packet in
            do {
                let frame = try AppAudioCodecBridge.decode(packet)
                received.withLock { $0 += frame.samples }
            } catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        try transmitter.rebuild(configuration: configuration, encoding: configuration.codecRuntimeReport.activeConfiguration)
        defer { transmitter.stop() }
        let framesPerStage = Int(48000 / quantum)
        for index in 0..<(framesPerStage * 4) {
            if index > 0, index.isMultiple(of: framesPerStage) {
                try transmitter.updateIsolation(enabled: (index / framesPerStage).isMultiple(of: 2) == false)
            }
            let offset = index * quantum
            try transmitter.process(.init(sequenceNumber: UInt64(index), capturedAt: Double(offset) / 48000,
                samples: (0..<quantum).map { Float(0.15 * sin(Double(offset + $0) * 2 * .pi * 600 / 48000)) }))
        }
        let samples = received.withLock { $0 }
        #expect(failures.withLock { $0.isEmpty })
        #expect(samples.count >= framesPerStage * quantum * 4 - 480)
        let maximumStep = zip(samples.dropFirst(24000), samples.dropFirst(24001)).map { abs($0 - $1) }.max() ?? 1
        #expect(maximumStep < 0.04, "The transmitted waveform itself must fade; a local RX fade cannot protect remote listeners")
    }

    @Test func changingTransmitIsolationDoesNotSuspendReceiving() async throws {
        let pipeline = AppAudioPipeline()
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { pipeline.stop() }
        let packet = try AppTestSupport.receivedAudioPacket(peerID: "peer",
            frame: .init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)), codec: .pcm16)
        let started = DispatchSemaphore(value: 0), finished = Mutex(false)
        defer { finished.withLock { $0 = true } }
        let task = Task.detached {
            var failed = 0, received = 0
            started.signal()
            repeat {
                do { _ = try pipeline.processReceivedAudioPacket(packet); received += 1 }
                catch { failed += 1 }
                try? await Task.sleep(for: .milliseconds(1))
            } while !finished.withLock({ $0 })
            return (received, failed)
        }
        #expect(waitForAudioWhileUIIsOccupied(started))
        try pipeline.updateSoundIsolation(transmit: true, receiveMaster: false, peers: [:])
        finished.withLock { $0 = true }
        let result = await task.value
        #expect(result.0 > 0)
        #expect(result.1 == 0, "The independent transmit graph cannot suspend remote voice")
    }

    @Test func inputReconfigurationDiscardsIncomingAudioWithoutWaiting() async throws {
        let pipeline = AppAudioPipeline()
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { pipeline.stop() }
        let packet = try AppTestSupport.receivedAudioPacket(peerID: "peer",
            frame: .init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)), codec: .pcm16)
        let completed = DispatchSemaphore(value: 0)
        let task = pipeline.reconfigureInput {
            let task = Task.detached {
                let result = Result { try pipeline.processReceivedAudioPacket(packet) }
                completed.signal()
                return result
            }
            #expect(waitForAudioWhileUIIsOccupied(completed),
                "An I/O change must not queue speech behind the native reconfiguration")
            return task
        }
        let result = await task.value
        #expect(throws: AppAudioPipelineError.notConfigured) { try result.get() }
        #expect(pipeline.snapshot.buses.first { $0.id == "rx-peer-peer" }?.sources.first?.scheduledFrameCount == 0)
    }

    @Test func receiveIsolationRetainsItsNativeParametersAfterGraphChanges() throws {
        let engine = AVAudioEngine()
        let pipeline = AppAudioPipeline(makeEngine: { engine })
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { pipeline.stop() }
        for enabled in [true, false, true] {
            try pipeline.updateSoundIsolation(transmit: false, receiveMaster: enabled, peers: ["peer": enabled])
            for effect in engine.attachedNodes.compactMap({ $0 as? AVAudioUnitEffect })
                where effect.audioComponentDescription.componentSubType == kAudioUnitSubType_AUSoundIsolation {
                let parameters = try #require(effect.auAudioUnit.parameterTree)
                #expect(parameters.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_SoundToIsolate))?.value
                    == AUValue(kAUSoundIsolationSoundType_Voice))
                #expect(parameters.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?.value
                    == (enabled ? 50 : 100))
            }
        }
    }

    @Test(arguments: [false, true])
    func stoppingOrMutingDiscardsPendingSpeech(mute: Bool) throws {
        let pipeline = AppAudioPipeline()
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: [])
        defer { pipeline.stop() }
        pipeline.applyVADSensitivity(.noisy)
        for number in 0..<4 {
            pipeline.processMicrophoneFrame(.init(sequenceNumber: UInt64(number),
                capturedAt: Double(number) * 0.005, samples: Array(repeating: 0.3, count: 240)))
        }
        #expect(pipeline.vadRuntimeSnapshot.state == .speech)
        if mute {
            let sent = pipeline.inputObservation.sentPackets
            let processed = pipeline.snapshot.buses.first { $0.id == "tx-bus" }?.sinks.first?.emittedFrameCount ?? 0
            pipeline.setInputMuted(true)
            for number in 4..<44 {
                pipeline.processMicrophoneFrame(.init(sequenceNumber: UInt64(number),
                    capturedAt: Double(number) * 0.005, samples: Array(repeating: 0.3, count: 240)))
            }
            #expect(pipeline.inputObservation.sentPackets == sent)
            #expect((pipeline.snapshot.buses.first { $0.id == "tx-bus" }?.sinks.first?.emittedFrameCount ?? 0) > processed,
                "Native DSP must consume silent time during mute instead of freezing an old speech tail")
            pipeline.setInputMuted(false)
        } else { pipeline.stop() }
        #expect(pipeline.vadRuntimeSnapshot.state == .silence,
            "A new unmuted capture/call must never inherit a previous speech window")
    }

    @Test(arguments: [0.005, 0.01, 0.02], VoiceActivitySensitivity.allCases)
    func vadHoldsOnlyTheAttackNotAlreadyCoveredByTheCurrentFrame(duration: Double, sensitivity: VoiceActivitySensitivity) {
        var controller = AudioTransmissionController()
        controller.applyVADSensitivity(sensitivity)
        let heldFrames = max(0, Int((sensitivity.configuration.attackDuration / duration).rounded()) - 1)
        var emitted: [UInt64] = []
        for index in 0..<20 {
            let frame = PCMFrame(sequenceNumber: UInt64(index), capturedAt: Double(index) * duration,
                samples: Array(repeating: 0.2, count: Int((48000 * duration).rounded())))
            let packets = controller.process(frame: frame, level: 0.2)
            for packet in packets {
                if case .voice(let voice) = packet { emitted.append(voice.sequenceNumber) }
            }
            #expect(emitted.count == max(0, index + 1 - heldFrames),
                "The current captured samples already contribute to VAD attack; do not wait another full frame")
        }
        #expect(emitted == (0..<emitted.count).map(UInt64.init), "No onset sample may be omitted or repeated")
    }

    @Test func cancelledRTCConsumerCannotScheduleIntoTheCurrentGraph() async throws {
        let pipeline = AppAudioPipeline()
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { pipeline.stop() }
        let packet = try AppTestSupport.receivedAudioPacket(peerID: "peer",
            frame: .init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)), codec: .pcm16)
        let gate = ManualAsyncGate()
        let task = Task.detached {
            await gate.wait()
            return Result { try pipeline.processReceivedAudioPacket(packet) }
        }
        await gate.waitForEntry()
        task.cancel()
        await gate.release()
        let result = await task.value
        #expect(throws: AppAudioPipelineError.notConfigured) { try result.get() }
        let source = pipeline.snapshot.buses.first { $0.id == "rx-peer-peer" }?.sources.first
        #expect(source?.scheduledFrameCount == 0)
    }

    @Test func transmitDSPAndEncodingDoNotWaitForTheUIActor() async throws {
        let pipeline = AppAudioPipeline()
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: [])
        defer { pipeline.stop() }
        let completion = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try pipeline.processCapturedFrame(.init(sequenceNumber: 0,
                samples: Array(repeating: 0.1, count: 480)))
            completion.signal()
        }
        #expect(waitForAudioWhileUIIsOccupied(completion),
            "Captured PCM must traverse DSP and encoding while UI/control is busy")
        _ = try await task.value
    }

    @Test func receiveDecodeAndScheduleDoNotWaitForTheUIActor() async throws {
        let pipeline = AppAudioPipeline()
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { pipeline.stop() }
        let packet = try AppTestSupport.receivedAudioPacket(peerID: "peer",
            frame: .init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)), codec: .pcm16)
        let completion = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try pipeline.processReceivedAudioPacket(packet)
            completion.signal()
        }
        #expect(waitForAudioWhileUIIsOccupied(completion),
            "Decoding and native playback scheduling must not wait for UI/control")
        _ = try await task.value
    }

    private func waitForAudioWhileUIIsOccupied(_ completion: DispatchSemaphore) -> Bool {
        completion.wait(timeout: .now() + .milliseconds(30)) == .success
    }

    @Test func transmitFormatChangeKeepsReceiveGraphRunning() throws {
        let engine = AVAudioEngine()
        let pipeline = AppAudioPipeline(makeEngine: { engine })
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { pipeline.stop() }
        try pipeline.processPlaybackFrame(.init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)))
        let before = pipeline.snapshot
        let nodes = engine.attachedNodes
        try pipeline.updateTransmitFormat(.init(sampleRate: 16000, channelCount: 1))
        let after = pipeline.snapshot
        #expect(engine.isRunning)
        #expect(engine.attachedNodes == nodes)
        let receiveBefore = before.buses.filter { $0.id != "tx-bus" }
        var receiveAfter = after.buses.filter { $0.id != "tx-bus" }
        // The live render clock keeps consuming audio during a TX change.
        // Compare graph/configuration exactly, but require its counters to
        // advance instead of incorrectly requiring the output to stand still.
        for bus in receiveAfter.indices where receiveBefore.indices.contains(bus) {
            for source in receiveAfter[bus].sources.indices where receiveBefore[bus].sources.indices.contains(source) {
                #expect((receiveAfter[bus].sources[source].bufferedDuration ?? 0)
                    <= (receiveBefore[bus].sources[source].bufferedDuration ?? 0))
                receiveAfter[bus].sources[source].bufferedDuration = receiveBefore[bus].sources[source].bufferedDuration
            }
            for sink in receiveAfter[bus].sinks.indices where receiveBefore[bus].sinks.indices.contains(sink) {
                #expect(receiveAfter[bus].sinks[sink].emittedFrameCount >= receiveBefore[bus].sinks[sink].emittedFrameCount)
                receiveAfter[bus].sinks[sink].emittedFrameCount = receiveBefore[bus].sinks[sink].emittedFrameCount
                receiveAfter[bus].sinks[sink].normalizationReport = receiveBefore[bus].sinks[sink].normalizationReport
            }
        }
        #expect(receiveBefore == receiveAfter)
        #expect(after.buses.first { $0.id == "tx-bus" }?.sinks.first?.targetFormat.sampleRate == 16000)
    }

    @Test(arguments: VoiceActivitySensitivity.allCases)
    func shortAcknowledgementsStartWithinTwentyMilliseconds(sensitivity: VoiceActivitySensitivity) {
        var controller = AudioTransmissionController()
        controller.applyVADSensitivity(sensitivity)
        let starts = [200, 412, 824, 1436] // 1, 1, 2, 3 second pauses around 60 ms replies
        var sent: [UInt64] = []
        var sentAt: [UInt64: Int] = [:]
        var clock: [UInt64] = []
        for number in 0..<1600 {
            let audible = starts.contains { number >= $0 && number < $0 + 12 }
            let samples = (0..<240).map { audible ? Float(sin(Double(number * 240 + $0) * 2 * .pi * 440 / 48000) * 0.3) : 0 }
            let frame = PCMFrame(sequenceNumber: UInt64(number), capturedAt: Double(number) * 0.005, samples: samples)
            for packet in controller.process(frame: frame, level: audible ? 0.2 : 0) {
                if case .voice(let voice) = packet { sent.append(voice.sequenceNumber); sentAt[voice.sequenceNumber] = number }
                switch packet {
                case .voice(let frame), .silence(let frame): clock.append(frame.sequenceNumber)
                }
            }
        }
        #expect(clock == (0..<clock.count).map(UInt64.init), "Silence must preserve the codec clock without omission or replay")
        #expect(clock.count >= 1596, "Only the pending VAD attack window may remain buffered")
        for start in starts {
            for number in start..<(start + 12) {
                #expect(sent.filter { $0 == UInt64(number) }.count == 1,
                    "Every part of a brief acknowledgement must be sent exactly once")
            }
            #expect((sentAt[UInt64(start)] ?? 10000) - start <= 4,
                "VAD must not add more than 20 ms before the first phoneme")
        }
    }
}
}
