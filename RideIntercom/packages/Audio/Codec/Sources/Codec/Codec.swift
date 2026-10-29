import AudioCore
import AudioToolbox
@preconcurrency import AVFAudio
import Foundation

public enum CodecError: Error, Equatable, Sendable {
    case invalidSampleCount(sampleCount: Int, channelCount: Int)
    case invalidByteCount
    case invalidFormat(AudioFormat)
    case formatMismatch(expected: AudioFormat, actual: AudioFormat)
    case unsupportedCodec(CodecIdentifier)
    case encoderUnavailable(CodecIdentifier)
    case decoderUnavailable(CodecIdentifier)
    case audioFormatCreationFailed(CodecIdentifier)
    case conversionFailed(CodecIdentifier, String)
    case malformedPayload(CodecIdentifier)
}

public enum CodecIdentifier: String, Codable, CaseIterable, Equatable, Sendable {
    case pcm16
    case mpeg4AACELD
    case mpeg4AACELDv2
    case opus

    public var displayName: String {
        switch self {
        case .pcm16:
            "PCM 16-bit"
        case .mpeg4AACELD:
            "MPEG-4 AAC-ELD"
        case .mpeg4AACELDv2:
            "MPEG-4 AAC-ELD v2"
        case .opus:
            "Opus"
        }
    }

    public var audioFormatID: AudioFormatID {
        switch self {
        case .pcm16:
            kAudioFormatLinearPCM
        case .mpeg4AACELD:
            kAudioFormatMPEG4AAC_ELD
        case .mpeg4AACELDv2:
            kAudioFormatMPEG4AAC_ELD_V2
        case .opus:
            kAudioFormatOpus
        }
    }
}

public struct AACELDv2Options: Codable, Equatable, Sendable {
    public static let allowedBitRateRange: ClosedRange<Int> = 12_000...128_000

    public var bitRate: Int

