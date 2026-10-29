import AudioCore
import Codec
import Foundation
import Synchronization
import RTC
import XCTest
@testable import RideIntercom

extension AudioE2ETests {
    /// Separate the sender's VAD/DSP/codec from network and playback scheduling.
    @MainActor
    func testTransmitChainPreservesConversationAndAcknowledgements() throws {
        var rows: [[String: Any]] = []
        for fixture in ["conversation-ja", "conversation-reply-ja"] {
            let reference = try SpeechFileInput(name: fixture).samples
            for quantum in [256, 960] {
                for isolation in [false, true] {
                    for codec: RTCAudioCodecIdentifier in [.pcm16, .opus, .mpeg4AACELD] {
                        let name = "transmit-\(fixture)-\(quantum)-\(isolation)-\(codec.rawValue)"
                        let pipeline = AppAudioPipeline()
                        let decoder = Mutex(StreamingCodecDecoder())
                        let probe = RenderedAudioProbe()
                        let failureStore = Mutex<[String]>([])
                        let sent = Mutex((packets: 0, bytes: 0))
                        pipeline.onTransmitPacket = { packet in
                            sent.withLock { $0.packets += 1; $0.bytes += packet.payload.count }
                            do { probe.append(try decoder.withLock { try AppAudioCodecBridge.decode(packet, using: $0) }, preservingTimeline: true) }
                            catch { failureStore.withLock { $0.append(String(describing: error)) } }
                        }
                        try pipeline.rebuild(configuration: .init(preferredCodec: codec,
                            transmitSoundIsolationEnabled: isolation), peerIDs: [])
                        // Two cycles include established native history and all long pauses.
                        for offset in stride(from: 0, to: reference.count * 2, by: quantum) {
                            let count = min(quantum, reference.count * 2 - offset)
                            let frame = PCMFrame(sequenceNumber: UInt64(offset / quantum),
                                capturedAt: Double(offset) / 48000,
                                samples: (0..<count).map { reference[(offset + $0) % reference.count] })
                            pipeline.processMicrophoneFrame(frame)

                        }
                        pipeline.stop()
                        let failures = failureStore.withLock { $0 }
                        let output = probe.snapshot()
                        let match = SpeechContinuity.measure(reference: reference, referenceRate: 48000,
                            output: output.samples, outputRate: output.rate)
                        let replies = try ConversationIdentity.measure(fixture: fixture, reference: reference,
                            output: output.samples, outputRate: output.rate, referenceOffset: match.referenceOffsetSeconds)
                        let budget = sent.withLock { $0 }
                        let passed = match.passed && match.missingActiveRatio == 0 && replies.passed && failures.isEmpty && output.invalid == 0
                        rows.append(["case": name, "continuity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(match)),
                            "acknowledgements": try JSONSerialization.jsonObject(with: JSONEncoder().encode(replies)),
                            "sentPackets": budget.packets, "codecPayloadBytes": budget.bytes, "passed": passed])
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".wav")
                        try probe.writeWAV(to: url, rendered: output)
                        let recording = XCTAttachment(contentsOfFile: url)
                        recording.name = name; recording.lifetime = .keepAlways; add(recording)
                        try? FileManager.default.removeItem(at: url)
                        XCTAssertTrue(failures.isEmpty, "\(name): \(failures)")
                        XCTAssertEqual(output.invalid, 0, name)
                        XCTAssertTrue(match.passed, "\(name): \(match)")
                        XCTAssertEqual(match.missingActiveRatio, 0, name)
                        XCTAssertTrue(replies.passed, "\(name): \(replies)")
                    }
                }
            }
        }
        let measurement: [String: Any] = ["scenario": "transmit-conversations", "role": "pipeline", "transport": "none",
            "cases": rows, "continuityPassed": rows.allSatisfy { $0["passed"] as? Bool == true }]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurement), uniformTypeIdentifier: "public.json")
        attachment.name = "transmit-conversations-measurement"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
