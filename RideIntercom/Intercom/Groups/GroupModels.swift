import Foundation
import CryptoKit

struct GroupMember: Identifiable, Equatable, Hashable, Codable {
    static let pendingInvitePrefix = "invite-pending-"
    let id: String
    var displayName: String
    var localName: String?
    var resolvedDisplayName: String { localName ?? displayName }
    var isMuted: Bool
    var isTalking: Bool
    var voiceLevel: Float
    var voicePeakLevel: Float
    var receivedAudioPacketCount: Int
    var playedAudioFrameCount: Int
    var queuedAudioFrameCount: Int
    var activeCodec: AudioCodecIdentifier?
    var authenticationState: PeerAuthenticationState
    var connectionState: PeerConnectionState

    init(
        id: String,
        displayName: String,
        localName: String? = nil,
        isMuted: Bool = false,
        isTalking: Bool = false,
        voiceLevel: Float = 0,
        voicePeakLevel: Float = 0,
        receivedAudioPacketCount: Int = 0,
        playedAudioFrameCount: Int = 0,
        queuedAudioFrameCount: Int = 0,
        activeCodec: AudioCodecIdentifier? = nil,
        authenticationState: PeerAuthenticationState = .open,
        connectionState: PeerConnectionState = .offline
    ) {
        self.id = id
        self.displayName = displayName
        self.localName = localName
        self.isMuted = isMuted
        self.isTalking = isTalking
        self.voiceLevel = voiceLevel
        self.voicePeakLevel = voicePeakLevel
        self.receivedAudioPacketCount = receivedAudioPacketCount
        self.playedAudioFrameCount = playedAudioFrameCount
        self.queuedAudioFrameCount = queuedAudioFrameCount
        self.activeCodec = activeCodec
        self.authenticationState = authenticationState
        self.connectionState = connectionState
    }

    var audioPipelineState: AudioPipelineState {
        if queuedAudioFrameCount > 0 {
            return .receiving
        }
        if playedAudioFrameCount > 0 {
            return .playing
        }
        if receivedAudioPacketCount > 0 {
            return .received
        }
        return .idle
    }

}

enum AudioPipelineState: String, Equatable, Hashable, Codable {
    case idle = "Audio Idle"
    case received = "Received"
    case receiving = "Receiving"
    case playing = "Playing"
}

enum VoiceLevelIntensity: Equatable {
    case silent
    case low
    case medium
    case high
}

enum AudioCheckPhase: String, Equatable {
    case idle = "Audio Check Idle"
    case recording = "Recording"
    case playing = "Playing Back"
    case completed = "Audio Check Complete"
    case failed = "Audio Check Failed"
}

struct VoiceLevelIndicatorState: Equatable {
    let level: Float
    let peakLevel: Float

    var levelPercent: Int {
        percent(for: level)
    }

    var peakPercent: Int {
        percent(for: peakLevel)
    }

    /// Display level mapped to 0-1 using dBFS scale (-60dBFS -> 0, 0dBFS -> 1).
    /// Allows typical speech (-20 to -6dBFS) to appear in the visible upper range of the meter.
    var displayLevel: Float {
        dBFSDisplayLevel(for: level)
    }

    /// Peak level mapped to 0-1 using dBFS scale.
    var displayPeakLevel: Float {
        dBFSDisplayLevel(for: peakLevel)
    }

    var intensity: VoiceLevelIntensity {
        switch clamped(level) {
        case 0..<0.05:
            .silent
        case 0..<0.35:
            .low
        case 0..<0.7:
            .medium
        default:
            .high
        }
    }

    private func percent(for value: Float) -> Int {
        Int((clamped(value) * 100).rounded())
    }

    private func clamped(_ value: Float) -> Float {
        min(1, max(0, value))
    }

    private func dBFSDisplayLevel(for rms: Float) -> Float {
        let c = clamped(rms)
        guard c > 0 else { return 0 }
        let dBFS = 20 * log10(c)
        return min(1, max(0, (dBFS + 60) / 60))
    }
}

struct VoicePeakWindow: Equatable {
    private let frameLimit: Int
    private var levels: [Float]

    init(frameLimit: Int = 100, levels: [Float] = []) {
        self.frameLimit = frameLimit
        self.levels = levels
    }