    public init(bitRate: Int = 32_000) {
        self.bitRate = Self.clamp(bitRate, Self.allowedBitRateRange)
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

public struct OpusOptions: Codable, Equatable, Sendable {
    public static let allowedBitRateRange: ClosedRange<Int> = 6_000...128_000

    public var bitRate: Int

    public init(bitRate: Int = 32_000) {
        self.bitRate = Self.clamp(bitRate, Self.allowedBitRateRange)
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

public struct CodecEncodingConfiguration: Codable, Equatable, Sendable {
    public var codec: CodecIdentifier
    public var format: AudioFormat
    public var aacELDv2Options: AACELDv2Options
    public var opusOptions: OpusOptions

    public init(
        codec: CodecIdentifier = .pcm16,
        format: AudioFormat = AudioFormat(),
        aacELDv2Options: AACELDv2Options = AACELDv2Options(),
        opusOptions: OpusOptions = OpusOptions()
    ) {
        self.codec = codec
        self.format = format
        self.aacELDv2Options = aacELDv2Options
        self.opusOptions = opusOptions
    }

    public var activeBitRate: Int? {
        switch codec {
        case .pcm16:
            nil
        case .mpeg4AACELD, .mpeg4AACELDv2:
            aacELDv2Options.bitRate
        case .opus:
            opusOptions.bitRate
        }
    }
}

public struct EncodedCodecFrame: Codable, Equatable, Sendable {
    public var sequenceNumber: UInt64
    public var codec: CodecIdentifier
    public var format: AudioFormat
    public var capturedAt: TimeInterval
    public var sampleCount: Int
    public var bitRate: Int?
    public var payload: Data

    public init(
        sequenceNumber: UInt64,
        codec: CodecIdentifier,
        format: AudioFormat,
        capturedAt: TimeInterval,
        sampleCount: Int,
        bitRate: Int? = nil,
        payload: Data
    ) {
        self.sequenceNumber = sequenceNumber
        self.codec = codec
        self.format = format
        self.capturedAt = capturedAt
        self.sampleCount = max(0, sampleCount)
        self.bitRate = bitRate.map { max(0, $0) }
        self.payload = payload
    }

    public var metadata: EncodedAudioMetadata {
        EncodedAudioMetadata(
            sequenceNumber: sequenceNumber,
            codec: codec.rawValue,
            format: format,
            capturedAt: capturedAt,
            sampleCount: sampleCount,
            bitRate: bitRate
        )
    }
}

public enum CodecSupport {
    public static func availableEncodingBitRates(codec: CodecIdentifier, format: AudioFormat) -> [Int] {
        guard codec != .pcm16, let input = AudioConverterBridge.makePCMFormat(format),
              let output = AudioConverterBridge.makeCompressedFormat(codec: codec, format: format, bitRate: nil),
              let converter = AVAudioConverter(from: input, to: output) else { return [] }
        return Array(Set((converter.applicableEncodeBitRates ?? []).map(\.intValue).filter { $0 > 0 })).sorted()
    }

    public static func isEncodingAvailable(for configuration: CodecEncodingConfiguration) -> Bool {
        guard configuration.format.isValid else { return false }
        switch configuration.codec {
        case .pcm16:
            return true
        case .mpeg4AACELD, .mpeg4AACELDv2, .opus:
            guard let pcmFormat = AudioConverterBridge.makePCMFormat(configuration.format),
                  let compressedFormat = AudioConverterBridge.makeCompressedFormat(
                    codec: configuration.codec,
                    format: configuration.format,
                    bitRate: configuration.activeBitRate
                  ) else {
                return false
            }
            guard AVAudioConverter(from: pcmFormat, to: compressedFormat) != nil else { return false }
            // Constructing a converter does not prove that this format/bit rate
            // can encode. In particular, ELD v2 can instantiate for mono and
            // then fail every conversion with kAudioCodecBadDataError.
            return (try? AudioConverterBridge.encode(samples: probeSamples(configuration.format),
                codec: configuration.codec, format: configuration.format,
                bitRate: configuration.activeBitRate)) != nil
        }
    }

    private static func probeSamples(_ format: AudioFormat) -> [Float] {
        let frames = max(1, Int(format.sampleRate * 0.02))
        return (0..<(frames * format.channelCount)).map { index in
            Float(sin(Double(index / format.channelCount) * 2 * .pi * 440 / format.sampleRate) * 0.25)
        }
    }

    static func isRoundTripAvailable(for configuration: CodecEncodingConfiguration) -> Bool {
        guard configuration.format.isValid else { return false }
        if configuration.codec == .pcm16 { return true }
        let input = probeSamples(configuration.format)
        do {
            let payload = try AudioConverterBridge.encode(samples: input, codec: configuration.codec,
                format: configuration.format, bitRate: configuration.activeBitRate)
            let output = try AudioConverterBridge.decode(payload: payload, codec: configuration.codec, format: configuration.format)
            return output.count == input.count && output.allSatisfy { $0.isFinite }
                && output.contains { abs($0) > 0.01 }
        } catch {
            return false
        }
    }

    public static func isDecodingAvailable(
        for codec: CodecIdentifier,
        format: AudioFormat = AudioFormat()
    ) -> Bool {
        guard format.isValid else { return false }
        switch codec {
        case .pcm16:
            return true
        case .mpeg4AACELD, .mpeg4AACELDv2, .opus:
            guard let pcmFormat = AudioConverterBridge.makePCMFormat(format),
                  let compressedFormat = AudioConverterBridge.makeCompressedFormat(codec: codec, format: format, bitRate: nil) else {
                return false
            }
            return AVAudioConverter(from: compressedFormat, to: pcmFormat) != nil
        }
    }
}

public struct CodecRuntimeReport: Codable, Equatable, Sendable {
    public var requestedConfiguration: CodecEncodingConfiguration
    public var activeConfiguration: CodecEncodingConfiguration
    public var availableCodecs: [CodecIdentifier]
    public var selectedCodec: CodecIdentifier
    public var isFallback: Bool

    public init(
        requestedConfiguration: CodecEncodingConfiguration,
        activeConfiguration: CodecEncodingConfiguration,
        availableCodecs: [CodecIdentifier],
        selectedCodec: CodecIdentifier,
        isFallback: Bool
    ) {
        self.requestedConfiguration = requestedConfiguration
        self.activeConfiguration = activeConfiguration
        self.availableCodecs = availableCodecs
        self.selectedCodec = selectedCodec
        self.isFallback = isFallback
    }

    public static func resolving(
        _ requestedConfiguration: CodecEncodingConfiguration,
        fallbackCodec: CodecIdentifier = .pcm16
    ) -> CodecRuntimeReport {
        let availableCodecs = CodecIdentifier.allCases.filter {
            let configuration = CodecEncodingConfiguration(
                codec: $0,
                format: requestedConfiguration.format,
                aacELDv2Options: requestedConfiguration.aacELDv2Options,
                opusOptions: requestedConfiguration.opusOptions
            )
            return CodecSupport.isRoundTripAvailable(for: configuration)
        }

        let selectedCodec: CodecIdentifier
        if availableCodecs.contains(requestedConfiguration.codec) {
            selectedCodec = requestedConfiguration.codec
        } else if availableCodecs.contains(fallbackCodec) {
            selectedCodec = fallbackCodec
        } else {
            selectedCodec = .pcm16
        }

        let activeConfiguration = CodecEncodingConfiguration(
            codec: selectedCodec,
            format: requestedConfiguration.format,
            aacELDv2Options: requestedConfiguration.aacELDv2Options,
            opusOptions: requestedConfiguration.opusOptions
        )

        return CodecRuntimeReport(
            requestedConfiguration: requestedConfiguration,
            activeConfiguration: activeConfiguration,
            availableCodecs: availableCodecs,
            selectedCodec: selectedCodec,
            isFallback: selectedCodec != requestedConfiguration.codec
        )
    }
}

public final class CodecEncoder {
    public private(set) var configuration: CodecEncodingConfiguration

    public init(configuration: CodecEncodingConfiguration = CodecEncodingConfiguration()) {
        self.configuration = configuration
    }

    public func apply(_ configuration: CodecEncodingConfiguration) {
        self.configuration = configuration
    }

    public func encode(_ frame: PCMFrame) throws -> EncodedCodecFrame {
        try validate(frame)

        let payload: Data
        switch configuration.codec {
        case .pcm16:
            payload = PCM16Codec.encode(frame.samples)
        case .mpeg4AACELD, .mpeg4AACELDv2, .opus:
            payload = try AudioConverterBridge.encode(
                samples: frame.samples,
                codec: configuration.codec,
                format: frame.format,
                bitRate: configuration.activeBitRate
            )
        }

        return EncodedCodecFrame(
            sequenceNumber: frame.sequenceNumber,
            codec: configuration.codec,
            format: frame.format,
            capturedAt: frame.capturedAt,
            sampleCount: frame.samples.count,
            bitRate: configuration.activeBitRate,
            payload: payload
        )
    }

    private func validate(_ frame: PCMFrame) throws {
        if frame.format != configuration.format {
            throw CodecError.formatMismatch(expected: configuration.format, actual: frame.format)
        }
        do {
            _ = try frame.validated()
        } catch {
            throw CodecError.invalidSampleCount(
                sampleCount: frame.samples.count,
                channelCount: frame.format.channelCount
            )
        }
    }
}

public final class CodecDecoder {
    /// Bounds untrusted compressed allocation to one second of the supported PCM range.
    public static let maximumDecodedFrameCount = 96_000
    public static let maximumPayloadBytes = 1_048_576
    public init() {}

    public func decode(_ frame: EncodedCodecFrame) throws -> PCMFrame {
        guard frame.format.isValid else { throw CodecError.invalidFormat(frame.format) }
        guard frame.payload.count <= Self.maximumPayloadBytes, frame.capturedAt.isFinite,
              frame.sampleCount >= 0,
              frame.sampleCount <= Self.maximumDecodedFrameCount * frame.format.channelCount else {
            throw CodecError.malformedPayload(frame.codec)
        }
        let samples: [Float]
        switch frame.codec {
        case .pcm16:
            samples = try PCM16Codec.decode(frame.payload)
        case .mpeg4AACELD, .mpeg4AACELDv2, .opus:
            samples = try AudioConverterBridge.decode(payload: frame.payload, codec: frame.codec, format: frame.format)
        }

        let decoded = PCMFrame(
            sequenceNumber: frame.sequenceNumber,
            format: frame.format,
            capturedAt: frame.capturedAt,
            samples: samples
        )
        do {
            _ = try decoded.validated()
        } catch {
            throw CodecError.invalidSampleCount(
                sampleCount: decoded.samples.count,
                channelCount: decoded.format.channelCount
            )
        }
        return decoded
    }
}

public enum PCM16Codec {
    public static func encode(_ samples: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * MemoryLayout<Int16>.size)

        for sample in samples {
            let clamped = sample.isFinite ? min(1, max(-1, sample)) : 0
            let scale: Float = clamped < 0 ? 32_768 : 32_767
            let rounded = Int((clamped * scale).rounded(.toNearestOrAwayFromZero))
            let bounded = min(Int(Int16.max), max(Int(Int16.min), rounded))
            let encoded = Int16(bounded).littleEndian
            data.append(UInt8(truncatingIfNeeded: encoded))
            data.append(UInt8(truncatingIfNeeded: encoded >> 8))
        }

        return data
    }

    public static func decode(_ data: Data) throws -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw CodecError.invalidByteCount
        }

        return stride(from: 0, to: data.count, by: MemoryLayout<Int16>.size).map { offset in
            let low = UInt16(data[data.startIndex + offset])
            let high = UInt16(data[data.startIndex + offset + 1]) << 8
            let rawValue = Int16(littleEndian: Int16(bitPattern: low | high))
            if rawValue == Int16.min {
                return -1
            }
            if rawValue < 0 {
                return Float(rawValue) / 32_768
            }
            return Float(rawValue) / Float(Int16.max)
        }
    }
}

enum AudioConverterBridge {
    static func encode(samples: [Float], codec: CodecIdentifier, format: AudioFormat, bitRate: Int?) throws -> Data {
        guard codec != .pcm16 else { return PCM16Codec.encode(samples) }
        guard !samples.isEmpty else {
            return try CompressedPayloadEnvelope.empty(codec: codec).encoded()
        }

        let frameCount = try avAudioFrameCount(forSampleCount: samples.count, format: format)
        guard let pcmFormat = makePCMFormat(format) else {
            throw CodecError.invalidFormat(format)
        }
        guard let compressedFormat = makeCompressedFormat(codec: codec, format: format, bitRate: bitRate) else {
            throw CodecError.audioFormatCreationFailed(codec)
        }
        let key = AudioConverterPool.Key(encoding: true, codec: codec, format: format, bitRate: bitRate, cookie: nil)
        guard let converter = AudioConverterPool.shared.take(key: key, make: {
            AVAudioConverter(from: pcmFormat, to: compressedFormat)
        }) else { throw CodecError.encoderUnavailable(codec) }
        defer { AudioConverterPool.shared.put(converter, key: key) }

        if let bitRate { converter.bitRate = bitRate }
        guard converter.maximumOutputPacketSize > 0 else { throw CodecError.encoderUnavailable(codec) }
        let inputBuffer = try makePCMBuffer(samples: samples, format: format, avFormat: pcmFormat, frameCount: frameCount)
        // The supported codecs use packets of at least 2.5 ms. Include flush
        // packets without allocating one maximum-size packet per PCM sample.
        let packetCapacity = AVAudioPacketCount(ceil(Double(frameCount) / max(1, format.sampleRate * 0.0025))) + 4
        let outputBuffer = AVAudioCompressedBuffer(
            format: compressedFormat,
            packetCapacity: packetCapacity,
            maximumPacketSize: max(1, converter.maximumOutputPacketSize)
        )

        let inputProvider = AudioBufferProvider(inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, inputStatus in
            inputProvider.provide(requested, inputStatus)
        }

        guard status != .error else {
            throw CodecError.conversionFailed(codec, conversionError?.localizedDescription ?? "Unknown AudioConverter encode error")
        }

        guard outputBuffer.packetCount > 0, outputBuffer.byteLength > 0 else {
            throw CodecError.conversionFailed(codec, "Encoder returned no audio for a nonempty PCM frame")
        }
        return try CompressedPayloadEnvelope(
            codec: codec,
            sourceSampleCount: samples.count,
            sourceFrameCount: UInt32(frameCount),
            maximumPacketSize: max(1, converter.maximumOutputPacketSize),
            packetCount: outputBuffer.packetCount,
            packetDescriptions: packetDescriptions(from: outputBuffer),
            magicCookie: converter.magicCookie,
            primingFrameCount: converter.primeInfo.leadingFrames,
            data: Data(bytes: outputBuffer.data, count: Int(outputBuffer.byteLength))
        ).encoded()
    }

