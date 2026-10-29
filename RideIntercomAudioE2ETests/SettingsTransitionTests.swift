import AVFAudio
import AudioCore
import Foundation
import Synchronization
import RTC
import SessionManager
import XCTest
@testable import RideIntercom

extension AudioE2ETests {
    @MainActor
    func testInputModeChangesRestoreTheSharedReceiveClock() async throws {
        let session = AudioSessionManager()
        _ = try session.configure(.init(prefersEchoCancelledInput: true))
        _ = try session.setActive(true)
        defer { _ = try? session.setActive(false) }
        let engine = AVAudioEngine(), probe = RenderedAudioProbe()
        let input = SpeechFileInput(samples: (0..<48000).map { Float(0.15 * sin(Double($0) * 2 * .pi * 600 / 48000)) }, engine: engine)
        let processing = AudioInputVoiceProcessingConfiguration(soundIsolationEnabled: false, otherAudioDuckingEnabled: true)
        try input.updateVoiceProcessing(processing)
        let capture = AudioInputStreamCapture(configuration: .intercom(voiceProcessing: processing), backend: input)
        let output = SystemAudioOutputStreamBackend(engine: engine)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { probe.append($0, time: $1) }
        let hardware = try output.startRendering(configuration: .intercomCall)
        let pipeline = AppAudioPipeline(makeEngine: { engine }, rendersToHardware: true)
        let failures = Mutex<[String]>([])
        defer {
            capture.stop(); pipeline.stop()
            pipeline.onTransmitPacket = nil
            engine.mainMixerNode.removeTap(onBus: 0); try? output.stopRendering()
        }
        pipeline.onTransmitPacket = { [weak pipeline] packet in
            guard let pipeline else { return }
            do { _ = try pipeline.processReceivedAudioPacket(.init(peerID: .init(rawValue: "peer"), packet: packet)) }
            catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        try pipeline.rebuild(configuration: .init(outputHardwareFormat: hardware, preferredCodec: .pcm16,
            transmitSoundIsolationEnabled: false, receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peerIDs: ["peer"])
        capture.setRuntimeEventHandler { event in
            guard case .inputFrame(let frame) = event else { return }
            do { try pipeline.processCapturedFrame(frame) }
            catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        XCTAssertEqual(capture.start().result, .applied)
        try await Task.sleep(for: .seconds(1))
        var rows: [[String: Any]] = []
        for enabled in [false, true, false, true] {
            let start = ProcessInfo.processInfo.systemUptime
            let report = pipeline.reconfigureInput {
                capture.updateVoiceProcessing(.init(soundIsolationEnabled: false, otherAudioDuckingEnabled: enabled))
            }
            let duration = ProcessInfo.processInfo.systemUptime - start
            XCTAssertEqual(report.result, .applied)
            XCTAssertLessThan(duration, 0.5, "Native I/O reconfiguration is bounded; never wait for queued speech")
            try await Task.sleep(for: .milliseconds(300))
            probe.reset()
            try await Task.sleep(for: .seconds(1))
            let recorded = probe.snapshot()
            let tone = ToneIntegrity.measure(samples: recorded.samples, rate: recorded.rate, frequencies: [600])
            XCTAssertTrue(tone.passed, "Shared input/output mode \(enabled): \(tone.dictionary)")
            rows.append(["voiceProcessing": enabled, "changeDurationSeconds": duration, "steady": tone.dictionary])
        }
        XCTAssertTrue(failures.withLock { $0.isEmpty })
        let data = try JSONSerialization.data(withJSONObject: ["scenario": "input-mode-recovery", "role": "pipeline",
            "transport": "none", "stages": rows])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "input-mode-recovery-measurement"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testLiveSettingsKeepBoundedSilenceAndContinuousSteadyAudio() async throws {
        let session = AudioSessionManager()
        _ = try session.configure(.init(prefersEchoCancelledInput: true))
        _ = try session.setActive(true)
        defer { _ = try? session.setActive(false) }
        let probe = RenderedAudioProbe(), engine = AVAudioEngine()
        let decodedProbe = RenderedAudioProbe(), mixedProbe = RenderedAudioProbe()
        let input = SpeechFileInput(samples: (0..<48000).map { Float(0.15 * sin(Double($0) * 2 * .pi * 600 / 48000)) }, engine: engine)
        try input.updateVoiceProcessing(.init(soundIsolationEnabled: false, otherAudioDuckingEnabled: true))
        let output = SystemAudioOutputStreamBackend(engine: engine)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in probe.append(buffer, time: time) }
        let hardware = try output.startRendering(configuration: .intercomCall)
        let pipeline = AppAudioPipeline(makeEngine: { engine }, rendersToHardware: true)
        let failureStore = Mutex<[String]>([])
        let rejectedReceives = Mutex<[(start: Double, end: Double)]>([])
        let delivery = AudioFrameDelivery { _ in }
        defer {
            try? input.stopCapture(); delivery.finish(); pipeline.stop()
            pipeline.onTransmitPacket = nil
            engine.mainMixerNode.removeTap(onBus: 0); try? output.stopRendering()
        }
        pipeline.onTransmitPacket = { [weak pipeline] packet in
            guard let pipeline else { return }
            let start = ProcessInfo.processInfo.systemUptime
            do { decodedProbe.append(try pipeline.processReceivedAudioPacket(.init(peerID: .init(rawValue: "peer"), packet: packet))) }
            catch AppAudioPipelineError.notConfigured {
                rejectedReceives.withLock { $0.append((start, ProcessInfo.processInfo.systemUptime)) }
            }
            catch { failureStore.withLock { $0.append(String(describing: error)) } }
        }
        pipeline.onOutputFrame = { mixedProbe.append($0) }
        try pipeline.rebuild(configuration: .init(outputHardwareFormat: hardware, preferredCodec: .pcm16,
            transmitSoundIsolationEnabled: false, maximumBufferedDuration: 0.2,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peerIDs: ["peer"])
        _ = try input.startCapture(configuration: .intercom(voiceProcessing: .init())) { frame in
            do { try pipeline.processCapturedFrame(frame) }
            catch { failureStore.withLock { $0.append(String(describing: error)) } }
            delivery.yield(frame)
        }
        try await Task.sleep(for: .seconds(1))
        probe.reset(); decodedProbe.reset(); mixedProbe.reset()
        let stages = ["PCM", "isolation-on", "Opus", "AAC-48k", "AAC-16k", "AAC-24k", "AAC-48k-high", "isolation-off",
                      "receive-master-on", "receive-master-off", "receive-peer-on", "receive-peer-off"]
        var boundaries: [Int] = []
        var changeHostTimes: [Double] = [], changeDurations: [Double] = []
        for (index, _) in stages.enumerated() {
            boundaries.append(probe.sampleCount)
            let changeStart = ProcessInfo.processInfo.systemUptime
            changeHostTimes.append(changeStart)
            switch index {
            case 1: try pipeline.updateSoundIsolation(transmit: true, receiveMaster: false, peers: [:])
            case 2: pipeline.updateCodec(preferred: .opus, aacELDv2BitRate: 64000, opusBitRate: 32000)
            case 3: pipeline.updateCodec(preferred: .mpeg4AACELD, aacELDv2BitRate: 64000, opusBitRate: 32000)
            case 4:
                try pipeline.updateTransmitFormat(.init(sampleRate: 16000, channelCount: 1))
                pipeline.updateCodec(preferred: .mpeg4AACELD, aacELDv2BitRate: 48000, opusBitRate: 32000)
            case 5:
                try pipeline.updateTransmitFormat(.init(sampleRate: 24000, channelCount: 1))
                pipeline.updateCodec(preferred: .mpeg4AACELD, aacELDv2BitRate: 32000, opusBitRate: 32000)
            case 6:
                try pipeline.updateTransmitFormat(.init())
                pipeline.updateCodec(preferred: .mpeg4AACELD, aacELDv2BitRate: 64000, opusBitRate: 32000)
            case 7: try pipeline.updateSoundIsolation(transmit: false, receiveMaster: false, peers: [:])
            case 8: try pipeline.updateSoundIsolation(transmit: false, receiveMaster: true, peers: [:])
            case 9: try pipeline.updateSoundIsolation(transmit: false, receiveMaster: false, peers: [:])
            case 10: try pipeline.updateSoundIsolation(transmit: false, receiveMaster: false, peers: ["peer": true])
            case 11: try pipeline.updateSoundIsolation(transmit: false, receiveMaster: false, peers: [:])
            default: break
            }
            changeDurations.append(ProcessInfo.processInfo.systemUptime - changeStart)
            try await Task.sleep(for: .seconds(2))
        }
        let failures = failureStore.withLock { $0 }
        let rejected = rejectedReceives.withLock { $0 }
        let recorded = probe.snapshot()
        let drops = input.droppedCaptureFrameCount + delivery.droppedFrameCount + pipeline.droppedRenderFrameCount
        let resets = output.playbackResetCount ?? 0
        let encodingFailures = pipeline.transmitEncodingFailureCount
        try input.stopCapture(); delivery.finish(); pipeline.stop(); try output.stopRendering()
        boundaries.append(recorded.samples.count)
        var rows: [[String: Any]] = []
        for (index, name) in stages.enumerated() {
            let start = boundaries[index], end = boundaries[index + 1]
            let stableStart = min(end, start + Int(recorded.rate * 0.3))
            let stable = Array(recorded.samples[stableStart..<end])
            let tone = ToneIntegrity.measure(samples: stable, rate: recorded.rate, frequencies: [600])
            let all = Array(recorded.samples[start..<end])
            let step = zip(all, all.dropFirst()).map { abs($0 - $1) }.max() ?? 1
            let width = Int(recorded.rate / 1000)
            var silence = 0, maximumSilence = 0
            for offset in stride(from: 0, through: max(0, all.count - width), by: width) {
                let rms = sqrt(all[offset..<(offset + width)].reduce(Float(0)) { $0 + $1 * $1 } / Float(width))
                silence = rms < 0.0001 ? silence + 1 : 0
                maximumSilence = max(maximumSilence, silence)
            }
            rows.append(["stage": name, "startSample": start, "endSample": end,
                "changeHostTime": changeHostTimes[index], "changeDurationSeconds": changeDurations[index],
                "steady": tone.dictionary, "maximumSampleStep": step, "maximumSilenceMilliseconds": maximumSilence])
            XCTAssertTrue(tone.passed, "\(name): \(tone.dictionary)")
            XCTAssertLessThan(step, 0.04, "No click across \(name)")
            XCTAssertLessThanOrEqual(maximumSilence, 120, "Only a bounded native reconfiguration interval may be silent")
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
        // Production deliberately rejects packets during RX graph mutations.
        // Only an attempt overlapping the actual mutation may be discarded;
        // no settling allowance or steady-state exception is added here.
        for attempt in rejected {
            XCTAssertTrue((8..<stages.count).contains { index in
                attempt.start <= changeHostTimes[index] + changeDurations[index]
                    && attempt.end >= changeHostTimes[index]
            }, "Unexpected receive rejection outside an RX graph change: \(attempt)")
        }
        XCTAssertEqual(drops, 0); XCTAssertEqual(resets, 0); XCTAssertEqual(encodingFailures, 0)
        let measurement: [String: Any] = ["scenario": "live-settings", "role": "pipeline", "transport": "none",
            "stages": rows, "firstOutputHostTime": probe.firstOutputTime ?? 0,
            "captureTiming": input.captureTiming, "captureDiscontinuities": input.captureDiscontinuities,
            "droppedFrames": drops, "outputResets": resets, "processingFailures": failures,
            "receiveRejections": rejected.map { ["start": $0.start, "end": $0.end] }]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurement), uniformTypeIdentifier: "public.json")
        attachment.name = "live-settings-measurement"; attachment.lifetime = .keepAlways; add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-settings.wav")
        try probe.writeWAV(to: url, rendered: recorded)
        let audio = XCTAttachment(contentsOfFile: url); audio.name = "live-settings"; audio.lifetime = .keepAlways; add(audio)
        try? FileManager.default.removeItem(at: url)
        for (name, stage) in [("decoded", decodedProbe), ("mixed", mixedProbe)] {
            let stageURL = FileManager.default.temporaryDirectory.appendingPathComponent("live-settings-\(name).wav")
            try stage.writeWAV(to: stageURL, rendered: stage.snapshot())
            let attachment = XCTAttachment(contentsOfFile: stageURL)
            attachment.name = "live-settings-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
            try? FileManager.default.removeItem(at: stageURL)
        }
    }
}
