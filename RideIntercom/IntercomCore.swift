import CryptoKit
import AVFoundation
import Foundation
import Observation

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

    var audioPipelineSummary: String {
        "RX \(receivedAudioPacketCount) / PLAY \(playedAudioFrameCount) / JIT \(queuedAudioFrameCount)"
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

enum AudioCheckCodecMode: String, CaseIterable {
    case direct = "Direct"
    case pcm16 = "PCM 16-bit"
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

struct IntercomGroup: Identifiable, Equatable, Codable {
    static let maximumMemberCount = 6

    let id: UUID
    var name: String
    var members: [GroupMember]
    var accessSecret: String?

    init(id: UUID = UUID(), name: String, members: [GroupMember], accessSecret: String? = nil) throws {
        guard (1...Self.maximumMemberCount).contains(members.count) else {
            throw IntercomGroupError.invalidMemberCount
        }

        self.id = id
        self.name = name
        self.members = members
        self.accessSecret = accessSecret
    }

}

enum IntercomGroupError: Error, Equatable {
    case invalidMemberCount
}

struct GroupAccessCredential: Equatable {
    let groupID: UUID
    let secret: String

    nonisolated var groupHash: String {
        var input = Data(groupID.uuidString.utf8)
        input.append(0)
        input.append(contentsOf: secret.utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated var symmetricKey: SymmetricKey {
        var input = Data("ride-intercom-audio-v1".utf8)
        input.append(0)
        input.append(contentsOf: groupID.uuidString.utf8)
        input.append(0)
        input.append(contentsOf: secret.utf8)
        return SymmetricKey(data: SHA256.hash(data: input))
    }
}

protocol GroupCredentialStoring: AnyObject {
    func save(_ credential: GroupAccessCredential)
    func credential(for groupID: UUID) -> GroupAccessCredential?
}

protocol GroupCredentialProviding {
    func credential(for group: IntercomGroup, store: GroupCredentialStoring?) -> GroupAccessCredential
}

struct DefaultGroupCredentialProvider: GroupCredentialProviding {
    func credential(for group: IntercomGroup, store: GroupCredentialStoring?) -> GroupAccessCredential {
        if let stored = store?.credential(for: group.id) {
            return stored
        }
        return GroupAccessCredential(groupID: group.id, secret: group.accessSecret ?? "local-dev-\(group.id.uuidString)")
    }
}

final class InMemoryGroupCredentialStore: GroupCredentialStoring {
    private var credentialsByGroupID: [UUID: GroupAccessCredential] = [:]

    func save(_ credential: GroupAccessCredential) {
        credentialsByGroupID[credential.groupID] = credential
    }

    func credential(for groupID: UUID) -> GroupAccessCredential? {
        credentialsByGroupID[groupID]
    }
}

struct LocalMemberIdentity: Equatable {
    let memberID: String
    var displayName: String
}

protocol LocalMemberIdentityStoring: AnyObject {
    func loadOrCreate() -> LocalMemberIdentity
}

final class InMemoryLocalMemberIdentityStore: LocalMemberIdentityStoring {
    private var identity: LocalMemberIdentity?
    private let makeID: () -> String
    private let defaultDisplayName: () -> String

    init(
        identity: LocalMemberIdentity? = nil,
        makeID: @escaping () -> String = { "member-\(UUID().uuidString.prefix(8).lowercased())" },
        defaultDisplayName: @escaping () -> String = { "You" }
    ) {
        self.identity = identity
        self.makeID = makeID
        self.defaultDisplayName = defaultDisplayName
    }

    func loadOrCreate() -> LocalMemberIdentity {
        if let identity {
            return identity
        }

        let identity = LocalMemberIdentity(memberID: makeID(), displayName: defaultDisplayName())
        self.identity = identity
        return identity
    }
}

final class UserDefaultsLocalMemberIdentityStore: LocalMemberIdentityStoring {
    private let defaults: UserDefaults
    private let makeID: () -> String
    private let defaultDisplayName: () -> String
    private let memberIDKey = "RideIntercom.localMemberID"
    private let displayNameKey = "RideIntercom.localDisplayName"

    init(
        defaults: UserDefaults = .standard,
        makeID: @escaping () -> String = { "member-\(UUID().uuidString.prefix(8).lowercased())" },
        defaultDisplayName: @escaping () -> String = { "You" }
    ) {
        self.defaults = defaults
        self.makeID = makeID
        self.defaultDisplayName = defaultDisplayName
    }

    func loadOrCreate() -> LocalMemberIdentity {
        let storedMemberID = defaults.string(forKey: memberIDKey)
        let storedDisplayName = defaults.string(forKey: displayNameKey)
        if let storedMemberID, let storedDisplayName {
            return LocalMemberIdentity(memberID: storedMemberID, displayName: storedDisplayName)
        }

        let identity = LocalMemberIdentity(
            memberID: storedMemberID ?? makeID(),
            displayName: storedDisplayName ?? defaultDisplayName()
        )
        defaults.set(identity.memberID, forKey: memberIDKey)
        defaults.set(identity.displayName, forKey: displayNameKey)
        return identity
    }
}

protocol GroupStoring: AnyObject {
    func loadGroups() -> [IntercomGroup]
    func saveGroups(_ groups: [IntercomGroup])
}

final class InMemoryGroupStore: GroupStoring {
    private var groups: [IntercomGroup]

    init(groups: [IntercomGroup] = []) {
        self.groups = groups.map { group in
            var group = group
            group.accessSecret = nil
            return group
        }
    }

    func loadGroups() -> [IntercomGroup] {
        groups
    }

    func saveGroups(_ groups: [IntercomGroup]) {
        self.groups = groups.map { group in
            var group = group
            group.accessSecret = nil
            return group
        }
    }
}

final class UserDefaultsGroupStore: GroupStoring {
    private let defaults: UserDefaults
    private let groupsKey = "RideIntercom.groups"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadGroups() -> [IntercomGroup] {
        guard let data = defaults.data(forKey: groupsKey),
              let groups = try? JSONDecoder().decode([IntercomGroup].self, from: data) else {
            return []
        }
        return groups
    }

    func saveGroups(_ groups: [IntercomGroup]) {
        let persistableGroups = groups.map { group in
            var group = group
            group.accessSecret = nil
            return group
        }
        guard let data = try? JSONEncoder().encode(persistableGroups) else { return }
        defaults.set(data, forKey: groupsKey)
    }
}

protocol KeychainSecretStoring: AnyObject {
    func saveSecret(_ secret: String, service: String, account: String) throws
    func secret(service: String, account: String) throws -> String?
}

final class KeychainGroupCredentialStore: GroupCredentialStoring {
    private let keychain: KeychainSecretStoring
    private let service: String

    init(
        keychain: KeychainSecretStoring = SystemKeychainSecretStore(),
        service: String = "RideIntercom.GroupCredential"
    ) {
        self.keychain = keychain
        self.service = service
    }

    func save(_ credential: GroupAccessCredential) {
        try? keychain.saveSecret(credential.secret, service: service, account: credential.groupID.uuidString)
    }

    func credential(for groupID: UUID) -> GroupAccessCredential? {
        guard let secret = (try? keychain.secret(service: service, account: groupID.uuidString)) ?? nil else {
            return nil
        }
        return GroupAccessCredential(groupID: groupID, secret: secret)
    }
}

enum KeychainSecretStoreError: Error, Equatable {
    case unsupportedPlatform
    case unexpectedStatus(Int32)
    case invalidData
}

struct GroupInviteToken: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let groupID: UUID
    let groupName: String
    let groupSecret: String
    let inviterMemberID: String
    let issuedAt: TimeInterval
    let expiresAt: TimeInterval?
    let signature: String

    init(
        version: Int = GroupInviteToken.currentVersion,
        groupID: UUID,
        groupName: String,
        groupSecret: String,
        inviterMemberID: String,
        issuedAt: TimeInterval,
        expiresAt: TimeInterval?,
        signature: String
    ) throws {
        guard version == Self.currentVersion else {
            throw GroupInviteTokenError.unsupportedVersion
        }

        self.version = version
        self.groupID = groupID
        self.groupName = groupName
        self.groupSecret = groupSecret
        self.inviterMemberID = inviterMemberID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.signature = signature
    }

    static func make(
        groupID: UUID,
        groupName: String,
        groupSecret: String,
        inviterMemberID: String,
        issuedAt: TimeInterval = Date().timeIntervalSince1970,
        expiresAt: TimeInterval? = nil
    ) throws -> GroupInviteToken {
        try GroupInviteToken(
            groupID: groupID,
            groupName: groupName,
            groupSecret: groupSecret,
            inviterMemberID: inviterMemberID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            signature: makeSignature(
                version: currentVersion,
                groupID: groupID,
                groupName: groupName,
                groupSecret: groupSecret,
                inviterMemberID: inviterMemberID,
                issuedAt: issuedAt,
                expiresAt: expiresAt
            )
        )
    }

    func verifySignature() -> Bool {
        signature == Self.makeSignature(
            version: version,
            groupID: groupID,
            groupName: groupName,
            groupSecret: groupSecret,
            inviterMemberID: inviterMemberID,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }

    func isExpired(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    private static func makeSignature(
        version: Int,
        groupID: UUID,
        groupName: String,
        groupSecret: String,
        inviterMemberID: String,
        issuedAt: TimeInterval,
        expiresAt: TimeInterval?
    ) -> String {
        let message = [
            "\(version)",
            groupID.uuidString,
            groupName,
            groupSecret,
            inviterMemberID,
            String(format: "%.3f", issuedAt),
            expiresAt.map { String(format: "%.3f", $0) } ?? ""
        ].joined(separator: "|")
        let key = SymmetricKey(data: Data(groupSecret.utf8))
        return HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum GroupInviteTokenError: Error, Equatable {
    case unsupportedVersion
    case invalidURL
    case invalidTokenEncoding
    case invalidSignature
    case expired
}

enum GroupInviteTokenCodec {
    static func joinURL(for token: GroupInviteToken) throws -> URL {
        let data = try JSONEncoder().encode(token)
        let encodedToken = data.base64URLEncodedString()
        guard let url = URL(string: "rideintercom://join?token=\(encodedToken)") else {
            throw GroupInviteTokenError.invalidURL
        }
        return url
    }

    static func decodeJoinURL(_ url: URL) throws -> GroupInviteToken {
        guard url.scheme == "rideintercom",
              url.host == "join",
              let encodedToken = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "token" })?
                .value,
              let data = Data(base64URLEncoded: encodedToken) else {
            throw GroupInviteTokenError.invalidURL
        }

        let token = try JSONDecoder().decode(GroupInviteToken.self, from: data)
        guard token.verifySignature() else {
            throw GroupInviteTokenError.invalidSignature
        }
        return token
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        self.init(base64Encoded: base64)
    }
}

struct HandshakeMessage: Codable, Equatable {
    let groupHash: String
    let memberID: String
    let nonce: String
    let mac: String

    static func make(
        credential: GroupAccessCredential,
        memberID: String,
        nonce: String = UUID().uuidString
    ) -> HandshakeMessage {
        let groupHash = credential.groupHash
        return HandshakeMessage(
            groupHash: groupHash,
            memberID: memberID,
            nonce: nonce,
            mac: makeMAC(groupHash: groupHash, memberID: memberID, nonce: nonce, secret: credential.secret)
        )
    }

    nonisolated func verify(credential: GroupAccessCredential) -> Bool {
        guard groupHash == credential.groupHash else { return false }

        let expectedMAC = Self.makeMAC(
            groupHash: groupHash,
            memberID: memberID,
            nonce: nonce,
            secret: credential.secret
        )
        return mac == expectedMAC
    }

    private nonisolated static func makeMAC(groupHash: String, memberID: String, nonce: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let message = [groupHash, memberID, nonce].joined(separator: "|")
        return HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum HandshakeService {
    static func makeMessage(
        credential: GroupAccessCredential,
        memberID: String,
        nonce: String = UUID().uuidString
    ) -> HandshakeMessage {
        HandshakeMessage.make(credential: credential, memberID: memberID, nonce: nonce)
    }

    static func verifyMessage(_ message: HandshakeMessage, credential: GroupAccessCredential) -> Bool {
        message.verify(credential: credential)
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

struct HandshakeRegistry {
    enum Result: Equatable {
        case accepted
        case rejected
    }

    private let credential: GroupAccessCredential
    private(set) var authenticatedPeerIDs: [String] = []

    nonisolated init(credential: GroupAccessCredential) {
        self.credential = credential
    }

    nonisolated mutating func accept(_ message: HandshakeMessage, fromPeerID peerID: String) -> Result {
        guard HandshakeService.verifyMessage(message, credential: credential) else { return .rejected }

        if !authenticatedPeerIDs.contains(peerID) {
            authenticatedPeerIDs.append(peerID)
        }
        return .accepted
    }

    nonisolated func isAuthenticated(peerID: String) -> Bool {
        authenticatedPeerIDs.contains(peerID)
    }
}

enum LocalDiscoveryInfo {
    nonisolated static let groupHashKey = "groupHash"
    private nonisolated static let credentialProvider: any GroupCredentialProviding = DefaultGroupCredentialProvider()

    nonisolated static func credential(for group: IntercomGroup) -> GroupAccessCredential {
        credentialProvider.credential(for: group, store: nil)
    }

    nonisolated static func makeDiscoveryInfo(for credential: GroupAccessCredential) -> [String: String] {
        [groupHashKey: credential.groupHash]
    }

    nonisolated static func matches(_ info: [String: String]?, credential: GroupAccessCredential) -> Bool {
        info?[groupHashKey] == credential.groupHash
    }
}

struct OwnerElection {
    static func owner(from memberIDs: [String]) -> String? {
        memberIDs.min()
    }
}

enum TransportRoute: String, Equatable {
    case local = "Local"
    case internet = "Internet"
}

enum CallConnectionState: Equatable {
    case idle
    case localConnecting
    case localConnected
    case internetConnecting
    case internetConnected
    case reconnectingOffline

    var label: String {
        switch self {
        case .idle:
            "Idle"
        case .localConnecting:
            "Local Connecting"
        case .localConnected:
            "Local Connected"
        case .internetConnecting:
            "Internet Connecting"
        case .internetConnected:
            "Internet Connected"
        case .reconnectingOffline:
            "Reconnecting / Offline"
        }
    }
}

enum IntercomAudioCategory: Equatable {
    case playAndRecord
}

enum IntercomAudioMode: Equatable {
    case `default`
    case voiceChat
}

struct IntercomAudioOptions: OptionSet, Equatable {
    let rawValue: Int

    static let mixWithOthers = IntercomAudioOptions(rawValue: 1 << 0)
    static let allowBluetooth = IntercomAudioOptions(rawValue: 1 << 1)
    static let allowBluetoothA2DP = IntercomAudioOptions(rawValue: 1 << 2)
    static let defaultToSpeaker = IntercomAudioOptions(rawValue: 1 << 3)
}

struct AudioPortInfo: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    static let systemDefault = AudioPortInfo(id: "__system_default__", name: "Auto")
    static let receiver = AudioPortInfo(id: "__receiver__", name: "Receiver")
    static let speaker = AudioPortInfo(id: "__speaker__", name: "Speaker")
}

struct AudioSessionConfiguration: Equatable {
    let category: IntercomAudioCategory
    let mode: IntercomAudioMode
    let options: IntercomAudioOptions

    static let intercom = AudioSessionConfiguration(
        category: .playAndRecord,
        mode: .voiceChat,
        options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP]
    )

    static let audioCheck = AudioSessionConfiguration(
        category: .playAndRecord,
        mode: .default,
        options: [.allowBluetooth, .allowBluetoothA2DP]
    )
}

protocol AudioSessionApplying: AnyObject {
    func apply(_ configuration: AudioSessionConfiguration) throws
    func setActive(_ active: Bool) throws
    var availableInputPorts: [AudioPortInfo] { get }
    var availableOutputPorts: [AudioPortInfo] { get }
    func setPreferredInputPort(_ port: AudioPortInfo) throws
    func setPreferredOutputPort(_ port: AudioPortInfo) throws
}

extension AudioSessionApplying {
    var availableInputPorts: [AudioPortInfo] { [.systemDefault] }
    var availableOutputPorts: [AudioPortInfo] { [.systemDefault] }
    func setPreferredInputPort(_ port: AudioPortInfo) throws {}
    func setPreferredOutputPort(_ port: AudioPortInfo) throws {}
}


final class AudioSessionManager {
    private let session: AudioSessionApplying
    private(set) var isConfigured = false
    private(set) var selectedInputPort: AudioPortInfo = .systemDefault
    private(set) var selectedOutputPort: AudioPortInfo = .systemDefault

    var availableInputPorts: [AudioPortInfo] { session.availableInputPorts }
    var availableOutputPorts: [AudioPortInfo] { session.availableOutputPorts }

    init(session: AudioSessionApplying = SystemAudioSessionAdapter()) {
        self.session = session
    }

    func configureForIntercom() throws {
        try session.apply(.intercom)
        try session.setActive(true)
        try session.setPreferredInputPort(selectedInputPort)
        try session.setPreferredOutputPort(selectedOutputPort)
        isConfigured = true
    }

    func configureForAudioCheck() throws {
        try session.apply(.audioCheck)
        try session.setActive(true)
        try session.setPreferredInputPort(selectedInputPort)
        try session.setPreferredOutputPort(selectedOutputPort)
        isConfigured = true
    }

    func setInputPort(_ port: AudioPortInfo) throws {
        selectedInputPort = port
        guard isConfigured else { return }
        try session.setPreferredInputPort(port)
    }

    func setOutputPort(_ port: AudioPortInfo) throws {
        selectedOutputPort = port
        guard isConfigured else { return }
        try session.setPreferredOutputPort(port)
    }

    func deactivate() throws {
        try session.setActive(false)
        isConfigured = false
    }
}

final class NoOpAudioSession: AudioSessionApplying {
    private(set) var appliedConfigurations: [AudioSessionConfiguration] = []
    private(set) var activeValues: [Bool] = []
    private(set) var inputPortSelections: [AudioPortInfo] = []
    private(set) var outputPortSelections: [AudioPortInfo] = []

    var stubbedInputPorts: [AudioPortInfo] = [.systemDefault]
    var stubbedOutputPorts: [AudioPortInfo] = [.systemDefault]

    var availableInputPorts: [AudioPortInfo] { stubbedInputPorts }
    var availableOutputPorts: [AudioPortInfo] { stubbedOutputPorts }

    func apply(_ configuration: AudioSessionConfiguration) throws {
        appliedConfigurations.append(configuration)
    }

    func setActive(_ active: Bool) throws {
        activeValues.append(active)
    }

    func setPreferredInputPort(_ port: AudioPortInfo) throws {
        inputPortSelections.append(port)
    }

    func setPreferredOutputPort(_ port: AudioPortInfo) throws {
        outputPortSelections.append(port)
    }
}

protocol AudioInputMonitoring: AnyObject {
    var onLevel: (@MainActor (Float) -> Void)? { get set }
    var onSamples: (@MainActor ([Float]) -> Void)? { get set }

    func start() throws
    func stop()
    var supportsSoundIsolation: Bool { get }
    var isSoundIsolationEnabled: Bool { get }
    func setSoundIsolationEnabled(_ enabled: Bool)
}

extension AudioInputMonitoring {
    var supportsSoundIsolation: Bool { false }
    var isSoundIsolationEnabled: Bool { false }
    func setSoundIsolationEnabled(_ enabled: Bool) {}
}

final class NoOpAudioInputMonitor: AudioInputMonitoring {
    var onLevel: (@MainActor (Float) -> Void)?
    var onSamples: (@MainActor ([Float]) -> Void)?
    private(set) var isRunning = false

    func start() throws {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func simulate(level: Float) {
        onLevel?(level)
    }

    func simulate(samples: [Float]) {
        onSamples?(samples)
    }
}

enum MicrophoneAuthorizationState: Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

protocol MicrophonePermissionAuthorizing {
    func authorizationState() -> MicrophoneAuthorizationState
    func requestAccess(completion: @escaping @MainActor (Bool) -> Void)
}

enum AudioInputMonitorError: Error, Equatable {
    case microphonePermissionRequestPending
    case microphonePermissionDenied
}

protocol CallTicking: AnyObject {
    var onTick: (@MainActor (TimeInterval) -> Void)? { get set }

    func start()
    func stop()
}

final class NoOpCallTicker: CallTicking {
    var onTick: (@MainActor (TimeInterval) -> Void)?
    private(set) var isRunning = false

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func simulateTick(now: TimeInterval) {
        guard isRunning else { return }
        onTick?(now)
    }
}

final class RepeatingCallTicker: CallTicking {
    var onTick: (@MainActor (TimeInterval) -> Void)?
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(interval: Duration = .milliseconds(10)) {
        self.interval = interval
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.interval ?? .milliseconds(10))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.onTick?(Date().timeIntervalSince1970)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

struct AudioLevelMeter {
    static func rmsLevel(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float.zero) { partialResult, sample in
            partialResult + sample * sample
        }
        return sqrt(sumOfSquares / Float(samples.count))
    }
}

enum AudioResampler {
    /// Resamples audio samples from one sample rate to another using linear interpolation.
    static func resample(_ samples: [Float], fromRate sourceRate: Double, toRate targetRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0 else { return samples }
        guard abs(sourceRate - targetRate) > 0.5 else { return samples }

        let ratio = targetRate / sourceRate
        let outputCount = max(1, Int((Double(samples.count) * ratio).rounded()))

        return (0..<outputCount).map { outputIndex in
            let sourcePosition = Double(outputIndex) / ratio
            let lowIndex = Int(sourcePosition)
            let highIndex = min(lowIndex + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lowIndex))
            return samples[lowIndex] * (1 - fraction) + samples[highIndex] * fraction
        }
    }
}

enum PCMAudioCodec {
    static func encode(_ samples: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * MemoryLayout<Int16>.size)

        for sample in samples {
            let clamped = min(1, max(-1, sample))
            let encodedSample = Int16((clamped * Float(Int16.max)).rounded())
            data.append(contentsOf: encodedSample.littleEndianBytes)
        }

        return data
    }

    static func decode(_ data: Data) throws -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw CodecError.invalidByteCount
        }

        return stride(from: 0, to: data.count, by: MemoryLayout<Int16>.size).map { offset in
            let rawValue = Int16(littleEndian: data[offset].int16LittleEndian(with: data[offset + 1]))
            return Float(rawValue) / Float(Int16.max)
        }
    }

    enum CodecError: Error, Equatable {
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


enum ControlMessage: Equatable {
    case keepalive
    case handshake(HandshakeMessage)
    case peerMuteState(isMuted: Bool)
}

struct LocalNetworkConfiguration {
    static let serviceType = "ride-intercom"
    static let bonjourService = "_ride-intercom._tcp"
}

enum TransportSendMode: Equatable {
    case unreliable
    case reliable
}

enum LocalNetworkRejectReason: String, Equatable {
    case groupMismatch = "group mismatch"
    case handshakeInvalid = "handshake invalid"
}

enum LocalNetworkStatus: Equatable {
    case idle
    case advertisingBrowsing
    case invited
    case invitationReceived
    case connected
    case rejected(LocalNetworkRejectReason)
    case unavailable

    var label: String {
        switch self {
        case .idle:
            "MC idle"
        case .advertisingBrowsing:
            "MC advertising+browsing"
        case .invited:
            "MC invited"
        case .invitationReceived:
            "MC invitation"
        case .connected:
            "MC connected"
        case .rejected(let reason):
            "MC rejected: \(reason.rawValue)"
        case .unavailable:
            "MC unavailable"
        }
    }
}

struct LocalNetworkEvent: Equatable {
    let status: LocalNetworkStatus
    let peerID: String?
    let occurredAt: TimeInterval?

    init(status: LocalNetworkStatus, peerID: String? = nil, occurredAt: TimeInterval? = nil) {
        self.status = status
        self.peerID = peerID
        self.occurredAt = occurredAt
    }
}

struct MultipeerPayload: Equatable {
    let data: Data
    let mode: TransportSendMode
}

struct ControlPayloadEnvelope: Codable, Equatable {
    let kind: Kind
    let handshake: HandshakeMessage?
    let peerMuteStateIsMuted: Bool?

    enum Kind: String, Codable {
        case keepalive
        case handshake
        case peerMuteState
    }

    init(message: ControlMessage) {
        switch message {
        case .keepalive:
            kind = .keepalive
            handshake = nil
            peerMuteStateIsMuted = nil
        case .handshake(let handshake):
            kind = .handshake
            self.handshake = handshake
            peerMuteStateIsMuted = nil
        case .peerMuteState(let isMuted):
            kind = .peerMuteState
            handshake = nil
            peerMuteStateIsMuted = isMuted
        }
    }

    var message: ControlMessage? {
        switch kind {
        case .keepalive:
            .keepalive
        case .handshake:
            handshake.map(ControlMessage.handshake)
        case .peerMuteState:
            peerMuteStateIsMuted.map { .peerMuteState(isMuted: $0) }
        }
    }
}

enum MultipeerPayloadBuilder {
    static func makePayload(
        for packet: OutboundAudioPacket,
        sequencer: inout AudioPacketSequencer,
        credential: GroupAccessCredential? = nil,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) throws -> MultipeerPayload {
        let envelope = sequencer.makeEnvelope(for: packet, sentAt: sentAt)
        let data: Data
        if let credential {
            data = try PacketCryptoService.encrypt(envelope, credential: credential)
        } else {
            data = try AudioPacketCodec.encode(envelope)
        }
        return MultipeerPayload(data: data, mode: .unreliable)
    }

    static func makePayload(for message: ControlMessage) throws -> MultipeerPayload {
        let data = try JSONEncoder().encode(ControlPayloadEnvelope(message: message))
        let mode: TransportSendMode
        switch message {
        case .keepalive:
            mode = .unreliable
        case .handshake, .peerMuteState:
            mode = .reliable
        }
        return MultipeerPayload(data: data, mode: mode)
    }

    static func decodeControlPayload(_ data: Data) throws -> ControlMessage? {
        try JSONDecoder().decode(ControlPayloadEnvelope.self, from: data).message
    }

    static func decodeAudioPayload(_ data: Data, credential: GroupAccessCredential? = nil) throws -> AudioPacketEnvelope {
        if let credential {
            return try PacketCryptoService.decrypt(data, credential: credential)
        }
        return try AudioPacketCodec.decode(data)
    }
}

enum TransportEvent: Equatable {
    case localNetworkStatus(LocalNetworkEvent)
    case connected(peerIDs: [String])
    case authenticated(peerIDs: [String])
    case remotePeerMuteState(peerID: String, isMuted: Bool)
    case disconnected
    case linkFailed(internetAvailable: Bool)
    case receivedPacket(ReceivedAudioPacket)
}

protocol Transport: AnyObject {
    var route: TransportRoute { get }
    var onEvent: (@MainActor (TransportEvent) -> Void)? { get set }

    func connect(group: IntercomGroup)
    func disconnect()
    func sendAudioFrame(_ frame: OutboundAudioPacket)
    func sendControl(_ message: ControlMessage)
    func setPreferredAudioCodec(_ codec: AudioCodecIdentifier)
    func setHEAACv2Quality(_ quality: HEAACv2Quality)
}

extension Transport {
    func setPreferredAudioCodec(_ codec: AudioCodecIdentifier) {}
    func setHEAACv2Quality(_ quality: HEAACv2Quality) {}
}

final class LocalTransport: Transport {
    let route: TransportRoute = .local
    var onEvent: (@MainActor (TransportEvent) -> Void)?
    private(set) var connectedGroup: IntercomGroup?
    private(set) var sentAudioPackets: [OutboundAudioPacket] = []
    private(set) var sentControlMessages: [ControlMessage] = []

    func connect(group: IntercomGroup) {
        connectedGroup = group
        emit(.localNetworkStatus(LocalNetworkEvent(status: .advertisingBrowsing)))
        emit(.connected(peerIDs: group.members.map(\.id)))
    }

    func disconnect() {
        connectedGroup = nil
        emit(.disconnected)
    }

    func sendAudioFrame(_ frame: OutboundAudioPacket) {
        sentAudioPackets.append(frame)
    }

    func sendControl(_ message: ControlMessage) {
        sentControlMessages.append(message)
    }

    func simulateLinkFailure(internetAvailable: Bool) {
        connectedGroup = nil
        emit(.linkFailed(internetAvailable: internetAvailable))
    }

    func simulateReceivedPacket(_ packet: ReceivedAudioPacket) {
        emit(.receivedPacket(packet))
    }

    func simulateAuthenticatedPeers(_ peerIDs: [String]) {
        emit(.authenticated(peerIDs: peerIDs))
    }

    func simulateConnectedPeers(_ peerIDs: [String]) {
        emit(.connected(peerIDs: peerIDs))
    }

    func simulateRemoteMuteState(peerID: String, isMuted: Bool) {
        emit(.remotePeerMuteState(peerID: peerID, isMuted: isMuted))
    }

    func simulateLocalNetworkStatus(
        _ status: LocalNetworkStatus,
        peerID: String? = nil,
        occurredAt: TimeInterval? = nil
    ) {
        emit(.localNetworkStatus(LocalNetworkEvent(status: status, peerID: peerID, occurredAt: occurredAt)))
    }

    private func emit(_ event: TransportEvent) {
        onEvent?(event)
    }
}


final class InternetTransport: Transport {
    let route: TransportRoute = .internet
    var onEvent: (@MainActor (TransportEvent) -> Void)?
    private(set) var connectedGroup: IntercomGroup?
    private(set) var sentAudioPackets: [OutboundAudioPacket] = []
    private(set) var sentControlMessages: [ControlMessage] = []
    private(set) var sentAudioEnvelopes: [AudioPacketEnvelope] = []
    private var sequencer: AudioPacketSequencer?
    private var receivedPacketFilter: ReceivedAudioPacketFilter?
    private var preferredAudioCodec: AudioCodecIdentifier = .pcm16
    private var heAACv2Quality: HEAACv2Quality = .medium

    func connect(group: IntercomGroup) {
        connectedGroup = group
        sequencer = AudioPacketSequencer(
            groupID: group.id,
            codec: preferredAudioCodec,
            heAACv2Quality: heAACv2Quality
        )
        receivedPacketFilter = ReceivedAudioPacketFilter(groupID: group.id)
        emit(.connected(peerIDs: group.members.map(\.id)))
    }

    func disconnect() {
        connectedGroup = nil
        sequencer = nil
        receivedPacketFilter = nil
        sentAudioEnvelopes.removeAll()
        emit(.disconnected)
    }

    func sendAudioFrame(_ frame: OutboundAudioPacket) {
        sentAudioPackets.append(frame)
        guard var sequencer else { return }
        sequencer.codec = preferredAudioCodec
        sequencer.heAACv2Quality = heAACv2Quality
        let envelope = sequencer.makeEnvelope(for: frame)
        self.sequencer = sequencer
        sentAudioEnvelopes.append(envelope)
    }

    func sendControl(_ message: ControlMessage) {
        sentControlMessages.append(message)
    }

    func setPreferredAudioCodec(_ codec: AudioCodecIdentifier) {
        preferredAudioCodec = codec
    }

    func setHEAACv2Quality(_ quality: HEAACv2Quality) {
        heAACv2Quality = quality
    }

    func simulateAuthenticatedPeers(_ peerIDs: [String]) {
        emit(.authenticated(peerIDs: peerIDs))
    }

    func simulateReceivedEnvelope(_ envelope: AudioPacketEnvelope, fromPeerID peerID: String) {
        guard var receivedPacketFilter else { return }
        guard let packet = receivedPacketFilter.accept(envelope, fromPeerID: peerID) else {
            self.receivedPacketFilter = receivedPacketFilter
            return
        }
        self.receivedPacketFilter = receivedPacketFilter
        emit(.receivedPacket(packet))
    }

    private func emit(_ event: TransportEvent) {
        onEvent?(event)
    }
}

struct HandoverController {
    private(set) var state: CallConnectionState = .idle

    mutating func disconnect() {
        state = .idle
    }

    mutating func connectLocal() {
        state = .localConnected
    }

    mutating func localLinkDidFail(internetAvailable: Bool) {
        state = internetAvailable ? .internetConnecting : .reconnectingOffline
    }

    mutating func internetDidConnect() {
        state = .internetConnected
    }

    mutating func localCandidateDidPassProbe() {
        state = .localConnected
    }
}

struct RouteProbeMetrics: Equatable {
    let rttMilliseconds: Double
    let jitterMilliseconds: Double
    let packetLossRate: Double
    let peerCount: Int
    let expectedPeerCount: Int
}

protocol RoutePolicy {
    func shouldPreferLocal(afterProbe metrics: RouteProbeMetrics) -> Bool
}

struct DefaultRoutePolicy: RoutePolicy {
    let maxRTTMilliseconds: Double
    let maxJitterMilliseconds: Double
    let maxPacketLossRate: Double

    init(
        maxRTTMilliseconds: Double = 180,
        maxJitterMilliseconds: Double = 60,
        maxPacketLossRate: Double = 0.10
    ) {
        self.maxRTTMilliseconds = maxRTTMilliseconds
        self.maxJitterMilliseconds = maxJitterMilliseconds
        self.maxPacketLossRate = maxPacketLossRate
    }

    func shouldPreferLocal(afterProbe metrics: RouteProbeMetrics) -> Bool {
        guard metrics.peerCount >= metrics.expectedPeerCount else { return false }
        guard metrics.rttMilliseconds <= maxRTTMilliseconds else { return false }
        guard metrics.jitterMilliseconds <= maxJitterMilliseconds else { return false }
        guard metrics.packetLossRate <= maxPacketLossRate else { return false }
        return true
    }
}

struct RouteCoordinator {
    private(set) var state: CallConnectionState = .idle
    private var policy: any RoutePolicy

    init(policy: any RoutePolicy = DefaultRoutePolicy()) {
        self.policy = policy
    }

    mutating func connectLocal() {
        state = .localConnected
    }

    mutating func localLinkDidFail(internetAvailable: Bool) {
        state = internetAvailable ? .internetConnecting : .reconnectingOffline
    }

    mutating func internetDidConnect() {
        state = .internetConnected
    }

    mutating func evaluateLocalProbe(_ metrics: RouteProbeMetrics) {
        if policy.shouldPreferLocal(afterProbe: metrics) {
            state = .localConnected
        }
    }

    mutating func disconnect() {
        state = .idle
    }
}

enum VoiceActivityState: Equatable {
    case idle
    case attack
    case talking
    case release
}

struct VoiceActivityDetector {
    static let minThreshold: Float = 0.006
    static let maxThreshold: Float = 0.12
    static let defaultThreshold: Float = 0.012

    private(set) var state: VoiceActivityState = .idle
    private var threshold: Float
    private let attackFrames: Int
    private let releaseFrames: Int
    private var speechFrames = 0
    private var silenceFrames = 0
    private var noiseFloor: Float = 0.001

    init(threshold: Float = VoiceActivityDetector.defaultThreshold, attackFrames: Int = 1, releaseFrames: Int = 40) {
        self.threshold = min(Self.maxThreshold, max(Self.minThreshold, threshold))
        self.attackFrames = attackFrames
        self.releaseFrames = releaseFrames
    }

    mutating func setThreshold(_ threshold: Float) {
        self.threshold = min(Self.maxThreshold, max(Self.minThreshold, threshold))
    }

    mutating func process(level: Float) -> VoiceActivityState {
        let clampedLevel = min(1, max(0, level))
        updateNoiseFloor(using: clampedLevel)

        let startMargin = max(threshold, noiseFloor * 0.6)
        let releaseMargin = max(threshold * 0.35, noiseFloor * 0.2)
        let startThreshold = min(Self.maxThreshold, max(Self.minThreshold, noiseFloor + startMargin))
        let releaseThreshold = min(Self.maxThreshold, max(Self.minThreshold, noiseFloor + releaseMargin))

        if clampedLevel >= startThreshold {
            speechFrames += 1
            silenceFrames = 0

            if speechFrames >= attackFrames {
                state = .talking
            } else {
                state = .attack
            }
        } else {
            speechFrames = 0

            switch state {
            case .talking, .release:
                if clampedLevel <= releaseThreshold {
                    silenceFrames += 1
                    state = silenceFrames >= releaseFrames ? .idle : .release
                } else {
                    silenceFrames = 0
                    state = .release
                }
            case .idle, .attack:
                silenceFrames = 0
                state = .idle
            }
        }

        return state
    }

    private mutating func updateNoiseFloor(using level: Float) {
        let floorTarget = min(level, 0.2)
        let smoothing: Float

        switch state {
        case .idle:
            smoothing = 0.04
        case .attack:
            smoothing = 0.015
        case .talking:
            smoothing = 0.002
        case .release:
            smoothing = 0.02
        }

        noiseFloor += (floorTarget - noiseFloor) * smoothing
        noiseFloor = min(0.2, max(0, noiseFloor))
    }
}

enum OutboundAudioPacket: Equatable {
    case voice(frameID: Int, samples: [Float] = [])
    case keepalive
}

enum AudioCodecIdentifier: String, Codable {
    case pcm16
    case heAACv2
    case opus
}

enum HEAACv2Quality: String, CaseIterable, Codable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var bitRate: Int {
        switch self {
        case .low:
            16_000
        case .medium:
            24_000
        case .high:
            40_000
        }
    }
}

enum AudioCodecError: Error, Equatable {
    case codecUnavailable(AudioCodecIdentifier)
}

protocol AudioEncoding {
    var codec: AudioCodecIdentifier { get }

    func encode(_ samples: [Float]) throws -> Data
    func decode(_ data: Data) throws -> [Float]
}

protocol AudioEncoderSession {
    var codec: AudioCodecIdentifier { get }

    mutating func encodeFrame(_ samples: [Float]) throws -> Data
    mutating func flush() throws -> [Data]
    mutating func reset()
}

protocol AudioDecoderSession {
    var codec: AudioCodecIdentifier { get }

    func decodePacket(_ data: Data) throws -> [Float]
    mutating func reset()
}

struct PCMAudioEncoding: AudioEncoding {
    let codec: AudioCodecIdentifier = .pcm16

    func encode(_ samples: [Float]) throws -> Data {
        PCMAudioCodec.encode(samples)
    }

    func decode(_ data: Data) throws -> [Float] {
        try PCMAudioCodec.decode(data)
    }
}

struct OpusAudioEncoding: AudioEncoding {
    let codec: AudioCodecIdentifier = .opus

    func encode(_ samples: [Float]) throws -> Data {
        throw AudioCodecError.codecUnavailable(.opus)
    }

    func decode(_ data: Data) throws -> [Float] {
        throw AudioCodecError.codecUnavailable(.opus)
    }
}

struct PCMAudioEncoderSession: AudioEncoderSession {
    let codec: AudioCodecIdentifier = .pcm16

    mutating func encodeFrame(_ samples: [Float]) throws -> Data {
        try PCMAudioEncoding().encode(samples)
    }

    mutating func flush() throws -> [Data] {
        []
    }

    mutating func reset() {}
}

struct OpusAudioEncoderSession: AudioEncoderSession {
    let codec: AudioCodecIdentifier = .opus

    mutating func encodeFrame(_ samples: [Float]) throws -> Data {
        try OpusAudioEncoding().encode(samples)
    }

    mutating func flush() throws -> [Data] {
        []
    }

    mutating func reset() {}
}

struct PCMAudioDecoderSession: AudioDecoderSession {
    let codec: AudioCodecIdentifier = .pcm16

    func decodePacket(_ data: Data) throws -> [Float] {
        try PCMAudioEncoding().decode(data)
    }

    mutating func reset() {}
}

struct OpusAudioDecoderSession: AudioDecoderSession {
    let codec: AudioCodecIdentifier = .opus

    func decodePacket(_ data: Data) throws -> [Float] {
        try OpusAudioEncoding().decode(data)
    }

    mutating func reset() {}
}

final class HEAACv2AudioEncoding: AudioEncoding {
    let codec: AudioCodecIdentifier = .heAACv2
    let quality: HEAACv2Quality

    private static let sampleRate: Double = 16_000
    private static let frameSize = 2_048
    private static let channelCount: AVAudioChannelCount = 2

    private var bufferedSamples: [Float] = []

    private lazy var stereoPCMFormat: AVAudioFormat? = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: false
        )
    }()

    private lazy var compressedFormat: AVAudioFormat? = {
        AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC_HE_V2,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Int(Self.channelCount),
            AVEncoderBitRateKey: quality.bitRate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Variable
        ])
    }()

    private lazy var encoder: AVAudioConverter? = {
        guard let stereoPCMFormat, let compressedFormat else { return nil }
        guard let converter = AVAudioConverter(from: stereoPCMFormat, to: compressedFormat) else {
            return nil
        }
        converter.bitRate = quality.bitRate
        converter.bitRateStrategy = AVAudioBitRateStrategy_Variable
        return converter
    }()

    private lazy var decoder: AVAudioConverter? = {
        guard let stereoPCMFormat, let compressedFormat else { return nil }
        return AVAudioConverter(from: compressedFormat, to: stereoPCMFormat)
    }()

    init(quality: HEAACv2Quality = .medium) {
        self.quality = quality
    }

    func encode(_ samples: [Float]) throws -> Data {
        bufferedSamples.append(contentsOf: samples)
        guard bufferedSamples.count >= Self.frameSize else { return Data() }

        guard let encoder,
              let stereoPCMFormat else {
            throw AudioCodecError.codecUnavailable(.heAACv2)
        }

        let frameSamples = Array(bufferedSamples.prefix(Self.frameSize))
        bufferedSamples.removeFirst(Self.frameSize)

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: stereoPCMFormat,
            frameCapacity: AVAudioFrameCount(Self.frameSize)
        ),
        let left = inputBuffer.floatChannelData?[0],
        let right = inputBuffer.floatChannelData?[1] else {
            throw AudioCodecError.codecUnavailable(.heAACv2)
        }

        inputBuffer.frameLength = AVAudioFrameCount(Self.frameSize)
        for index in 0..<Self.frameSize {
            left[index] = frameSamples[index]
            right[index] = frameSamples[index]
        }

        let maximumPacketSize = max(1, Int(encoder.maximumOutputPacketSize))
        let outputBuffer = AVAudioCompressedBuffer(
            format: encoder.outputFormat,
            packetCapacity: 1,
            maximumPacketSize: maximumPacketSize
        )

        var isConsumed = false
        var conversionError: NSError?
        let status = encoder.convert(to: outputBuffer, error: &conversionError) { _, status in
            if isConsumed {
                status.pointee = .noDataNow
                return nil
            }
            isConsumed = true
            status.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw conversionError
        }

        guard status == .haveData, outputBuffer.byteLength > 0 else {
            return Data()
        }

        return Data(bytes: outputBuffer.data, count: Int(outputBuffer.byteLength))
    }

    func decode(_ data: Data) throws -> [Float] {
        guard !data.isEmpty else { return [] }

        guard let decoder,
              let stereoPCMFormat else {
            throw AudioCodecError.codecUnavailable(.heAACv2)
        }

        let inputBuffer = AVAudioCompressedBuffer(
            format: decoder.inputFormat,
            packetCapacity: 1,
            maximumPacketSize: data.count
        )

        inputBuffer.packetCount = 1
        inputBuffer.byteLength = UInt32(data.count)
        data.withUnsafeBytes { source in
            guard let sourceBaseAddress = source.baseAddress else { return }
            memcpy(inputBuffer.data, sourceBaseAddress, data.count)
        }
        if let packetDescriptions = inputBuffer.packetDescriptions {
            packetDescriptions[0] = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(data.count)
            )
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: stereoPCMFormat,
            frameCapacity: AVAudioFrameCount(Self.frameSize * 2)
        ) else {
            throw AudioCodecError.codecUnavailable(.heAACv2)
        }

        var isConsumed = false
        var conversionError: NSError?
        let status = decoder.convert(to: outputBuffer, error: &conversionError) { _, status in
            if isConsumed {
                status.pointee = .noDataNow
                return nil
            }
            isConsumed = true
            status.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw conversionError
        }

        guard status == .haveData,
              outputBuffer.frameLength > 0,
              let leftChannel = outputBuffer.floatChannelData?[0] else {
            return []
        }

        let frameCount = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: leftChannel, count: frameCount))
    }
}