    static func decode(payload: Data, codec: CodecIdentifier, format: AudioFormat) throws -> [Float] {
        guard codec != .pcm16 else { return try PCM16Codec.decode(payload) }
        guard !payload.isEmpty else { return [] }

        let envelope = try CompressedPayloadEnvelope.decode(payload, expectedCodec: codec)
        guard envelope.sourceSampleCount == Int(envelope.sourceFrameCount) * format.channelCount else {
            throw CodecError.malformedPayload(codec)
        }
        guard !envelope.data.isEmpty else { return [] }
        guard let pcmFormat = makePCMFormat(format) else {
            throw CodecError.invalidFormat(format)
        }
        guard let compressedFormat = makeDecodeFormat(codec: codec, format: format, cookie: envelope.magicCookie) else {
            throw CodecError.audioFormatCreationFailed(codec)
        }
        compressedFormat.magicCookie = envelope.magicCookie
        let key = AudioConverterPool.Key(encoding: false, codec: codec, format: format, bitRate: nil, cookie: envelope.magicCookie)
        guard let converter = AudioConverterPool.shared.take(key: key, make: {
            AVAudioConverter(from: compressedFormat, to: pcmFormat)
        }) else { throw CodecError.decoderUnavailable(codec) }
        defer { AudioConverterPool.shared.put(converter, key: key) }

        // Preserve decoder delay explicitly; the packet envelope carries the
        // encoder priming samples that are removed once below.
        converter.primeMethod = .none
        // AAC decoders need the encoder's actual stream configuration.

        let inputBuffer = AVAudioCompressedBuffer(
            format: compressedFormat,
            packetCapacity: max(1, envelope.packetCount),
            maximumPacketSize: max(1, envelope.maximumPacketSize)
        )
        inputBuffer.byteLength = UInt32(envelope.data.count)
        inputBuffer.packetCount = envelope.packetCount
        envelope.data.withUnsafeBytes { source in
            if let baseAddress = source.baseAddress {
                inputBuffer.data.copyMemory(from: baseAddress, byteCount: envelope.data.count)
            }
        }
        if let destinationDescriptions = inputBuffer.packetDescriptions {
            for (index, description) in envelope.packetDescriptions.enumerated() {
                destinationDescriptions[index] = description.audioStreamPacketDescription
            }
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: max(1, envelope.sourceFrameCount + envelope.primingFrameCount)
        ) else {
            throw CodecError.audioFormatCreationFailed(codec)
        }

        let inputProvider = AudioBufferProvider(inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, inputStatus in
            inputProvider.provide(requested, inputStatus)
        }

        guard status != .error else {
            throw CodecError.conversionFailed(codec, conversionError?.localizedDescription ?? "Unknown AudioConverter decode error")
        }

        let primingSamples = Int(envelope.primingFrameCount) * format.channelCount
        let decoded = try samples(from: outputBuffer, format: format,
            sampleLimit: envelope.sourceSampleCount + primingSamples)
        guard decoded.count >= envelope.sourceSampleCount + primingSamples else {
            throw CodecError.conversionFailed(codec, "Decoder returned fewer samples than the source and priming frames")
        }
        return Array(decoded.dropFirst(primingSamples).prefix(envelope.sourceSampleCount))
    }

