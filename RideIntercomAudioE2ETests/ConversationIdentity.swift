import Foundation
import XCTest

/// Each short reply is checked at the ONE whole-recording alignment. A good
/// long sentence cannot compensate for a missing or repeated acknowledgement.
struct ConversationIdentity: Codable, Sendable {
    struct Reply: Codable, Sendable {
        let text: String
        let outputSeconds: Double
        let correlation: Float
    }
    let replies: [Reply]
    var passed: Bool {
        Set(replies.map(\.text)) == ["うん", "ふん"] && replies.allSatisfy { $0.correlation >= 0.65 }
    }

    private struct Manifest: Decodable {
        struct Fixture: Decodable {
            struct Utterance: Decodable { let text: String; let startSeconds: Double; let endSeconds: Double }
            let name: String
            let utterances: [Utterance]
        }
        let fixtures: [Fixture]
    }

    static func measure(fixture: String, reference: [Float], output: [Float], outputRate: Double,
                        referenceOffset: Double) throws -> Self {
        let url = try XCTUnwrap(Bundle(for: AudioE2ETests.self).url(forResource: "conversation-manifest", withExtension: "json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        let utterances = try XCTUnwrap(manifest.fixtures.first { $0.name == fixture }).utterances
        let period = Double(reference.count) / 48000
        let duration = Double(output.count) / outputRate
        var replies: [Reply] = []
        for utterance in utterances where ["うん", "ふん"].contains(utterance.text) {
            let start = utterance.startSeconds - 0.04, end = utterance.endSeconds + 0.04
            let expected = RenderedAudioProbe.features(Array(reference[Int(start * 48000)..<Int(end * 48000)]), rate: 48000)
            for cycle in -1...Int(ceil(duration / period) + 2) {
                let time = start - referenceOffset + Double(cycle) * period
                guard time >= 0, time + end - start <= duration else { continue }
                let actual = RenderedAudioProbe.features(Array(output[Int(time * outputRate)..<Int((time + end - start) * outputRate)]), rate: outputRate)
                var dot: Float = 0, a: Float = 0, b: Float = 0
                for (left, right) in zip(expected, actual) {
                    for (x, y) in zip(left, right) { dot += x * y; a += x * x; b += y * y }
                }
                replies.append(.init(text: utterance.text, outputSeconds: time + 0.04,
                    correlation: a * b > 1e-8 ? dot / sqrt(a * b) : 0))
            }
        }
        return Self(replies: replies)
    }
}

extension AudioE2ETests {
    func testConversationOracleRejectsMissingAcknowledgements() throws {
        let reference = try SpeechFileInput(name: "conversation-ja").samples
        let clean = try ConversationIdentity.measure(fixture: "conversation-ja", reference: reference,
            output: reference, outputRate: 48000, referenceOffset: 0)
        XCTAssertTrue(clean.passed)
        for range in [6.744958333333333..<6.9925625, 8.9925625..<9.26125] {
            var broken = reference
            for index in Int(range.lowerBound * 48000)..<Int(range.upperBound * 48000) { broken[index] = 0 }
            XCTAssertFalse(try ConversationIdentity.measure(fixture: "conversation-ja", reference: reference,
                output: broken, outputRate: 48000, referenceOffset: 0).passed)
        }
    }
}
