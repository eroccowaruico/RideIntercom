import AudioCore
import Codec
import Foundation
import RTC

enum OutboundAudioPacket: Equatable {
    case voice(PCMFrame)
    case keepalive
}

typealias AudioCodecIdentifier = RTC.RTCAudioCodecIdentifier

enum RTCAudioFormatPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case mono48k
    case mono24k
    case mono16k

    var id: String { rawValue }

    var audioFormat: AudioFormat {
        switch self {
        case .mono48k:
            AudioFormat(sampleRate: 48_000, channelCount: 1)
        case .mono24k:
            AudioFormat(sampleRate: 24_000, channelCount: 1)
        case .mono16k:
            AudioFormat(sampleRate: 16_000, channelCount: 1)
        }
    }

    var label: String {
        switch self {
        case .mono48k:
            "48 kHz"
        case .mono24k:
            "24 kHz"
        case .mono16k:
            "16 kHz"
        }
    }
}

extension AudioFormat {
    nonisolated static let intercomHardwarePreferred = AudioFormat(sampleRate: 48_000, channelCount: 1)
    nonisolated static let intercomMixer = AudioFormat(sampleRate: 48_000, channelCount: 1)
    nonisolated static let intercomPacketAudio = AudioFormat(sampleRate: 48_000, channelCount: 1)
}

extension RTC.RTCAudioFormat {
    nonisolated static let intercomPacketAudio = RTC.RTCAudioFormat(audioFormat: .intercomPacketAudio)

    init(audioFormat: AudioFormat) {
        self.init(sampleRate: audioFormat.sampleRate, channelCount: audioFormat.channelCount)
    }

    var audioFormat: AudioFormat {
        AudioFormat(sampleRate: sampleRate, channelCount: channelCount)
    }
}

extension RTC.RTCAudioPolicy {
    nonisolated static let intercomDefault = RTC.RTCAudioPolicy(
        preferredSendFormat: .intercomPacketAudio,
        preferredCodecs: [.pcm16]
    )
}

private extension AudioFormat {
    init(rtcFormat: RTC.RTCAudioFormat) {
        self.init(sampleRate: rtcFormat.sampleRate, channelCount: rtcFormat.channelCount)
    }
}

private extension Codec.CodecIdentifier {
    var rtcIdentifier: RTC.RTCAudioCodecIdentifier {
        RTC.RTCAudioCodecIdentifier(rawValue: rawValue)
    }
}

private extension RTC.RTCAudioCodecIdentifier {
    var codecIdentifier: Codec.CodecIdentifier {
        Codec.CodecIdentifier(rawValue: rawValue) ?? .pcm16
    }
}

struct AppAudioCodecOptions: Sendable {
    private let aacELDv2BitRate: Int
    private let opusBitRate: Int

    init(aacELDv2BitRate: Int = 32_000, opusBitRate: Int = 32_000) {
        self.aacELDv2BitRate = Codec.AACELDv2Options(bitRate: aacELDv2BitRate).bitRate
        self.opusBitRate = Codec.OpusOptions(bitRate: opusBitRate).bitRate
    }

    var aacELDv2Options: Codec.AACELDv2Options {
        Codec.AACELDv2Options(bitRate: aacELDv2BitRate)
    }

    var opusOptions: Codec.OpusOptions {
        Codec.OpusOptions(bitRate: opusBitRate)
    }
}

enum AppAudioCodecBridge {
    static func makeRTCAudioPolicy(
        preferred codec: AudioCodecIdentifier,
        format: AudioFormat = .intercomPacketAudio,
        options: AppAudioCodecOptions = AppAudioCodecOptions()
    ) -> RTC.RTCAudioPolicy {
        let selectedCodec = selectedRTCCodec(codec, format: format, options: options)
        let availableCodecs = availableRTCCodecs(format: format, options: options)
        let preferredCodecs = ([selectedCodec] + availableCodecs)
            .reduce(into: [AudioCodecIdentifier]()) { codecs, codec in
                if !codecs.contains(codec) {
                    codecs.append(codec)
                }
            }
        return RTC.RTCAudioPolicy(
            preferredSendFormat: RTC.RTCAudioFormat(audioFormat: format),
            preferredCodecs: preferredCodecs,
            maximumBitRate: runtimeReport(for: codec, format: format, options: options)
                .activeConfiguration
                .activeBitRate
        )
    }

    static func availableRTCCodecs(
        format: AudioFormat = .intercomPacketAudio,
        options: AppAudioCodecOptions = AppAudioCodecOptions()
    ) -> [AudioCodecIdentifier] {
        let available = Set(runtimeReport(for: .pcm16, format: format, options: options)
            .availableCodecs
            .map(\.rtcIdentifier))
        return [AudioCodecIdentifier.mpeg4AACELDv2, .opus, .pcm16].filter { available.contains($0) }
    }

    static func selectedRTCCodec(
        _ preferred: AudioCodecIdentifier,
        format: AudioFormat = .intercomPacketAudio,
        options: AppAudioCodecOptions = AppAudioCodecOptions()
    ) -> AudioCodecIdentifier {
        runtimeReport(for: preferred, format: format, options: options).selectedCodec.rtcIdentifier
    }

    static func runtimeReport(
        for preferred: AudioCodecIdentifier,
        format: AudioFormat = .intercomPacketAudio,
        options: AppAudioCodecOptions = AppAudioCodecOptions()
    ) -> CodecRuntimeReport {
        CodecRuntimeReport.resolving(Codec.CodecEncodingConfiguration(
            codec: preferred.codecIdentifier,
            format: format,
            aacELDv2Options: options.aacELDv2Options,
            opusOptions: options.opusOptions
        ))
    }

    static func encode(
        _ frame: PCMFrame,
        preferred codec: AudioCodecIdentifier,
        options: AppAudioCodecOptions = AppAudioCodecOptions()
    ) throws -> RTC.RTCAudioPacket {
        let report = runtimeReport(for: codec, format: frame.format, options: options)
        let encoded = try Codec.CodecEncoder(configuration: report.activeConfiguration).encode(frame)
        return RTC.RTCAudioPacket(
            sequenceNumber: encoded.sequenceNumber,
            codec: encoded.codec.rtcIdentifier,
            format: RTC.RTCAudioFormat(audioFormat: encoded.format),
            capturedAt: encoded.capturedAt,
            sampleCount: encoded.sampleCount,
            bitRate: encoded.bitRate,
            payload: encoded.payload
        )
    }

    static func decode(_ packet: RTC.RTCAudioPacket) throws -> PCMFrame {
        try Codec.CodecDecoder().decode(Codec.EncodedCodecFrame(
            sequenceNumber: packet.sequenceNumber,
            codec: packet.codec.codecIdentifier,
            format: AudioFormat(rtcFormat: packet.format),
            capturedAt: packet.capturedAt,
            sampleCount: packet.sampleCount ?? 0,
            bitRate: packet.bitRate,
            payload: packet.payload
        ))
    }
}
