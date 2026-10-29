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
struct TransportAdapterTests {
    @Test(arguments: [RTCAudioCodecIdentifier.pcm16, .opus, .mpeg4AACELD])
    func capturedSpeechReachesRTCWhileUIIsOccupied(codec: RTCAudioCodecIdentifier) async throws {
        let rtc = FakeRTCCallSession()
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        adapter.startMedia()
        adapter.sendAudioPacket(.init(sequenceNumber: 999, codec: .pcm16, payload: Data([0, 0])))
        await AppTestSupport.waitUntil { rtc.sentAudioSequences == [999] }
        let pipeline = AppAudioPipeline()
        try pipeline.rebuild(configuration: .init(preferredCodec: codec, transmitSoundIsolationEnabled: false), peerIDs: [])
        pipeline.onTransmitPacket = adapter.audioPacketSink
        let delivery = AudioFrameDelivery { _ in }
        defer { delivery.finish(); adapter.disconnect(); pipeline.stop() }
        let completed = DispatchSemaphore(value: 0)
        let task = Task.detached {
            for index in 0..<6 {
                pipeline.processMicrophoneFrame(.init(sequenceNumber: UInt64(index),
                    capturedAt: Double(index) * 0.01, samples: Array(repeating: 0.2, count: 480)),
                    shouldProcess: { delivery.isActive })
            }
            let deadline = ContinuousClock.now + .milliseconds(25)
            while rtc.sentAudioSequences.count < 2, ContinuousClock.now < deadline { await Task.yield() }
            if rtc.sentAudioSequences.count > 1 { completed.signal() }
        }
        #expect(waitWhileUIIsOccupied(completed), "Capture → VAD → DSP → codec → RTC must not wait for UI")
        await task.value
        let count = pipeline.inputObservation.sentPackets
        delivery.finish()
        pipeline.processMicrophoneFrame(.init(sequenceNumber: 6, samples: Array(repeating: 0.2, count: 480)),
            shouldProcess: { delivery.isActive })
        #expect(pipeline.inputObservation.sentPackets == count, "A retired capture binding cannot feed a new call")
    }