    static func makeDecodeFormat(codec: CodecIdentifier, format: AudioFormat, cookie: Data?) -> AVAudioFormat? {
        guard codec == .mpeg4AACELD || codec == .mpeg4AACELDv2, let cookie else {
            return makeCompressedFormat(codec: codec, format: format, bitRate: nil)
        }
        var description = AudioStreamBasicDescription()
        description.mFormatID = codec.audioFormatID
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = cookie.withUnsafeBytes {
            AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32(cookie.count), $0.baseAddress, &size, &description)
        }
        guard status == noErr else { return nil }
        return AVAudioFormat(streamDescription: &description)
    }

    static func makePCMFormat(_ format: AudioFormat) -> AVAudioFormat? {
        guard format.isValid else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channelCount),
            interleaved: false
        )
    }

    static func makeCompressedFormat(codec: CodecIdentifier, format: AudioFormat, bitRate: Int?) -> AVAudioFormat? {
        guard format.isValid else { return nil }
        guard codec != .pcm16 else { return makePCMFormat(format) }

        var settings: [String: Any] = [
            AVFormatIDKey: codec.audioFormatID,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]

        if let bitRate {
            settings[AVEncoderBitRateKey] = bitRate
        }

        return AVAudioFormat(settings: settings)
    }

    private static func avAudioFrameCount(forSampleCount sampleCount: Int, format: AudioFormat) throws -> AVAudioFrameCount {
        guard sampleCount.isMultiple(of: format.channelCount) else {
            throw CodecError.invalidSampleCount(sampleCount: sampleCount, channelCount: format.channelCount)
        }
        return AVAudioFrameCount(sampleCount / format.channelCount)
    }

    static func makePCMBuffer(
        samples: [Float],
        format: AudioFormat,
        avFormat: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else {
            throw CodecError.audioFormatCreationFailed(.pcm16)
        }

        buffer.frameLength = frameCount
        if format.channelCount == 1 {
            samples.withUnsafeBufferPointer { input in
                if let base = input.baseAddress { channels[0].update(from: base, count: Int(frameCount)) }
            }
        } else {
            for frameIndex in 0..<Int(frameCount) {
                for channelIndex in 0..<format.channelCount {
                    channels[channelIndex][frameIndex] = samples[frameIndex * format.channelCount + channelIndex]
                }
            }
        }

        return buffer
    }

    static func samples(from buffer: AVAudioPCMBuffer, format: AudioFormat, sampleLimit: Int) throws -> [Float] {
        guard let channels = buffer.floatChannelData else {
            throw CodecError.audioFormatCreationFailed(.pcm16)
        }

        let frameLength = Int(buffer.frameLength)
        if format.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: min(frameLength, sampleLimit)))
        }
        var samples: [Float] = []
        samples.reserveCapacity(frameLength * format.channelCount)
        for frameIndex in 0..<frameLength {
            for channelIndex in 0..<format.channelCount {
                samples.append(channels[channelIndex][frameIndex])
            }
        }

        if samples.count > sampleLimit {
            samples.removeLast(samples.count - sampleLimit)
        }
        return samples
    }

    static func packetDescriptions(from buffer: AVAudioCompressedBuffer) -> [CompressedPayloadEnvelope.PacketDescription] {
        guard let packetDescriptions = buffer.packetDescriptions else { return [] }
        return (0..<Int(buffer.packetCount)).map { index in
            CompressedPayloadEnvelope.PacketDescription(packetDescriptions[index])
        }
    }
}

