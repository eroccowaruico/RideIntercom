import Foundation

/// Connection recovery only: never queues or retransmits application audio.
/// The owner chooses event-driven UDP recovery or route maintenance scheduling.
struct ConnectionRetry: Sendable {
    struct Policy: Sendable {
        let initialDelay: TimeInterval
        let maximumDelay: TimeInterval
        static let connectionRecovery = Policy(initialDelay: 2, maximumDelay: 30)
    }

    let delay: TimeInterval
    var deadline: TimeInterval

    init(after previous: Self?, at now: TimeInterval, policy: Policy) {
        delay = min(policy.maximumDelay, previous.map { $0.delay * 2 } ?? policy.initialDelay)
        deadline = now + delay
    }

    // Preserve failure history, but let the native connection own its timeout.
    mutating func beginAttempt() { deadline = .infinity }
}