struct HEAACv2AudioEncoderSession: AudioEncoderSession {
    let codec: AudioCodecIdentifier = .heAACv2
    private var encoding: HEAACv2AudioEncoding

    init(quality: HEAACv2Quality = .medium) {
        self.encoding = HEAACv2AudioEncoding(quality: quality)
    }

    mutating func encodeFrame(_ samples: [Float]) throws -> Data {
        try encoding.encode(samples)
    }

    mutating func flush() throws -> [Data] {
        []
    }

    mutating func reset() {
        encoding = HEAACv2AudioEncoding(quality: encoding.quality)
    }
}

struct HEAACv2AudioDecoderSession: AudioDecoderSession {
    let codec: AudioCodecIdentifier = .heAACv2
    private let encoding: HEAACv2AudioEncoding

    init(quality: HEAACv2Quality = .medium) {
        self.encoding = HEAACv2AudioEncoding(quality: quality)
    }

    func decodePacket(_ data: Data) throws -> [Float] {
        try encoding.decode(data)
    }

    mutating func reset() {}
}

enum AudioCodecSessionFactory {
    static func makeEncoderSession(
        preferred codecs: [AudioCodecIdentifier],
        heAACv2Quality: HEAACv2Quality = .medium
    ) -> any AudioEncoderSession {
        for codec in codecs {
            switch codec {
            case .pcm16:
                return PCMAudioEncoderSession()
            case .heAACv2:
                return HEAACv2AudioEncoderSession(quality: heAACv2Quality)
            case .opus:
                // Opus backend is not installed yet. Keep this slot for future implementation.
                continue
            }
        }
        return PCMAudioEncoderSession()
    }

