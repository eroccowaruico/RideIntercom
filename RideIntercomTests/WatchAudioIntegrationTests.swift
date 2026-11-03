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
    @Test(arguments: [0, 32])
    func failedWatchAudioCheckRestoresRouteAndMute(keyCount: Int) async {
        let h = AppTestSupport.makeHarness(groups: [])
        let vm = h.viewModel, input = h.viewModel.audioInputCapture, output = h.viewModel.audioOutputRenderer
        await verifyPhoneAudioCheck(h)
        vm.applyLocalMute(true)
        do {
            _ = try await vm.attachWatchAudio(.init(sessionID: UUID(), key: Data(repeating: 7, count: keyCount),
                endpoint: .init(name: "invalid", type: "invalid", domain: "invalid")), audioCheck: true)
            Issue.record("Invalid audio-check setup must fail")
        } catch {}
        #expect(vm.audioCheckPhase == .failed && !vm.audioCheckOwnsAudioPipeline)
        #expect(vm.audioInputCapture === input && vm.audioOutputRenderer === output)
        #expect(vm.watchAudioLink == nil && !vm.isUsingWatchAudio && vm.isMuted)
        #expect(!vm.hasAnyActiveGroupConnection && h.callSession.startMediaCallCount == 0)
        await verifyPhoneAudioCheck(h)
    }

    @Test func cancelledWatchAudioCheckRestoresBeforeLateActivation() async throws {
        let h = AppTestSupport.makeHarness(groups: []), gate = ManualAsyncGate()
        h.audioSessionBackend.activationGate = gate
        let vm = h.viewModel, input = h.viewModel.audioInputCapture, output = h.viewModel.audioOutputRenderer
        vm.applyLocalMute(true)
        let id = UUID(), key = Data(repeating: 4, count: 32)
        let watch = try AudioDeviceConnection(sessionID: id, key: key, role: .device)
        defer { watch.stop(); vm.cancelAudioCheck() }
        let endpoint = try await watch.prepare()
        _ = try await vm.attachWatchAudio(.init(sessionID: id, key: key, endpoint: endpoint), audioCheck: true)
        await gate.waitForEntry()
        #expect(vm.audioCheckPhase == .preparing && !vm.canStartAudioCheck)
        vm.cancelAudioCheck()
        await gate.release()
        _ = await vm.audioSessionManager.requestActive(false).value
        #expect(vm.audioCheckPhase == .idle && !vm.audioCheckOwnsAudioPipeline)
        #expect(vm.audioInputCapture === input && vm.audioOutputRenderer === output)
        #expect(vm.watchAudioLink == nil && !vm.isUsingWatchAudio && vm.isMuted)
        #expect(h.inputBackend.startCount == 0 && h.callSession.startMediaCallCount == 0)
        await verifyPhoneAudioCheck(h)
    }

    @Test func watchAudioCheckRecordsOnPhoneAndRestoresBackendsWithoutStartingCall() async throws {
        let h = AppTestSupport.makeHarness(groups: [])
        let vm = h.viewModel, owner = AppCallOwner(account: h.viewModel.accountSession, viewModel: h.viewModel)
        let originalInput = vm.audioInputCapture, originalOutput = vm.audioOutputRenderer
        await verifyPhoneAudioCheck(h)
        let phoneStartsBeforeWatch = h.inputBackend.startCount
        vm.applyLocalMute(true)
        let id = UUID(), key = Data(repeating: 9, count: 32)
        let watch = try AudioDeviceConnection(sessionID: id, key: key, role: .device)
        let watchOutput = AudioOutputStreamRenderer(configuration: .init(maximumBufferedDuration: 0.1), backend: watch)
        defer { _ = watchOutput.stop(); watch.stop(); vm.cancelAudioCheck() }
        let endpoint = try await watch.prepare()
        try #require(watchOutput.start().result == .applied)
        let request = WatchControlRequest(.startAudioCheck(.init(sessionID: id, key: key, endpoint: endpoint)), snapshot: owner.watchSnapshot())
        let reply = await owner.handleWatchRequest(request)
        #expect(reply.problem == nil && !reply.snapshot.hasCall)
        #expect(watch.connect(to: try #require(reply.audioEndpoint)))
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        #expect(vm.audioCheckPhase == .recording)
        #expect(vm.audioCheckWatchSessionID == id)
        #expect(vm.audioInputCapture !== originalInput && vm.audioOutputRenderer !== originalOutput)
        #expect(h.inputBackend.startCount == phoneStartsBeforeWatch && h.callSession.startMediaCallCount == 0)
        await AppTestSupport.waitUntil { watch.isSendReady }
        try #require(watch.isSendReady)
        watch.setSendingAllowed(true)
        try #require(watch.isSendingAllowed)
        for index in 0..<30 {
            let frame = PCMFrame(sequenceNumber: UInt64(index), format: .intercomPacketAudio,
                capturedAt: 100 + Double(index) * 0.01,
                samples: (0..<480).map { Float(sin(Double(index * 480 + $0) * .pi * 880 / 48_000) * 0.3) })
            try #require(watchOutput.schedule(frame).result == .applied)
            try await Task.sleep(for: .milliseconds(10))
        }
        await AppTestSupport.waitUntil { !vm.audioCheckRecordedFrames.isEmpty }
        try #require(!vm.audioCheckRecordedFrames.isEmpty, "Watch device audio must reach Phone capture")
        watch.setSendingAllowed(false)
        vm.finishAudioCheckRecording(playbackDuration: .seconds(5))
        #expect(vm.audioCheckPhase == .preparing && vm.audioCheckRecordedFrameCount > 0,
            "Phone waits for the Watch to close its microphone before replay")
        #expect(vm.audioCheckRecordedNonzeroSamples > 0, "Phone transmit processing must preserve device audio")
        let play = await owner.handleWatchRequest(.init(.playAudioCheck(id), snapshot: owner.watchSnapshot()))
        #expect(play.problem == nil && vm.audioCheckPhase == .playing)
        #expect(!vm.playWatchAudioCheck(sessionID: id), "Duplicate play requests cannot restart playback")
        let stopped = await owner.handleWatchRequest(.init(.stopAudioCheck(id), snapshot: owner.watchSnapshot()))
        #expect(stopped.problem == nil)
        #expect(vm.audioInputCapture === originalInput && vm.audioOutputRenderer === originalOutput)
        #expect(vm.watchAudioLink == nil && !vm.isUsingWatchAudio && vm.isMuted)
        #expect(!vm.playWatchAudioCheck(sessionID: id), "Cancelled audio cannot replay")
        #expect(!vm.hasAnyActiveGroupConnection && h.callSession.startMediaCallCount == 0)
        await verifyPhoneAudioCheck(h)
    }

    private func verifyPhoneAudioCheck(_ h: AppTestSupport.Harness) async {
        let vm = h.viewModel
        // Explicit user unmute: restoring the phone preference never silently
        // changes it just because the Watch check ended.
        vm.applyLocalMute(false)
        let previousOutputFrames = h.outputBackend.scheduledFrames.count
        vm.startAudioCheck()
        await AppTestSupport.waitUntil { vm.audioCheckPhase == .recording }
        #expect(vm.audioCheckPhase == .recording && !vm.isUsingWatchAudio)
        h.inputBackend.emit(.init(sequenceNumber: 1, format: .intercomPacketAudio,
            capturedAt: 200, samples: Array(repeating: 0.3, count: 480)))
        await AppTestSupport.waitUntil { !vm.audioCheckRecordedFrames.isEmpty }
        vm.finishAudioCheckRecording(playbackDuration: .seconds(5))
        #expect(vm.audioCheckPhase == .playing && vm.audioCheckRecordedFrameCount == 480)
        await AppTestSupport.waitUntil { h.outputBackend.scheduledFrames.count > previousOutputFrames }
        #expect(h.outputBackend.scheduledFrames.dropFirst(previousOutputFrames).contains { $0.samples.contains { abs($0) > 0.01 } },
            "A restored phone route must actually record/process/schedule new phone audio")
        vm.completeAudioCheckPlayback()
        #expect(vm.audioCheckPhase == .completed && !vm.audioCheckOwnsAudioPipeline)
    }

    @Test func watchAudioPassesThroughThePhoneCallWithoutOpeningPhoneInputOrPlayback() async throws {
        let h = try AppTestSupport.makeHarnessWithSavedUser(), received = Mutex<[Float]>([]), ready = Mutex(false)
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