final class AudioBufferProvider: @unchecked Sendable {
    private let buffer: AVAudioBuffer
    private var offset: UInt32 = 0
    private let exhausted: AVAudioConverterInputStatus
    init(_ buffer: AVAudioBuffer, exhausted: AVAudioConverterInputStatus = .endOfStream) { self.buffer = buffer; self.exhausted = exhausted }

    func provide(_ requested: UInt32, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if let pcm = buffer as? AVAudioPCMBuffer {
            guard offset < pcm.frameLength else { status.pointee = exhausted; return nil }
            let count = min(requested, pcm.frameLength - offset)
            guard let part = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: count),
                  let input = pcm.floatChannelData, let output = part.floatChannelData else {
                status.pointee = exhausted; return nil
            }
            part.frameLength = count
            for channel in 0..<Int(pcm.format.channelCount) {
                output[channel].update(from: input[channel].advanced(by: Int(offset)), count: Int(count))
            }
            offset += count
            status.pointee = .haveData
            return part
        }
        guard let compressed = buffer as? AVAudioCompressedBuffer, offset < compressed.packetCount,
              let descriptions = compressed.packetDescriptions else {
            status.pointee = exhausted; return nil
        }
        let count = min(requested, compressed.packetCount - offset)
        let part = AVAudioCompressedBuffer(format: compressed.format, packetCapacity: count,
            maximumPacketSize: compressed.maximumPacketSize)
        var bytes = 0
        for index in 0..<Int(count) {
            var description = descriptions[Int(offset) + index]
            part.data.advanced(by: bytes).copyMemory(from: compressed.data.advanced(by: Int(description.mStartOffset)),
                byteCount: Int(description.mDataByteSize))
            description.mStartOffset = Int64(bytes)
            part.packetDescriptions?[index] = description
            bytes += Int(description.mDataByteSize)
        }
        part.packetCount = count
        part.byteLength = UInt32(bytes)
        offset += count
        status.pointee = .haveData
        return part
    }
}

