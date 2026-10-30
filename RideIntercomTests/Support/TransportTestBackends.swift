import AVFAudio
import Foundation
import Synchronization
import AudioCore
import AudioMixer
import Codec
import RTC
import SessionManager
import Testing
import VADGate
import SoundIsolation
import PeakLimiter
@testable import RideIntercom

final class RecordingCallSession: RideIntercom.CallSession {
    var onEvent: ((TransportEvent) -> Void)?
    var processReceivedAudio: (@Sendable (RTC.ReceivedAudioPacket) -> AudioPacketReception)?
    private(set) var activeRouteDebugTypeName = "RecordingCallSession"
    private(set) var connectedGroup: IntercomGroup?
    private(set) var startMediaCallCount = 0
    private(set) var stopMediaCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var audioPolicies: [RTC.RTCAudioPolicy] = []
    private(set) var localMuteValues: [Bool] = []
    private(set) var outputMuteValues: [Bool] = []
    private(set) var enabledRouteValues: [Set<RTC.RouteKind>] = []
    private(set) var runtimePackageReports: [[RTCRuntimePackageReport]] = []
    private nonisolated let audioPackets = Mutex<[RTC.RTCAudioPacket]>([])
    var sentAudioPackets: [RTC.RTCAudioPacket] { audioPackets.withLock { $0 } }
    var audioPacketSink: @Sendable (RTC.RTCAudioPacket) -> Void {
        { [self] packet in audioPackets.withLock { $0.append(packet) } }
    }
    private(set) var sentControlMessages: [ControlMessage] = []
    private(set) var sentApplicationDataMessages: [ApplicationDataMessage] = []

    func connect(group: IntercomGroup) {
        connectedGroup = group
        let peerIDs = group.members.dropFirst().map(\.id)
        onEvent?(.localNetworkStatus(LocalNetworkEvent(status: .advertisingBrowsing)))
        onEvent?(.connected(peerIDs: peerIDs))
    }

    func startMedia() {
        startMediaCallCount += 1
    }

    func stopMedia() {
        stopMediaCallCount += 1
    }

    func disconnect() {
        disconnectCallCount += 1
        connectedGroup = nil
        memberships.removeAll()
        onEvent?(.disconnected)
    }

    func setAudioPolicy(_ policy: RTC.RTCAudioPolicy) {
        audioPolicies.append(policy)
    }

    func setLocalMute(_ muted: Bool) {
        localMuteValues.append(muted)
    }

    func setOutputMute(_ muted: Bool) {
        outputMuteValues.append(muted)
    }

    func setEnabledRoutes(_ routes: Set<RTC.RouteKind>) {
        enabledRouteValues.append(routes)
    }

    func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport]) {
        runtimePackageReports.append(reports)
    }

    func sendAudioPacket(_ packet: RTC.RTCAudioPacket) {
        audioPackets.withLock { $0.append(packet) }
    }

    func sendControl(_ message: ControlMessage) {
        sentControlMessages.append(message)
    }

    func sendApplicationData(_ message: ApplicationDataMessage) {
        sentApplicationDataMessages.append(message)
    }

    private var memberships: [String: UUID] = [:]
    func authenticate(_ peerIDs: [String]) {
        memberships = memberships.filter { peerIDs.contains($0.key) }
        for id in peerIDs where memberships[id] == nil { memberships[id] = UUID() }
        onEvent?(.authenticated(members: peerIDs.map {
            .init(peer: .init(id: .init(rawValue: $0), displayName: $0), route: .multipeer,
                  isConnected: true, membershipID: memberships[$0])
        }))
    }

    func receive(_ packet: RTC.ReceivedAudioPacket) {
        onEvent?(.receivedAudioPacket(packet, processReceivedAudio?(packet) ?? .unavailable))
    }

    func publishMetrics(_ metrics: RTC.RouteMetrics) {
        onEvent?(.routeMetrics(metrics))
    }
}

final class FakeRTCCallSession: RTC.CallSession {
    var events: AsyncStream<RTC.CallSessionEvent> {
        let id = UUID()
        let stream = AsyncStream<RTC.CallSessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        stream.continuation.onTermination = { [weak self] _ in
            _ = self?.lock.withLock { self?.subscribers.removeValue(forKey: id) }
        }
        lock.withLock {
            hasSubscriberValue = true
            subscribers[id] = stream.continuation
        }
        return stream.stream
    }

