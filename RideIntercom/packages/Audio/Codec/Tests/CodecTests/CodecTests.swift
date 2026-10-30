import AudioCore
import AudioToolbox
import Foundation
import Testing
@testable import Codec

@Test func codecIdentifiersExposeExpectedAudioFormatIDs() {
    #expect(CodecIdentifier.pcm16.audioFormatID == kAudioFormatLinearPCM)
    #expect(CodecIdentifier.mpeg4AACELDv2.audioFormatID == kAudioFormatMPEG4AAC_ELD_V2)
    #expect(CodecIdentifier.opus.audioFormatID == kAudioFormatOpus)
}

@Test func defaultConfigurationUsesAudioCoreVoicePreset() {
    let configuration = CodecEncodingConfiguration()

    #expect(configuration.codec == .pcm16)
    #expect(configuration.format == AudioFormat(sampleRate: 48_000, channelCount: 1))
    #expect(configuration.aacELDv2Options.bitRate == 32_000)
    #expect(configuration.opusOptions.bitRate == 48_000)
}

@Test func runtimeReportKeepsRequestedAndSelectedCodecInformationInPackage() {
    let requested = CodecEncodingConfiguration(codec: .pcm16)

    let report = CodecRuntimeReport.resolving(requested)

    #expect(report.requestedConfiguration == requested)
    #expect(report.activeConfiguration == requested)
    #expect(report.selectedCodec == .pcm16)
    #expect(report.isFallback == false)
    #expect(report.availableCodecs.contains(.pcm16))
}

@Test func codecSpecificOptionsClampBitRates() {
    #expect(AACELDv2Options(bitRate: 1_000).bitRate == 12_000)
    #expect(AACELDv2Options(bitRate: 256_000).bitRate == 128_000)
    #expect(OpusOptions(bitRate: 1_000).bitRate == 48_000)
    #expect(OpusOptions(bitRate: 256_000).bitRate == 128_000)
}

@Test(arguments: [16_000.0, 24_000.0, 48_000.0])
func opusBitRateChangesEncodedAudioRatherThanOnlyPacketMetadata(rate: Double) throws {
    let format = AudioFormat(sampleRate: rate, channelCount: 1)
    let samples = (0..<Int(rate * 0.02)).map { index in
        Float(0.3 * sin(Double(index) * 2 * .pi * 440 / rate)
            + 0.2 * sin(Double(index) * 2 * .pi * 1730 / rate))
    }
    let pcm = PCMFrame(sequenceNumber: 0, format: format, capturedAt: 0, samples: samples)
    func encode(_ bitRate: Int) throws -> EncodedCodecFrame {
        try CodecEncoder(configuration: .init(codec: .opus, format: format,
            opusOptions: .init(bitRate: bitRate))).encode(pcm)
    }
    let low = try encode(48_000), high = try encode(128_000)
    #expect(high.payload.count > low.payload.count)
    #expect(try CodecDecoder().decode(low).samples.count == samples.count)
    #expect(try CodecDecoder().decode(high).samples.count == samples.count)
}

@Test func pcm16EncodingUsesSignedLittleEndianSamples() throws {
    let data = PCM16Codec.encode([-1, -0.5, 0, 0.5, 1])

    #expect(Array(data) == [
        0x00, 0x80,
        0x00, 0xc0,
        0x00, 0x00,
        0x00, 0x40,
        0xff, 0x7f,
    ])

    let decoded = try PCM16Codec.decode(data)
    #expect(decoded[0] == -1)
    #expect(abs(decoded[1] - -0.5) < 0.000_1)
    #expect(decoded[2] == 0)
    #expect(abs(decoded[3] - 0.5) < 0.000_1)
    #expect(decoded[4] == 1)
}

@Test func pcm16EncodingClampsOutOfRangeSamples() throws {
    let decoded = try PCM16Codec.decode(PCM16Codec.encode([-2, 2]))

    #expect(decoded == [-1, 1])
}

@Test func pcm16DecodeRejectsOddByteCounts() {
    do {
        _ = try PCM16Codec.decode(Data([0x00]))
        Issue.record("PCM16 decode must reject odd byte counts")
    } catch {
        #expect(error as? CodecError == .invalidByteCount)
    }
}