    static func makeDecoderSession(
        codec: AudioCodecIdentifier,
        heAACv2Quality: HEAACv2Quality = .medium
    ) -> any AudioDecoderSession {
        switch codec {
        case .pcm16:
            PCMAudioDecoderSession()
        case .heAACv2:
            HEAACv2AudioDecoderSession(quality: heAACv2Quality)
        case .opus:
            OpusAudioDecoderSession()
        }
    }
}

enum AudioEncodingSelector {
    static func encoder(preferred codecs: [AudioCodecIdentifier]) -> any AudioEncoding {
        for codec in codecs {
            switch codec {
            case .pcm16:
                return PCMAudioEncoding()
            case .heAACv2:
                return HEAACv2AudioEncoding()
            case .opus:
                continue
            }
        }

        return PCMAudioEncoding()
    }
}

struct EncodedVoicePacket: Codable, Equatable {
    let frameID: Int
    let codec: AudioCodecIdentifier
    let payload: Data

    static func make(
        frameID: Int,
        samples: [Float],
        codec: AudioCodecIdentifier = .pcm16,
        heAACv2Quality: HEAACv2Quality = .medium
    ) throws -> EncodedVoicePacket {
        switch codec {
        case .pcm16:
            try make(frameID: frameID, samples: samples, encoder: PCMAudioEncoding())
        case .heAACv2:
            try make(frameID: frameID, samples: samples, encoder: HEAACv2AudioEncoding(quality: heAACv2Quality))
        case .opus:
            try make(frameID: frameID, samples: samples, encoder: OpusAudioEncoding())
        }
    }

