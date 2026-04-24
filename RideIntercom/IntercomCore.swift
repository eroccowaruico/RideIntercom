import CryptoKit
import AVFoundation
import Foundation
import Observation
import OSLog

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

    nonisolated static func make(
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
    nonisolated static func makeMessage(
        credential: GroupAccessCredential,
        memberID: String,
        nonce: String = UUID().uuidString
    ) -> HandshakeMessage {
        HandshakeMessage.make(credential: credential, memberID: memberID, nonce: nonce)
    }

    nonisolated static func verifyMessage(_ message: HandshakeMessage, credential: GroupAccessCredential) -> Bool {
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

    nonisolated static func credential(for group: IntercomGroup) -> GroupAccessCredential {
        GroupAccessCredential(groupID: group.id, secret: group.accessSecret ?? "local-dev-\(group.id.uuidString)")
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
    func setAvailablePortsChangedHandler(_ handler: (() -> Void)?)
}

extension AudioSessionApplying {
    var availableInputPorts: [AudioPortInfo] { [.systemDefault] }
    var availableOutputPorts: [AudioPortInfo] { [.systemDefault] }
    func setPreferredInputPort(_ port: AudioPortInfo) throws {}
    func setPreferredOutputPort(_ port: AudioPortInfo) throws {}
    func setAvailablePortsChangedHandler(_ handler: (() -> Void)?) {}
}


final class AudioSessionManager {
    private let session: AudioSessionApplying
    private(set) var isConfigured = false
    private(set) var selectedInputPort: AudioPortInfo = .systemDefault
    private(set) var selectedOutputPort: AudioPortInfo = .systemDefault
    var onAvailablePortsChanged: (() -> Void)?

    var availableInputPorts: [AudioPortInfo] { session.availableInputPorts }
    var availableOutputPorts: [AudioPortInfo] { session.availableOutputPorts }

    init(session: AudioSessionApplying = SystemAudioSessionAdapter()) {
        self.session = session
        self.session.setAvailablePortsChangedHandler { [weak self] in
            self?.handleAvailablePortsChanged()
        }
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

    private func handleAvailablePortsChanged() {
        let inputPorts = session.availableInputPorts
        let outputPorts = session.availableOutputPorts

        if !inputPorts.contains(selectedInputPort) {
            selectedInputPort = .systemDefault
            if isConfigured {
                try? session.setPreferredInputPort(.systemDefault)
            }
        }

        if !outputPorts.contains(selectedOutputPort) {
            selectedOutputPort = .systemDefault
            if isConfigured {
                try? session.setPreferredOutputPort(.systemDefault)
            }
        }

        onAvailablePortsChanged?()
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
    case outboundPacketBuilt(OutboundPacketDiagnostics)
}

struct OutboundPacketDiagnostics: Equatable {
    let route: TransportRoute
    let streamID: UUID
    let sequenceNumber: Int
    let packetKind: AudioPacketEnvelope.PacketKind
    let metadata: AudioTransmitMetadata?
}

protocol Transport: AnyObject {
    var route: TransportRoute { get }
    var onEvent: (@MainActor (TransportEvent) -> Void)? { get set }

    func connect(group: IntercomGroup)
    func disconnect()
    func sendAudioFrame(_ frame: OutboundAudioPacket)
    func sendControl(_ message: ControlMessage)
}

protocol CallSession: AnyObject {
    var onEvent: (@MainActor (TransportEvent) -> Void)? { get set }
    var activeRouteDebugTypeName: String { get }

    func startStandby(group: IntercomGroup)
    func connect(group: IntercomGroup)
    func disconnect()
    func sendAudioFrame(_ frame: OutboundAudioPacket)
    func sendControl(_ message: ControlMessage)
}

enum RouteKind: String, CaseIterable, Codable {
    case multipeer
    case webRTC
}

struct RouteCapabilities: Equatable {
    var supportsLocalDiscovery: Bool
    var supportsOfflineOperation: Bool
    var supportsManagedMediaStream: Bool
    var supportsAppManagedPacketMedia: Bool
    var supportsReliableControl: Bool
    var supportsUnreliableControl: Bool
    var requiresSignaling: Bool
}

protocol CallRoute: AnyObject {
    var kind: RouteKind { get }
    var capabilities: RouteCapabilities { get }
    var onEvent: (@MainActor (TransportEvent) -> Void)? { get set }
    var debugTypeName: String { get }

    func startStandby(group: IntercomGroup)
    func activate(group: IntercomGroup)
    func deactivate()
    func sendAudioFrame(_ frame: OutboundAudioPacket)
    func sendControl(_ message: ControlMessage)
}

final class MultipeerLocalRoute: CallRoute {
    let kind: RouteKind = .multipeer
    let capabilities = RouteCapabilities(
        supportsLocalDiscovery: true,
        supportsOfflineOperation: true,
        supportsManagedMediaStream: false,
        supportsAppManagedPacketMedia: true,
        supportsReliableControl: true,
        supportsUnreliableControl: true,
        requiresSignaling: false
    )
    var onEvent: (@MainActor (TransportEvent) -> Void)? {
        get { transport.onEvent }
        set { transport.onEvent = newValue }
    }
    var debugTypeName: String { String(describing: type(of: transport)) }

    private let transport: Transport

    init(transport: Transport) {
        self.transport = transport
    }

    func startStandby(group: IntercomGroup) {
        transport.connect(group: group)
    }

    func activate(group: IntercomGroup) {
        transport.connect(group: group)
    }

    func deactivate() {
        transport.disconnect()
    }

    func sendAudioFrame(_ frame: OutboundAudioPacket) {
        transport.sendAudioFrame(frame)
    }

    func sendControl(_ message: ControlMessage) {
        transport.sendControl(message)
    }
}

final class RouteManager: CallSession {
    var onEvent: (@MainActor (TransportEvent) -> Void)?
    var activeRouteDebugTypeName: String { preferredRoute.debugTypeName }

    private let preferredRoute: CallRoute

    init(preferredRoute: CallRoute) {
        self.preferredRoute = preferredRoute
        self.preferredRoute.onEvent = { [weak self] event in
            self?.handleRouteEvent(event)
        }
    }

    func startStandby(group: IntercomGroup) {
        preferredRoute.startStandby(group: group)
    }

    func connect(group: IntercomGroup) {
        preferredRoute.activate(group: group)
    }

    func disconnect() {
        preferredRoute.deactivate()
    }

    func sendAudioFrame(_ frame: OutboundAudioPacket) {
        preferredRoute.sendAudioFrame(frame)
    }

    func sendControl(_ message: ControlMessage) {
        preferredRoute.sendControl(message)
    }

    private func handleRouteEvent(_ event: TransportEvent) {
        onEvent?(event)
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
    enum Phase: Equatable {
        case idle
        case localConnected
        case internetConnecting
        case internetConnected
        case localCandidate(deadline: TimeInterval)
        case localProbing(deadline: TimeInterval)
        case handoverToLocal(deadline: TimeInterval)
        case reconnectingOffline
    }

    private(set) var state: CallConnectionState = .idle
    private(set) var phase: Phase = .idle
    private var policy: any RoutePolicy
    private let probeWindow: TimeInterval
    private let dualSendWindow: TimeInterval

    init(policy: any RoutePolicy = DefaultRoutePolicy()) {
        self.policy = policy
        self.probeWindow = 7.5
        self.dualSendWindow = 1.0
    }

    init(
        policy: any RoutePolicy = DefaultRoutePolicy(),
        probeWindow: TimeInterval,
        dualSendWindow: TimeInterval
    ) {
        self.policy = policy
        self.probeWindow = probeWindow
        self.dualSendWindow = dualSendWindow
    }

    mutating func connectLocal() {
        state = .localConnected
        phase = .localConnected
    }

    mutating func localLinkDidFail(internetAvailable: Bool) {
        if internetAvailable {
            state = .internetConnecting
            phase = .internetConnecting
        } else {
            state = .reconnectingOffline
            phase = .reconnectingOffline
        }
    }

    mutating func internetDidConnect() {
        state = .internetConnected
        phase = .internetConnected
    }

    mutating func localCandidateDetected(now: TimeInterval = Date().timeIntervalSince1970) {
        guard case .internetConnected = phase else { return }
        phase = .localCandidate(deadline: now + probeWindow)
    }

    mutating func beginLocalProbe(now: TimeInterval = Date().timeIntervalSince1970) {
        switch phase {
        case .internetConnected, .localCandidate:
            phase = .localProbing(deadline: now + probeWindow)
        default:
            break
        }
    }

    mutating func evaluateLocalProbe(_ metrics: RouteProbeMetrics, now: TimeInterval = Date().timeIntervalSince1970) {
        beginLocalProbe(now: now)
        if policy.shouldPreferLocal(afterProbe: metrics) {
            phase = .handoverToLocal(deadline: now + dualSendWindow)
        }
    }

    mutating func advance(now: TimeInterval = Date().timeIntervalSince1970) {
        switch phase {
        case .localCandidate(let deadline), .localProbing(let deadline):
            if now >= deadline {
                phase = .internetConnected
            }
        case .handoverToLocal(let deadline):
            if now >= deadline {
                phase = .localConnected
                state = .localConnected
            }
        default:
            break
        }
    }

    var shouldDualSend: Bool {
        if case .handoverToLocal = phase {
            return true
        }
        return false
    }

    mutating func disconnect() {
        state = .idle
        phase = .idle
    }
}

enum VoiceActivityState: Equatable {
    case idle
    case attack
    case talking
    case release
}

struct VoiceActivityDetector {
    static let minThreshold: Float = 0.00025
    static let maxThreshold: Float = 0.12
    static let defaultThreshold: Float = 0.003

    private(set) var state: VoiceActivityState = .idle
    private var threshold: Float
    private let attackFrames: Int
    private let releaseFrames: Int
    private var speechFrames = 0
    private var silenceFrames = 0
    private var noiseFloor: Float = VoiceActivityDetector.minThreshold

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

struct EncodedVoicePacket: Codable, Equatable {
    let frameID: Int
    let codec: AudioCodecIdentifier
    let payload: Data

    static func make(
        frameID: Int,
        samples: [Float]
    ) throws -> EncodedVoicePacket {
        EncodedVoicePacket(
            frameID: frameID,
            codec: .pcm16,
            payload: PCMAudioCodec.encode(samples)
        )
    }

    func decodeSamples() throws -> [Float] {
        try PCMAudioCodec.decode(payload)
    }
}

enum AudioCodecFallbackReason: String, Codable, Equatable {
    case codecUnavailable
    case encoderReturnedEmptyPayload
    case encodingFailed
}

struct AudioTransmitMetadata: Codable, Equatable {
    let requestedCodec: AudioCodecIdentifier
    let encodedCodec: AudioCodecIdentifier
    let fallbackReason: AudioCodecFallbackReason?
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
    let transmitMetadata: AudioTransmitMetadata?

    init(
        groupID: UUID,
        streamID: UUID,
        sequenceNumber: Int,
        sentAt: TimeInterval,
        kind: PacketKind,
        frameID: Int?,
        samples: [Float] = [],
        encodedVoice: EncodedVoicePacket? = nil,
        transmitMetadata: AudioTransmitMetadata? = nil
    ) {
        self.groupID = groupID
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.sentAt = sentAt
        self.kind = kind
        self.frameID = frameID
        self.samples = samples
        self.encodedVoice = encodedVoice
        self.transmitMetadata = transmitMetadata
    }

    init(
        groupID: UUID,
        streamID: UUID,
        sequenceNumber: Int,
        sentAt: TimeInterval,
        encodedVoice: EncodedVoicePacket,
        transmitMetadata: AudioTransmitMetadata? = nil
    ) {
        self.groupID = groupID
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.sentAt = sentAt
        self.kind = .voice
        self.frameID = encodedVoice.frameID
        self.samples = []
        self.encodedVoice = encodedVoice
        self.transmitMetadata = transmitMetadata
    }

    init(
        groupID: UUID,
        streamID: UUID,
        sequenceNumber: Int,
        sentAt: TimeInterval,
        packet: OutboundAudioPacket
    ) {
        self.groupID = groupID
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.sentAt = sentAt

        switch packet {
        case .voice(let frameID, let samples):
            if let encodedVoice = try? EncodedVoicePacket.make(frameID: frameID, samples: samples) {
                self.kind = .voice
                self.frameID = frameID
                self.samples = []
                self.encodedVoice = encodedVoice
                self.transmitMetadata = AudioTransmitMetadata(
                    requestedCodec: .pcm16,
                    encodedCodec: .pcm16,
                    fallbackReason: nil
                )
            } else {
                self.kind = .keepalive
                self.frameID = nil
                self.samples = []
                self.encodedVoice = nil
                self.transmitMetadata = AudioTransmitMetadata(
                    requestedCodec: .pcm16,
                    encodedCodec: .pcm16,
                    fallbackReason: .encodingFailed
                )
            }
        case .keepalive:
            self.kind = .keepalive
            self.frameID = nil
            self.samples = []
            self.encodedVoice = nil
            self.transmitMetadata = AudioTransmitMetadata(
                requestedCodec: .pcm16,
                encodedCodec: .pcm16,
                fallbackReason: nil
            )
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
        guard envelope.groupID == groupID else { return nil }

        let packetID = PacketID(streamID: envelope.streamID, sequenceNumber: envelope.sequenceNumber)
        guard !seenPacketIDs.contains(packetID),
              let packet = decodePacket(envelope, fromPeerID: peerID) else {
            return nil
        }

        seenPacketIDs.insert(packetID)

        return ReceivedAudioPacket(peerID: peerID, envelope: envelope, packet: packet)
    }

    private mutating func decodePacket(_ envelope: AudioPacketEnvelope, fromPeerID peerID: String) -> OutboundAudioPacket? {
        switch envelope.kind {
        case .keepalive:
            return .keepalive
        case .voice:
            if let encodedVoice = envelope.encodedVoice {
                guard let decodedSamples = try? encodedVoice.decodeSamples() else {
                    return nil
                }
                return .voice(frameID: encodedVoice.frameID, samples: decodedSamples)
            }

            guard let frameID = envelope.frameID else { return nil }
            return .voice(frameID: frameID, samples: envelope.samples)
        }
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

enum RemoteAudioJitterBufferDefaults {
    static let playoutDelay: TimeInterval = 0.015
    static let packetLifetime: TimeInterval = 2.0
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

    init(
        playoutDelay: TimeInterval = RemoteAudioJitterBufferDefaults.playoutDelay,
        packetLifetime: TimeInterval = RemoteAudioJitterBufferDefaults.packetLifetime
    ) {
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
    private(set) var streamID: UUID
    private var nextSequenceNumber = 1

    init(
        groupID: UUID,
        streamID: UUID = UUID()
    ) {
        self.groupID = groupID
        self.streamID = streamID
    }

    mutating func makeEnvelope(for packet: OutboundAudioPacket, sentAt: TimeInterval = Date().timeIntervalSince1970) -> AudioPacketEnvelope {
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
                packet: .keepalive
            )
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
                encodedVoice: encodedVoice,
                transmitMetadata: AudioTransmitMetadata(
                    requestedCodec: .pcm16,
                    encodedCodec: .pcm16,
                    fallbackReason: nil
                )
            )
        } catch {
            return AudioPacketEnvelope(
                groupID: groupID,
                streamID: streamID,
                sequenceNumber: nextSequenceNumber,
                sentAt: sentAt,
                kind: .keepalive,
                frameID: nil,
                samples: [],
                encodedVoice: nil,
                transmitMetadata: AudioTransmitMetadata(
                    requestedCodec: .pcm16,
                    encodedCodec: .pcm16,
                    fallbackReason: .encodingFailed
                )
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
    nonisolated static let muteAutoStopDelayDefault: Duration = .seconds(2)
    nonisolated static let normalMasterOutputVolume: Float = 1
    nonisolated static let maximumMasterOutputVolume: Float = 2

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
    private(set) var preferredTransmitCodec: AudioCodecIdentifier = .pcm16
    private(set) var heAACv2Quality: HEAACv2Quality = .medium
    private(set) var masterOutputVolume: Float = 1
    private(set) var isOutputMuted = false
    private(set) var remoteOutputVolumes: [String: Float] = [:]
    var isMicrophoneCaptureRunning: Bool {
        isAudioReady && !isMicrophoneCaptureSuspendedByMute
    }

    var availableInputPorts: [AudioPortInfo] { audioSessionManager.availableInputPorts }
    var availableOutputPorts: [AudioPortInfo] { audioSessionManager.availableOutputPorts }
    var isAudioDeviceSelectionLive: Bool { audioSessionManager.isConfigured }
    var diagnosticsInputLevel: Float {
        if audioCheckPhase == .recording {
            return audioCheckInputLevel
        }
        guard let localMember = selectedGroup?.members.first, !isMuted else { return 0 }
        return localMember.voiceLevel
    }
    var diagnosticsInputPeakLevel: Float {
        if audioCheckPhase == .recording {
            return audioCheckInputPeakLevel
        }
        guard let localMember = selectedGroup?.members.first, !isMuted else { return 0 }
        return localMember.voicePeakLevel
    }
    var diagnosticsOutputLevel: Float {
        if audioCheckPhase == .playing {
            return audioCheckOutputLevel
        }
        return lastScheduledOutputRMS
    }
    var diagnosticsOutputPeakLevel: Float {
        if audioCheckPhase == .playing {
            return audioCheckOutputPeakLevel
        }
        return lastScheduledOutputPeakRMS
    }
    private(set) var audioCheckPhase: AudioCheckPhase = .idle
    private(set) var audioCheckInputLevel: Float = 0
    private(set) var audioCheckInputPeakLevel: Float = 0
    private(set) var audioCheckOutputLevel: Float = 0
    private(set) var audioCheckOutputPeakLevel: Float = 0
    private(set) var audioCheckStatusMessage = "Audio check idle"
    private(set) var sentVoicePacketCount = 0
    private(set) var receivedVoicePacketCount = 0
    private(set) var playedAudioFrameCount = 0
    private(set) var lastScheduledOutputRMS: Float = 0
    private(set) var lastScheduledOutputPeakRMS: Float = 0
    private(set) var scheduledOutputBatchCount = 0
    private(set) var scheduledOutputFrameCount = 0
    private(set) var connectedPeerIDs: [String] = []
    private(set) var authenticatedPeerIDs: [String] = []
    private(set) var localNetworkStatus: LocalNetworkStatus = .idle
    private(set) var lastLocalNetworkPeerID: String?
    private(set) var lastLocalNetworkEventAt: TimeInterval?
    private(set) var lastReceivedAudioAt: TimeInterval?
    private(set) var droppedAudioPacketCount = 0
    private(set) var jitterQueuedFrameCount = 0
    private(set) var inviteStatusMessage: String?
    private(set) var transmitFallbackCount = 0
    private(set) var receiveMetadataMismatchCount = 0
    private(set) var lastTransmitFallbackSummary: String?
    private(set) var lastReceiveMetadataMismatchSummary: String?
    private let callSession: CallSession
    private let audioSessionManager: AudioSessionManager
    private let audioInputMonitor: AudioInputMonitoring
    private let callTicker: CallTicking
    private let audioFramePlayer: AudioFramePlaying
    private let credentialStore: GroupCredentialStoring
    private let credentialProvider: any GroupCredentialProviding
    private let groupStore: GroupStoring
    private let localMemberIdentity: LocalMemberIdentity
    private let remoteTalkerTimeout: TimeInterval
    private let muteAutoStopDelay: Duration
    private var audioTransmissionController: AudioTransmissionController
    private var jitterBuffer: JitterBuffer
    private var remoteVoiceReceivedAt: [String: TimeInterval] = [:]
    private var localVoicePeakWindow = VoicePeakWindow()
    private var remoteVoicePeakWindows: [String: VoicePeakWindow] = [:]
    private var playbackOutputPeakWindow = VoicePeakWindow()
    private var audioCheckInputPeakWindow = VoicePeakWindow()
    private var audioCheckOutputPeakWindow = VoicePeakWindow()
    private var audioCheckRecordedSamples: [Float] = []
    private var audioCheckTask: Task<Void, Never>?
    private var muteAutoStopTask: Task<Void, Never>?
    private var audioCheckOwnsAudioPipeline = false
    private var isMicrophoneCaptureSuspendedByMute = false
    private var isLocalStandbyOnly = false
    private var nextAudioFrameID = 1
    private let diagnosticsLogger = Logger(subsystem: "com.yowamushi-inc.RideIntercom", category: "codec-diagnostics")

    static func makeForCurrentProcess() -> IntercomViewModel {
        let audioFramePlayer = BufferedAudioFramePlayer(renderer: SystemAudioOutputRenderer())

        if isUITestProcess {
            let localMemberIdentityStore = InMemoryLocalMemberIdentityStore(
                identity: LocalMemberIdentity(memberID: "member-uitest", displayName: "You")
            )
            let localMemberIdentity = localMemberIdentityStore.loadOrCreate()
            let callSession = RouteManager(
                preferredRoute: MultipeerLocalRoute(
                    transport: MultipeerLocalTransport(displayName: localMemberIdentity.memberID)
                )
            )

            return IntercomViewModel(
                callSession: callSession,
                credentialStore: InMemoryGroupCredentialStore(),
                groupStore: InMemoryGroupStore(),
                localMemberIdentityStore: localMemberIdentityStore,
                audioFramePlayer: audioFramePlayer
            )
        }

        let localMemberIdentityStore = UserDefaultsLocalMemberIdentityStore()
        let localMemberIdentity = localMemberIdentityStore.loadOrCreate()
        let callSession = RouteManager(
            preferredRoute: MultipeerLocalRoute(
                transport: MultipeerLocalTransport(displayName: localMemberIdentity.memberID)
            )
        )

        return IntercomViewModel(
            callSession: callSession,
            credentialStore: KeychainGroupCredentialStore(),
            groupStore: UserDefaultsGroupStore(),
            localMemberIdentityStore: localMemberIdentityStore,
            audioFramePlayer: audioFramePlayer
        )
    }

    private static var isUITestProcess: Bool {
        ProcessInfo.processInfo.arguments.contains("UI-TEST")
    }

    init(
        groups: [IntercomGroup]? = nil,
        callSession: CallSession? = nil,
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
        remoteTalkerTimeout: TimeInterval = 0.6,
        muteAutoStopDelay: Duration = IntercomViewModel.muteAutoStopDelayDefault
    ) {
        let localMemberIdentityStore = localMemberIdentityStore ?? InMemoryLocalMemberIdentityStore()
        let localMemberIdentity = localMemberIdentityStore.loadOrCreate()
        let groupStore = groupStore ?? InMemoryGroupStore()
        let storedGroups = groupStore.loadGroups()
        self.groups = groups ?? storedGroups
        let localTransport = localTransport ?? MultipeerLocalTransport(displayName: localMemberIdentity.memberID)
        self.callSession = callSession ?? RouteManager(preferredRoute: MultipeerLocalRoute(transport: localTransport))
        _ = internetTransport
        self.audioSessionManager = audioSessionManager ?? AudioSessionManager()
        if let audioInputMonitor {
            self.audioInputMonitor = audioInputMonitor
        } else {
            self.audioInputMonitor = SystemAudioInputMonitor()
        }
        let initialVoiceActivityDetectionThreshold = AudioTransmissionController.defaultVoiceActivityThreshold
        self.voiceActivityDetectionThreshold = initialVoiceActivityDetectionThreshold
        self.audioTransmissionController = audioTransmissionController ?? AudioTransmissionController()
        self.callTicker = callTicker ?? RepeatingCallTicker()
        if let audioFramePlayer {
            self.audioFramePlayer = audioFramePlayer
        } else {
            self.audioFramePlayer = BufferedAudioFramePlayer(renderer: SystemAudioOutputRenderer())
        }
        self.credentialStore = credentialStore ?? InMemoryGroupCredentialStore()
        self.credentialProvider = DefaultGroupCredentialProvider()
        self.groupStore = groupStore
        self.localMemberIdentity = localMemberIdentity
        self.jitterBuffer = jitterBuffer ?? JitterBuffer()
        self.remoteTalkerTimeout = remoteTalkerTimeout
        self.muteAutoStopDelay = muteAutoStopDelay
        self.audioTransmissionController.setVoiceActivityThreshold(initialVoiceActivityDetectionThreshold)

        self.callSession.onEvent = { [weak self] event in
            self?.handleTransportEvent(event)
        }
        self.audioSessionManager.onAvailablePortsChanged = { [weak self] in
            self?.handleAvailableAudioPortsChanged()
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
    }

    var connectionLabel: String {
        connectionState.label
    }

    var diagnosticsSnapshot: DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            audio: AudioDebugSnapshot(
                transmittedVoicePacketCount: sentVoicePacketCount,
                receivedVoicePacketCount: receivedVoicePacketCount,
                playedAudioFrameCount: playedAudioFrameCount
            ),
            playback: PlaybackDebugSnapshot(
                lastScheduledOutputRMS: lastScheduledOutputRMS,
                scheduledOutputBatchCount: scheduledOutputBatchCount,
                scheduledOutputFrameCount: scheduledOutputFrameCount
            ),
            connectedPeerCount: connectedPeerCount,
            authenticatedPeerCount: authenticatedPeerCount,
            localMemberID: localMemberIdentity.memberID,
            transportTypeName: callSession.activeRouteDebugTypeName,
            selectedGroupID: selectedGroup?.id,
            selectedGroupMemberCount: selectedGroup?.members.count ?? 0,
            groupHashPrefix: selectedGroup.map { String(credential(for: $0).groupHash.prefix(8)) },
            inviteStatusMessage: inviteStatusMessage,
            hasInviteURL: selectedGroupInviteURL != nil,
            localNetwork: LocalNetworkDebugSnapshot(
                status: localNetworkStatus,
                peerID: lastLocalNetworkPeerID,
                occurredAt: lastLocalNetworkEventAt
            ),
            reception: ReceptionDebugSnapshot(
                lastReceivedAudioAt: lastReceivedAudioAt,
                droppedAudioPacketCount: droppedAudioPacketCount,
                jitterQueuedFrameCount: jitterQueuedFrameCount
            ),
            transmitFallbackCount: transmitFallbackCount,
            receiveMetadataMismatchCount: receiveMetadataMismatchCount,
            lastTransmitFallbackSummary: lastTransmitFallbackSummary,
            lastReceiveMetadataMismatchSummary: lastReceiveMetadataMismatchSummary
        )
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

    var audioInputProcessingSummary: String {
        let isolationLabel: String
        if audioInputMonitor.supportsSoundIsolation {
            isolationLabel = isSoundIsolationEnabled ? "ON" : "OFF"
        } else {
            isolationLabel = "N/A"
        }
        return String(format: "VAD %.4f / ISOLATION %@", voiceActivityDetectionThreshold, isolationLabel)
    }

    var supportsSoundIsolation: Bool {
        audioInputMonitor.supportsSoundIsolation
    }

    var connectedPeerCount: Int {
        connectedPeerIDs.count
    }

    var connectionDebugSummary: String {
        diagnosticsSnapshot.connectionSummary
    }

    var callSessionDebugTypeName: String {
        callSession.activeRouteDebugTypeName
    }

    var transportDebugSummary: String {
        diagnosticsSnapshot.transportSummary
    }

    var authenticatedPeerCount: Int {
        authenticatedPeerIDs.count
    }

    var selectedGroupInviteURL: URL? {
        guard let selectedGroup else { return nil }
        let inviterMemberID: String
        if selectedGroup.members.contains(where: { $0.id == localMemberIdentity.memberID }) {
            inviterMemberID = localMemberIdentity.memberID
        } else if let firstMemberID = selectedGroup.members.first?.id {
            inviterMemberID = firstMemberID
        } else {
            return nil
        }

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

    func selectGroup(_ group: IntercomGroup) {
        if selectedGroup?.id == group.id, hasActiveConversationConnection {
            return
        }

        callSession.disconnect()
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

    func showGroupSelection() {
        disconnect()
        selectedGroup = nil
        inviteStatusMessage = nil
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
        remoteOutputVolumes.removeValue(forKey: memberID)

        if selectedGroup?.id == groupID {
            selectedGroup = groups[groupIndex]
        }
        persistGroups()
    }

    func createTalkGroup() {
        let groupID = UUID()
        let newGroup = try? IntercomGroup(
            id: groupID,
            name: "Talk Group",
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
        isLocalStandbyOnly = false
        connectionState = connectedPeerIDs.isEmpty ? .localConnecting : .localConnected
        markMembers(connectionState == .localConnected ? .connected : .connecting)
        if localNetworkStatus == .idle || localNetworkStatus == .unavailable {
            var group = selectedGroup
            if let credential = credentialStore.credential(for: selectedGroup.id) {
                group.accessSecret = credential.secret
            }
            callSession.connect(group: group)
        }
    }

    private func startActiveCallAfterAuthenticatedPeer() {
        guard isLocalStandbyOnly,
              !authenticatedPeerIDs.isEmpty,
              startAudioPipelineIfNeeded() else { return }

        isLocalStandbyOnly = false
        connectionState = .localConnected
        markConnectedMembers(peerIDs: connectedPeerIDs)
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
            if isMuted {
                scheduleMuteAutoStopIfNeeded()
            }
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
        var group = selectedGroup
        if let credential = credentialStore.credential(for: selectedGroup.id) {
            group.accessSecret = credential.secret
        }
        callSession.startStandby(group: group)
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
        muteAutoStopTask?.cancel()
        muteAutoStopTask = nil
        callSession.disconnect()
        audioInputMonitor.stop()
        audioFramePlayer.stop()
        callTicker.stop()
        try? audioSessionManager.deactivate()
        connectionState = .idle
        isVoiceActive = false
        isAudioReady = false
        isMicrophoneCaptureSuspendedByMute = false
        remoteVoiceReceivedAt.removeAll()
        resetVoiceLevelWindows()
        connectedPeerIDs = []
        authenticatedPeerIDs = []
        isLocalStandbyOnly = false
        localNetworkStatus = .idle
        lastLocalNetworkPeerID = nil
        lastLocalNetworkEventAt = nil
        lastReceivedAudioAt = nil
        droppedAudioPacketCount = 0
        jitterQueuedFrameCount = 0
        resetAudioDebugCounters()
        markMembers(.offline)
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            scheduleMuteAutoStopIfNeeded()
        } else {
            restoreMicrophoneCaptureIfNeeded()
        }

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
        broadcastControl(.peerMuteState(isMuted: isMuted))
        broadcastMetadataKeepalive()
    }

    private func scheduleMuteAutoStopIfNeeded() {
        muteAutoStopTask?.cancel()
        muteAutoStopTask = nil

        guard isAudioReady, !isMicrophoneCaptureSuspendedByMute else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: muteAutoStopDelay)
        muteAutoStopTask = Task { @MainActor [weak self] in
            guard let self else { return }

            try? await clock.sleep(until: deadline, tolerance: .zero)
            guard !Task.isCancelled else { return }

            guard self.isMuted, self.isAudioReady, !self.isMicrophoneCaptureSuspendedByMute else { return }
            self.audioInputMonitor.stop()
            self.isMicrophoneCaptureSuspendedByMute = true
        }
    }

    private func restoreMicrophoneCaptureIfNeeded() {
        muteAutoStopTask?.cancel()
        muteAutoStopTask = nil

        guard isMicrophoneCaptureSuspendedByMute, isAudioReady else { return }

        do {
            try audioInputMonitor.start()
            isMicrophoneCaptureSuspendedByMute = false
            audioErrorMessage = nil
        } catch {
            audioErrorMessage = audioSetupMessage(for: error)
        }
    }

    func toggleVoiceActivity() {
        setVoiceActive(!isVoiceActive)
    }

    func processMicrophoneLevelForDebug(_ level: Float) {
        handleMicrophoneLevel(level)
    }

    func setPreferredTransmitCodec(_ codec: AudioCodecIdentifier) {
        preferredTransmitCodec = .pcm16
        setLocalActiveCodec(.pcm16)
        broadcastMetadataKeepalive()
    }

    func setHEAACv2Quality(_ quality: HEAACv2Quality) {
        heAACv2Quality = .medium
        broadcastMetadataKeepalive()
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
            selectedInputPort = audioSessionManager.selectedInputPort
            audioErrorMessage = nil
        } catch {
            audioErrorMessage = "Audio input device change failed"
        }
    }

    func setOutputPort(_ port: AudioPortInfo) {
        do {
            try audioSessionManager.setOutputPort(port)
            selectedOutputPort = audioSessionManager.selectedOutputPort
            audioErrorMessage = nil
        } catch {
            audioErrorMessage = "Audio output device change failed"
        }
    }

    func setMasterOutputVolume(_ value: Float) {
        masterOutputVolume = clampedMasterOutputVolume(value)
    }

    func toggleOutputMute() {
        isOutputMuted.toggle()
    }

    func setRemoteOutputVolume(peerID: String, value: Float) {
        remoteOutputVolumes[peerID] = clampedAudioGain(value)
    }

    func remoteOutputVolume(for peerID: String) -> Float {
        remoteOutputVolumes[peerID] ?? 1
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
        let readyFrames = jitterBuffer.drainReadyFrames(now: now)
        playedAudioFrameCount += readyFrames.count
        droppedAudioPacketCount = jitterBuffer.droppedFrameCount
        jitterQueuedFrameCount = jitterBuffer.queuedFrameCount
        markPlayedAudioFrames(readyFrames)
        let outputFrames = applyOutputGain(to: readyFrames)
        let mixedOutput = AudioMixer.mix(outputFrames)
        let outputLevel = AudioLevelMeter.rmsLevel(samples: mixedOutput)
        lastScheduledOutputRMS = outputLevel
        lastScheduledOutputPeakRMS = playbackOutputPeakWindow.record(outputLevel)
        if !outputFrames.isEmpty {
            scheduledOutputBatchCount += 1
            scheduledOutputFrameCount += outputFrames.count
        }
        audioFramePlayer.play(outputFrames)
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
        let packets = audioTransmissionController.process(frameID: frameID, level: level, samples: samples)
        for packet in packets {
            send(packet)
        }

        setVoiceActive(packets.contains { packet in
            if case .voice = packet {
                return true
            }
            return false
        })
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

        let playbackCodec: AudioCodecIdentifier = .pcm16
        let playbackSamples = makeAudioCheckPlaybackSamples(from: recordedSamples)

        let outputLevel = AudioLevelMeter.rmsLevel(samples: playbackSamples)
        audioCheckOutputLevel = min(1, max(0, outputLevel))
        audioCheckOutputPeakLevel = audioCheckOutputPeakWindow.record(audioCheckOutputLevel)
        audioCheckPhase = .playing
        audioCheckStatusMessage = "Playing recorded audio for 5 seconds (\(audioCodecDisplayName(playbackCodec)))"
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

    private func makeAudioCheckPlaybackSamples(from samples: [Float]) -> [Float] {
        guard let packet = try? EncodedVoicePacket.make(frameID: 1, samples: samples) else {
            return samples
        }

        guard let decodedSamples = try? packet.decodeSamples(), !decodedSamples.isEmpty else {
            return samples
        }
        return decodedSamples
    }

    private func audioCodecDisplayName(_ codec: AudioCodecIdentifier) -> String {
        switch codec {
        case .pcm16:
            "PCM 16-bit"
        case .heAACv2:
            "HE-AAC v2 VBR"
        case .opus:
            "Opus"
        }
    }

    private func send(_ packet: OutboundAudioPacket) {
        switch packet {
        case .voice:
            sentVoicePacketCount += 1
            callSession.sendAudioFrame(packet)
        case .keepalive:
            callSession.sendControl(.keepalive)
        }
    }

    private func broadcastControl(_ message: ControlMessage, preferredRoute: TransportRoute? = nil) {
        _ = preferredRoute
        callSession.sendControl(message)
    }

    private func broadcastMetadataKeepalive(preferredRoute: TransportRoute? = nil) {
        _ = preferredRoute
        callSession.sendAudioFrame(.keepalive)
    }

    private func sendStateMetadataSnapshot(for route: TransportRoute) {
        broadcastControl(.peerMuteState(isMuted: isMuted), preferredRoute: route)
        broadcastMetadataKeepalive(preferredRoute: route)
    }

    private func setVoiceActive(_ isActive: Bool) {
        isVoiceActive = isActive
        guard var group = selectedGroup, !group.members.isEmpty else { return }
        group.members[0].isTalking = isActive
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    private func handleTransportEvent(_ event: TransportEvent) {
        switch event {
        case .localNetworkStatus(let event):
            localNetworkStatus = event.status
            lastLocalNetworkPeerID = event.peerID
            lastLocalNetworkEventAt = event.occurredAt
        case .connected(let peerIDs):
            connectedPeerIDs = peerIDs
            addDiscoveredMembersIfNeeded(peerIDs: peerIDs)
            removeDisconnectedAuthenticatedPeers(connectedPeerIDs: peerIDs)
            localNetworkStatus = .connected
            if isLocalStandbyOnly {
                connectionState = .idle
            } else {
                connectionState = .localConnected
            }
            markConnectedMembers(peerIDs: peerIDs)
        case .authenticated(let peerIDs):
            let authenticatedPeerIDSet = Set(peerIDs)
            authenticatedPeerIDs = Array(authenticatedPeerIDSet).sorted()
            connectedPeerIDs = Array(Set(connectedPeerIDs).union(authenticatedPeerIDSet)).sorted()
            addDiscoveredMembersIfNeeded(peerIDs: authenticatedPeerIDs)
            if !isLocalStandbyOnly {
                connectionState = .localConnected
            }
            markConnectedMembers(peerIDs: connectedPeerIDs)
            startActiveCallAfterAuthenticatedPeer()
            sendStateMetadataSnapshot(for: .local)
        case .remotePeerMuteState(let peerID, let isMuted):
            setRemotePeerMuteState(peerID: peerID, isMuted: isMuted)
        case .disconnected:
            connectedPeerIDs = []
            authenticatedPeerIDs = []
            localNetworkStatus = .idle
            connectionState = .idle
            isVoiceActive = false
            markMembers(.offline)
        case .linkFailed(let internetAvailable):
            _ = internetAvailable
            connectedPeerIDs = []
            authenticatedPeerIDs = []
            localNetworkStatus = .unavailable
            connectionState = .reconnectingOffline
            markMembers(.connecting)
        case .receivedPacket(let packet):
            handleReceivedPacket(packet)
        case .outboundPacketBuilt(let diagnostics):
            handleOutboundPacketDiagnostics(diagnostics)
        }
    }

    private func handleAvailableAudioPortsChanged() {
        selectedInputPort = audioSessionManager.selectedInputPort
        selectedOutputPort = audioSessionManager.selectedOutputPort
    }

    private func handleReceivedPacket(_ packet: ReceivedAudioPacket) {
        guard authenticatedPeerIDs.isEmpty || authenticatedPeerIDs.contains(packet.peerID) else {
            return
        }
        let receivedAt = packet.envelope.sentAt < 1_000_000
            ? packet.envelope.sentAt
            : Date().timeIntervalSince1970
        if let codec = packet.envelope.encodedVoice?.codec ?? packet.envelope.transmitMetadata?.encodedCodec {
            setRemotePeerCodec(packet.peerID, codec: codec)
        }
        captureReceiveMetadataMismatchIfNeeded(packet)

        switch packet.packet {
        case .voice(_, let samples):
            jitterBuffer.enqueue(packet, receivedAt: receivedAt)
            receivedVoicePacketCount += 1
            lastReceivedAudioAt = receivedAt
            remoteVoiceReceivedAt[packet.peerID] = receivedAt
            droppedAudioPacketCount = jitterBuffer.droppedFrameCount
            jitterQueuedFrameCount = jitterBuffer.queuedFrameCount
            applyReceivedVoiceMemberState(peerID: packet.peerID, voiceLevel: AudioLevelMeter.rmsLevel(samples: samples))
        case .keepalive:
            droppedAudioPacketCount = jitterBuffer.droppedFrameCount
            jitterQueuedFrameCount = jitterBuffer.queuedFrameCount
        }

        // In production, received packets can arrive in bursts on the main actor.
        // Draining here prevents playback from waiting for the next ticker cycle.
        if receivedAt >= 1_000_000 {
            drainJitterBuffer(now: receivedAt)
        }
    }

    private func applyReceivedVoiceMemberState(peerID: String, voiceLevel: Float) {
        guard var group = selectedGroup else { return }
        guard let memberIndex = group.members.firstIndex(where: { $0.id == peerID }) else { return }

        let clampedLevel = min(1, max(0, voiceLevel))
        group.members[memberIndex].isTalking = true
        group.members[memberIndex].voiceLevel = clampedLevel
        group.members[memberIndex].voicePeakLevel = remoteVoicePeakWindows[peerID, default: VoicePeakWindow()].record(clampedLevel)
        group.members[memberIndex].receivedAudioPacketCount += 1
        group.members[memberIndex].queuedAudioFrameCount += 1
        selectedGroup = group
        replaceSelectedGroup(group)
    }

    private func resetAudioDebugCounters() {
        sentVoicePacketCount = 0
        receivedVoicePacketCount = 0
        playedAudioFrameCount = 0
        lastScheduledOutputRMS = 0
        lastScheduledOutputPeakRMS = 0
        scheduledOutputBatchCount = 0
        scheduledOutputFrameCount = 0
        lastReceivedAudioAt = nil
        droppedAudioPacketCount = 0
        jitterQueuedFrameCount = 0
        playbackOutputPeakWindow = VoicePeakWindow()
        transmitFallbackCount = 0
        receiveMetadataMismatchCount = 0
        lastTransmitFallbackSummary = nil
        lastReceiveMetadataMismatchSummary = nil
    }

    private func resetVoiceLevelWindows() {
        localVoicePeakWindow = VoicePeakWindow()
        remoteVoicePeakWindows.removeAll()
    }

    private func handleOutboundPacketDiagnostics(_ diagnostics: OutboundPacketDiagnostics) {
        guard let metadata = diagnostics.metadata else { return }
        setLocalActiveCodec(metadata.encodedCodec)
        let hasFallback = metadata.fallbackReason != nil || metadata.requestedCodec != metadata.encodedCodec
        guard hasFallback else { return }

        transmitFallbackCount += 1
        let reason = metadata.fallbackReason?.rawValue ?? "codecMismatch"
        let summary = "TX FB #\(transmitFallbackCount) / \(metadata.requestedCodec.rawValue)->\(metadata.encodedCodec.rawValue) / \(reason)"
        lastTransmitFallbackSummary = summary
        diagnosticsLogger.error("tx fallback route=\(diagnostics.route.rawValue, privacy: .public) stream=\(diagnostics.streamID.uuidString, privacy: .public) seq=\(diagnostics.sequenceNumber) req=\(metadata.requestedCodec.rawValue, privacy: .public) enc=\(metadata.encodedCodec.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func captureReceiveMetadataMismatchIfNeeded(_ packet: ReceivedAudioPacket) {
        guard let metadata = packet.envelope.transmitMetadata else { return }
        guard let actualCodec = packet.envelope.encodedVoice?.codec else { return }
        guard metadata.encodedCodec != actualCodec else { return }

        receiveMetadataMismatchCount += 1
        let summary = "RX META #\(receiveMetadataMismatchCount) / meta=\(metadata.encodedCodec.rawValue) actual=\(actualCodec.rawValue)"
        lastReceiveMetadataMismatchSummary = summary
        diagnosticsLogger.error("rx metadata mismatch peer=\(packet.peerID, privacy: .public) stream=\(packet.envelope.streamID.uuidString, privacy: .public) seq=\(packet.envelope.sequenceNumber) meta=\(metadata.encodedCodec.rawValue, privacy: .public) actual=\(actualCodec.rawValue, privacy: .public)")
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
        let playedByPeer = Dictionary(grouping: frames, by: \.peerID).mapValues(\.count)
        for (peerID, count) in playedByPeer {
            guard let memberIndex = group.members.firstIndex(where: { $0.id == peerID }) else { continue }
            group.members[memberIndex].playedAudioFrameCount += count
            group.members[memberIndex].queuedAudioFrameCount = max(0, group.members[memberIndex].queuedAudioFrameCount - count)
        }
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

    private func applyOutputGain(to frames: [JitterBufferedAudioFrame]) -> [JitterBufferedAudioFrame] {
        frames.map { frame in
            let gain = isOutputMuted ? 0 : masterOutputVolume * remoteOutputVolume(for: frame.peerID)
            return JitterBufferedAudioFrame(
                peerID: frame.peerID,
                streamID: frame.streamID,
                sequenceNumber: frame.sequenceNumber,
                frameID: frame.frameID,
                samples: frame.samples.map { clampedAudioSample($0 * gain) }
            )
        }
    }

    private func clampedMasterOutputVolume(_ value: Float) -> Float {
        min(Self.maximumMasterOutputVolume, max(0, value))
    }

    private func clampedAudioGain(_ value: Float) -> Float {
        min(1, max(0, value))
    }

    private func clampedAudioSample(_ value: Float) -> Float {
        min(1, max(-1, value))
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
