import Foundation

public struct RTCAudioCodecIdentifier: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let pcm16 = RTCAudioCodecIdentifier(rawValue: "pcm16")
    public static let opus = RTCAudioCodecIdentifier(rawValue: "opus")
    public static let mpeg4AACELDv2 = RTCAudioCodecIdentifier(rawValue: "mpeg4AACELDv2")
    public static let routeManaged = RTCAudioCodecIdentifier(rawValue: "route-managed")
}

public enum AudioMediaOwnership: String, Codable, Equatable, Sendable {
    case appManagedPacketAudio
    case routeManagedMediaStream
}

public struct RTCAudioFormat: Codable, Equatable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int

    public init(sampleRate: Double = 48_000, channelCount: Int = 1) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public struct RTCAudioPolicy: Codable, Equatable, Sendable {
    public var preferredSendFormat: RTCAudioFormat
    public var preferredCodecs: [RTCAudioCodecIdentifier]
    public var maximumBitRate: Int?

    public init(
        preferredSendFormat: RTCAudioFormat = RTCAudioFormat(),
        preferredCodecs: [RTCAudioCodecIdentifier] = [.pcm16],
        maximumBitRate: Int? = nil
    ) {
        self.preferredSendFormat = preferredSendFormat
        self.preferredCodecs = preferredCodecs.isEmpty ? [.pcm16] : preferredCodecs
        self.maximumBitRate = maximumBitRate.map { max(0, $0) }
    }
}

public enum RTCAudioPolicyError: Error, Equatable, Sendable {
    case unsupportedCodec(RTCAudioCodecIdentifier)
    case noMutuallySupportedCodec(preferred: [RTCAudioCodecIdentifier], supported: [RTCAudioCodecIdentifier])
}

public struct RTCAudioPacket: Codable, Equatable, Sendable {
    public var sequenceNumber: UInt64
    public var codec: RTCAudioCodecIdentifier
    public var format: RTCAudioFormat
    public var capturedAt: TimeInterval
    public var sampleCount: Int?
    public var bitRate: Int?
    public var payload: Data

    public init(
        sequenceNumber: UInt64,
        codec: RTCAudioCodecIdentifier,
        format: RTCAudioFormat = RTCAudioFormat(),
        capturedAt: TimeInterval = Date().timeIntervalSince1970,
        sampleCount: Int? = nil,
        bitRate: Int? = nil,
        payload: Data
    ) {
        self.sequenceNumber = sequenceNumber
        self.codec = codec
        self.format = format
        self.capturedAt = capturedAt
        self.sampleCount = sampleCount.map { max(0, $0) }
        self.bitRate = bitRate.map { max(0, $0) }
        self.payload = payload
    }
}

public struct ReceivedAudioPacket: Equatable, Sendable {
    public var peerID: PeerID
    public var packet: RTCAudioPacket

    public init(peerID: PeerID, packet: RTCAudioPacket) {
        self.peerID = peerID
        self.packet = packet
    }
}
