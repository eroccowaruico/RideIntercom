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
    @Test func adapterPreservesACompleteHardwareTapBurst() async {
        let rtc = FakeRTCCallSession()
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        adapter.connect(group: IntercomSeedData.recentGroups[0])
        adapter.startMedia()
        await rtc.waitForOperation("startMedia")
        // One actual 100 ms tap becomes five 20 ms packets in the same turn.
        for sequence in 0..<5 {
            adapter.sendAudioPacket(.init(sequenceNumber: UInt64(sequence), codec: .pcm16,
                sampleCount: 960, payload: Data(repeating: 0, count: 1920)))
        }
        await AppTestSupport.waitUntil { rtc.sentAudioSequences.last == 4 }
        #expect(rtc.sentAudioSequences == [0, 1, 2, 3, 4])
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