@Test func encoderProducesTransportableAudioCorePCMFrames() throws {
    let encoder = CodecEncoder()
    let pcm = PCMFrame(
        sequenceNumber: 42,
        format: AudioFormat(sampleRate: 48_000, channelCount: 1),
        capturedAt: 123,
        samples: [0, 0.25, -0.25]
    )

    let frame = try encoder.encode(pcm)

    #expect(frame.sequenceNumber == 42)
    #expect(frame.codec == .pcm16)
    #expect(frame.format.sampleRate == 48_000)
    #expect(frame.capturedAt == 123)
    #expect(frame.sampleCount == 3)
    #expect(frame.metadata == EncodedAudioMetadata(
        sequenceNumber: 42,
        codec: "pcm16",
        format: pcm.format,
        capturedAt: 123,
        sampleCount: 3
    ))
    #expect(frame.payload == PCM16Codec.encode([0, 0.25, -0.25]))
}

@Test func encoderRejectsMismatchedFormatInsteadOfResampling() {
    let encoder = CodecEncoder(configuration: CodecEncodingConfiguration(format: AudioFormat(sampleRate: 48_000, channelCount: 1)))
    let frame = PCMFrame(
        sequenceNumber: 1,
        format: AudioFormat(sampleRate: 24_000, channelCount: 2),
        capturedAt: 0,
        samples: [0.1, -0.1]
    )

    do {
        _ = try encoder.encode(frame)
        Issue.record("Codec must not resample or channel-mix implicitly")
    } catch {
        #expect(error as? CodecError == .formatMismatch(
            expected: AudioFormat(sampleRate: 48_000, channelCount: 1),
            actual: AudioFormat(sampleRate: 24_000, channelCount: 2)
        ))
    }
}

@Test func decoderSelectsCodecFromFrameMetadata() throws {
    let encoded = try CodecEncoder().encode(PCMFrame(sequenceNumber: 9, capturedAt: 456, samples: [0.1, -0.1]))
    let decoded = try CodecDecoder().decode(encoded)

    #expect(decoded.sequenceNumber == 9)
    #expect(decoded.format == encoded.format)
    #expect(decoded.capturedAt == 456)
    #expect(decoded.samples.count == 2)
    #expect(abs(decoded.samples[0] - 0.1) < 0.000_1)
    #expect(abs(decoded.samples[1] - -0.1) < 0.000_1)
}

@Test func compressedDecoderRejectsNonCodecPayloads() {
    let frame = EncodedCodecFrame(
        sequenceNumber: 1,
        codec: .opus,
        format: AudioFormat(),
        capturedAt: 0,
        sampleCount: 0,
        payload: Data([0xde, 0xad, 0xbe, 0xef])
    )

    do {
        _ = try CodecDecoder().decode(frame)
        Issue.record("Compressed codecs must reject payloads that do not include Codec packet metadata")
    } catch {
        #expect(error as? CodecError == .malformedPayload(.opus))
    }
}

@Test func supportReportsPCMAlwaysAvailable() {
    #expect(CodecSupport.isEncodingAvailable(for: CodecEncodingConfiguration(codec: .pcm16)))
    #expect(CodecSupport.isDecodingAvailable(for: .pcm16))
}

@Test func compressedEnvelopeRejectsInvalidAllocationAndPacketRanges() throws {
    let valid: [String: Any] = ["c": "opus", "s": 960, "f": 960,
        "r": 0,
        "m": 8, "n": 1,
        "p": [[0, 960, 8]],
        "d": Data(repeating: 0, count: 8).base64EncodedString()]
    #expect(try CompressedPayloadEnvelope.decode(JSONSerialization.data(withJSONObject: valid), expectedCodec: .opus).sourceFrameCount == 960)
    let mutations: [[String: Any]] = [
        ["m": 0], ["m": Int.max], ["n": 0],
        ["n": UInt32.max], ["f": UInt32.max], ["s": -1],
        ["r": UInt32.max], ["k": Data(repeating: 0, count: 16_385).base64EncodedString()],
        ["p": [[-1, 960, 8]]],
        ["p": [[4, 960, 8]]],
        ["p": [[0, 960, 8, 1]]],
        ["d": Data(repeating: 0, count: 16).base64EncodedString()]
    ]
    for mutation in mutations {
        let payload = try JSONSerialization.data(withJSONObject: valid.merging(mutation) { _, new in new })
        let frame = EncodedCodecFrame(sequenceNumber: 1, codec: .opus, format: AudioFormat(), capturedAt: 0, sampleCount: 960, payload: payload)
        #expect(throws: CodecError.malformedPayload(.opus)) { try CodecDecoder().decode(frame) }
    }
}

