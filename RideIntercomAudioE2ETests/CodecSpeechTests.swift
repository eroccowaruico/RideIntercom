import AudioCore
import AudioMixer
import Codec
import Foundation
import XCTest
@testable import RideIntercom

extension AudioE2ETests {
    /// Isolate native codec quality from VAD, Audio Units, scheduling and RTC.
    @MainActor
    func testNativeCodecsPreserveWholeSpeech() throws {
        var rows: [[String: Any]] = []
        for fixture in ["speech-ja", "speech", "conversation-ja", "conversation-reply-ja"] {
        let reference = try SpeechFileInput(name: fixture).samples
        var settings: [(CodecIdentifier, Double, Int)] = []
        for rate in [16000.0, 24000, 48000] {
            let format = AudioFormat(sampleRate: rate, channelCount: 1)
            settings.append((.pcm16, rate, 32000))
            for bitRate in [AppAudioCodecBridge.minimumOpusBitRate(format: format), 32000, 128000] {
                settings.append((.opus, rate, bitRate))
            }
            for bitRate in AppAudioCodecBridge.availableAACBitRates(format: format) {
                settings.append((.mpeg4AACELD, rate, bitRate))
            }
        }
        for (codec, rate, bitRate) in settings {
            let encoder = try StreamingCodecEncoder(configuration: .init(codec: codec, format: .init(sampleRate: rate, channelCount: 1),
                aacELDv2Options: .init(bitRate: bitRate), opusOptions: .init(bitRate: bitRate)))
            let decoder = StreamingCodecDecoder()
            let probe = RenderedAudioProbe()
            var failures: [String] = []
            let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init(sampleRate: rate, channelCount: 1)) { input, _ in
                do { if let packet = try encoder.encode(input) { probe.append(try decoder.decode(packet)) } }
                catch { failures.append(String(describing: error)) }
            }
            try processor.start()
            defer { processor.stop() }
            for offset in stride(from: 0, to: reference.count, by: 480) {
                let samples = Array(reference[offset..<min(reference.count,offset+480)])
                let input = PCMFrame(sequenceNumber: UInt64(offset / 480), capturedAt: Double(offset) / 48000, samples: samples)
                try processor.process(input)
            }
            XCTAssertTrue(failures.isEmpty)
            let output = probe.snapshot()
            let match = SpeechContinuity.measure(reference: reference, referenceRate: 48000, output: output.samples, outputRate: output.rate)
            let name = "native-\(fixture)-\(codec.rawValue)-\(Int(rate))-\(bitRate)"
            print("CODEC_SPEECH",name,match.alignmentCorrelation,match.matchedWindowRatio,match.missingActiveRatio)
            rows.append(["case": name, "matchedWindowRatio": match.matchedWindowRatio,
                "missingActiveRatio": match.missingActiveRatio, "passed": match.passed && match.missingActiveRatio == 0])
            let data = XCTAttachment(data: try JSONEncoder().encode(match), uniformTypeIdentifier: "public.json")
            data.name = name + "-continuity"; data.lifetime = .keepAlways; add(data)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".wav")
            try probe.writeWAV(to:url,rendered:output)
            let audio = XCTAttachment(contentsOfFile:url); audio.name=name;audio.lifetime = .keepAlways;add(audio)
            try? FileManager.default.removeItem(at:url)
            XCTAssertTrue(match.passed,name)
            XCTAssertEqual(match.missingActiveRatio,0,name)
            if fixture.hasPrefix("conversation") {
                let replies = try ConversationIdentity.measure(fixture: fixture, reference: reference,
                    output: output.samples, outputRate: output.rate, referenceOffset: match.referenceOffsetSeconds)
                XCTAssertTrue(replies.passed, "\(name): \(replies)")
            }
        }
        }
        let measurement: [String: Any] = ["scenario": "native-codecs", "role": "pipeline", "transport": "none",
            "cases": rows, "continuityPassed": rows.allSatisfy { $0["passed"] as? Bool == true }]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurement), uniformTypeIdentifier: "public.json")
        attachment.name = "native-codecs-measurement"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