    static func make(
        frameID: Int,
        samples: [Float],
        encoder: any AudioEncoding
    ) throws -> EncodedVoicePacket {
        EncodedVoicePacket(frameID: frameID, codec: encoder.codec, payload: try encoder.encode(samples))
    }

    func decodeSamples() throws -> [Float] {
        let decoder = AudioCodecSessionFactory.makeDecoderSession(codec: codec)
        return try decodeSamples(using: decoder)
    }

    func decodeSamples(using encoder: any AudioEncoding) throws -> [Float] {
        try encoder.decode(payload)
    }

    func decodeSamples(using decoder: any AudioDecoderSession) throws -> [Float] {
        try decoder.decodePacket(payload)
    }
}

struct AudioPacketEnvelope: Codable, Equatable {
    enum PacketKind: String, Codable {
        case voice
        case keepalive
    }

    let groupID: UUID
    let streamID: UUID
    let sequenceNumber: Int
    let sentAt: TimeInterval
    let kind: PacketKind
    let frameID: Int?
    let samples: [Float]
    let encodedVoice: EncodedVoicePacket?

    init(
        groupID: UUID,
        streamID: UUID,
        sequenceNumber: Int,
        sentAt: TimeInterval,
        kind: PacketKind,
        frameID: Int?,
        samples: [Float] = [],
        encodedVoice: EncodedVoicePacket? = nil
    ) {
        self.groupID = groupID
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.sentAt = sentAt
        self.kind = kind
        self.frameID = frameID
        self.samples = samples
        self.encodedVoice = encodedVoice
    }

    init(
        groupID: UUID,
        streamID: UUID,
        sequenceNumber: Int,
        sentAt: TimeInterval,
        encodedVoice: EncodedVoicePacket
    ) {
        self.groupID = groupID
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.sentAt = sentAt
        self.kind = .voice
        self.frameID = encodedVoice.frameID
        self.samples = []
        self.encodedVoice = encodedVoice
    }

    init(
        groupID: UUID,
        streamID: UUID,
        sequenceNumber: Int,
        sentAt: TimeInterval,
        packet: OutboundAudioPacket,
        codec: AudioCodecIdentifier = .pcm16,
        heAACv2Quality: HEAACv2Quality = .medium
    ) {
        self.groupID = groupID
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.sentAt = sentAt

        switch packet {
        case .voice(let frameID, let samples):
            let encodedVoice = try? EncodedVoicePacket.make(
                frameID: frameID,
                samples: samples,
                codec: codec,
                heAACv2Quality: heAACv2Quality
            )
            if let encodedVoice,
               !(codec == .heAACv2 && encodedVoice.payload.isEmpty) {
                self.kind = .voice
                self.frameID = frameID
                self.samples = []
                self.encodedVoice = encodedVoice
            } else {
                self.kind = .keepalive
                self.frameID = nil
                self.samples = []
                self.encodedVoice = nil
            }
        case .keepalive:
            self.kind = .keepalive
            self.frameID = nil
            self.samples = []
            self.encodedVoice = nil
        }
    }

    var packet: OutboundAudioPacket? {
        switch kind {
        case .voice:
            if let encodedVoice,
               let decodedSamples = try? encodedVoice.decodeSamples() {
                return .voice(frameID: encodedVoice.frameID, samples: decodedSamples)
            }
            guard let frameID else { return nil }
            return .voice(frameID: frameID, samples: samples)
        case .keepalive:
            return .keepalive
        }
    }
}

struct ReceivedAudioPacket: Equatable {
    let peerID: String
    let envelope: AudioPacketEnvelope
    let packet: OutboundAudioPacket
}

struct ReceivedAudioPacketFilter {
    private let groupID: UUID
    private var seenPacketIDs: Set<PacketID> = []

    init(groupID: UUID) {
        self.groupID = groupID
    }

    mutating func accept(_ data: Data, fromPeerID peerID: String) throws -> ReceivedAudioPacket? {
        let envelope = try AudioPacketCodec.decode(data)
        return accept(envelope, fromPeerID: peerID)
    }

    mutating func accept(_ envelope: AudioPacketEnvelope, fromPeerID peerID: String) -> ReceivedAudioPacket? {
        guard envelope.groupID == groupID,
              let packet = envelope.packet else { return nil }

        let packetID = PacketID(streamID: envelope.streamID, sequenceNumber: envelope.sequenceNumber)
        guard seenPacketIDs.insert(packetID).inserted else { return nil }

        return ReceivedAudioPacket(peerID: peerID, envelope: envelope, packet: packet)
    }

    private struct PacketID: Hashable {
        let streamID: UUID
        let sequenceNumber: Int
    }
}

struct JitterBufferedAudioFrame: Equatable {
    let peerID: String
    let streamID: UUID
    let sequenceNumber: Int
    let frameID: Int
    let samples: [Float]
}

struct JitterBuffer {
    private let playoutDelay: TimeInterval
    private let packetLifetime: TimeInterval
    private var queuedPackets: [QueuedPacket] = []
    private var seenPacketIDs: Set<PacketID> = []
    private(set) var droppedFrameCount = 0

    var queuedFrameCount: Int {
        queuedPackets.count
    }

    init(playoutDelay: TimeInterval = 0.015, packetLifetime: TimeInterval = 0.40) {
        self.playoutDelay = playoutDelay
        self.packetLifetime = packetLifetime
    }