    mutating func record(_ level: Float) -> Float {
        let clampedLevel = min(1, max(0, level))
        levels.append(clampedLevel)
        if levels.count > frameLimit {
            levels.removeFirst(levels.count - frameLimit)
        }
        return levels.max() ?? 0
    }
}

enum PeerAuthenticationState: String, Equatable, Hashable, Codable {
    case open = "AUTH OPEN"
    case pending = "AUTH PENDING"
    case authenticated = "AUTH OK"
    case offline = "AUTH OFF"
}

enum PeerConnectionState: String, Equatable, Codable {
    case connected = "Connected"
    case connecting = "Connecting"
    case offline = "Offline"
}

/// Account identity chooses the conversation; device identities authorize its endpoints.
struct AccountCallPair: Codable, Equatable {
    let first: AccountPrincipal
    let second: AccountPrincipal
    init(_ a: AccountPrincipal, _ b: AccountPrincipal) {
        if a.orderingKey < b.orderingKey { first = a; second = b }
        else { first = b; second = a }
    }
    var isValid: Bool { first.isValid && second.isValid && first.orderingKey < second.orderingKey }
    var id: UUID { IntercomGroup.directCallID(memberIDs: ["account-v1", first.orderingKey, second.orderingKey]) }
    func other(than principal: AccountPrincipal) -> AccountPrincipal? {
        principal == first ? second : principal == second ? first : nil
    }
}

extension AccountPrincipal {
    var orderingKey: String { Data(issuer.utf8).base64EncodedString() + ":" + userID }
}

struct AccountDeviceBinding: Codable, Equatable {
    let principal: AccountPrincipal
    let publicKey: String
}

struct IntercomGroup: Identifiable, Equatable {
    enum Kind: String, Codable { case group, direct }
    static let maximumMemberCount = 8

    let id: UUID
    var name: String
    var members: [GroupMember]
    var accessSecret: String?
    let kind: Kind
    let accountPair: AccountCallPair?
    var accountDevices: [String: AccountDeviceBinding]

    init(id: UUID = UUID(), name: String, members: [GroupMember], accessSecret: String? = nil, kind: Kind = .group, accountPair: AccountCallPair? = nil, accountDevices: [String: AccountDeviceBinding] = [:]) throws {
        guard (1...Self.maximumMemberCount).contains(members.count) else {
            throw IntercomGroupError.invalidMemberCount
        }
        guard Self.isValidName(name), Set(members.map(\.id)).count == members.count,
              members.allSatisfy({ Self.isValidMemberID($0.id) && Self.isValidName($0.displayName) && ($0.localName.map(Self.isValidName) ?? true) }) else {
            throw IntercomGroupError.invalidIdentity
        }
        if let pair = accountPair {
            guard kind == .direct, pair.isValid, id == pair.id,
                  Set(accountDevices.keys) == Set(members.map(\.id)),
                  accountDevices.allSatisfy({ memberID, binding in
                      !memberID.hasPrefix(GroupMember.pendingInvitePrefix) && pair.other(than: binding.principal) != nil
                      && DeviceIdentityProof.isValidPublicKey(binding.publicKey)
                  }) else { throw IntercomGroupError.invalidIdentity }
        } else {
            guard accountDevices.isEmpty else { throw IntercomGroupError.invalidIdentity }
            if kind == .direct {
                guard members.count == 2, !members.contains(where: { $0.id.hasPrefix(GroupMember.pendingInvitePrefix) }),
                      id == Self.directCallID(memberIDs: members.map(\.id)) else { throw IntercomGroupError.invalidIdentity }
            }
        }

        self.id = id
        self.name = name
        self.members = members
        self.accessSecret = accessSecret
        self.kind = kind
        self.accountPair = accountPair
        self.accountDevices = accountDevices
    }

    /// Identifies a pair, never supplies a credential. Keys remain random and private.
    static func directCallID(memberIDs: [String]) -> UUID {
        let input = "rideintercom.direct-call.v1|" + memberIDs.sorted().joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    nonisolated static func isValidMemberID(_ value: String) -> Bool {
        (1...63).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    nonisolated static func isValidName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 320
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

}

enum IntercomGroupError: Error, Equatable {
    case invalidMemberCount
    case invalidIdentity
    case invalidStoredGroups
    case storageUnavailable
    case credentialVerificationFailed
}

struct GroupAccessCredential: Equatable {
    let groupID: UUID
    let secret: String


}
