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
    init(owner: AppCallOwner, session: WCSession = .default) {
        self.owner = owner
        self.session = session
        super.init()
    }
    func activate() {
        guard WCSession.isSupported(), !started else { return }
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
    }
    private func publish(_ value: WatchCallSnapshot) {
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(value) else { return }
        try? session.updateApplicationContext(["rideintercom.watch.v1": data])
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self, let owner else { return }
            publish(owner.watchSnapshot())
        }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self, let owner else { return }
            publish(owner.watchSnapshot())
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        let response = Reply(send: replyHandler)
        Task { @MainActor [weak self] in
            guard let self, let owner, messageData.count <= 32_768,
                  let request = try? JSONDecoder().decode(WatchControlRequest.self, from: messageData),
                  let data = try? JSONEncoder().encode(owner.handleWatchRequest(request)) else {
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
