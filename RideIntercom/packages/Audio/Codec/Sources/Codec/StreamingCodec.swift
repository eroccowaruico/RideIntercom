import AudioCore
import AVFAudio
import Foundation

/// One encoder per uninterrupted sender stream. Native codec history and
/// partial packets survive each input quantum; no per-packet EOS/reset.
public final class StreamingCodecEncoder {
    public let configuration: CodecEncodingConfiguration
    private let converter: AVAudioConverter?
    private let pcmFormat: AVAudioFormat
    private let compressedFormat: AVAudioFormat
    private var streamID = UUID()
    private var capturedStart: TimeInterval?
    private var inputEnd: TimeInterval?
    private var emittedFrames = 0

    public init(configuration: CodecEncodingConfiguration) throws {
        self.configuration = configuration
        guard let pcm = AudioConverterBridge.makePCMFormat(configuration.format),
              let initial = AudioConverterBridge.makeCompressedFormat(codec: configuration.codec,
                format: configuration.format, bitRate: configuration.activeBitRate) else {
            throw CodecError.invalidFormat(configuration.format)
        }
        var compressed = initial
        if configuration.codec == .opus || configuration.codec == .mpeg4AACELD {
            var description = withExtendedLifetime(initial) { initial.streamDescription.pointee }
            // Opus supports 10 ms frames. AAC-ELD supports 480-sample frames
            // (10 ms at 48 kHz); its default is 512. Request the native frame
            // size explicitly instead of waiting for the 20 ms Opus default.
            description.mFramesPerPacket = configuration.codec == .opus
                ? UInt32(configuration.format.sampleRate / 100) : 480
            guard let format = AVAudioFormat(streamDescription: &description) else {
                throw CodecError.audioFormatCreationFailed(configuration.codec)
            }
            compressed = format
        }
        pcmFormat = pcm
        compressedFormat = compressed
        if configuration.codec == .pcm16 { converter = nil }
        else {
            guard let native = AVAudioConverter(from: pcm, to: compressed) else {
                throw CodecError.encoderUnavailable(configuration.codec)
            }
            // Preserve transients using the native reservoir while respecting
            // the selected long-term bit rate. Constant-size AAC packets waste
            // bits in pauses and distort quiet syllables at speech bit rates.
            if configuration.codec == .mpeg4AACELD {
                native.bitRateStrategy = AVAudioBitRateStrategy_LongTermAverage
            }
            if let rate = configuration.activeBitRate { native.bitRate = rate }
            converter = native
        }
    }

    public func encode(_ frame: PCMFrame) throws -> EncodedCodecFrame? {
        _ = try frame.validated()
        guard frame.format == configuration.format else {
            throw CodecError.formatMismatch(expected: configuration.format, actual: frame.format)
        }
        guard frame.frameCount > 0 else { return nil }
        guard frame.frameCount <= Int(frame.format.sampleRate) else { throw CodecError.malformedPayload(configuration.codec) }
        if let end = inputEnd, abs(frame.capturedAt - end) > 2 / frame.format.sampleRate {
            converter?.reset()
            capturedStart = nil
            emittedFrames = 0
            streamID = UUID()
        }
        if capturedStart == nil { capturedStart = frame.capturedAt }
        inputEnd = frame.capturedAt + Double(frame.frameCount) / frame.format.sampleRate
        guard let converter else { return try CodecEncoder(configuration: configuration).encode(frame) }
        let input = try AudioConverterBridge.makePCMBuffer(samples: frame.samples, format: frame.format,
            avFormat: pcmFormat, frameCount: UInt32(frame.frameCount))
        let nativePacketFrames = max(1, compressedFormat.streamDescription.pointee.mFramesPerPacket)
        let capacity = UInt32(frame.frameCount) / nativePacketFrames + 2
        let output = AVAudioCompressedBuffer(format: compressedFormat, packetCapacity: capacity,
            maximumPacketSize: max(1, converter.maximumOutputPacketSize))
        let provider = AudioBufferProvider(input, exhausted: .noDataNow)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { count, state in provider.provide(count, state) }
        guard status != .error else {
            throw CodecError.conversionFailed(configuration.codec, error?.localizedDescription ?? "Streaming encode failed")
        }
        guard output.packetCount > 0 else { return nil }
        var description = compressedFormat.streamDescription.pointee
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let cookie = converter.magicCookie ?? Data()
        let formatStatus = cookie.withUnsafeBytes {
            AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32(cookie.count), $0.baseAddress, &size, &description)
        }
        guard formatStatus == noErr, description.mFramesPerPacket > 0 else {
            throw CodecError.audioFormatCreationFailed(configuration.codec)
        }
        let packetDescriptions = AudioConverterBridge.packetDescriptions(from: output)
        let count = packetDescriptions.reduce(0) {
            $0 + Int($1.variableFramesInPacket > 0 ? $1.variableFramesInPacket : nativePacketFrames)
        }
        let timestamp = capturedStart! + Double(emittedFrames) / frame.format.sampleRate
        emittedFrames += count
        let envelope = CompressedPayloadEnvelope(streamID: streamID, codec: configuration.codec,
            sourceSampleCount: count * frame.format.channelCount, sourceFrameCount: UInt32(count),
            maximumPacketSize: output.maximumPacketSize, packetCount: output.packetCount,
            packetDescriptions: packetDescriptions, magicCookie: converter.magicCookie,
            primingFrameCount: 0, data: Data(bytes: output.data, count: Int(output.byteLength)))
        return EncodedCodecFrame(sequenceNumber: frame.sequenceNumber, codec: configuration.codec,
            format: frame.format, capturedAt: timestamp, sampleCount: count * frame.format.channelCount,
            bitRate: configuration.activeBitRate, payload: try envelope.encoded())
    }
}

