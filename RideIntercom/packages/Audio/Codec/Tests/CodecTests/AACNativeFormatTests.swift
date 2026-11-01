import AudioCore
import AVFAudio
import CoreAudioTypes
#if canImport(AudioToolbox)
import AudioToolbox
#endif
import Foundation
import Testing
@testable import Codec

@Test(arguments: [16_000.0, 24_000.0, 48_000.0])
func nativeELDv2ExposesCookieBeforeItsFirstAudio(rate: Double) throws {
    let format = AudioFormat(sampleRate: rate, channelCount: 2)
    let pcm = try #require(AudioConverterBridge.makePCMFormat(format))
    let compressed = try #require(AudioConverterBridge.makeCompressedFormat(codec: .mpeg4AACELDv2, format: format, bitRate: 64000))
    let converter = try #require(AVAudioConverter(from: pcm, to: compressed))
    converter.bitRate = 64000
    let cookie = try #require(converter.magicCookie)
    let native = try #require(AudioConverterBridge.makeDecodeFormat(codec: .mpeg4AACELDv2, format: format, cookie: cookie))
    let description = withExtendedLifetime(native) { native.streamDescription.pointee }
    #expect(description.mFramesPerPacket > 0)
}

@Test(arguments: [16_000.0, 24_000.0, 48_000.0])
func nativeELDv2StreamKeepsPCMFrameCountsAndClockAfterAPause(rate: Double) throws {
    let format = AudioFormat(sampleRate: rate, channelCount: 2)
    let configuration = CodecEncodingConfiguration(codec: .mpeg4AACELDv2, format: format,
        aacELDv2Options: .init(bitRate: 64_000))
    let encoder = try StreamingCodecEncoder(configuration: configuration)
    let decoder = StreamingCodecDecoder()
    let count = Int(rate / 50)
    let nativePCMFrames = rate == 48_000 ? 1024 : 512
    for start in [0.0, 3.0] {
        var nextTimestamp = start
        var outputFrames = 0
        var audible = false
        for index in 0..<20 {
            let frame = PCMFrame(sequenceNumber: UInt64(index), format: format,
                capturedAt: start + Double(index) / 50,
                samples: (0..<(count * 2)).map {
                    Float(0.2 * sin(Double(index * count + $0 / 2) * 2 * .pi * 440 / rate))
                })
            guard var packet = try encoder.encode(frame) else { continue }
            var envelope = try CompressedPayloadEnvelope.decode(packet.payload, expectedCodec: .mpeg4AACELDv2)
            #expect(envelope.sourceFrameCount == envelope.packetCount * UInt32(nativePCMFrames))
            let decoded = try decoder.decode(packet)
            #expect(decoded.format == format)
            #expect(decoded.samples.allSatisfy { $0.isFinite })
            #expect(abs(decoded.capturedAt - nextTimestamp) <= 1 / rate)
            #expect(decoded.samples.count == packet.sampleCount)
            outputFrames += decoded.frameCount
            nextTimestamp = decoded.capturedAt + Double(decoded.frameCount) / rate
            audible = audible || decoded.samples.contains { abs($0) > 0.05 }
            envelope.packetizationJitterFrames = 1025
            packet.payload = try envelope.encoded()
            #expect(throws: CodecError.self) { _ = try StreamingCodecDecoder().decode(packet) }
        }
        #expect(audible)
        #expect(outputFrames <= 20 * count)
        #expect(outputFrames >= 20 * count - nativePCMFrames)
    }
}

#if canImport(AudioToolbox)
@Test(arguments: [CodecIdentifier.mpeg4AACELD, .mpeg4AACELDv2],
      [16_000.0, 24_000.0, 48_000.0].flatMap { rate in [1, 2].map { (rate, $0) } })
func nativeAACFormatMatchesLegacyDecodedSamples(codec: CodecIdentifier, setting: (Double, Int)) throws {
    let (rate, channels) = setting
    let format = AudioFormat(sampleRate: rate, channelCount: channels)
    let configuration = CodecEncodingConfiguration(codec: codec, format: format,
        aacELDv2Options: .init(bitRate: channels == 1 ? 32_000 : 64_000))
    let samples = (0..<(Int(rate * 0.06) * channels)).map {
        Float(0.2 * sin(Double($0 / channels) * 2 * .pi * 440 / rate))
    }
    let frame = PCMFrame(sequenceNumber: 0, format: format, capturedAt: 0, samples: samples)
    guard CodecSupport.isEncodingAvailable(for: configuration) else {
        #expect(!CodecRuntimeReport.resolving(configuration).availableCodecs.contains(codec))
        #expect(throws: CodecError.self) { try CodecEncoder(configuration: configuration).encode(frame) }
        return
    }
    let independent = try CodecEncoder(configuration: configuration).encode(frame)
    let packets = [independent, try #require(try StreamingCodecEncoder(configuration: configuration).encode(frame))]
    for packet in packets {
        let reference = try decodeAACRaw(packet, parseFormat: true)
        let candidate = try decodeAACRaw(packet, parseFormat: false)
        #expect(candidate.count == reference.count)
        #expect(candidate.contains { abs($0) > 0.05 })
        let maximumError = zip(candidate, reference).map { abs($0 - $1) }.max() ?? .infinity
        #expect(maximumError < 0.000_001)
    }
}

private func decodeAACRaw(_ packet: EncodedCodecFrame, parseFormat: Bool) throws -> [Float] {
    let envelope = try CompressedPayloadEnvelope.decode(packet.payload, expectedCodec: packet.codec)
    let cookie = try #require(envelope.magicCookie)
    let compressed: AVAudioFormat
    if parseFormat {
        var description = AudioStreamBasicDescription()
        description.mFormatID = packet.codec.audioFormatID
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = cookie.withUnsafeBytes {
            AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32(cookie.count), $0.baseAddress, &size, &description)
        }
        #expect(status == noErr)
        compressed = try #require(AVAudioFormat(streamDescription: &description))
    } else {
        compressed = try #require(AudioConverterBridge.makeDecodeFormat(codec: packet.codec, format: packet.format, cookie: cookie))
    }
    compressed.magicCookie = cookie
    let pcm = try #require(AudioConverterBridge.makePCMFormat(packet.format))
    let converter = try #require(AVAudioConverter(from: compressed, to: pcm))
    converter.magicCookie = cookie
    converter.primeMethod = .none
    let input = AVAudioCompressedBuffer(format: compressed, packetCapacity: envelope.packetCount,
        maximumPacketSize: envelope.maximumPacketSize)
    input.packetCount = envelope.packetCount
    input.byteLength = UInt32(envelope.data.count)
    envelope.data.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    for (index, description) in envelope.packetDescriptions.enumerated() {
        input.packetDescriptions?[index] = description.audioStreamPacketDescription
    }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: pcm,
        frameCapacity: envelope.sourceFrameCount + 8192))
    let provider = AudioBufferProvider(input)
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { count, state in provider.provide(count, state) }
    #expect(status != .error, "\(error?.localizedDescription ?? "")")
    return try AudioConverterBridge.samples(from: output, format: packet.format, sampleLimit: Int(output.frameLength) * packet.format.channelCount)
}
#endif
