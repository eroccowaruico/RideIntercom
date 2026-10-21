import AVFAudio
import Foundation
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
    private(set) var sentAudioPackets: [RTC.RTCAudioPacket] = []
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
        sentAudioPackets.append(packet)
    }

    func sendControl(_ message: ControlMessage) {
        sentControlMessages.append(message)
    }

    func sendApplicationData(_ message: ApplicationDataMessage) {
        sentApplicationDataMessages.append(message)
    }

    func authenticate(_ peerIDs: [String]) {
        onEvent?(.authenticated(peerIDs: peerIDs))
    }

    func receive(_ packet: RTC.ReceivedAudioPacket) {
        onEvent?(.receivedAudioPacket(packet))
    }

    func publishMetrics(_ metrics: RTC.RouteMetrics) {
        onEvent?(.routeMetrics(metrics))
    }
}

final class FakeRTCCallSession: RTC.CallSession {
    var events: AsyncStream<RTC.CallSessionEvent> {
        lock.lock()
        hasSubscriberValue = true
        lock.unlock()
        return eventStream
    }

    var hasSubscriber: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasSubscriberValue
    }

    private let eventStream: AsyncStream<RTC.CallSessionEvent>
    private let continuation: AsyncStream<RTC.CallSessionEvent>.Continuation
    private let lock = NSLock()
    private var hasSubscriberValue = false

    init() {
        var continuation: AsyncStream<RTC.CallSessionEvent>.Continuation?
        self.eventStream = AsyncStream { continuation = $0 }
        self.continuation = continuation!
    }

    func emit(_ event: RTC.CallSessionEvent) {
        continuation.yield(event)
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
    func sendApplicationData(_ message: RTC.ApplicationDataMessage) async {}
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
