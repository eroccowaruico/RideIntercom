import CryptoKit
import Foundation

// Packet audio serialization, encryption, sequencing, and Multipeer payload helpers.
public enum PCMAudioCodec {
    public static func encode(_ samples: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * MemoryLayout<Int16>.size)

        for sample in samples {
            let clamped = min(1, max(-1, sample))
            let encodedSample = Int16((clamped * Float(Int16.max)).rounded())
            data.append(contentsOf: encodedSample.littleEndianBytes)
        }

        return data
    }

    public static func decode(_ data: Data) throws -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw CodecError.invalidByteCount
        }

        return stride(from: 0, to: data.count, by: MemoryLayout<Int16>.size).map { offset in
            let rawValue = Int16(littleEndian: data[offset].int16LittleEndian(with: data[offset + 1]))
            return Float(rawValue) / Float(Int16.max)
        }
    }

    public enum CodecError: Error, Equatable {
        case invalidByteCount
    }
}

private extension Int16 {
    var littleEndianBytes: [UInt8] {
        let value = littleEndian
        return [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
}

private extension UInt8 {
    func int16LittleEndian(with highByte: UInt8) -> Int16 {
        Int16(bitPattern: UInt16(self) | (UInt16(highByte) << 8))
    }
}

public enum AudioPacketCodec {
    public static func encode(_ envelope: AudioPacketEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> AudioPacketEnvelope {
        try JSONDecoder().decode(AudioPacketEnvelope.self, from: data)
    }
}

enum EncryptedAudioPacketCodec {
    static func encode(_ envelope: AudioPacketEnvelope, credential: GroupAccessCredential) throws -> Data {
        let plaintext = try AudioPacketCodec.encode(envelope)
        let sealedBox = try AES.GCM.seal(plaintext, using: credential.symmetricKey)
        guard let combined = sealedBox.combined else {
            throw CryptoError.unavailableCombinedRepresentation
        }
        return combined
    }

    static func decode(_ data: Data, credential: GroupAccessCredential) throws -> AudioPacketEnvelope {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(sealedBox, using: credential.symmetricKey)
        return try AudioPacketCodec.decode(plaintext)
    }

    enum CryptoError: Error, Equatable {
        case unavailableCombinedRepresentation
    }
}

enum PacketCryptoService {
    static func encrypt(_ envelope: AudioPacketEnvelope, credential: GroupAccessCredential) throws -> Data {
        try EncryptedAudioPacketCodec.encode(envelope, credential: credential)
    }

    static func decrypt(_ data: Data, credential: GroupAccessCredential) throws -> AudioPacketEnvelope {
        try EncryptedAudioPacketCodec.decode(data, credential: credential)
    }
}

struct AudioPacketSequencer {
    let groupID: UUID
    private(set) var streamID: UUID
    private var nextSequenceNumber = 1

    init(groupID: UUID, streamID: UUID = UUID()) {
        self.groupID = groupID
        self.streamID = streamID
    }

    mutating func makeEnvelope(for packet: OutboundAudioPacket, sentAt: TimeInterval = Date().timeIntervalSince1970) -> AudioPacketEnvelope {
        let envelope: AudioPacketEnvelope
        switch packet {
        case .voice(let frameID, let samples):
            envelope = makeVoiceEnvelope(frameID: frameID, samples: samples, sentAt: sentAt)
        }
        nextSequenceNumber += 1
        return envelope
    }

    private mutating func makeVoiceEnvelope(frameID: Int, samples: [Float], sentAt: TimeInterval) -> AudioPacketEnvelope {
        do {
            let encodedVoice = try EncodedVoicePacket.make(frameID: frameID, samples: samples)
            return AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: nextSequenceNumber,
                sentAt: sentAt,
                encodedVoice: encodedVoice
            )
        } catch {
            return AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: nextSequenceNumber,
                sentAt: sentAt,
                kind: .voice,
                frameID: frameID,
                samples: samples,
                encodedVoice: nil
            )
        }
    }
}

struct ReceivedAudioPacketFilter {
    private let groupID: UUID
    private var seenPacketIDs: Set<PacketID> = []

    init(groupID: UUID) {
        self.groupID = groupID
    }

    mutating func accept(_ envelope: AudioPacketEnvelope, fromPeerID peerID: String) -> ReceivedAudioPacket? {
        guard envelope.groupID == groupID else { return nil }

        let packetID = PacketID(streamID: envelope.streamID, sequenceNumber: envelope.sequenceNumber)
        guard !seenPacketIDs.contains(packetID),
              let packet = envelope.packet else {
            return nil
        }

        seenPacketIDs.insert(packetID)
        return ReceivedAudioPacket(peerID: peerID, envelope: envelope, packet: packet)
    }

    private struct PacketID: Hashable {
        let streamID: UUID
        let sequenceNumber: Int
    }
}

struct HandshakeRegistry {
    enum Result: Equatable {
        case accepted
        case rejected
    }

