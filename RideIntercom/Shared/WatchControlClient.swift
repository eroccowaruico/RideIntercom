import Foundation
import Observation

/// Display and in-flight UI only. The companion iPhone remains the call owner.
@MainActor @Observable
final class WatchControlClient {
    private(set) var snapshot: WatchCallSnapshot?
    private(set) var isReachable = false
    private(set) var isWaiting = false
    private(set) var problem: WatchControlProblem?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private let send: (WatchControlRequest) async throws -> WatchControlReply
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init,
         send: @escaping (WatchControlRequest) async throws -> WatchControlReply) {
        self.now = now
        self.send = send
    }

    func setReachable(_ value: Bool) {
        guard isReachable != value else { return }
        isReachable = value
        connectionGeneration = UUID()
        isWaiting = false
        if !value { snapshot = nil; problem = .unavailable }
    }

    func receive(_ value: WatchCallSnapshot) {
        guard isReachable, snapshot.map({ value.generatedAt >= $0.generatedAt }) ?? true else { return }
        snapshot = value
    }

    func perform(_ action: WatchCallAction) async {
        guard isReachable else { problem = .unavailable; return }
        guard !isWaiting else { return }
        let generation = connectionGeneration
        let displayedReference = snapshot?.reference
        isWaiting = true; problem = nil
        defer { if generation == connectionGeneration { isWaiting = false } }
        do {
            // A long-running call may outlive its displayed snapshot. Refresh once on
            // interaction, never poll or enqueue a delayed microphone/start command.
            if action != .refresh, snapshot == nil || snapshot!.validUntil <= now() {
                let updated = try await send(.init(.refresh))
                guard generation == connectionGeneration else { return }
                receive(updated.snapshot)
                guard displayedReference != nil, displayedReference == snapshot?.reference else {
                    problem = .stale; return
                }
            }
            let reply = try await send(.init(action, snapshot: snapshot))
            guard generation == connectionGeneration else { return }
            receive(reply.snapshot)
            problem = reply.problem
        } catch {
            guard generation == connectionGeneration else { return }
            problem = .unavailable
        }
    }
}
