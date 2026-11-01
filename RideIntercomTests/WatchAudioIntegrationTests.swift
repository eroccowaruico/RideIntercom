import AudioCore
import AudioDevice
import Foundation
import RTC
import SessionManager
import Synchronization
import Testing
@testable import RideIntercom

/// Actual local encrypted device link and native AAC, with synthetic Watch
/// input and the existing offline phone graph. No microphone/device claims.
@MainActor struct WatchAudioIntegrationTests {
    @Test func watchAudioPassesThroughThePhoneCallWithoutOpeningPhoneInputOrPlayback() async throws {
        let h = AppTestSupport.makeHarness(), received = Mutex<[Float]>([]), ready = Mutex(false)
        let vm = h.viewModel
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        var actions: [WatchCallAction] = []
        let client = WatchControlClient { request in
            actions.append(request.action)
            return await owner.handleWatchRequest(request)
        }
        client.setReachable(true)
        _ = await client.perform(.refresh)
        let target = try #require(client.snapshot?.targets.first,
            "The Watch client must expose a saved destination before starting")
        let originalInput = vm.audioInputCapture, originalOutput = vm.audioOutputRenderer
        vm.applyLocalMute(true) // A phone-only preference cannot silence Watch input.
        let key = Data(repeating: 7, count: 32), sessionID = UUID()
        let watch = try AudioDeviceConnection(sessionID: sessionID, key: key, role: .device,
            onAvailability: { value in ready.withLock { $0 = value } })
        let watchInput = AudioInputStreamCapture(configuration: .init(voiceProcessing:
            .init(soundIsolationEnabled: false, otherAudioDuckingEnabled: false)), backend: watch)
        let watchOutput = AudioOutputStreamRenderer(configuration: .init(maximumBufferedDuration: 0.1), backend: watch)
        watchInput.setRuntimeEventHandler { event in
            if case .inputFrame(let frame) = event { received.withLock { $0.append(contentsOf: frame.samples) } }
        }
        defer { _ = watchInput.stop(); _ = watchOutput.stop(); watch.stop(); vm.disconnect() }
        let local = try await watch.prepare()
        try #require(watchInput.start().result == .applied && watchOutput.start().result == .applied)
        let offer = WatchAudioOffer(sessionID: sessionID, key: key, endpoint: local)
        let reply = try #require(await client.perform(.startAudio(target.id, offer)))
        #expect(reply.problem == nil)
        #expect(watch.connect(to: try #require(reply.audioEndpoint)))
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { ready.withLock { $0 } && vm.isAudioReady }
        #expect(vm.isAudioReady && vm.isUsingWatchAudio)
        #expect(vm.isMuted, "Watch does not overwrite the saved phone microphone preference")
        #expect(vm.audioInputCapture !== originalInput && vm.audioOutputRenderer !== originalOutput)
        let deadline = vm.callDisconnectDeadline
        let callReference = vm.currentCallReference
        func deliver(_ indices: Range<Int>) async throws {
            for index in indices {
                let frame = PCMFrame(sequenceNumber: UInt64(index),
                    format: .init(sampleRate: 48_000, channelCount: 1),
                    capturedAt: 100 + Double(index) * 0.01,
                    samples: (0..<480).map { Float(sin(Double(index * 480 + $0) * .pi * 880 / 48_000)) * 0.3 })
                #expect(watchOutput.schedule(frame).result == .applied)
                h.callSession.receive(try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
                // Pace the synthetic source at its existing 10-ms media cadence.
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        watch.setSendingAllowed(true)
        try await deliver(0..<60)
        await AppTestSupport.waitUntil { !h.callSession.sentAudioPackets.isEmpty && received.withLock { $0.contains { abs($0) > 0.01 } } }
        #expect(!h.callSession.sentAudioPackets.isEmpty, "Watch input must reach the existing RTC transmit sink")
        #expect(received.withLock { $0.contains { abs($0) > 0.01 } }, "The phone's mixed receive audio must return to the device")

        // Release only the local device gate: no phone mute/control command.
        watch.setSendingAllowed(false)
        let receivedBeforeRelease = received.withLock { $0.count }
        try await deliver(60..<120)
        await AppTestSupport.waitUntil { received.withLock { $0.count > receivedBeforeRelease } }
        #expect(!watch.isSendingAllowed && watch.isSendReady)
        #expect(received.withLock { $0.count > receivedBeforeRelease }, "Reception continues while the Watch microphone gate is closed")
        #expect(vm.isAudioReady && vm.isUsingWatchAudio && vm.currentCallReference == callReference)
        #expect(!h.callSession.sentAudioPackets.contains { (100.6..<101.2).contains($0.capturedAt) },
            "Frames offered while released must not enter the phone RTC transmitter")
        #expect(actions == [.refresh, .startAudio(target.id, offer)], "Press and release never synchronize phone mute")

        watch.setSendingAllowed(true)
        try await deliver(120..<180)
        await AppTestSupport.waitUntil { h.callSession.sentAudioPackets.contains { $0.capturedAt >= 101.2 } }
        #expect(h.callSession.sentAudioPackets.contains { $0.capturedAt >= 101.2 }, "A new explicit press resumes Watch transmission")
        watch.setSendingAllowed(false)
        #expect(h.inputBackend.startCount == 0)
        #expect(h.outputBackend.scheduledFrames.isEmpty)
        #expect(vm.callDisconnectDeadline == deadline)
        let ended = try #require(await client.perform(.end))
        #expect(ended.problem == nil && client.snapshot?.hasCall == false)
        #expect(actions == [.refresh, .startAudio(target.id, offer), .end])
        #expect(vm.watchAudioLink == nil && !vm.isAudioReady)
        #expect(vm.audioInputCapture === originalInput && vm.audioOutputRenderer === originalOutput,
            "Ending the device route restores the original local audio backends")
        #expect(vm.isMuted, "Returning to phone audio preserves its own microphone preference")
        let sent = h.callSession.sentAudioPackets.count
        watch.setSendingAllowed(true)
        _ = watchOutput.schedule(.init(sequenceNumber: 100, capturedAt: 200, samples: Array(repeating: 0.3, count: 480)))
        for _ in 0..<20 { await Task.yield() }
        #expect(h.callSession.sentAudioPackets.count == sent, "Ended audio cannot enter a later call")
    }
}