    @Test func incomingAudioIsProcessedWhileTheUIActorIsOccupied() async throws {
        let rtc = FakeRTCCallSession()
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        let pipeline = AppAudioPipeline()
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { adapter.disconnect(); pipeline.stop() }
        let completed = DispatchSemaphore(value: 0)
        adapter.processReceivedAudio = { packet in
            do {
                let frame = try pipeline.processReceivedAudioPacket(packet)
                completed.signal()
                return .processed(level: (try? AudioSignalMeter.measure(frame).rms) ?? 0)
            } catch { return .failed(String(describing: error)) }
        }
        let packet = try AppTestSupport.receivedAudioPacket(peerID: "peer",
            frame: .init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)), codec: .pcm16)
        rtc.emit(.receivedAudioPacket(packet))
        #expect(waitWhileUIIsOccupied(completed), "The App's RTC consumer must schedule audio before UI resumes")
    }

    private func waitWhileUIIsOccupied(_ completion: DispatchSemaphore) -> Bool {
        completion.wait(timeout: .now() + .milliseconds(30)) == .success
    }

    @Test func queuedAudioDrainsWithoutWaitingForTheUIActor() async {
        let rtc = FakeRTCCallSession()
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        adapter.startMedia()
        adapter.sendAudioPacket(.init(sequenceNumber: 0, codec: .pcm16,
            sampleCount: 480, payload: Data(repeating: 0, count: 960)))
        await AppTestSupport.waitUntil { rtc.sentAudioSequences == [0] }
        for sequence in 1...3 {
            adapter.sendAudioPacket(.init(sequenceNumber: UInt64(sequence), codec: .pcm16,
                sampleCount: 480, payload: Data(repeating: 0, count: 960)))
        }
        #expect(audioArrivesWhileUIIsOccupied(rtc),
            "Already encoded audio must drain while UI/control work occupies MainActor")
        #expect(rtc.sentAudioSequences == [0, 1, 2, 3])
        adapter.disconnect()
    }

    private func audioArrivesWhileUIIsOccupied(_ rtc: FakeRTCCallSession) -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(30)
        while ContinuousClock.now < deadline {
            if rtc.sentAudioSequences.last == 3 { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return false
    }

    @Test func keepaliveMetadataUsesReliableControlDelivery() async {
        let rtc = FakeRTCCallSession()
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        adapter.sendControl(.keepalive)
        await AppTestSupport.waitUntil { !rtc.sentApplicationDataMessages.isEmpty }
        #expect(rtc.sentApplicationDataMessages.first?.delivery == .reliable)
        adapter.disconnect()
    }

    @Test(arguments: [0.005, 0.01, 0.02])
    func adapterPreservesACompleteHardwareTapBurst(duration: Double) async {
        let rtc = FakeRTCCallSession()
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        adapter.connect(group: IntercomSeedData.recentGroups[0])
        adapter.startMedia()
        await rtc.waitForOperation("startMedia")
        // The time budget must survive packetization changes: 5/10/20 ms.
        let count = Int((0.1 / duration).rounded())
        let samples = Int((48000 * duration).rounded())
        for sequence in 0..<count {
            adapter.sendAudioPacket(.init(sequenceNumber: UInt64(sequence), codec: .pcm16,
                sampleCount: samples, payload: Data(repeating: 0, count: samples * 2)))
        }
        await AppTestSupport.waitUntil { rtc.sentAudioSequences.last == UInt64(count - 1) }
        #expect(rtc.sentAudioSequences == (0..<count).map(UInt64.init))
        adapter.disconnect()
    }
    @Test func currentProcessUsesPackageBackedRTCRouteManager() {
        let adapter = RideIntercomCallSessionAdapter(memberID: "fixture-local")
        #expect(adapter.activeRouteDebugTypeName == "RTC RouteManager")
    }

    @Test func callSessionAdapterIgnoresFallbackRouteFailureUntilSessionFails() async {
        let rtcSession = FakeRTCCallSession()
        let adapter = RideIntercomCallSessionAdapter(memberID: "member-local", rtcSession: rtcSession)
        defer { withExtendedLifetime(adapter) {} }
        let recorder = TransportEventRecorder()
        adapter.onEvent = { event in
            recorder.append(event)
        }

        await AppTestSupport.waitUntil { rtcSession.hasSubscriber }
        rtcSession.emit(.error(.connectionFailed(.webRTC, "WebRTC route configuration is unavailable")))
        await AppTestSupport.waitUntil(timeout: .milliseconds(50)) { recorder.containsLinkFailure }

        #expect(!recorder.containsLinkFailure)

        rtcSession.emit(.stateChanged(.failed))
        await AppTestSupport.waitUntil { recorder.containsLinkFailure }

        #expect(recorder.containsLinkFailure)
    }

    @Test func adapterSerializesSuspendingRTCOperations() async {
        let rtc = FakeRTCCallSession()
        rtc.prepareDelay = .milliseconds(80)
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        adapter.connect(group: IntercomSeedData.recentGroups[0])
        try? await Task.sleep(for: .milliseconds(10))
        adapter.startMedia()
        adapter.stopMedia()
        adapter.disconnect()
        await AppTestSupport.waitUntil { rtc.operations.last == "stopConnection" }
        #expect(rtc.operations == ["prepare", "startConnection", "startMedia", "stopMedia", "stopConnection"])
    }

    @Test func adapterKeepsOnlyFreshAudioWhileConnectionCommandsAreBusy() async {
        let rtc = FakeRTCCallSession()
        rtc.prepareDelay = .milliseconds(50)
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        adapter.connect(group: IntercomSeedData.recentGroups[0])
        adapter.startMedia()
        for sequence in 0..<100 {
            adapter.sendAudioPacket(.init(sequenceNumber: UInt64(sequence), codec: .pcm16, payload: Data([0, 0])))
        }
        await AppTestSupport.waitUntil { rtc.sentAudioSequences.last == 99 }
        #expect(rtc.sentAudioSequences == [95, 96, 97, 98, 99])
        adapter.disconnect()

        let stalled = FakeRTCCallSession()
        stalled.prepareDelay = .milliseconds(200)
        let other = RideIntercomCallSessionAdapter(rtcSession: stalled)
        other.connect(group: IntercomSeedData.recentGroups[0])
        other.startMedia()
        other.sendAudioPacket(.init(sequenceNumber: 0, codec: .pcm16, payload: Data([0, 0])))
        await AppTestSupport.waitUntil { stalled.operations.contains("startMedia") }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(stalled.sentAudioSequences.isEmpty)
        other.disconnect()
    }

}
}
