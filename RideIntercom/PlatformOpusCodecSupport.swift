import Foundation

#if canImport(AVFAudio)
import AVFAudio
import AudioToolbox
#endif

enum DefaultOpusCodecBackendFactory {
    static let environmentKey = "RIDEINTERCOM_ENABLE_SYSTEM_OPUS"

    static func installIfEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        backendFactory: () -> (any OpusCodecBackend)? = { makeBackendIfAvailable() }
    ) {
        guard environment[environmentKey] == "1" else { return }
        guard let backend = backendFactory() else { return }
        OpusCodecBackendRegistry.install(backend)
    }

    private static func makeBackendIfAvailable() -> (any OpusCodecBackend)? {
        #if canImport(AVFAudio)
        return SystemOpusCodecBackend.makeIfAvailable()
        #else
        return nil
        #endif
    }
}

#if canImport(AVFAudio)
private final class SystemOpusCodecBackend: OpusCodecBackend {
    private static let sampleRate: Double = 16_000
    private static let channelCount: AVAudioChannelCount = 1

    private let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    private let encoder: AVAudioConverter
    private let decoder: AVAudioConverter

    private init?(bitRate: Int = 24_000) {
        guard let pcm = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: false
        ) else {
            return nil
        }

        guard let opus = AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Int(Self.channelCount),
            AVEncoderBitRateKey: bitRate
        ]) else {
            return nil
        }

        guard let encoder = AVAudioConverter(from: pcm, to: opus),
              let decoder = AVAudioConverter(from: opus, to: pcm) else {
            return nil
        }

        self.pcmFormat = pcm
        self.opusFormat = opus
        self.encoder = encoder
        self.decoder = decoder
    }

    static func makeIfAvailable() -> (any OpusCodecBackend)? {
        SystemOpusCodecBackend()
    }

    func encode(_ samples: [Float]) throws -> Data {
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = pcmBuffer.floatChannelData?[0] else {
            throw AudioCodecError.codecUnavailable(.opus)
        }

        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }

        let maxPacketSize = max(512, Int(encoder.maximumOutputPacketSize))
        let compressedBuffer = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: maxPacketSize
        )

        var consumed = false
        var conversionError: NSError?
        let status = encoder.convert(to: compressedBuffer, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return pcmBuffer
        }

        if conversionError != nil || status == .error || compressedBuffer.byteLength == 0 {
            throw AudioCodecError.codecUnavailable(.opus)
        }

        return Data(bytes: compressedBuffer.data, count: Int(compressedBuffer.byteLength))
    }

    func decode(_ data: Data) throws -> [Float] {
        let compressedBuffer = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: max(1, data.count)
        )

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            memcpy(compressedBuffer.data, baseAddress, data.count)
        }
        compressedBuffer.byteLength = UInt32(data.count)
        compressedBuffer.packetCount = 1

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: 4096
        ) else {
            throw AudioCodecError.codecUnavailable(.opus)
        }

        var consumed = false
        var conversionError: NSError?
        let status = decoder.convert(to: outputBuffer, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return compressedBuffer
        }

        if conversionError != nil || status == .error {
            throw AudioCodecError.codecUnavailable(.opus)
        }

        guard outputBuffer.frameLength > 0,
              let channel = outputBuffer.floatChannelData?[0] else {
            return []
        }

        let frameCount = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channel, count: frameCount))
    }
}
#endif
