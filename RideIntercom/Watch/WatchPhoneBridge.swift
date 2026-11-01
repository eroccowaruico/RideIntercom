#if os(iOS)
import Foundation
import Observation
@preconcurrency import WatchConnectivity

/// Owned once by the app. Observation pushes current state; there is no polling.
@MainActor
final class WatchPhoneBridge: NSObject, WCSessionDelegate {
    private weak var owner: AppCallOwner?
    private let session: WCSession
    private var started = false
    private var lastPublishedSnapshot: WatchCallSnapshot?
    #if DEBUG && RIDEINTERCOM_VALIDATION
    private var recordingObservations: [[String: Any]] = []
    #endif
    init(owner: AppCallOwner, session: WCSession = .default) {
        self.owner = owner
        self.session = session
        super.init()
    }
    func activate() {
        guard SystemSurfaceScope.permitsCompanionAccess, WCSession.isSupported(), !started else { return }
        started = true
        session.delegate = self
        session.activate()
        observeAndPublish()
    }
    private func observeAndPublish() {
        guard let owner else { return }
        let value = withObservationTracking { owner.watchSnapshot() } onChange: { [weak self] in
            guard let bridge = self else { return }
            Task { @MainActor in bridge.observeAndPublish() }
        }
        publish(value)
        #if DEBUG && RIDEINTERCOM_VALIDATION
        if SystemSurfaceScope.permitsCompanionAccess, let check = value.audioCheck {
            let observations: [String: Any] = ["uptime": ProcessInfo.processInfo.systemUptime, "sessionID": check.sessionID.uuidString, "phase": check.phase.rawValue,
                "recordedFrames": check.recordedFrames, "nonzeroSamples": check.nonzeroSamples,
                "hasCall": value.hasCall, "usingWatch": owner.viewModel?.isUsingWatchAudio == true,
                "backendsRestored": owner.viewModel.map { $0.audioInputCapture === $0.nativeAudioInputCapture && $0.audioOutputRenderer === $0.nativeAudioOutputRenderer } ?? false]
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("watch-audio-check-phone.json")
            recordingObservations.append(observations)
            if recordingObservations.count > 24 { recordingObservations.removeFirst() }
            if let data = try? JSONSerialization.data(withJSONObject: recordingObservations, options: .sortedKeys) { try? data.write(to: file, options: .atomic) }
        }
        #endif
    }
    private func publish(_ value: WatchCallSnapshot, force: Bool = false) {
        guard SystemSurfaceScope.permitsCompanionAccess, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              force || value.needsPublication(after: lastPublishedSnapshot),
              let data = try? JSONEncoder().encode(value) else { return }
        do {
            try session.updateApplicationContext(["rideintercom.watch.v1": data])
            lastPublishedSnapshot = value
        } catch {
            // Keep the last accepted value so a later state observation can
            // retry. Explicit Watch refreshes also return a fresh snapshot.
        }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self, let owner else { return }
            publish(owner.watchSnapshot(), force: true)
        }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self, let owner else { return }
            publish(owner.watchSnapshot(), force: true)
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        guard SystemSurfaceScope.permitsCompanionAccess else { return }
        session.activate()
    }
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        let response = Reply(send: replyHandler)
        Task { @MainActor [weak self] in
            guard SystemSurfaceScope.permitsCompanionAccess, let self, let owner, messageData.count <= 32_768,
                  let request = try? JSONDecoder().decode(WatchControlRequest.self, from: messageData),
                  SystemSurfaceScope.permitsSystemAccess || request.action.isRecordingFixtureAction,
                  let data = try? JSONEncoder().encode(await owner.handleWatchRequest(request)) else {
                response.send(Data()); return
            }
            response.send(data)
            publish(owner.watchSnapshot())
        }
    }
    // WatchConnectivity supplies a callback safe to invoke from the receiving queue.
    // Transfer that callback exactly once to the app's main-actor call owner.
    private nonisolated struct Reply: @unchecked Sendable { let send: (Data) -> Void }
}
#endif
