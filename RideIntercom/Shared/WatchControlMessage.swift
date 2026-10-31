import Foundation

nonisolated struct WatchCallTarget: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    var canNotify = false
}

nonisolated enum CallNotificationStatus: String, Codable, Sendable {
    case processing, accepted, noDestinations = "no_destinations", retryLater = "retry_later", rejected, cancelled
}

nonisolated struct WatchCallNotification: Codable, Equatable, Sendable {
    let requestID: UUID
    let status: CallNotificationStatus
    let canCancel: Bool
}

nonisolated enum WatchCallState: String, Codable, Sendable {
    case signedOut, idle, connecting, inCall, audioPaused, audioUnavailable
}

nonisolated struct WatchCallSnapshot: Codable, Equatable, Sendable {
    let reference: String?
    let generatedAt: Date
    let validUntil: Date
    let targets: [WatchCallTarget]
    let title: String?
    let hasCall: Bool
    let isMuted: Bool
    let state: WatchCallState
    var notification: WatchCallNotification?
}

nonisolated enum WatchCallAction: Codable, Equatable, Sendable {
    case refresh
    case start(String)
    case end
    case setMuted(Bool)
    case requestCall(String)
    case cancelCallRequest(UUID)
}

nonisolated struct WatchControlRequest: Codable, Equatable, Sendable {
    let action: WatchCallAction
    let reference: String?
    let validUntil: Date
    init(_ action: WatchCallAction, snapshot: WatchCallSnapshot? = nil) {
        self.action = action
        reference = snapshot?.reference
        validUntil = snapshot?.validUntil ?? .distantPast
    }
}

nonisolated enum WatchControlProblem: String, Codable, Sendable {
    case unavailable, stale, noAccount, missingDestination, denied
}

nonisolated struct WatchControlReply: Codable, Equatable, Sendable {
    let snapshot: WatchCallSnapshot
    let problem: WatchControlProblem?
}