struct CompressedPayloadEnvelope: Codable, Equatable, Sendable {
    struct PacketDescription: Codable, Equatable, Sendable {
        var startOffset: Int64
        var variableFramesInPacket: UInt32
        var dataByteSize: UInt32

        init(_ description: AudioStreamPacketDescription) {
            self.startOffset = description.mStartOffset
            self.variableFramesInPacket = description.mVariableFramesInPacket
            self.dataByteSize = description.mDataByteSize
        }

        var audioStreamPacketDescription: AudioStreamPacketDescription {
            AudioStreamPacketDescription(
                mStartOffset: startOffset,
                mVariableFramesInPacket: variableFramesInPacket,
                mDataByteSize: dataByteSize
            )
        }
    }

    var streamID: UUID? = nil
    var codec: CodecIdentifier
    var sourceSampleCount: Int
    var sourceFrameCount: UInt32
    var maximumPacketSize: Int
    var packetCount: UInt32
    var packetDescriptions: [PacketDescription]
    var magicCookie: Data? = nil
    var primingFrameCount: UInt32
    var data: Data

    static func empty(codec: CodecIdentifier) -> CompressedPayloadEnvelope {
        CompressedPayloadEnvelope(
            codec: codec,
            sourceSampleCount: 0,
            sourceFrameCount: 0,
            maximumPacketSize: 1,
            packetCount: 0,
            packetDescriptions: [],
            primingFrameCount: 0,
            data: Data()
        )
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data, expectedCodec: CodecIdentifier) throws -> CompressedPayloadEnvelope {
        do {
            let envelope = try JSONDecoder().decode(CompressedPayloadEnvelope.self, from: data)
            guard envelope.codec == expectedCodec else {
                throw CodecError.malformedPayload(expectedCodec)
            }
            guard envelope.packetDescriptions.isEmpty || envelope.packetDescriptions.count == Int(envelope.packetCount) else {
                throw CodecError.malformedPayload(expectedCodec)
            }
            // Validate every size before AVAudioCompressedBuffer allocation and memcpy.
            let count = Int(envelope.packetCount)
            guard envelope.sourceFrameCount <= CodecDecoder.maximumDecodedFrameCount,
                  envelope.primingFrameCount <= 8_192,
                  (envelope.magicCookie?.count ?? 0) <= 16_384,
                  envelope.sourceSampleCount >= 0,
                  envelope.maximumPacketSize > 0,
                  envelope.maximumPacketSize <= CodecDecoder.maximumPayloadBytes,
                  count <= CodecDecoder.maximumPayloadBytes / envelope.maximumPacketSize,
                  envelope.data.count <= count * envelope.maximumPacketSize else {
                throw CodecError.malformedPayload(expectedCodec)
            }
            if envelope.data.isEmpty {
                guard count == 0, envelope.sourceFrameCount == 0, envelope.sourceSampleCount == 0,
                      envelope.packetDescriptions.isEmpty else { throw CodecError.malformedPayload(expectedCodec) }
            } else {
                guard count > 0, envelope.sourceFrameCount > 0 else { throw CodecError.malformedPayload(expectedCodec) }
                for packet in envelope.packetDescriptions {
                    guard packet.startOffset >= 0, packet.startOffset <= envelope.data.count,
                          packet.dataByteSize > 0,
                          packet.dataByteSize <= envelope.maximumPacketSize,
                          Int(packet.dataByteSize) <= envelope.data.count - Int(packet.startOffset),
                          packet.variableFramesInPacket <= CodecDecoder.maximumDecodedFrameCount else {
                        throw CodecError.malformedPayload(expectedCodec)
                    }
                }
            }
            return envelope
        } catch let error as CodecError {
            throw error
        } catch {
            throw CodecError.malformedPayload(expectedCodec)
        }
    }
}