    private let credential: GroupAccessCredential
    private(set) var authenticatedPeerIDs: [String] = []

    init(credential: GroupAccessCredential) {
        self.credential = credential
    }

    mutating func accept(_ message: HandshakeMessage, fromPeerID peerID: String) -> Result {
        guard message.verify(credential: credential) else { return .rejected }

        if !authenticatedPeerIDs.contains(peerID) {
            authenticatedPeerIDs.append(peerID)
        }
        return .accepted
    }

    func isAuthenticated(peerID: String) -> Bool {
        authenticatedPeerIDs.contains(peerID)
    }
}

enum LocalDiscoveryInfo {
    static let groupHashKey = "groupHash"

    static func credential(for group: CallGroup) -> GroupAccessCredential {
        GroupAccessCredential(groupID: group.id, secret: group.accessSecret ?? "local-dev-\(group.id.uuidString)")
    }

    static func makeDiscoveryInfo(for credential: GroupAccessCredential) -> [String: String] {
        [groupHashKey: credential.groupHash]
    }

    static func matches(_ info: [String: String]?, credential: GroupAccessCredential) -> Bool {
        info?[groupHashKey] == credential.groupHash
    }
}

struct LocalNetworkConfiguration {
    static let serviceType = "ride-intercom"
}

enum TransportSendMode: Equatable {
    case unreliable
    case reliable
}

struct MultipeerPayload: Equatable {
    let data: Data
    let mode: TransportSendMode
}

struct AudioPayloadBuildResult: Equatable {
    let payload: MultipeerPayload
    let envelope: AudioPacketEnvelope
    let transmitMetadata: AudioTransmitMetadata
}

struct ControlPayloadEnvelope: Codable, Equatable {
    let kind: Kind
    let handshake: HandshakeMessage?

    enum Kind: String, Codable {
        case keepalive
        case handshake
    }

    init(message: RouteControlMessage) {
        switch message {
        case .keepalive:
            kind = .keepalive
            handshake = nil
        case .handshake(let handshake):
            kind = .handshake
            self.handshake = handshake
        }
    }

    var message: RouteControlMessage? {
        switch kind {
        case .keepalive:
            .keepalive
        case .handshake:
            handshake.map(RouteControlMessage.handshake)
        }
    }
}

struct ApplicationDataPayloadEnvelope: Codable, Equatable {
    let payloadKind: String
    let message: ApplicationDataMessage

    init(message: ApplicationDataMessage) {
        self.payloadKind = "applicationData"
        self.message = message
    }

    var applicationData: ApplicationDataMessage? {
        payloadKind == "applicationData" ? message : nil
    }
}

enum MultipeerPayloadBuilder {
    static func makePayload(
        for packet: OutboundAudioPacket,
        sequencer: inout AudioPacketSequencer,
        credential: GroupAccessCredential? = nil,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) throws -> AudioPayloadBuildResult {
        let envelope = sequencer.makeEnvelope(for: packet, sentAt: sentAt)
        let data: Data
        if let credential {
            data = try PacketCryptoService.encrypt(envelope, credential: credential)
        } else {
            data = try AudioPacketCodec.encode(envelope)
        }
        let metadata = AudioTransmitMetadata(
            mediaCodec: envelope.encodedVoice?.codec ?? .pcm16
        )
        return AudioPayloadBuildResult(
            payload: MultipeerPayload(data: data, mode: .unreliable),
            envelope: envelope,
            transmitMetadata: metadata
        )
    }

    static func makePayload(for message: RouteControlMessage) throws -> MultipeerPayload {
        let data = try JSONEncoder().encode(ControlPayloadEnvelope(message: message))
        let mode: TransportSendMode
        switch message {
        case .keepalive:
            mode = .unreliable
        case .handshake:
            mode = .reliable
        }
        return MultipeerPayload(data: data, mode: mode)
    }

    static func makePayload(for message: ApplicationDataMessage) throws -> MultipeerPayload {
        let data = try JSONEncoder().encode(ApplicationDataPayloadEnvelope(message: message))
        let mode: TransportSendMode
        switch message.delivery {
        case .reliable:
            mode = .reliable
        case .unreliable:
            mode = .unreliable
        }
        return MultipeerPayload(data: data, mode: mode)
    }

    static func decodeControlPayload(_ data: Data) throws -> RouteControlMessage? {
        try JSONDecoder().decode(ControlPayloadEnvelope.self, from: data).message
    }

    static func decodeApplicationDataPayload(_ data: Data) throws -> ApplicationDataMessage? {
        try JSONDecoder().decode(ApplicationDataPayloadEnvelope.self, from: data).applicationData
    }

    static func decodeAudioPayload(_ data: Data, credential: GroupAccessCredential? = nil) throws -> AudioPacketEnvelope {
        if let credential {
            return try PacketCryptoService.decrypt(data, credential: credential)
        }
        return try AudioPacketCodec.decode(data)
    }
}
