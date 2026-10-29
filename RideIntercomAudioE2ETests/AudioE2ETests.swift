import AVFAudio
import AudioCore
import Codec
import Foundation
import RTC
import SessionManager
import XCTest
@testable import RideIntercom

final class AudioE2ETests: XCTestCase {
    /// Same production mixer/codec/output, in one process, without RTC or VAD.
    /// Compare 20 ms file delivery with the 100 ms capture batches seen on iOS.
    @MainActor
    func testSpeechContinuityWithoutNetwork() async throws {
        let samples = try SpeechFileInput(name: "speech-ja").samples
        var failures: [String] = []
        for milliseconds in [20, 100] {
            let name = "pipeline-\(milliseconds)ms"
            let probe = RenderedAudioProbe()
            let engine = AVAudioEngine()
            let output = SystemAudioOutputStreamBackend(engine: engine)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in probe.append(buffer) }
            defer { engine.mainMixerNode.removeTap(onBus: 0); try? output.stopRendering() }
            let hardware = try output.startRendering(configuration: .intercom)
            let pipeline = AppAudioPipeline()
            defer { pipeline.stop() }
            var processingFailures: [String] = []
            pipeline.onTransmitPacket = { packet in
                do { try pipeline.processReceivedAudioPacket(.init(peerID: PeerID(rawValue: "loopback"), packet: packet)) }
                catch { processingFailures.append(String(describing: error)) }
            }
            pipeline.onOutputFrame = { frame in
                do { try output.schedule(frame) }
                catch { processingFailures.append(String(describing: error)) }
            }
            try pipeline.rebuild(configuration: .init(rtcSendFormat: .init(sampleRate: 48_000, channelCount: 1),
                outputHardwareFormat: hardware, preferredCodec: .pcm16, transmitSoundIsolationEnabled: false,
                maximumBufferedDuration: 0.1), peerIDs: ["loopback"])
            let start = ContinuousClock.now
            let count = milliseconds * 48
            var resetStart = 0
            for index in 0..<(22_000 / milliseconds) {
                try await Task.sleep(until: start + .milliseconds(index * milliseconds), clock: .continuous)
                if index == 2_000 / milliseconds { probe.reset(); resetStart = output.playbackResetCount ?? 0 }
                let block = (0..<count).map { samples[(index * count + $0) % samples.count] }
                try pipeline.processCapturedFrame(PCMFrame(sequenceNumber: UInt64(index),
                    format: .init(sampleRate: 48_000, channelCount: 1),
                    capturedAt: ProcessInfo.processInfo.systemUptime, samples: block))
            }
            try await Task.sleep(until: start + .seconds(22), clock: .continuous)
            let rendered = probe.snapshot()
            let resets = (output.playbackResetCount ?? 0) - resetStart
            let mixer = String(describing: pipeline.snapshot)
            pipeline.stop()
            try output.stopRendering()
            let continuity = await Task.detached {
                SpeechContinuity.measure(reference: samples, referenceRate: 48_000,
                                         output: rendered.samples, outputRate: rendered.rate)
            }.value
            let measurement: [String: Any] = ["scenario": name, "role": "pipeline", "transport": "none",
                "remoteFixture": "speech-ja", "continuityPassed": continuity.passed,
                "continuity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(continuity)),
                "renderedSamples": rendered.samples.count, "sampleRate": rendered.rate,
                "outputPlaybackResets": resets, "mixer": mixer, "processingFailures": processingFailures]
            let data = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys]),
                                     uniformTypeIdentifier: "public.json")
            data.name = name + "-measurement"; data.lifetime = .keepAlways; add(data)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try probe.writeWAV(to: url, rendered: rendered)
            let recording = XCTAttachment(contentsOfFile: url)
            recording.name = name + "-speech"; recording.lifetime = .keepAlways; add(recording)
            if !continuity.passed || !processingFailures.isEmpty || rendered.invalid > 0
                || rendered.samples.count < Int(rendered.rate * 19) {
                failures.append("\(name): matched=\(continuity.matchedWindowRatio), missing=\(continuity.missingActiveRatio), resets=\(resets), errors=\(processingFailures)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    func testContinuityRejectsGapsRepeatsAndMissingSpeech() throws {
        let speech = try SpeechFileInput(name: "speech").samples
        let other = try SpeechFileInput(name: "reply").samples
        let clean = (0..<960_000).map { speech[($0 + 12_345) % speech.count] * 0.3 }
        func measure(_ output: [Float]) -> SpeechContinuity {
            SpeechContinuity.measure(reference: speech, referenceRate: 48_000, output: output, outputRate: 48_000)
        }
        XCTAssertTrue(measure(clean).passed, "Fixed delay and gain must preserve speech")
        let filtered = clean.reduce(into: [Float]()) { values, sample in
            values.append(0.8 * (values.last ?? 0) + 0.2 * sample)
        }.map { tanh($0 * 8) }
        XCTAssertTrue(measure(filtered).passed, "Coloration alone is not a dropout")
        var gaps = clean
        for index in gaps.indices where index % 24_000 < 4_800 { gaps[index] = 0 }
        XCTAssertFalse(measure(gaps).passed, "Repeated 100 ms losses must fail")
        XCTAssertGreaterThan(measure(gaps).missingActiveRatio, 0.05)
        var missing = clean
        missing.replaceSubrange(240_000..<264_000, with: repeatElement(0, count: 24_000))
        XCTAssertFalse(measure(missing).passed, "One missing half-second must fail")
        var repeated = clean
        repeated.replaceSubrange(240_000..<288_000, with: clean[192_000..<240_000])
        XCTAssertFalse(measure(repeated).passed, "Repeated speech must fail even without silence")
        var reordered = clean
        reordered.replaceSubrange(240_000..<480_000, with: clean[480_000..<720_000])
        reordered.replaceSubrange(480_000..<720_000, with: clean[240_000..<480_000])
        XCTAssertFalse(measure(reordered).passed, "Out-of-order speech must fail")
        XCTAssertFalse(measure(Array(repeating: 0, count: clean.count)).passed)
        XCTAssertFalse(measure((0..<clean.count).map { other[$0 % other.count] }).passed)
    }

    func testSpeechMatcherRejectsSilenceAndWrongSpeaker() throws {
        let speech = try SpeechFileInput(name: "speech").samples
        let other = try SpeechFileInput(name: "reply").samples
        let delayed = Array(repeating: Float(0), count: 12_345) + speech.map { $0 * 0.2 }
        XCTAssertGreaterThan(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: delayed, outputRate: 48_000), 0.95)
        XCTAssertEqual(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: Array(repeating: 0, count: speech.count), outputRate: 48_000), 0)
        XCTAssertLessThan(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: other, outputRate: 48_000), 0.4)
        let filtered = speech.reduce(into: [Float]()) { values, sample in
            values.append(0.8 * (values.last ?? 0) + 0.2 * sample)
        }
        XCTAssertGreaterThan(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: filtered.map { tanh($0 * 8) }, outputRate: 48_000), 0.8)
        var state: UInt64 = 1
        let noise = speech.map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Float(state >> 32) / Float(UInt32.max) - 0.5
        }
        XCTAssertLessThan(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: noise, outputRate: 48_000), 0.4)
    }

    @MainActor
    func testSystemSessionAcceptsCallProfiles() throws {
        let manager = AudioSessionManager()
        for configuration in [
            AudioSessionConfiguration(),
            AudioSessionConfiguration(prefersEchoCancelledInput: true),
            AudioSessionConfiguration(defaultToSpeaker: true),
            AudioSessionConfiguration(mode: .voiceChat),
        ] {
            let report = try manager.configure(configuration)
            print("SYSTEM SESSION: \(report)")
            for operation in report.operations {
                if case .failed = operation.result { XCTFail("\(configuration): \(operation)") }
            }
        }
    }

    @MainActor
    func testDuplexSpeechOverNetwork() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let scenarioData = try XCTUnwrap(env["AUDIO_E2E_SCENARIOS"]?.data(using: .utf8))
        let scenarios = try JSONDecoder().decode([AudioE2EScenario].self, from: scenarioData)
        let initial = try XCTUnwrap(scenarios.first)
        let run = try XCTUnwrap(env["AUDIO_E2E_RUN"], "Run scripts/audio_e2e.py; a second endpoint is required")
        let role = try XCTUnwrap(env["AUDIO_E2E_ROLE"])
        XCTAssertTrue(["a", "b"].contains(role))
        let groupID = try XCTUnwrap(UUID(uuidString: run))
        let transport = env["AUDIO_E2E_TRANSPORT"] ?? "local"
        let internet: CloudflareRealtimeConfiguration?
        if transport == "webrtc" {
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(env["AUDIO_E2E_WORKER_URL"])))
            internet = .init(workerURL: url, accessToken: run)
            #if os(macOS)
            let room = RTCCredential.derived(groupID: groupID.uuidString, secret: "fixture-only-\(run)").groupHash
            let worker = try AudioE2EWorker(port: UInt16(try XCTUnwrap(url.port)), run: run, room: room)
            try await worker.start()
            addTeardownBlock { await worker.stop() }
            #endif
        } else { internet = nil }
        let suffix = env["AUDIO_E2E_SPEECH_PAIR"] == "japanese" ? "-ja" : ""
        let localFixture = (role == "a" ? "speech" : "reply") + suffix
        let remoteFixture = (role == "a" ? "reply" : "speech") + suffix
        let input = try SpeechFileInput(name: localFixture)
        let remote = try SpeechFileInput(name: remoteFixture)
        let probe = RenderedAudioProbe()
        let outputEngine = AVAudioEngine()
        let output = SystemAudioOutputStreamBackend(engine: outputEngine)
        outputEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in probe.append(buffer) }
        defer { outputEngine.mainMixerNode.removeTap(onBus: 0) }
        let namespace = "RideIntercom.AudioE2E.\(run).\(role)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        let keychain = FixtureKeychain()
        let credentials = KeychainGroupCredentialStore(keychain: keychain, namespace: namespace)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(namespace)
        defer {
            defaults.removePersistentDomain(forName: namespace)
            for ref in (try? credentials.references()) ?? [] { try? credentials.delete(reference: ref) }
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = UserDefaultsAppSettingsStore(defaults: defaults)
        var configuration = AppSettings(enabledRTCTransportRoutes: transport == "webrtc" ? [.webRTC] : [.multipeer])
        configuration.preferredTransmitCodec = AudioCodecIdentifier(rawValue: initial.codec)
        configuration.rtcAudioFormatPreset = try XCTUnwrap(RTCAudioFormatPreset(rawValue: initial.format))
        configuration.audioSessionProfile = try XCTUnwrap(AudioSessionProfile(rawValue: initial.profile))
        settings.save(configuration)
        let callSession: RideIntercomCallSessionAdapter? = internet.map { internet in
            RideIntercomCallSessionAdapter(memberID: "e2e-\(role)-\(run.prefix(8))", internetConfiguration: internet,
                sessionFactory: { policy, routes, configuration in
                    RTC.CallSessionFactory.makeSession(.init(
                        routeConfiguration: .init(enabledRoutes: routes, preferredRoute: .webRTC), audioPolicy: policy,
                        webRTC: .init(cloudflareConfigurationProvider: { _ in configuration },
                                      engineFactory: { makeAudioE2EWebRTCEngine() })))
                })
        }
        let viewModel = IntercomViewModel(
            callSession: callSession,
            groupRepository: GroupRepository(store: FileGroupStore(directory: directory), credentials: credentials),
            appSettingsStore: settings,
            internetSettingsStore: InternetConnectionSettingsStore(keychain: keychain, namespace: namespace),
            localMemberIdentityStore: UserDefaultsLocalMemberIdentityStore(defaults: defaults,
                makeID: { "e2e-\(role)-\(run.prefix(8))" }, defaultDisplayName: { "Audio E2E \(role)" }),
            audioInputCapture: AudioInputStreamCapture(configuration: .intercom(voiceProcessing: IntercomViewModel.defaultVoiceProcessingConfiguration()), backend: input),
            audioOutputRenderer: AudioOutputStreamRenderer(configuration: .intercom, backend: output)
        )
        defer { viewModel.disconnect() }
        viewModel.setSoundIsolationEnabled(initial.transmitIsolation)
        let token = try GroupInviteToken.make(groupID: groupID, groupName: "Audio E2E",
            groupSecret: "fixture-only-\(run)", inviterMemberID: "fixture-owner")
        try viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        let barrier = AudioE2EBarrier(session: viewModel.callSession)

        func status() -> String {
            "state=\(viewModel.connectionState) authenticated=\(viewModel.authenticatedPeerIDs.count) ready=\(viewModel.isAudioReady) tx=\(viewModel.sentVoicePacketCount) rx=\(viewModel.receivedVoicePacketCount) scheduled=\(viewModel.scheduledOutputFrameCount) audioError=\(viewModel.audioErrorMessage ?? "none") input=\(String(describing: viewModel.lastInputStreamOperationReport?.result)) output=\(String(describing: viewModel.lastOutputStreamOperationReport?.result)) session=\(String(describing: viewModel.lastAudioSessionConfigurationReport?.operations))"
        }
        defer {
            let attachment = XCTAttachment(string: status() + "\nmixer=\(viewModel.audioPipeline.snapshot)\nvad=\(viewModel.vadGateRuntimeSnapshot)")
            attachment.name = "endpoint-\(role)-status"; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await waitUntil(seconds: 60, description: "Authenticated peer and active audio", status: status) {
            viewModel.authenticatedPeerIDs.count == 1 && viewModel.isAudioReady
        }
        let peerID = try XCTUnwrap(viewModel.authenticatedPeerIDs.first)
        var continuityFailures: [String] = []
        for scenario in scenarios {
            try await barrier.meet("begin-" + scenario.id)
            try scenario.apply(to: viewModel, peerID: peerID)
            try await waitUntil(seconds: 60, description: "Reconfigured audio " + scenario.id, status: status) {
                viewModel.authenticatedPeerIDs.count == 1 && viewModel.isAudioReady
            }
            try await barrier.meet("configured-" + scenario.id)
            // Drain bounded playback and effect tails before measuring a mute.
            try await Task.sleep(for: .seconds(2))
            scenario.verifyApplied(to: viewModel, peerID: peerID)
            probe.reset()
            let before = (viewModel.sentVoicePacketCount, viewModel.receivedVoicePacketCount,
                          viewModel.scheduledOutputFrameCount, output.playbackResetCount ?? 0)
            let start = ContinuousClock.now
            while start.duration(to: .now) < .seconds(scenario.seconds) {
                XCTAssertTrue(viewModel.isAudioReady, "\(scenario.id): \(status())")
                XCTAssertEqual(viewModel.authenticatedPeerIDs.count, 1, status())
                XCTAssertNil(viewModel.audioErrorMessage, status())
                try await Task.sleep(for: .milliseconds(100))
            }
            let rendered = probe.snapshot()
            let tx = viewModel.sentVoicePacketCount - before.0
            let rx = viewModel.receivedVoicePacketCount - before.1
            let scheduled = viewModel.scheduledOutputFrameCount - before.2
            let playbackResets = (output.playbackResetCount ?? 0) - before.3
            XCTAssertEqual(rendered.invalid, 0)
            XCTAssertGreaterThan(rendered.samples.count, Int(rendered.rate * scenario.seconds * 0.8))
            let remoteSamples = remote.samples, localSamples = input.samples
            // Analysis must not block the app actor and manufacture a keepalive timeout.
            let (match, localMatch, continuity) = await Task.detached {
                (RenderedAudioProbe.speechMatch(reference: remoteSamples, referenceRate: 48_000,
                    output: rendered.samples, outputRate: rendered.rate),
                 RenderedAudioProbe.speechMatch(reference: localSamples, referenceRate: 48_000,
                    output: rendered.samples, outputRate: rendered.rate),
                 SpeechContinuity.measure(reference: remoteSamples, referenceRate: 48_000,
                    output: rendered.samples, outputRate: rendered.rate))
            }.value
            let peak = rendered.samples.reduce(Float(0)) { max($0, abs($1)) }
            XCTAssertLessThanOrEqual(peak, 1.001, "Limiter must bound the actual output")
            let report = viewModel.audioPipeline.codecRuntimeReport
            let measurement: [String: Any] = ["scenario": scenario.id, "role": role, "transport": transport,
                "localFixture": localFixture, "remoteFixture": remoteFixture,
                "continuity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(continuity)),
                "continuityPassed": continuity.passed,
                "outputPlaybackResets": playbackResets,
                "requestedCodec": scenario.codec, "selectedCodec": report.selectedCodec.rawValue,
                "fallback": report.isFallback, "format": scenario.format, "requestedBitRate": scenario.bitRate,
                "selectedBitRate": report.activeConfiguration.activeBitRate as Any? ?? NSNull(),
                "sessionReport": String(describing: viewModel.lastAudioSessionConfigurationReport),
                "voiceProcessingReport": String(describing: viewModel.lastVoiceProcessingOperationReport),
                "mixer": String(describing: viewModel.audioPipeline.snapshot),
                "remoteSpeechCorrelation": match, "localSpeechCorrelation": localMatch,
                "renderedSamples": rendered.samples.count, "sampleRate": rendered.rate,
                "peak": peak, "transmitted": tx, "received": rx, "scheduled": scheduled,
                "expectedSilence": scenario.expectsSilence]
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys]),
                uniformTypeIdentifier: "public.json")
            attachment.name = "endpoint-\(role)-\(scenario.id)-measurement"; attachment.lifetime = .keepAlways; add(attachment)
            let renderedURL = directory.appendingPathComponent("rendered-\(role)-\(scenario.id).wav")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try probe.writeWAV(to: renderedURL, rendered: rendered)
            let recording = XCTAttachment(contentsOfFile: renderedURL)
            recording.name = "endpoint-\(role)-\(scenario.id)-speech"; recording.lifetime = .keepAlways; add(recording)
            if scenario.expectsSilence {
                XCTAssertLessThan(peak, 0.001, "\(scenario.id) must silence the actual render output")
            } else {
                XCTAssertGreaterThan(tx, 20, status())
                XCTAssertGreaterThan(rx, 20, status())
                XCTAssertGreaterThan(scheduled, 20, status())
                XCTAssertGreaterThan(match, 0.45, "Remote speech missing in \(scenario.id): \(status())")
                XCTAssertGreaterThan(match, localMatch + 0.10, "Reject local echo and unrelated audio")
                if !continuity.passed {
                    continuityFailures.append("\(scenario.id): matched=\(continuity.matchedWindowRatio), missing=\(continuity.missingActiveRatio), longest=\(continuity.longestMissingSeconds)s")
                }
            }
            try await barrier.meet("measured-" + scenario.id)
        }
        // Report a normal failed test after collecting every condition. With
        // continueAfterFailure=false, XCTest aborts this async Swift test host
        // and adds an unrelated "runner exited with code 75" failure.
        continueAfterFailure = true
        XCTAssertTrue(continuityFailures.isEmpty, "Speech continuity failed: " + continuityFailures.joined(separator: "; "))
    }

    @MainActor
    private func waitUntil(seconds: Double, description: String, status: () -> String, condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition(), start.duration(to: .now) < .seconds(seconds) { try await Task.sleep(for: .milliseconds(50)) }
        guard condition() else {
            XCTFail("\(description) timed out: \(status())")
            throw NSError(domain: "AudioE2E", code: 1)
        }
    }
}
