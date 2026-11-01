import AudioCore
import Foundation
import Testing
@testable import Codec

@Test(arguments: [CodecIdentifier.pcm16, .opus], [16_000.0, 24_000.0, 48_000.0])
func portableCodecsKeepIndependentAndStreamingAudio(codec: CodecIdentifier, rate: Double) throws {
    let format = AudioFormat(sampleRate: rate, channelCount: 1)
    let configuration = CodecEncodingConfiguration(codec: codec, format: format)
    let report = CodecRuntimeReport.resolving(configuration)
    #expect(report.selectedCodec == codec)
    #expect(!report.isFallback)
    let encoder = CodecEncoder(configuration: configuration)
    let decoder = CodecDecoder()
    let streamEncoder = try StreamingCodecEncoder(configuration: configuration)
    let streamDecoder = StreamingCodecDecoder()
    let count = Int(rate * 0.02)
    var streamed: [Float] = []
    var nextTimestamp = 0.0
    for index in 0..<12 {
        let frame = PCMFrame(sequenceNumber: UInt64(index), format: format,
            capturedAt: Double(index) * 0.02,
            samples: (0..<count).map { Float(0.2 * sin(Double(index * count + $0) * 2 * .pi * 440 / rate)) })
        let packet = try encoder.encode(frame)
        #expect(packet.codec == codec)
        let decoded = try decoder.decode(packet)
        #expect(decoded.sequenceNumber == frame.sequenceNumber)
        #expect(decoded.format == frame.format)
        #expect(decoded.capturedAt == frame.capturedAt)
        #expect(decoded.samples.count == frame.samples.count)
        #expect(decoded.samples.allSatisfy { $0.isFinite })
        #expect(decoded.samples.contains { abs($0) > 0.05 })

        let streamPacket = try #require(try streamEncoder.encode(frame))
        #expect(streamPacket.codec == codec)
        let streamFrame = try streamDecoder.decode(streamPacket)
        #expect(streamFrame.format == frame.format)
        #expect(abs(streamFrame.capturedAt - nextTimestamp) <= 1 / rate)
        nextTimestamp = streamFrame.capturedAt + Double(streamFrame.frameCount) / rate
        streamed += streamFrame.samples
    }
    #expect(streamed.count >= 12 * count - Int(rate * 0.005))
    #expect(streamed.allSatisfy { $0.isFinite })
    #expect(streamed.contains { abs($0) > 0.05 })
}

@Test(arguments: [16_000.0, 24_000.0, 48_000.0])
func aacCookiePreservesNativeFormatAcrossPacketAndStreamEncoders(rate: Double) throws {
    let format = AudioFormat(sampleRate: rate, channelCount: 1)
    let configuration = CodecEncodingConfiguration(codec: .mpeg4AACELD, format: format)
    let frame = PCMFrame(sequenceNumber: 4, format: format, capturedAt: 1,
        samples: (0..<Int(rate * 0.06)).map { Float(0.2 * sin(Double($0) * 2 * .pi * 440 / rate)) })
    let independent = try CodecEncoder(configuration: configuration).encode(frame)
    let streaming = try #require(try StreamingCodecEncoder(configuration: configuration).encode(frame))
    for (packet, expectedFrames) in [(independent, UInt32(512)), (streaming, UInt32(480))] {
        var envelope = try CompressedPayloadEnvelope.decode(packet.payload, expectedCodec: .mpeg4AACELD)
        let cookie = try #require(envelope.magicCookie)
        #expect(!cookie.isEmpty)
        let native = try #require(AudioConverterBridge.makeDecodeFormat(codec: .mpeg4AACELD,
            format: format, cookie: cookie))
        #expect(native.streamDescription.pointee.mFramesPerPacket == expectedFrames)
        envelope.magicCookie = Data([0xff, 0x00, 0x01])
        var damaged = packet
        damaged.payload = try envelope.encoded()
        #expect(throws: CodecError.self) { _ = try StreamingCodecDecoder().decode(damaged) }
    }
    let independentPCM = try CodecDecoder().decode(independent)
    let streamingPCM = try StreamingCodecDecoder().decode(streaming)
    #expect(independentPCM.samples.contains { abs($0) > 0.05 })
    #expect(streamingPCM.samples.contains { abs($0) > 0.05 })
}
