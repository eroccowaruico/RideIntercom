import Foundation
@preconcurrency import WatchConnectivity

@MainActor
final class WatchConnectivityClient: NSObject, WCSessionDelegate {
    let client: WatchControlClient
    let audio: WatchAudioController
    private let session: WCSession
    init(session: WCSession = .default) {
        self.session = session
        let control = WatchControlClient { request in
            guard SystemSurfaceScope.permitsSystemAccess else { throw CocoaError(.featureUnsupported) }
            let data = try JSONEncoder().encode(request)
            let response: Data = try await withCheckedThrowingContinuation { continuation in
                session.sendMessageData(data, replyHandler: { continuation.resume(returning: $0) },
                                        errorHandler: { continuation.resume(throwing: $0) })
            }
            guard response.count <= 262_144 else { throw CocoaError(.coderReadCorrupt) }
            return try JSONDecoder().decode(WatchControlReply.self, from: response)
        }
        client = control
        audio = WatchAudioController(client: control)
        super.init()
    }
    func activate() {
        guard SystemSurfaceScope.permitsSystemAccess, WCSession.isSupported() else { return }
        session.delegate = self
        if session.activationState != .activated { session.activate() }
        else { refreshReachability() }
    }
    private func refreshReachability() {
        guard SystemSurfaceScope.permitsSystemAccess else { return }
        client.setReachable(session.activationState == .activated && session.isReachable)
        if client.isReachable { Task { await client.perform(.refresh) } }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor [weak self] in self?.refreshReachability() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refreshReachability() }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard SystemSurfaceScope.permitsSystemAccess, let data = applicationContext["rideintercom.watch.v1"] as? Data, data.count <= 262_144,
              let value = try? JSONDecoder().decode(WatchCallSnapshot.self, from: data) else { return }
        Task { @MainActor [weak self] in self?.client.receive(value) }
    }
}