    mutating func enqueue(_ packet: ReceivedAudioPacket, receivedAt: TimeInterval) {
        guard case .voice = packet.packet else { return }

        let packetID = PacketID(
            streamID: packet.envelope.streamID,
            sequenceNumber: packet.envelope.sequenceNumber
        )
        guard seenPacketIDs.insert(packetID).inserted else {
            droppedFrameCount += 1
            return
        }

        queuedPackets.append(QueuedPacket(packet: packet, receivedAt: receivedAt))
    }

    mutating func drainReadyFrames(now: TimeInterval) -> [JitterBufferedAudioFrame] {
        let queuedCountBeforeExpiration = queuedPackets.count
        queuedPackets.removeAll { queuedPacket in
            now - queuedPacket.receivedAt >= packetLifetime
        }
        droppedFrameCount += queuedCountBeforeExpiration - queuedPackets.count

        let readyPackets = queuedPackets
            .filter { now - $0.receivedAt >= playoutDelay }
            .sorted { left, right in
                if left.packet.envelope.streamID != right.packet.envelope.streamID {
                    return left.packet.envelope.streamID.uuidString < right.packet.envelope.streamID.uuidString
                }
                return left.packet.envelope.sequenceNumber < right.packet.envelope.sequenceNumber
            }

        let readyPacketIDs = Set(readyPackets.map {
            PacketID(
                streamID: $0.packet.envelope.streamID,
                sequenceNumber: $0.packet.envelope.sequenceNumber
            )
        })
        queuedPackets.removeAll { queuedPacket in
            readyPacketIDs.contains(
                PacketID(
                    streamID: queuedPacket.packet.envelope.streamID,
                    sequenceNumber: queuedPacket.packet.envelope.sequenceNumber
                )
            )
        }

        return readyPackets.compactMap { queuedPacket in
            guard case .voice(let frameID, let samples) = queuedPacket.packet.packet else { return nil }
            return JitterBufferedAudioFrame(
                peerID: queuedPacket.packet.peerID,
                streamID: queuedPacket.packet.envelope.streamID,
                sequenceNumber: queuedPacket.packet.envelope.sequenceNumber,
                frameID: frameID,
                samples: samples
            )
        }
    }

    private struct QueuedPacket {
        let packet: ReceivedAudioPacket
        let receivedAt: TimeInterval
    }

    private struct PacketID: Hashable {
        let streamID: UUID
        let sequenceNumber: Int
    }
}

protocol AudioFramePlaying: AnyObject {
    func start() throws
    func stop()
    func play(_ frame: JitterBufferedAudioFrame)
    func play(_ frames: [JitterBufferedAudioFrame])
}

final class NoOpAudioFramePlayer: AudioFramePlaying {
    private(set) var playedFrames: [JitterBufferedAudioFrame] = []
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() throws {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func play(_ frame: JitterBufferedAudioFrame) {
        playedFrames.append(frame)
    }

    func play(_ frames: [JitterBufferedAudioFrame]) {
        playedFrames.append(contentsOf: frames)
    }
}

enum AudioMixer {
    static func mix(_ frames: [JitterBufferedAudioFrame]) -> [Float] {
        let sampleCount = frames.map(\.samples.count).max() ?? 0
        guard sampleCount > 0 else { return [] }

        return (0..<sampleCount).map { sampleIndex in
            let mixedSample = frames.reduce(Float.zero) { partialResult, frame in
                guard sampleIndex < frame.samples.count else { return partialResult }
                return partialResult + frame.samples[sampleIndex]
            }
            return min(1.0, max(-1.0, mixedSample))
        }
    }
}

protocol AudioOutputRendering: AnyObject {
    func start() throws
    func stop()
    func schedule(samples: [Float])
}

final class NoOpAudioOutputRenderer: AudioOutputRendering {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var scheduledSampleBuffers: [[Float]] = []

    func start() throws {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func schedule(samples: [Float]) {
        scheduledSampleBuffers.append(samples)
    }
}

final class BufferedAudioFramePlayer: AudioFramePlaying {
    private let renderer: AudioOutputRendering

    init(renderer: AudioOutputRendering) {
        self.renderer = renderer
    }

    func start() throws {
        try renderer.start()
    }

    func stop() {
        renderer.stop()
    }

    func play(_ frame: JitterBufferedAudioFrame) {
        guard !frame.samples.isEmpty else { return }
        renderer.schedule(samples: frame.samples)
    }

    func play(_ frames: [JitterBufferedAudioFrame]) {
        let samples = AudioMixer.mix(frames)
        guard !samples.isEmpty else { return }
        renderer.schedule(samples: samples)
    }
}


enum DefaultGroupStoreFactory {
    static func make(defaults: UserDefaults = .standard) -> GroupStoring {
        UserDefaultsGroupStore(defaults: defaults)
    }
}

enum DefaultGroupCredentialStoreFactory {
    static func make() -> GroupCredentialStoring {
        KeychainGroupCredentialStore()
    }
}

enum CurrentProcessRuntimeFactory {
    static func makeLive() -> IntercomViewModel {
        let localMemberIdentityStore = UserDefaultsLocalMemberIdentityStore()
        let localMemberIdentity = localMemberIdentityStore.loadOrCreate()
        return IntercomViewModel(
            localTransport: DefaultLocalTransportFactory.make(displayName: localMemberIdentity.memberID),
            credentialStore: DefaultGroupCredentialStoreFactory.make(),
            groupStore: DefaultGroupStoreFactory.make(),
            localMemberIdentityStore: localMemberIdentityStore,
            audioFramePlayer: AudioFramePlayerFactory.makeDefault()
        )
    }

    static func makeUITesting(defaults: UserDefaults) -> IntercomViewModel {
        IntercomViewModel(
            groupStore: DefaultGroupStoreFactory.make(defaults: defaults),
            localMemberIdentityStore: UserDefaultsLocalMemberIdentityStore(defaults: defaults),
            audioSessionManager: AudioSessionManager(session: NoOpAudioSession()),
            audioInputMonitor: NoOpAudioInputMonitor(),
            audioFramePlayer: NoOpAudioFramePlayer()
        )
    }
}

enum AudioPacketCodec {
    static func encode(_ envelope: AudioPacketEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> AudioPacketEnvelope {
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

struct AudioPacketSequencer {
    let groupID: UUID
    let streamID: UUID
    var codec: AudioCodecIdentifier
    var heAACv2Quality: HEAACv2Quality
    private var nextSequenceNumber = 1
    private var encoderSession: any AudioEncoderSession
    private var encoderSessionHEAACv2Quality: HEAACv2Quality?

    init(
        groupID: UUID,
        streamID: UUID = UUID(),
        codec: AudioCodecIdentifier = .pcm16,
        heAACv2Quality: HEAACv2Quality = .medium
    ) {
        self.groupID = groupID
        self.streamID = streamID
        self.codec = codec
        self.heAACv2Quality = heAACv2Quality
        self.encoderSession = AudioCodecSessionFactory.makeEncoderSession(
            preferred: [codec, .pcm16],
            heAACv2Quality: heAACv2Quality
        )
        self.encoderSessionHEAACv2Quality = codec == .heAACv2 ? heAACv2Quality : nil
    }

    mutating func makeEnvelope(for packet: OutboundAudioPacket, sentAt: TimeInterval = Date().timeIntervalSince1970) -> AudioPacketEnvelope {
        if encoderSession.codec != codec
            || (codec == .heAACv2 && encoderSessionHEAACv2Quality != heAACv2Quality) {
            encoderSession = AudioCodecSessionFactory.makeEncoderSession(
                preferred: [codec, .pcm16],
                heAACv2Quality: heAACv2Quality
            )
            encoderSessionHEAACv2Quality = codec == .heAACv2 ? heAACv2Quality : nil
        }

        let envelope: AudioPacketEnvelope
        switch packet {
        case .voice(let frameID, let samples):
            envelope = makeVoiceEnvelope(frameID: frameID, samples: samples, sentAt: sentAt)
        case .keepalive:
            envelope = AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: nextSequenceNumber,
                sentAt: sentAt,
                packet: .keepalive,
                codec: encoderSession.codec,
                heAACv2Quality: heAACv2Quality
            )
        }

        nextSequenceNumber += 1
        return envelope
    }

    private mutating func makeVoiceEnvelope(frameID: Int, samples: [Float], sentAt: TimeInterval) -> AudioPacketEnvelope {
        do {
            let payload = try encoderSession.encodeFrame(samples)
            guard !(payload.isEmpty && encoderSession.codec == .heAACv2) else {
                return AudioPacketEnvelope(
                    groupID: groupID,
                    streamID: streamID,
                    sequenceNumber: nextSequenceNumber,
                    sentAt: sentAt,
                    packet: .keepalive,
                    codec: encoderSession.codec,
                    heAACv2Quality: heAACv2Quality
                )
            }

            let encodedVoice = EncodedVoicePacket(
                frameID: frameID,
                codec: encoderSession.codec,
                payload: payload
            )
            return AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: nextSequenceNumber,
                sentAt: sentAt,
                encodedVoice: encodedVoice
            )
        } catch AudioCodecError.codecUnavailable where encoderSession.codec != .pcm16 {
            codec = .pcm16
            encoderSession = AudioCodecSessionFactory.makeEncoderSession(
                preferred: [.pcm16],
                heAACv2Quality: heAACv2Quality
            )
            encoderSessionHEAACv2Quality = nil
            return makeVoiceEnvelope(frameID: frameID, samples: samples, sentAt: sentAt)
        } catch {
            return AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: nextSequenceNumber,
                sentAt: sentAt,
                packet: .keepalive,
                codec: encoderSession.codec,
                heAACv2Quality: heAACv2Quality
            )
        }
    }
}

struct AudioTransmissionController {
    static let defaultVoiceActivityThreshold = VoiceActivityDetector.defaultThreshold

    private struct CapturedFrame {
        let frameID: Int
        let samples: [Float]
    }

    private var detector: VoiceActivityDetector
    private let preRollLimit: Int
    private let keepaliveIntervalFrames: Int
    private var preRoll: [CapturedFrame] = []
    private var framesSinceKeepalive = 0
    private var wasSendingVoice = false

    init(
        detector: VoiceActivityDetector = VoiceActivityDetector(threshold: Self.defaultVoiceActivityThreshold),
        preRollLimit: Int = 20,
        keepaliveIntervalFrames: Int = 50
    ) {
        self.detector = detector
        self.preRollLimit = preRollLimit
        self.keepaliveIntervalFrames = keepaliveIntervalFrames
    }

    mutating func process(frameID: Int, level: Float, samples: [Float] = []) -> [OutboundAudioPacket] {
        let state = detector.process(level: level)
        var packets: [OutboundAudioPacket] = []

        if state == .talking || state == .release {
            if !wasSendingVoice {
                packets.append(contentsOf: preRoll.map { .voice(frameID: $0.frameID, samples: $0.samples) })
            }
            packets.append(.voice(frameID: frameID, samples: samples))
            framesSinceKeepalive = 0
            wasSendingVoice = true
        } else {
            appendToPreRoll(frameID: frameID, samples: samples)
            framesSinceKeepalive += 1
            wasSendingVoice = false

            if framesSinceKeepalive >= keepaliveIntervalFrames {
                packets.append(.keepalive)
                framesSinceKeepalive = 0
            }
        }

        return packets
    }

    mutating func setVoiceActivityThreshold(_ threshold: Float) {
        detector.setThreshold(threshold)
    }

    private mutating func appendToPreRoll(frameID: Int, samples: [Float]) {
        preRoll.append(CapturedFrame(frameID: frameID, samples: samples))
        if preRoll.count > preRollLimit {
            preRoll.removeFirst(preRoll.count - preRollLimit)
        }
    }
}

@MainActor
@Observable
final class IntercomViewModel {
    private static let pendingMemberPrefix = "pending-"
    private static let pendingInviteMemberPrefix = "invite-pending-"

    private(set) var groups: [IntercomGroup]
    private(set) var selectedGroup: IntercomGroup?
    private(set) var connectionState: CallConnectionState = .idle
    private(set) var isMuted = false
    private(set) var isVoiceActive = false
    private(set) var isAudioReady = false
    private(set) var audioErrorMessage: String?
    private(set) var selectedInputPort: AudioPortInfo = .systemDefault
    private(set) var selectedOutputPort: AudioPortInfo = .systemDefault
    private(set) var voiceActivityDetectionThreshold: Float = AudioTransmissionController.defaultVoiceActivityThreshold
    private(set) var isSoundIsolationEnabled = false
    private(set) var audioCheckCodecMode: AudioCheckCodecMode = .direct
    private(set) var preferredTransmitCodec: AudioCodecIdentifier = .pcm16
    private(set) var heAACv2Quality: HEAACv2Quality = .medium

