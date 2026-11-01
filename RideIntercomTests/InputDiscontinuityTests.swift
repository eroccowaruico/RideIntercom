import AudioCore
import Foundation
import RTC
import Synchronization
import Testing
import VADGate
@testable import RideIntercom

@MainActor struct InputDiscontinuityTests {
    @Test(arguments: [false, true])
    func interruptedInputDiscardsOldVADAndDSPAudio(changesFormat: Bool) throws {
        let driver = OfflineAudioDriver()
        let pipeline = AppAudioPipeline(makeEngine: driver.makeEngine)
        try pipeline.rebuild(configuration: .init(preferredCodec: .pcm16,
            transmitSoundIsolationEnabled: false), peerIDs: [])
        defer { pipeline.stop() }
        pipeline.applyVADSensitivity(.noisy)
        let sent = Mutex<[RTCAudioPacket]>([])
        pipeline.onTransmitPacket = { packet in sent.withLock { $0.append(packet) } }
        for i in 0..<4 {
            pipeline.processMicrophoneFrame(.init(sequenceNumber: UInt64(i), capturedAt: Double(i) * 0.01,
                samples: Array(repeating: 0.4, count: 480)))
        }
        #expect(pipeline.vadRuntimeSnapshot.state == .speech)
        sent.withLock { $0.removeAll() }
        let nextStart = changesFormat ? 0.04 : 10.0
        let rate = changesFormat ? 24_000.0 : 48_000.0
        for i in 0..<20 {
            pipeline.processMicrophoneFrame(.init(sequenceNumber: UInt64(i + 4),
                format: .init(sampleRate: rate, channelCount: 1), capturedAt: nextStart + Double(i) * 0.01,
                samples: Array(repeating: 0, count: Int(rate * 0.01))))
        }
        let packets = sent.withLock { $0 }
        #expect(!packets.isEmpty, "The resumed silent stream must run through the native pipeline")
        #expect(packets.allSatisfy { $0.capturedAt >= nextStart }, "No VAD pre-roll from the previous input stream may escape")
        #expect(packets.allSatisfy { $0.payload.allSatisfy { $0 == 0 } }, "PCM16 silence must contain no previous speech or DSP tail")
        #expect(pipeline.vadRuntimeSnapshot.state == .silence)
    }

    @Test func missingInputExpiresItsTalkingDisplayWithoutChangingMuteOrTheCall() async {
        let now = Date()
        let h = AppTestSupport.makeHarness(callAccessNow: { now }), vm = h.viewModel
        defer { vm.disconnect() }
        vm.selectGroup(vm.groups[0])
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { vm.isAudioReady }
        for i in 0..<6 {
            let frame = PCMFrame(sequenceNumber: UInt64(i), capturedAt: Double(i) * 0.01,
                samples: Array(repeating: 0.3, count: 480))
            vm.audioPipeline.processMicrophoneFrame(frame)
            vm.handleMicrophoneFrame(frame)
        }
        #expect(vm.isVoiceActive)
        let deadline = vm.callDisconnectDeadline
        vm.handleCallTick(now: now.timeIntervalSince1970 + vm.remoteTalkerTimeout / 2)
        #expect(vm.isVoiceActive, "Remote capture timestamps must not expire a fresh local observation")
        vm.handleCallTick(now: now.timeIntervalSince1970 + vm.remoteTalkerTimeout + 0.01)
        #expect(!vm.isVoiceActive)
        #expect(vm.selectedGroup?.members.first?.voiceLevel == 0)
        #expect(!vm.isMuted && vm.isAudioReady && vm.callDisconnectDeadline == deadline)
        #expect(vm.selectedGroup?.members.first?.voicePeakLevel == 0)
        let fresh = PCMFrame(sequenceNumber: 10, capturedAt: 1, samples: Array(repeating: 0.3, count: 480))
        vm.audioPipeline.processMicrophoneFrame(fresh)
        vm.handleMicrophoneFrame(fresh)
        #expect(vm.isVoiceActive)
        vm.stopAudioPipeline()
        #expect(!vm.isVoiceActive && vm.selectedGroup?.members.first?.voiceLevel == 0)
        #expect(vm.selectedGroup?.members.first?.voicePeakLevel == 0)
        #expect(!vm.isMuted && vm.callDisconnectDeadline == deadline)
    }
}
