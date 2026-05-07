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
    #expect(configuration.aacELDv2Options.bitRate == 24_000)
    #expect(configuration.opusOptions.bitRate == 32_000)
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
    #expect(OpusOptions(bitRate: 1_000).bitRate == 6_000)
    #expect(OpusOptions(bitRate: 256_000).bitRate == 128_000)
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
    let codec = AudioCodec()
    let encoded = try codec.encode(PCMFrame(sequenceNumber: 9, capturedAt: 456, samples: [0.1, -0.1]))
    let decoded = try codec.decode(encoded)

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