@Test func pcmDecoderAcceptsDataSliceAndEncoderHandlesNonfinitePrimitiveInput() throws {
    let bytes = Data([99, 99, 0, 0, 255, 127]).dropFirst(2)
    #expect(try PCM16Codec.decode(bytes) == [0, 1])
    #expect(try PCM16Codec.decode(PCM16Codec.encode([.nan, .infinity])) == [0, 0])
}

@Test(arguments: CodecIdentifier.allCases, [16_000.0, 24_000.0, 48_000.0])
func advertisedCodecsMustCarryRealTimeAudio(codec: CodecIdentifier, sampleRate: Double) throws {
    let format = AudioFormat(sampleRate: sampleRate, channelCount: 1)
    let count = Int(sampleRate * 0.02)
    let signal = (0..<count).map { Float(sin(Double($0) * 2 * .pi * 440 / sampleRate) * 0.3) }
    let configuration = CodecEncodingConfiguration(codec: codec, format: format)
    let report = CodecRuntimeReport.resolving(configuration)
    // No skipping unsupported codecs: verify the selected fallback also carries
    // actual audio, and never advertise a converter that only instantiates.
    if report.availableCodecs.contains(codec) {
        #expect(report.selectedCodec == codec)
        #expect(CodecSupport.isEncodingAvailable(for: configuration))
    } else {
        #expect(report.selectedCodec == .pcm16)
        #expect(report.isFallback)
        #expect(!CodecSupport.isRoundTripAvailable(for: configuration))
    }
    if codec != .mpeg4AACELDv2 { #expect(report.selectedCodec == codec) }
    let encoded = try CodecEncoder(configuration: report.activeConfiguration).encode(
        PCMFrame(sequenceNumber: 7, format: format, capturedAt: 10, samples: signal))
    #expect(encoded.codec == report.selectedCodec)
    #expect(!encoded.payload.isEmpty)
    #expect(encoded.payload.count < 8_192)
    let decoded = try CodecDecoder().decode(encoded)
    #expect(decoded.samples.count == signal.count)
    #expect(decoded.samples.allSatisfy { $0.isFinite })
    let energy = decoded.samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(count)
    #expect(energy > 0.005, "A successful codec conversion must not return priming silence")
}

@Test(arguments: [16_000.0, 24_000.0, 48_000.0])
func opusRoundTripPreservesSpeechAtTheEndOfEachPacket(sampleRate: Double) throws {
    let format = AudioFormat(sampleRate: sampleRate, channelCount: 1)
    let count = Int(sampleRate * 0.02)
    let tail = Int(sampleRate * 0.003)
    let input = (0..<count).map { index in
        index < count - tail ? Float(0) : Float(sin(Double(index) * 2 * .pi * 1000 / sampleRate) * 0.6)
    }
    let encoded = try CodecEncoder(configuration: .init(codec: .opus, format: format)).encode(
        PCMFrame(sequenceNumber: 0, format: format, samples: input))
    let output = try CodecDecoder().decode(encoded).samples
    #expect(output.count == count)
    #expect(output.suffix(tail).contains { abs($0) > 0.1 },
        "Encoder priming must not replace the end of every speech packet")
}

@Test func opusQualityFloorAppliesToDecodedAndChangedSettings() throws {
    var options = try JSONDecoder().decode(OpusOptions.self, from: Data(#"{"bitRate":16000}"#.utf8))
    #expect(options.bitRate == 48_000)
    options.bitRate = 32_000
    #expect(options.bitRate == 48_000)
    options.bitRate = 64_000
    #expect(options.bitRate == 64_000)
}
