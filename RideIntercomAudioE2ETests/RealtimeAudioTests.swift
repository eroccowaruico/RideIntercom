import AVFAudio
import AudioCore
import Codec
import Foundation
import Synchronization
import RTC
import SessionManager
import XCTest
@testable import RideIntercom

extension AudioE2ETests {
    @MainActor
    func testRealtimeAudioLatencyAndIdentity() async throws {
        let session = AudioSessionManager()
        _ = try session.configure(.init(prefersEchoCancelledInput: true))
        _ = try session.setActive(true)
        defer { _ = try? session.setActive(false) }
        weak var previousPipeline: AppAudioPipeline?
        for fixture in ["speech-ja", "conversation-ja", "conversation-reply-ja"] {
        for codec: RTCAudioCodecIdentifier in [.pcm16, .opus, .mpeg4AACELD] {
            XCTAssertNil(previousPipeline, "The previous case must release its engine before opening another native I/O graph")
            let engine = AVAudioEngine()
            let input = try SpeechFileInput(name: fixture, engine: engine)
            let probe = RenderedAudioProbe()
            try input.updateVoiceProcessing(.init(soundIsolationEnabled: false, otherAudioDuckingEnabled: true))
            let output = SystemAudioOutputStreamBackend(engine: engine)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
                probe.append(buffer, time: time)
            }
            let pipeline = AppAudioPipeline(makeEngine: { engine }, rendersToHardware: true)
            previousPipeline = pipeline
            let transmitted = RenderedAudioProbe(), mixed = RenderedAudioProbe()
            let inputAges = Mutex<[Double]>([]), txAges = Mutex<[Double]>([])
            var mixAges: [Double] = []
            let errorStore = Mutex<[String]>([])
            let delivery = AudioFrameDelivery { _ in }
            defer {
                try? input.stopCapture()
                delivery.finish()
                pipeline.stop()
                engine.mainMixerNode.removeTap(onBus: 0)
                try? output.stopRendering()
            }
            pipeline.onTransmitPacket = { [weak pipeline] packet in
                guard let pipeline else { return }
                do {
                    txAges.withLock { $0.append(ProcessInfo.processInfo.systemUptime - packet.capturedAt) }
                    transmitted.append(try pipeline.processReceivedAudioPacket(.init(peerID: .init(rawValue: "loopback"), packet: packet)), preservingTimeline: true)
                }
                catch { errorStore.withLock { $0.append(String(describing: error)) } }
            }
            pipeline.onOutputFrame = { frame in
                mixed.append(frame)
                mixAges.append(ProcessInfo.processInfo.systemUptime - frame.capturedAt)
            }
            _ = try input.startCapture(configuration: .intercom(voiceProcessing: .init())) { frame in
                inputAges.withLock { $0.append(ProcessInfo.processInfo.systemUptime - frame.capturedAt) }
                pipeline.processMicrophoneFrame(frame)
                delivery.yield(frame)
            }
            // Match startAudioPipelineIfNeeded: input, output, then graph.
            // Starting capture after building the graph stops the shared engine
            // and invalidates players that have already prepared their clocks.
            let hardware = try output.startRendering(configuration: .intercomCall)
            try pipeline.rebuild(configuration: .init(outputHardwareFormat: hardware, preferredCodec: codec,
                transmitSoundIsolationEnabled: true, maximumBufferedDuration: 0.2,
                receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peerIDs: ["loopback"])
            XCTAssertEqual(pipeline.codecRuntimeReport.selectedCodec.rawValue, codec.rawValue)
            XCTAssertFalse(pipeline.codecRuntimeReport.isFallback)
            try await Task.sleep(for: .seconds(1))
            probe.reset(); transmitted.reset(); mixed.reset()
            inputAges.withLock { $0.removeAll() }; txAges.withLock { $0.removeAll() }; mixAges.removeAll()
            try await Task.sleep(for: .seconds(fixture == "speech-ja" ? 8 : 20))
            let errors = errorStore.withLock { $0 }
            let recorded = probe.snapshot()
            let dropped = (capture: input.droppedCaptureFrameCount, delivery: delivery.droppedFrameCount,
                           render: pipeline.droppedRenderFrameCount)
            let playbackResets = output.playbackResetCount ?? 0
            let playout = pipeline.receivePlayoutDiagnostics(peerID: "loopback")
            let nodeLatencies = engine.attachedNodes.map { node in
                ["node": String(describing: type(of: node)), "latency": String(node.latency),
                 "presentation": String(node.outputPresentationLatency)]
            }
            // End capture/render before offline analysis. Otherwise the analysis
            // itself starves the app actor and contaminates the drop counters.
            try input.stopCapture()
            delivery.finish()
            pipeline.stop()
            try output.stopRendering()
            let inputTime = try XCTUnwrap(input.firstCaptureTime)
            let outputTime = try XCTUnwrap(probe.firstOutputTime)
            let continuity = await Task.detached {
                SpeechContinuity.measure(reference: input.samples, referenceRate: 48000,
                    output: recorded.samples, outputRate: recorded.rate)
            }.value
            let replies = fixture.hasPrefix("conversation") ? try ConversationIdentity.measure(fixture: fixture, reference: input.samples,
                output: recorded.samples, outputRate: recorded.rate, referenceOffset: continuity.referenceOffsetSeconds) : nil
            let latency = outputTime - inputTime - continuity.referenceOffsetSeconds
            var stages: [String: Double] = [:]
            var stageContinuities: [String: Any] = [:]
            for (name, stage) in [("transmitted", transmitted), ("mixed", mixed)] {
                let recording = stage.snapshot()
                let match = SpeechContinuity.measure(reference: input.samples, referenceRate: 48000,
                    output: recording.samples, outputRate: recording.rate)
                stageContinuities[name] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(match))
                stages[name] = (stage.firstOutputTime ?? 0) - inputTime - match.referenceOffsetSeconds
            }
            let measurement: [String: Any] = ["scenario": "realtime-\(fixture)-\(codec.rawValue)", "role": "pipeline", "transport": "none",
                "codec": pipeline.codecRuntimeReport.selectedCodec.rawValue, "fixture": fixture,
                "acknowledgements": try replies.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull(),
                "captureTiming": input.captureTiming, "captureDiscontinuities": input.captureDiscontinuities,
                "playoutAdjustments": playout?.adjustments ?? 0, "playoutResets": playout?.resets ?? 0,
                "stageLatencies": stages, "stageContinuities": stageContinuities, "nodeLatencies": nodeLatencies,
                "maximumInputDeliveryAge": inputAges.withLock { $0.max() ?? 0 }, "maximumEncodeDeliveryAge": txAges.withLock { $0.max() ?? 0 },
                "maximumMixerDeliveryAge": mixAges.max() ?? 0,
                "renderLatencySeconds": latency, "outputPresentationLatencySeconds": engine.outputNode.outputPresentationLatency,
                "inputStartHostTime": inputTime, "outputStartHostTime": outputTime,
                "continuity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(continuity)),
                "continuityPassed": continuity.passed && continuity.missingActiveRatio == 0 && (replies?.passed ?? true),
                "renderedSamples": recorded.samples.count, "sampleRate": recorded.rate,
                "processingFailures": errors, "encodingFailures": pipeline.transmitEncodingFailureCount,
                "captureDroppedFrames": dropped.capture,
                "deliveryDroppedFrames": dropped.delivery,
                "renderDroppedFrames": dropped.render,
                "outputPlaybackResets": playbackResets]
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys]),
                uniformTypeIdentifier: "public.json")
            attachment.name = "realtime-\(fixture)-\(codec.rawValue)-measurement"; attachment.lifetime = .keepAlways; add(attachment)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("realtime-\(fixture)-\(codec.rawValue).wav")
            try probe.writeWAV(to: url, rendered: recorded)
            let recording = XCTAttachment(contentsOfFile: url)
            recording.name = "realtime-\(fixture)-\(codec.rawValue)-speech"; recording.lifetime = .keepAlways; add(recording)
            try? FileManager.default.removeItem(at: url)
            XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
            XCTAssertEqual(pipeline.transmitEncodingFailureCount, 0)
            XCTAssertEqual(dropped.capture, 0)
            XCTAssertEqual(dropped.delivery, 0)
            XCTAssertEqual(dropped.render, 0)
            XCTAssertTrue(continuity.passed, "\(fixture): \(continuity)")
            XCTAssertEqual(continuity.missingActiveRatio, 0, "Even sub-percent missing speech is a regression")
            if let replies { XCTAssertTrue(replies.passed, "\(fixture): \(replies)") }
            XCTAssertGreaterThanOrEqual(latency, -0.01)
            XCTAssertLessThanOrEqual(latency + 0.01, 0.125, "Include the 10 ms alignment resolution in the latency budget")
        }
        }
    }
}