    var availableInputPorts: [AudioPortInfo] { audioSessionManager.availableInputPorts }
    var availableOutputPorts: [AudioPortInfo] { audioSessionManager.availableOutputPorts }
    private(set) var audioCheckPhase: AudioCheckPhase = .idle
    private(set) var audioCheckInputLevel: Float = 0
    private(set) var audioCheckInputPeakLevel: Float = 0
    private(set) var audioCheckOutputLevel: Float = 0
    private(set) var audioCheckOutputPeakLevel: Float = 0
    private(set) var audioCheckStatusMessage = "Audio check idle"
    private(set) var sentVoicePacketCount = 0
    private(set) var receivedVoicePacketCount = 0
    private(set) var playedAudioFrameCount = 0
    private(set) var connectedPeerIDs: [String] = []
    private(set) var authenticatedPeerIDs: [String] = []
    private(set) var localNetworkStatus: LocalNetworkStatus = .idle
    private(set) var lastLocalNetworkPeerID: String?
    private(set) var lastLocalNetworkEventAt: TimeInterval?
    private(set) var lastReceivedAudioAt: TimeInterval?
    private(set) var droppedAudioPacketCount = 0
    private(set) var jitterQueuedFrameCount = 0
    private(set) var inviteStatusMessage: String?
    private(set) var uiEventRevision: UInt64 = 0
    private let localTransport: Transport
    private let internetTransport: Transport
    private let audioSessionManager: AudioSessionManager
    private let audioInputMonitor: AudioInputMonitoring
    private let callTicker: CallTicking
    private let audioFramePlayer: AudioFramePlaying
    private let credentialStore: GroupCredentialStoring
    private let credentialProvider: any GroupCredentialProviding
    private let groupStore: GroupStoring
    private let localMemberIdentity: LocalMemberIdentity
    private let remoteTalkerTimeout: TimeInterval
    private var audioTransmissionController: AudioTransmissionController
    private var jitterBuffer: JitterBuffer
    private var remoteVoiceReceivedAt: [String: TimeInterval] = [:]
    private var localVoicePeakWindow = VoicePeakWindow()
    private var remoteVoicePeakWindows: [String: VoicePeakWindow] = [:]
    private var audioCheckInputPeakWindow = VoicePeakWindow()
    private var audioCheckOutputPeakWindow = VoicePeakWindow()
    private var audioCheckRecordedSamples: [Float] = []
    private var audioCheckTask: Task<Void, Never>?
    private var audioCheckOwnsAudioPipeline = false
    private var isLocalStandbyOnly = false
    private var nextAudioFrameID = 1
    private var routeCoordinator = RouteCoordinator()

    static func makeForCurrentProcess() -> IntercomViewModel {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let defaults = UserDefaults(suiteName: "RideIntercomUITests") ?? .standard
            if ProcessInfo.processInfo.arguments.contains("--reset-ui-testing-data") {
                defaults.removePersistentDomain(forName: "RideIntercomUITests")
            }
            return CurrentProcessRuntimeFactory.makeUITesting(defaults: defaults)
        }

        return CurrentProcessRuntimeFactory.makeLive()
    }

    init(
        groups: [IntercomGroup]? = nil,
        localTransport: Transport? = nil,
        internetTransport: Transport? = nil,
        credentialStore: GroupCredentialStoring? = nil,
        groupStore: GroupStoring? = nil,
        localMemberIdentityStore: LocalMemberIdentityStoring? = nil,
        audioSessionManager: AudioSessionManager? = nil,
        audioInputMonitor: AudioInputMonitoring? = nil,
        audioTransmissionController: AudioTransmissionController? = nil,
        callTicker: CallTicking? = nil,
        audioFramePlayer: AudioFramePlaying? = nil,
        jitterBuffer: JitterBuffer? = nil,
        remoteTalkerTimeout: TimeInterval = 0.6
    ) {
        let groupStore = groupStore ?? InMemoryGroupStore()
        let storedGroups = groupStore.loadGroups()
        self.groups = groups ?? storedGroups
        self.localTransport = localTransport ?? LocalTransport()
        self.internetTransport = internetTransport ?? InternetTransport()
        self.audioSessionManager = audioSessionManager ?? AudioSessionManager()
        self.audioInputMonitor = audioInputMonitor ?? AudioInputMonitorFactory.makeDefault()
        let initialVoiceActivityDetectionThreshold = AudioTransmissionController.defaultVoiceActivityThreshold
        self.voiceActivityDetectionThreshold = initialVoiceActivityDetectionThreshold
        self.audioTransmissionController = audioTransmissionController ?? AudioTransmissionController()
        self.callTicker = callTicker ?? RepeatingCallTicker()
        self.audioFramePlayer = audioFramePlayer ?? AudioFramePlayerFactory.makeDefault()
        self.credentialStore = credentialStore ?? InMemoryGroupCredentialStore()
        self.credentialProvider = DefaultGroupCredentialProvider()
        self.groupStore = groupStore
        self.localMemberIdentity = (localMemberIdentityStore ?? InMemoryLocalMemberIdentityStore()).loadOrCreate()
        self.jitterBuffer = jitterBuffer ?? JitterBuffer()
        self.remoteTalkerTimeout = remoteTalkerTimeout
        self.audioTransmissionController.setVoiceActivityThreshold(initialVoiceActivityDetectionThreshold)

        self.localTransport.onEvent = { [weak self] event in
            self?.handleTransportEvent(event, route: .local)
        }
        self.internetTransport.onEvent = { [weak self] event in
            self?.handleTransportEvent(event, route: .internet)
        }
        self.audioInputMonitor.onLevel = { [weak self] level in
            self?.handleMicrophoneLevel(level)
        }
        self.audioInputMonitor.onSamples = { [weak self] samples in
            self?.handleMicrophoneSamples(samples)
        }
        self.callTicker.onTick = { [weak self] now in
            self?.handleCallTick(now: now)
        }
        self.isSoundIsolationEnabled = self.audioInputMonitor.isSoundIsolationEnabled
        self.localTransport.setPreferredAudioCodec(preferredTransmitCodec)
        self.localTransport.setHEAACv2Quality(heAACv2Quality)
        self.internetTransport.setPreferredAudioCodec(preferredTransmitCodec)
        self.internetTransport.setHEAACv2Quality(heAACv2Quality)
    }

    var selectedGroupSlots: [GroupMember?] {
        selectedGroup?.members.map(Optional.some) ?? []
    }

    var connectionLabel: String {
        connectionState.label
    }

    var localTransportDebugTypeName: String {
        String(describing: type(of: localTransport))
    }

    var diagnosticsSnapshot: DiagnosticsSnapshot {
        DiagnosticsSnapshotBuilder.make(
            sentVoicePacketCount: sentVoicePacketCount,
            receivedVoicePacketCount: receivedVoicePacketCount,
            playedAudioFrameCount: playedAudioFrameCount,
            connectedPeerCount: connectedPeerCount,
            authenticatedPeerCount: authenticatedPeerCount,
            localMemberID: localMemberIdentity.memberID,
            transportTypeName: localTransportDebugTypeName,
            selectedGroupID: selectedGroup?.id,
            selectedGroupMemberCount: selectedGroup?.members.count ?? 0,
            groupHashPrefix: selectedGroup.map { String(credential(for: $0).groupHash.prefix(8)) },
            inviteStatusMessage: inviteStatusMessage,
            hasInviteURL: selectedGroupInviteURL != nil,
            localNetworkStatus: localNetworkStatus,
            lastLocalNetworkPeerID: lastLocalNetworkPeerID,
            lastLocalNetworkEventAt: lastLocalNetworkEventAt,
            lastReceivedAudioAt: lastReceivedAudioAt,
            droppedAudioPacketCount: droppedAudioPacketCount,
            jitterQueuedFrameCount: jitterQueuedFrameCount
        )
    }

    var transportDebugSummary: String {
        diagnosticsSnapshot.transportSummary
    }

    var callPresenceLabel: String {
        if connectionState == .idle, localNetworkStatus != .idle {
            return "Waiting for Riders"
        }
        return connectionLabel
    }

    var canDisconnectCall: Bool {
        connectionState != .idle || isAudioReady || !authenticatedPeerIDs.isEmpty
    }

    var routeLabel: String {
        switch connectionState {
        case .localConnected, .localConnecting:
            TransportRoute.local.rawValue
        case .internetConnected, .internetConnecting:
            TransportRoute.internet.rawValue
        case .idle, .reconnectingOffline:
            "Offline"
        }
    }

    var ownerName: String {
        guard let members = selectedGroup?.members,
              let ownerID = OwnerElection.owner(from: members.map(\.id)),
              let owner = members.first(where: { $0.id == ownerID }) else {
            return "Unknown"
        }
        return owner.displayName
    }

    var audioDebugSummary: String {
        diagnosticsSnapshot.audio.summary
    }

    var audioInputProcessingSummary: String {
        let isolationLabel: String
        if audioInputMonitor.supportsSoundIsolation {
            isolationLabel = isSoundIsolationEnabled ? "ON" : "OFF"
        } else {
            isolationLabel = "N/A"
        }
        return String(format: "VOICE ACTIVITY DETECTION THRESHOLD %.2f / SOUND ISOLATION %@", voiceActivityDetectionThreshold, isolationLabel)
    }

    var supportsSoundIsolation: Bool {
        audioInputMonitor.supportsSoundIsolation
    }

    var audioCheckSummary: String {
        let inputPercent = VoiceLevelIndicatorState(level: audioCheckInputLevel, peakLevel: audioCheckInputPeakLevel).levelPercent
        let outputPercent = VoiceLevelIndicatorState(level: audioCheckOutputLevel, peakLevel: audioCheckOutputPeakLevel).levelPercent
        return "\(audioCheckPhase.rawValue) / MIC \(inputPercent) / OUT \(outputPercent)"
    }

    var connectedPeerCount: Int {
        connectedPeerIDs.count
    }

    var connectionDebugSummary: String {
        diagnosticsSnapshot.connectionSummary
    }

    var authenticatedPeerCount: Int {
        authenticatedPeerIDs.count
    }

    var authenticationDebugSummary: String {
        diagnosticsSnapshot.authenticationSummary
    }

    var localMemberDebugSummary: String {
        diagnosticsSnapshot.localMemberSummary
    }

    var selectedGroupDebugSummary: String {
        diagnosticsSnapshot.selectedGroupSummary
    }

    var groupHashDebugSummary: String {
        diagnosticsSnapshot.groupHashSummary
    }

    var inviteDebugSummary: String {
        diagnosticsSnapshot.inviteSummary
    }

    var realDeviceCallDebugSummary: String {
        realDeviceCallDebugSummary(now: Date().timeIntervalSince1970)
    }

    func realDeviceCallDebugSummary(now: TimeInterval) -> String {
        diagnosticsSnapshot.realDeviceCallSummary(connectionLabel: connectionLabel, isAudioReady: isAudioReady, now: now)
    }

    var localNetworkDebugSummary: String {
        localNetworkDebugSummary(now: Date().timeIntervalSince1970)
    }

    func localNetworkDebugSummary(now: TimeInterval) -> String {
        diagnosticsSnapshot.localNetwork.summary(now: now)
    }

    var receptionDebugSummary: String {
        receptionDebugSummary(now: Date().timeIntervalSince1970)
    }

    var selectedGroupInviteURL: URL? {
        guard let selectedGroup,
              let inviterMemberID = inviterMemberID(for: selectedGroup) else { return nil }

        let credential = credential(for: selectedGroup)
        let token = try? GroupInviteToken.make(
            groupID: selectedGroup.id,
            groupName: selectedGroup.name,
            groupSecret: credential.secret,
            inviterMemberID: inviterMemberID,
            expiresAt: Date().timeIntervalSince1970 + 7 * 24 * 60 * 60
        )
        return token.flatMap { try? GroupInviteTokenCodec.joinURL(for: $0) }
    }

    func receptionDebugSummary(now: TimeInterval) -> String {
        diagnosticsSnapshot.reception.summary(now: now)
    }

    func selectGroup(_ group: IntercomGroup) {
        if selectedGroup?.id == group.id, hasActiveConversationConnection {
            return
        }

        localTransport.disconnect()
        selectedGroup = group.withMemberAuthenticationState(.open)
        connectionState = .idle
        isVoiceActive = false
        connectedPeerIDs = []
        authenticatedPeerIDs = []
        localNetworkStatus = .idle
        lastLocalNetworkPeerID = nil
        lastLocalNetworkEventAt = nil
        inviteStatusMessage = nil
        resetVoiceLevelWindows()
        resetAudioDebugCounters()
        startLocalStandby()
    }

    private var hasActiveConversationConnection: Bool {
        isAudioReady || connectionState == .localConnected || connectionState == .internetConnected || !authenticatedPeerIDs.isEmpty
    }

    func deleteGroup(_ groupID: UUID) {
        if selectedGroup?.id == groupID {
            disconnect()
            selectedGroup = nil
        }
        groups.removeAll { $0.id == groupID }
        persistGroups()
    }

    func canRemoveMember(_ memberID: String) -> Bool {
        memberID != localMemberIdentity.memberID
    }

    func removeMember(_ memberID: String, from groupID: UUID) {
        guard canRemoveMember(memberID),
              let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }

        groups[groupIndex].members.removeAll { $0.id == memberID }
        connectedPeerIDs.removeAll { $0 == memberID }
        authenticatedPeerIDs.removeAll { $0 == memberID }
        remoteVoiceReceivedAt.removeValue(forKey: memberID)
        remoteVoicePeakWindows.removeValue(forKey: memberID)

        if selectedGroup?.id == groupID {
            selectedGroup = groups[groupIndex]
        }
        persistGroups()
    }

    func createTrailGroup() {
        let groupID = UUID()
        let newGroup = try? IntercomGroup(
            id: groupID,
            name: "Trail Group",
            members: [
                GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName)
            ]
        )

