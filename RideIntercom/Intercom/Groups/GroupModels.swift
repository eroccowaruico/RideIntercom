import Foundation

struct GroupMember: Identifiable, Equatable, Hashable, Codable {
    let id: String
    var displayName: String
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

struct IntercomGroup: Identifiable, Equatable {
    static let maximumMemberCount = 8

    let id: UUID
    var name: String
    var members: [GroupMember]
    var accessSecret: String?

    init(id: UUID = UUID(), name: String, members: [GroupMember], accessSecret: String? = nil) throws {
        guard (1...Self.maximumMemberCount).contains(members.count) else {
            throw IntercomGroupError.invalidMemberCount
        }
        guard Self.isValidName(name), Set(members.map(\.id)).count == members.count,
              members.allSatisfy({ Self.isValidMemberID($0.id) && Self.isValidName($0.displayName) }) else {
            throw IntercomGroupError.invalidIdentity
        }

        self.id = id
        self.name = name
        self.members = members
        self.accessSecret = accessSecret
    }

    static func isValidMemberID(_ value: String) -> Bool {
        (1...63).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func isValidName(_ value: String) -> Bool {
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
    case rollbackFailed
}

struct GroupAccessCredential: Equatable {
    let groupID: UUID
    let secret: String


}

protocol GroupCredentialStoring: AnyObject {
    func save(_ credential: GroupAccessCredential) throws
    func credential(for groupID: UUID) throws -> GroupAccessCredential?
    func delete(for groupID: UUID) throws
}
