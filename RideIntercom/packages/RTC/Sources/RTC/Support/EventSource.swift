import Foundation

/// Each reader owns a subscription. Cancelling a call's reader must not finish
/// the route's event source, which will be reused by the next connection.
final class EventSource<Event: Sendable>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var isFinished = false

    var stream: AsyncStream<Event> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
            lock.withLock {
                if isFinished { continuation.finish() }
                else { continuations[id] = continuation }
            }
        }
    }

    deinit {
        for continuation in continuations.values { continuation.finish() }
    }

    func yield(_ event: Event) {
        lock.withLock {
            for continuation in Array(continuations.values) { continuation.yield(event) }
        }
    }

    func finish() {
        lock.withLock {
            isFinished = true
            let subscribers = Array(continuations.values)
            continuations.removeAll()
            for continuation in subscribers { continuation.finish() }
        }
    }
}