/// Owned by one remote peer. A new stream identity resets only that peer's
/// native decoder; different peers/codecs never share codec history.
public final class StreamingCodecDecoder {
    private var streamID: UUID?
    private var converter: AVAudioConverter?
    private var compressedFormat: AVAudioFormat?
    private var pcmFormat: AVAudioFormat?
    private var format: AudioFormat?
    private var codec: CodecIdentifier?
    private var lastDecodedEnd: TimeInterval?
    private var transition = PCMStreamTransition()

    public init() {}

    public func decode(_ frame: EncodedCodecFrame) throws -> PCMFrame {
        if frame.codec == .pcm16 {
            let changed = codec != nil && (codec != frame.codec || format != frame.format)
            codec = frame.codec; format = frame.format; streamID = nil; converter = nil
            return finish(try CodecDecoder().decode(frame), streamChanged: changed)
        }
        guard frame.format.isValid, frame.capturedAt.isFinite,
              frame.payload.count <= CodecDecoder.maximumPayloadBytes else { throw CodecError.malformedPayload(frame.codec) }
        let envelope = try CompressedPayloadEnvelope.decode(frame.payload, expectedCodec: frame.codec)
        guard let identity = envelope.streamID else { return try CodecDecoder().decode(frame) }
        guard frame.sampleCount == envelope.sourceSampleCount,
              envelope.sourceSampleCount == Int(envelope.sourceFrameCount) * frame.format.channelCount else {
            throw CodecError.malformedPayload(frame.codec)
        }
        let changed = streamID != identity || format != frame.format || codec != frame.codec
        if changed {
            guard let pcm = AudioConverterBridge.makePCMFormat(frame.format),
                  let compressed = AudioConverterBridge.makeDecodeFormat(codec: frame.codec, format: frame.format, cookie: envelope.magicCookie) else {
                throw CodecError.audioFormatCreationFailed(frame.codec)
            }
            compressed.magicCookie = envelope.magicCookie
            guard let native = AVAudioConverter(from: compressed, to: pcm) else { throw CodecError.decoderUnavailable(frame.codec) }
            converter = native
            pcmFormat = pcm
            compressedFormat = compressed
            streamID = identity
            format = frame.format
            codec = frame.codec
        }
        let input = AVAudioCompressedBuffer(format: compressedFormat!, packetCapacity: envelope.packetCount,
            maximumPacketSize: envelope.maximumPacketSize)
        input.packetCount = envelope.packetCount
        input.byteLength = UInt32(envelope.data.count)
        envelope.data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { input.data.copyMemory(from: base, byteCount: bytes.count) }
        }
        for (index, description) in envelope.packetDescriptions.enumerated() {
            input.packetDescriptions?[index] = description.audioStreamPacketDescription
        }
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat!, frameCapacity: envelope.sourceFrameCount + 8192) else {
            throw CodecError.audioFormatCreationFailed(frame.codec)
        }
        let provider = AudioBufferProvider(input, exhausted: .noDataNow)
        var error: NSError?
        let status = converter!.convert(to: output, error: &error) { count, state in provider.provide(count, state) }
        guard status != .error else { throw CodecError.conversionFailed(frame.codec, error?.localizedDescription ?? "Streaming decode failed") }
        let samples = try AudioConverterBridge.samples(from: output, format: frame.format,
            sampleLimit: Int(output.frameLength) * frame.format.channelCount)
        let skipped = max(0, Int(envelope.sourceFrameCount) - Int(output.frameLength))
        return finish(PCMFrame(sequenceNumber: frame.sequenceNumber, format: frame.format,
            capturedAt: frame.capturedAt + Double(skipped) / frame.format.sampleRate, samples: samples), streamChanged: changed)
    }

    private func finish(_ frame: PCMFrame, streamChanged: Bool) -> PCMFrame {
        guard frame.frameCount > 0 else { return frame }
        if let end = lastDecodedEnd,
           streamChanged || abs(frame.capturedAt - end) > 2 / frame.format.sampleRate {
            // A long pause must never resurrect the last audible sample.
            if abs(frame.capturedAt - end) > 0.1 { transition.reset() }
            transition.begin(settlingDuration: 0)
        }
        lastDecodedEnd = frame.capturedAt + Double(frame.frameCount) / frame.format.sampleRate
        return transition.process(frame)
    }
}