        guard let newGroup else { return }
        groups.insert(newGroup, at: 0)
        persistGroups()
        selectGroup(newGroup)
    }

    func addPendingMember(displayName: String? = nil) {
        guard var group = selectedGroup,
              group.members.count < IntercomGroup.maximumMemberCount else { return }

        let nextNumber = group.members.count
        let memberID = "\(Self.pendingMemberPrefix)\(group.id.uuidString.prefix(8).lowercased())-\(nextNumber)"
        let name = displayName ?? "Rider \(nextNumber)"
        group.members.append(GroupMember(id: memberID, displayName: name))
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    func reserveInviteMemberSlot(displayName: String? = nil) {
        guard var group = selectedGroup,
              group.members.count < IntercomGroup.maximumMemberCount else { return }

        let nextNumber = group.members.count
        let memberID = "\(Self.pendingInviteMemberPrefix)\(group.id.uuidString.prefix(8).lowercased())-\(nextNumber)-\(UUID().uuidString.prefix(8).lowercased())"
        let name = displayName ?? "Invited Rider \(nextNumber)"
        group.members.append(
            GroupMember(
                id: memberID,
                displayName: name,
                authenticationState: .pending,
                connectionState: .connecting
            )
        )
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    func acceptInviteURL(_ url: URL, now: TimeInterval = Date().timeIntervalSince1970) throws {
        let token = try GroupInviteTokenCodec.decodeJoinURL(url)
        guard !token.isExpired(now: now) else {
            throw GroupInviteTokenError.expired
        }
        credentialStore.save(GroupAccessCredential(groupID: token.groupID, secret: token.groupSecret))

        let group = try IntercomGroup(
            id: token.groupID,
            name: token.groupName,
            members: [
                GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName),
                GroupMember(id: token.inviterMemberID, displayName: "Inviter")
            ]
        )

        if let existingIndex = groups.firstIndex(where: { $0.id == group.id }) {
            groups[existingIndex] = group
        } else {
            groups.insert(group, at: 0)
        }
        persistGroups()
        selectGroup(group)
        inviteStatusMessage = "JOINED \(token.groupName)"
    }

    func connectLocal() {
        guard let selectedGroup else { return }

        guard startAudioPipelineIfNeeded() else { return }
        routeCoordinator.connectLocal()
        isLocalStandbyOnly = false
        connectionState = connectedPeerIDs.isEmpty ? .localConnecting : .localConnected
        markMembers(connectionState == .localConnected ? .connected : .connecting)
        if localNetworkStatus == .idle || localNetworkStatus == .unavailable {
            localTransport.connect(group: groupForTransport(selectedGroup))
        }
    }

    private func startActiveCallAfterAuthenticatedPeer(route: TransportRoute) {
        guard isLocalStandbyOnly,
              !authenticatedPeerIDs.isEmpty,
              startAudioPipelineIfNeeded() else { return }

        isLocalStandbyOnly = false
        if route == .local {
            routeCoordinator.evaluateLocalProbe(defaultRouteProbeMetrics())
        } else {
            routeCoordinator.internetDidConnect()
        }
        connectionState = routeCoordinator.state
        markConnectedMembers(peerIDs: connectedPeerIDs)
    }

    private func defaultRouteProbeMetrics() -> RouteProbeMetrics {
        let expectedPeerCount = max(connectedPeerIDs.count, authenticatedPeerIDs.count)
        return RouteProbeMetrics(
            rttMilliseconds: 0,
            jitterMilliseconds: 0,
            packetLossRate: 0,
            peerCount: connectedPeerIDs.count,
            expectedPeerCount: expectedPeerCount
        )
    }

    private func startAudioPipelineIfNeeded() -> Bool {
        if isAudioReady {
            return true
        }

        do {
            try audioSessionManager.configureForIntercom()
            try audioInputMonitor.start()
            try audioFramePlayer.start()
            callTicker.start()
            isAudioReady = true
            audioErrorMessage = nil
            return true
        } catch {
            isAudioReady = false
            audioErrorMessage = audioSetupMessage(for: error)
            return false
        }
    }

    private func startLocalStandby() {
        guard let selectedGroup,
              !isAudioReady,
              localNetworkStatus == .idle else { return }

        isLocalStandbyOnly = true
        localTransport.connect(group: groupForTransport(selectedGroup))
    }

    private func audioSetupMessage(for error: Error) -> String {
        guard let audioInputError = error as? AudioInputMonitorError else {
            return "Audio setup failed"
        }

        switch audioInputError {
        case .microphonePermissionRequestPending:
            return "Microphone permission requested. Allow access, then connect again."
        case .microphonePermissionDenied:
            return "Microphone access is off. Enable it in Privacy & Security, then connect again."
        }
    }

    func disconnect() {
        audioCheckTask?.cancel()
        localTransport.disconnect()
        internetTransport.disconnect()
        audioInputMonitor.stop()
        audioFramePlayer.stop()
        callTicker.stop()
        try? audioSessionManager.deactivate()
        connectionState = .idle
        isVoiceActive = false
        isAudioReady = false
        remoteVoiceReceivedAt.removeAll()
        resetVoiceLevelWindows()
        connectedPeerIDs = []
        authenticatedPeerIDs = []
        isLocalStandbyOnly = false
        routeCoordinator.disconnect()
        localNetworkStatus = .idle
        lastLocalNetworkPeerID = nil
        lastLocalNetworkEventAt = nil
        lastReceivedAudioAt = nil
        droppedAudioPacketCount = 0
        jitterQueuedFrameCount = 0
        resetAudioDebugCounters()
        markMembers(.offline)
    }

    func simulateLocalFailure(internetAvailable: Bool = true) {
        if let localTransport = localTransport as? LocalTransport {
            localTransport.simulateLinkFailure(internetAvailable: internetAvailable)
        } else {
            handleTransportEvent(.linkFailed(internetAvailable: internetAvailable), route: .local)
        }
    }

    func toggleMute() {
        isMuted.toggle()
        guard var group = selectedGroup, !group.members.isEmpty else { return }
        group.members[0].isMuted = isMuted
        if isMuted {
            group.members[0].isTalking = false
            group.members[0].voiceLevel = 0
            group.members[0].voicePeakLevel = 0
            localVoicePeakWindow = VoicePeakWindow()
        }
        selectedGroup = group
        replaceSelectedGroup(group)
        activeTransport?.sendControl(.peerMuteState(isMuted: isMuted))
    }

    func toggleVoiceActivity() {
        setVoiceActive(!isVoiceActive)
    }

    func processMicrophoneLevelForDebug(_ level: Float) {
        handleMicrophoneLevel(level)
    }

    func setAudioCheckCodecMode(_ mode: AudioCheckCodecMode) {
        audioCheckCodecMode = mode
    }

    func setPreferredTransmitCodec(_ codec: AudioCodecIdentifier) {
        preferredTransmitCodec = codec
        localTransport.setPreferredAudioCodec(codec)
        internetTransport.setPreferredAudioCodec(codec)
    }

    func setHEAACv2Quality(_ quality: HEAACv2Quality) {
        heAACv2Quality = quality
        localTransport.setHEAACv2Quality(quality)
        internetTransport.setHEAACv2Quality(quality)
    }

    func setVoiceActivityDetectionThreshold(_ value: Float) {
        let clamped = min(VoiceActivityDetector.maxThreshold, max(VoiceActivityDetector.minThreshold, value))
        voiceActivityDetectionThreshold = clamped
        audioTransmissionController.setVoiceActivityThreshold(clamped)
    }

    func setSoundIsolationEnabled(_ enabled: Bool) {
        guard audioInputMonitor.supportsSoundIsolation else {
            isSoundIsolationEnabled = false
            return
        }
        audioInputMonitor.setSoundIsolationEnabled(enabled)
        isSoundIsolationEnabled = audioInputMonitor.isSoundIsolationEnabled
    }

    func setInputPort(_ port: AudioPortInfo) {
        do {
            try audioSessionManager.setInputPort(port)
            selectedInputPort = port
            audioErrorMessage = nil
        } catch {
            audioErrorMessage = "Audio input device change failed"
        }
    }

    func setOutputPort(_ port: AudioPortInfo) {
        do {
            try audioSessionManager.setOutputPort(port)
            selectedOutputPort = port
            audioErrorMessage = nil
        } catch {
            audioErrorMessage = "Audio output device change failed"
        }
    }

    func startAudioCheck(recordDuration: Duration = .seconds(5), playbackDuration: Duration = .seconds(5)) {
        guard audioCheckPhase != .recording, audioCheckPhase != .playing else { return }

        audioCheckTask?.cancel()
        resetAudioCheckMeters()
        audioCheckRecordedSamples = []
        audioCheckPhase = .recording
        audioCheckStatusMessage = "Recording microphone for 5 seconds"
        audioCheckOwnsAudioPipeline = !isAudioReady

        do {
            if audioCheckOwnsAudioPipeline {
                try audioSessionManager.configureForAudioCheck()
            }
            try audioInputMonitor.start()
            try audioFramePlayer.start()
        } catch {
            audioCheckPhase = .failed
            audioCheckStatusMessage = audioSetupMessage(for: error)
            if audioCheckOwnsAudioPipeline {
                audioInputMonitor.stop()
                audioFramePlayer.stop()
                try? audioSessionManager.deactivate()
            }
            return
        }

        audioCheckTask = Task { [weak self] in
            try? await Task.sleep(for: recordDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishAudioCheckRecording(playbackDuration: playbackDuration)
            }
        }
    }

    func finishAudioCheckRecordingForDebug(playbackDuration: Duration = .seconds(5)) {
        finishAudioCheckRecording(playbackDuration: playbackDuration)
    }

    func expireRemoteTalkers(now: TimeInterval = Date().timeIntervalSince1970) {
        for (peerID, lastVoiceAt) in remoteVoiceReceivedAt where now - lastVoiceAt >= remoteTalkerTimeout {
            setRemotePeer(peerID, isTalking: false)
            remoteVoiceReceivedAt.removeValue(forKey: peerID)
        }
    }

    private func handleCallTick(now: TimeInterval) {
        expireRemoteTalkers(now: now)
        drainJitterBuffer(now: now)
    }

    private func drainJitterBuffer(now: TimeInterval) {
        let drainResult = RemoteAudioPipelineService.drainReadyAudioFrames(now: now, jitterBuffer: &jitterBuffer)
        playedAudioFrameCount += drainResult.readyFrames.count
        droppedAudioPacketCount = drainResult.droppedAudioPacketCount
        jitterQueuedFrameCount = drainResult.jitterQueuedFrameCount
        markPlayedAudioFrames(drainResult.readyFrames)
        audioFramePlayer.play(drainResult.readyFrames)
    }

    private func handleMicrophoneLevel(_ level: Float) {
        processMicrophoneFrame(level: level, samples: [])
    }

    private func handleMicrophoneSamples(_ samples: [Float]) {
        processMicrophoneFrame(level: AudioLevelMeter.rmsLevel(samples: samples), samples: samples)
    }

    private func processMicrophoneFrame(level: Float, samples: [Float]) {
        processAudioCheckInput(level: level, samples: samples)

        guard !isMuted else {
            setLocalVoiceLevel(0)
            setVoiceActive(false)
            return
        }

        let frameID = nextAudioFrameID
        nextAudioFrameID += 1

        setLocalVoiceLevel(level)
        let result = HandleMicrophoneInputUseCase.execute(
            controller: &audioTransmissionController,
            frameID: frameID,
            level: level,
            samples: samples
        )
        for packet in result.packets {
            send(packet)
        }

        setVoiceActive(result.isVoiceActive)
    }

    private func processAudioCheckInput(level: Float, samples: [Float]) {
        guard audioCheckPhase == .recording else { return }

        let clampedLevel = min(1, max(0, level))
        audioCheckInputLevel = clampedLevel
        audioCheckInputPeakLevel = audioCheckInputPeakWindow.record(clampedLevel)
        audioCheckRecordedSamples.append(contentsOf: samples)
    }

    private func finishAudioCheckRecording(playbackDuration: Duration) {
        guard audioCheckPhase == .recording else { return }

        let recordedSamples = audioCheckRecordedSamples
        guard !recordedSamples.isEmpty else {
            audioCheckPhase = .failed
            audioCheckStatusMessage = "No microphone samples captured"
            stopAudioCheckOwnedPipeline()
            return
        }

        let playbackSamples: [Float]
        switch audioCheckCodecMode {
        case .direct:
            playbackSamples = recordedSamples
        case .pcm16:
            playbackSamples = (try? PCMAudioCodec.decode(PCMAudioCodec.encode(recordedSamples))) ?? recordedSamples
        }

        let outputLevel = AudioLevelMeter.rmsLevel(samples: playbackSamples)
        audioCheckOutputLevel = min(1, max(0, outputLevel))
        audioCheckOutputPeakLevel = audioCheckOutputPeakWindow.record(audioCheckOutputLevel)
        audioCheckPhase = .playing
        audioCheckStatusMessage = "Playing recorded audio for 5 seconds"
        audioFramePlayer.play(JitterBufferedAudioFrame(
            peerID: "audio-check",
            streamID: UUID(),
            sequenceNumber: 1,
            frameID: 1,
            samples: playbackSamples
        ))

        audioCheckTask?.cancel()
        audioCheckTask = Task { [weak self] in
            try? await Task.sleep(for: playbackDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.completeAudioCheckPlayback()
            }
        }
    }

    private func completeAudioCheckPlayback() {
        guard audioCheckPhase == .playing else { return }

        audioCheckPhase = .completed
        audioCheckStatusMessage = "Audio check complete"
        audioCheckOutputLevel = 0
        stopAudioCheckOwnedPipeline()
    }

    private func stopAudioCheckOwnedPipeline() {
        guard audioCheckOwnsAudioPipeline else { return }

        audioInputMonitor.stop()
        audioFramePlayer.stop()
        try? audioSessionManager.deactivate()
        audioCheckOwnsAudioPipeline = false
    }

    private func resetAudioCheckMeters() {
        audioCheckInputLevel = 0
        audioCheckInputPeakLevel = 0
        audioCheckOutputLevel = 0
        audioCheckOutputPeakLevel = 0
        audioCheckInputPeakWindow = VoicePeakWindow()
        audioCheckOutputPeakWindow = VoicePeakWindow()
    }

    private func send(_ packet: OutboundAudioPacket) {
        switch packet {
        case .voice:
            sentVoicePacketCount += 1
            setLocalActiveCodec(preferredTransmitCodec)
            activeTransport?.sendAudioFrame(packet)
        case .keepalive:
            activeTransport?.sendControl(.keepalive)
        }
    }

    private var activeTransport: Transport? {
        switch connectionState {
        case .localConnected, .localConnecting:
            localTransport
        case .internetConnected, .internetConnecting:
            internetTransport
        case .idle, .reconnectingOffline:
            nil
        }
    }

    private func setVoiceActive(_ isActive: Bool) {
        isVoiceActive = isActive
        guard var group = selectedGroup, !group.members.isEmpty else { return }
        group.members[0].isTalking = isActive
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    private func handleTransportEvent(_ event: TransportEvent, route: TransportRoute) {
        uiEventRevision &+= 1
        switch event {
        case .localNetworkStatus(let event):
            localNetworkStatus = event.status
            lastLocalNetworkPeerID = event.peerID
            lastLocalNetworkEventAt = event.occurredAt
        case .connected(let peerIDs):
            connectedPeerIDs = peerIDs
            addDiscoveredMembersIfNeeded(peerIDs: peerIDs)
            removeDisconnectedAuthenticatedPeers(connectedPeerIDs: peerIDs)
            if route == .local {
                localNetworkStatus = .connected
                routeCoordinator.connectLocal()
            } else {
                routeCoordinator.internetDidConnect()
            }
            if isLocalStandbyOnly, route == .local {
                connectionState = .idle
            } else {
                connectionState = routeCoordinator.state
            }
            markConnectedMembers(peerIDs: peerIDs)
        case .authenticated(let peerIDs):
            let authenticatedPeerIDSet = Set(peerIDs)
            authenticatedPeerIDs = Array(authenticatedPeerIDSet).sorted()
            connectedPeerIDs = Array(Set(connectedPeerIDs).union(authenticatedPeerIDSet)).sorted()
            addDiscoveredMembersIfNeeded(peerIDs: authenticatedPeerIDs)
            if !isLocalStandbyOnly {
                if route == .local {
                    routeCoordinator.evaluateLocalProbe(defaultRouteProbeMetrics())
                } else {
                    routeCoordinator.internetDidConnect()
                }
                connectionState = routeCoordinator.state
            }
            markConnectedMembers(peerIDs: connectedPeerIDs)
            startActiveCallAfterAuthenticatedPeer(route: route)
        case .remotePeerMuteState(let peerID, let isMuted):
            setRemotePeerMuteState(peerID: peerID, isMuted: isMuted)
        case .disconnected:
            connectedPeerIDs = []
            authenticatedPeerIDs = []
            routeCoordinator.disconnect()
            if route == .local {
                localNetworkStatus = .idle
            }
            connectionState = .idle
            isVoiceActive = false
            markMembers(.offline)
        case .linkFailed(let internetAvailable):
            guard route == .local else { return }
            routeCoordinator.localLinkDidFail(internetAvailable: internetAvailable)
            if internetAvailable, let selectedGroup {
                connectionState = routeCoordinator.state
                markMembers(.connecting)
                internetTransport.connect(group: selectedGroup)
            } else {
                connectedPeerIDs = []
                authenticatedPeerIDs = []
                localNetworkStatus = .unavailable
                connectionState = routeCoordinator.state
                markMembers(.connecting)
            }
        case .receivedPacket(let packet):
            handleReceivedPacket(packet)
        }
    }

    private func handleReceivedPacket(_ packet: ReceivedAudioPacket) {
        guard let receivedAt = RemoteAudioPacketAcceptanceService.acceptedReceiveTimestamp(
            peerID: packet.peerID,
            authenticatedPeerIDs: authenticatedPeerIDs,
            packetSentAt: packet.envelope.sentAt
        ) else {
            return
        }
        if let codec = packet.envelope.encodedVoice?.codec {
            setRemotePeerCodec(packet.peerID, codec: codec)
        }

        guard let ingressResult = RemoteAudioPipelineService.processReceivedPacket(
            packet,
            isAuthorized: true,
            receivedAt: receivedAt,
            jitterBuffer: &jitterBuffer
        ) else {
            return
        }

        receivedVoicePacketCount += ingressResult.receivedVoicePacketCountIncrement
        if let lastReceivedAudioAt = ingressResult.lastReceivedAudioAt {
            self.lastReceivedAudioAt = lastReceivedAudioAt
            remoteVoiceReceivedAt[packet.peerID] = lastReceivedAudioAt
        }
        droppedAudioPacketCount = ingressResult.droppedAudioPacketCount
        jitterQueuedFrameCount = ingressResult.jitterQueuedFrameCount
        if let remoteVoiceLevel = ingressResult.remoteVoiceLevel {
            applyReceivedVoiceMemberState(peerID: packet.peerID, voiceLevel: remoteVoiceLevel)
        }
    }

    private func applyReceivedVoiceMemberState(peerID: String, voiceLevel: Float) {
        guard var group = selectedGroup else { return }

        group = RemoteMemberAudioStateService.applyReceivedVoice(
            to: group,
            peerID: peerID,
            voiceLevel: voiceLevel,
            peakWindows: &remoteVoicePeakWindows
        )
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    private func resetAudioDebugCounters() {
        sentVoicePacketCount = 0
        receivedVoicePacketCount = 0
        playedAudioFrameCount = 0
        lastReceivedAudioAt = nil
        droppedAudioPacketCount = 0
        jitterQueuedFrameCount = 0
    }

    private func resetVoiceLevelWindows() {
        localVoicePeakWindow = VoicePeakWindow()
        remoteVoicePeakWindows.removeAll()
    }

    private func setLocalVoiceLevel(_ level: Float) {
        guard var group = selectedGroup, !group.members.isEmpty else { return }

        let clampedLevel = min(1, max(0, level))
        group.members[0].voiceLevel = clampedLevel
        group.members[0].voicePeakLevel = localVoicePeakWindow.record(clampedLevel)
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    private func setRemotePeer(_ peerID: String, isTalking: Bool, voiceLevel: Float? = nil) {
        guard var group = selectedGroup,
              let memberIndex = group.members.firstIndex(where: { $0.id == peerID }) else { return }

        group.members[memberIndex].isTalking = isTalking
        if let voiceLevel {
            let clampedLevel = min(1, max(0, voiceLevel))
            group.members[memberIndex].voiceLevel = clampedLevel
            group.members[memberIndex].voicePeakLevel = remoteVoicePeakWindows[peerID, default: VoicePeakWindow()].record(clampedLevel)
        } else if !isTalking {
            group.members[memberIndex].voiceLevel = 0
            group.members[memberIndex].voicePeakLevel = 0
            remoteVoicePeakWindows.removeValue(forKey: peerID)
        }
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    private func setRemotePeerMuteState(peerID: String, isMuted: Bool) {
        guard var group = selectedGroup,
              let memberIndex = group.members.firstIndex(where: { $0.id == peerID }) else { return }

        group.members[memberIndex].isMuted = isMuted
        if isMuted {
            group.members[memberIndex].isTalking = false
            group.members[memberIndex].voiceLevel = 0
            group.members[memberIndex].voicePeakLevel = 0
        }
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    private func setLocalActiveCodec(_ codec: AudioCodecIdentifier) {
        guard var group = selectedGroup,
              !group.members.isEmpty else { return }

        group.members[0].activeCodec = codec
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    private func setRemotePeerCodec(_ peerID: String, codec: AudioCodecIdentifier) {
        guard var group = selectedGroup,
              let memberIndex = group.members.firstIndex(where: { $0.id == peerID }) else { return }

        group.members[memberIndex].activeCodec = codec
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    private func markPlayedAudioFrames(_ frames: [JitterBufferedAudioFrame]) {
        guard var group = selectedGroup, !frames.isEmpty else { return }

        group = RemoteMemberAudioStateService.applyPlayedFrames(frames, to: group)
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    private func removeDisconnectedAuthenticatedPeers(connectedPeerIDs: [String]) {
        let connectedPeerIDSet = Set(connectedPeerIDs)
        let disconnectedPeerIDs = authenticatedPeerIDs.filter { !connectedPeerIDSet.contains($0) }
        authenticatedPeerIDs.removeAll { !connectedPeerIDSet.contains($0) }

        for peerID in disconnectedPeerIDs {
            remoteVoiceReceivedAt.removeValue(forKey: peerID)
            setRemotePeer(peerID, isTalking: false)
        }
    }

    private func markConnectedMembers(peerIDs: [String]) {
        let connectedPeerIDSet = Set(peerIDs)
        let authenticatedPeerIDSet = Set(authenticatedPeerIDs)
        guard var group = selectedGroup else { return }

        group.members = group.members.map { member in
            var updated = member
            if member.id == localMemberIdentity.memberID {
                updated.connectionState = isAudioReady ? .connected : .offline
                updated.authenticationState = .open
            } else if connectedPeerIDSet.contains(member.id) {
                updated.connectionState = .connected
                updated.authenticationState = authenticatedPeerIDSet.contains(member.id) ? .authenticated : .pending
            } else {
                updated.connectionState = .offline
                updated.authenticationState = .offline
                updated.isTalking = false
                updated.voiceLevel = 0
                updated.voicePeakLevel = 0
                updated.queuedAudioFrameCount = 0
            }
            return updated
        }
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    private func addDiscoveredMembersIfNeeded(peerIDs: [String]) {
        guard var group = selectedGroup else { return }

        for peerID in peerIDs {
            guard !group.members.contains(where: { $0.id == peerID }) else { continue }

            if let pendingInviteIndex = group.members.firstIndex(where: { isPendingInviteMemberID($0.id) }) {
                let reservedName = group.members[pendingInviteIndex].displayName
                group.members[pendingInviteIndex] = GroupMember(id: peerID, displayName: reservedName)
                continue
            }

            guard group.members.count < IntercomGroup.maximumMemberCount else { continue }
            group.members.append(GroupMember(id: peerID, displayName: peerID))
        }

        selectedGroup = group
        replaceSelectedGroup(group)
    }

    private func markMembers(_ state: PeerConnectionState) {
        guard var group = selectedGroup else { return }
        group.members = group.members.map { member in
            var updated = member
            updated.connectionState = state
            if member.id == localMemberIdentity.memberID {
                updated.authenticationState = .open
            } else {
                switch state {
                case .connected:
                    updated.authenticationState = authenticatedPeerIDs.contains(member.id) ? .authenticated : .pending
                case .connecting:
                    updated.authenticationState = .pending
                case .offline:
                    updated.authenticationState = .offline
                }
            }
            if state == .offline {
                updated.isTalking = false
                updated.voiceLevel = 0
                updated.voicePeakLevel = 0
                updated.queuedAudioFrameCount = 0
            }
            return updated
        }
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    private func replaceSelectedGroup(_ group: IntercomGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
        persistGroups()
    }

    private func persistGroups() {
        groupStore.saveGroups(groups)
    }

    private func isPendingInviteMemberID(_ memberID: String) -> Bool {
        memberID.hasPrefix(Self.pendingInviteMemberPrefix)
    }

    private func credential(for group: IntercomGroup) -> GroupAccessCredential {
        credentialProvider.credential(for: group, store: credentialStore)
    }

    private func groupForTransport(_ group: IntercomGroup) -> IntercomGroup {
        guard let credential = credentialStore.credential(for: group.id) else { return group }
        var updated = group
        updated.accessSecret = credential.secret
        return updated
    }

    private func inviterMemberID(for group: IntercomGroup) -> String? {
        if group.members.contains(where: { $0.id == localMemberIdentity.memberID }) {
            return localMemberIdentity.memberID
        }

        return group.members.first?.id
    }
}

private extension IntercomGroup {
    func withMemberAuthenticationState(_ state: PeerAuthenticationState) -> IntercomGroup {
        var updated = self
        updated.members = members.map { member in
            var updatedMember = member
            updatedMember.authenticationState = state
            return updatedMember
        }
        return updated
    }
}

enum IntercomSeedData {
    static let recentGroups: [IntercomGroup] = [
        try! IntercomGroup(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Ridge Team",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-108", displayName: "Aki"),
                GroupMember(id: "member-215", displayName: "Mina")
            ]
        ),
        try! IntercomGroup(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Morning Hike",
            members: [
                GroupMember(id: "member-010", displayName: "You"),
                GroupMember(id: "member-400", displayName: "Ken")
            ]
        )
    ]
}
