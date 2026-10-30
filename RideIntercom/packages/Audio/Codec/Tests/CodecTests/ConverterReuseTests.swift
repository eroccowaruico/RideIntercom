import AVFAudio
import AudioCore
import Testing
@testable import Codec

@Test func converterReuseIsExclusiveBoundedAndResetsPacketState() throws {
    let pool = AudioConverterPool(capacity: 2)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let key = AudioConverterPool.Key(encoding: true, codec: .opus, format: .init(), bitRate: 32000, cookie: nil)
    var created = 0
    func make() -> AVAudioConverter? { created += 1; return AVAudioConverter(from: format, to: format) }
    let first = try #require(pool.take(key: key, make: make))
    let concurrent = try #require(pool.take(key: key, make: make))
    #expect(first !== concurrent, "An active converter cannot be shared by another packet")
    pool.put(first, key: key)
    pool.put(concurrent, key: key)
    for _ in 0..<100 {
        let reused = try #require(pool.take(key: key, make: make))
        #expect(reused === first || reused === concurrent)
        pool.put(reused, key: key)
    }
    #expect(created == 2)
    let third = try #require(make())
    pool.put(third, key: key)
    #expect(pool.cachedCount == 2, "Idle converters have a hard capacity")
}

@Test func repeatedIndependentOpusPacketsKeepDurationAndSilenceIndependent() throws {
    let configuration = CodecEncodingConfiguration(codec: .opus)
    let encoder = CodecEncoder(configuration: configuration)
    let decoder = CodecDecoder()
    for index in 0..<30 {
        let silent = index.isMultiple(of: 2)
        let samples = (0..<960).map { i in silent ? Float(0) : Float(sin(Double(i) * 2 * .pi * 440 / 48000) * 0.4) }
        let frame = PCMFrame(sequenceNumber: UInt64(index), format: .init(), samples: samples)
        let output = try decoder.decode(encoder.encode(frame))
        #expect(output.samples.count == samples.count)
        #expect(output.sequenceNumber == frame.sequenceNumber)
        if silent { #expect(output.samples.allSatisfy { abs($0) < 0.0001 }, "Previous speech must not leak into a new packet") }
        else { #expect(output.samples.contains { abs($0) > 0.1 }) }
    }
}

@Test(arguments: [CodecIdentifier.opus, .mpeg4AACELD], [16000.0, 24000, 48000])
func pausedStreamsReuseTheirDecoderWithoutRetainingOldSpeech(codec: CodecIdentifier, rate: Double) throws {
    let format = AudioFormat(sampleRate: rate, channelCount: 1)
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: codec, format: format))
    let decoder = StreamingCodecDecoder()
    let first = try #require(try encoder.encode(.init(sequenceNumber: 0, format: format,
        capturedAt: 0, samples: Array(repeating: 0.4, count: Int(rate / 10)))))
    _ = try decoder.decode(first)
    // Observe ownership without adding a test-only factory or runtime counter.
    let native = try #require(Mirror(reflecting: decoder).descendant("converter") as? AVAudioConverter)
    let resumed = try #require(try encoder.encode(.init(sequenceNumber: 1, format: format,
        capturedAt: 3, samples: (0..<Int(rate / 10)).map { Float(sin(Double($0) * 0.07) * 0.1) })))
    let output = try decoder.decode(resumed)
    var transition = PCMStreamTransition()
    transition.begin(settlingDuration: 0)
    let independent = transition.process(try StreamingCodecDecoder().decode(resumed))
    #expect((Mirror(reflecting: decoder).descendant("converter") as? AVAudioConverter) === native,
        "A new stream ID after silence must reset native history, not allocate a new decoder")
    #expect(output.capturedAt == independent.capturedAt)
    #expect(output.samples.count == independent.samples.count)
    #expect(zip(output.samples, independent.samples)
        .allSatisfy { abs($0 - $1) < 0.00001 }, "Old speech and decoder history must not survive reset")
}