    var hasSubscriber: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasSubscriberValue
    }

    private var subscribers: [UUID: AsyncStream<RTC.CallSessionEvent>.Continuation] = [:]
    private let lock = NSLock()
    private var hasSubscriberValue = false

    func emit(_ event: RTC.CallSessionEvent) {
        let current = lock.withLock { Array(subscribers.values) }
        for continuation in current { continuation.yield(event) }
    }

    var prepareDelay: Duration = .zero
    var prepareGate: ManualAsyncGate?
    var audioGate: ManualAsyncGate?
    private var recordedOperations: [String] = []
    private var operationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var recordedMutes: [Bool] = []
    var operations: [String] { lock.withLock { recordedOperations } }
    var localMuteValues: [Bool] { lock.withLock { recordedMutes } }
    private func record(_ name: String) {
        let waiters = lock.withLock {
            recordedOperations.append(name)
            return operationWaiters.removeValue(forKey: name) ?? []
        }
        for waiter in waiters { waiter.resume() }
    }
    func waitForOperation(_ name: String) async {
        await withCheckedContinuation { continuation in
            let complete = lock.withLock {
                if recordedOperations.contains(name) { return true }
                operationWaiters[name, default: []].append(continuation)
                return false
            }
            if complete { continuation.resume() }
        }
    }
    func prepare(_ request: RTC.CallStartRequest) async {
        if let prepareGate { await prepareGate.wait() }
        if prepareDelay != .zero { try? await Task.sleep(for: prepareDelay) }
        record("prepare")
    }
    func startConnection() async { record("startConnection") }
    func stopConnection() async { record("stopConnection") }
    func startMedia() async { record("startMedia") }
    func stopMedia() async { record("stopMedia") }
    private var recordedAudioSequences: [UInt64] = []
    var sentAudioSequences: [UInt64] { lock.withLock { recordedAudioSequences } }
    func sendAudioPacket(_ packet: RTC.RTCAudioPacket) async {
        if let audioGate { await audioGate.wait() }
        lock.withLock { recordedAudioSequences.append(packet.sequenceNumber) }
    }
    private var recordedApplicationData: [RTC.ApplicationDataMessage] = []
    var sentApplicationDataMessages: [RTC.ApplicationDataMessage] { lock.withLock { recordedApplicationData } }
    func sendApplicationData(_ message: RTC.ApplicationDataMessage) async {
        lock.withLock { recordedApplicationData.append(message) }
    }
    private var recordedPolicies: [RTC.RTCAudioPolicy] = []
    var audioPolicies: [RTC.RTCAudioPolicy] { lock.withLock { recordedPolicies } }
    func updateAudioPolicy(_ policy: RTC.RTCAudioPolicy) async {
        lock.withLock { recordedPolicies.append(policy) }
        record("audioPolicy")
    }
    func updateRuntimePackageReports(_ reports: [RTC.RTCRuntimePackageReport]) async {}
    func setLocalMute(_ muted: Bool) async { lock.withLock { recordedMutes.append(muted) } }
    func setOutputMute(_ muted: Bool) async {}
}

final class TransportEventRecorder {
    private let lock = NSLock()
    private var events: [TransportEvent] = []

    var containsLinkFailure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains {
            if case .linkFailed = $0 {
                return true
            }
            return false
        }
    }

    func append(_ event: TransportEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

final class NoOpCallTicker: CallTicking {
    var onTick: ((TimeInterval) -> Void)?
    private(set) var isRunning = false

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

final class InternetTestKeychain: KeychainSecretStoring {
    func accounts(service: String) -> [String] { [] }
    var value: String?
    func createSecretIfAbsent(_ value: String, service: String, account: String) throws -> String {
        if let retained = try secret(service: service, account: account) { return retained }
        try saveSecret(value, service: service, account: account)
        return value
    }
    func saveSecret(_ secret: String, service: String, account: String) throws { value = secret }
    func secret(service: String, account: String) throws -> String? { value }
    func deleteSecret(service: String, account: String) throws { value = nil }
}

final class RejectingGroupCredentialStore: GroupCredentialStoring {
    func saveSecret(_ secret: String, reference: UUID) throws { throw IntercomGroupError.storageUnavailable }
    func secret(reference: UUID) -> String? { nil }
    func delete(reference: UUID) {}
    func references() -> Set<UUID> { [] }
}
