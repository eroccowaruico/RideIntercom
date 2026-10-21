import Foundation

/// Each reader owns a mailbox. Slow readers keep control transitions, but audio
/// and telemetry are useful only while fresh. A wake-up never carries payloads.
final class EventSource<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptions: [UUID: Subscription] = [:]
    private var isFinished = false
    private let isTransient: @Sendable (Event) -> Bool

    init(isTransient: @escaping @Sendable (Event) -> Bool = { _ in false }) {
        self.isTransient = isTransient
    }

    var stream: AsyncStream<Event> {
        let id = UUID()
        let subscription = Subscription(isTransient: isTransient)
        lock.withLock {
            if isFinished { subscription.finish() }
            else { subscriptions[id] = subscription }
        }
        return AsyncStream(unfolding: { await subscription.next() }, onCancel: { [weak self] in
            subscription.finish()
            _ = self?.lock.withLock { self?.subscriptions.removeValue(forKey: id) }
        })
    }

    deinit { for subscription in subscriptions.values { subscription.finish() } }

    func yield(_ event: Event) {
        lock.withLock { for subscription in subscriptions.values { subscription.yield(event) } }
    }

    func finish() {
        lock.withLock {
            isFinished = true
            for subscription in subscriptions.values { subscription.finish() }
            subscriptions.removeAll()
        }
    }

    private final class Subscription: @unchecked Sendable {
        private struct Entry {
            var event: Event
            var expiresAt: ContinuousClock.Instant?
        }
        private let lock = NSLock()
        private let isTransient: @Sendable (Event) -> Bool
        private let wakeup = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        private var entries: [Entry] = []
        private var isFinished = false

        init(isTransient: @escaping @Sendable (Event) -> Bool) { self.isTransient = isTransient }

        func yield(_ event: Event) {
            lock.withLock {
                guard !isFinished else { return }
                let now = ContinuousClock.now
                entries.removeAll { $0.expiresAt.map { $0 <= now } ?? false }
                let transient = isTransient(event)
                if transient, entries.lazy.filter({ $0.expiresAt != nil }).count >= 64,
                   let oldest = entries.firstIndex(where: { $0.expiresAt != nil }) {
                    entries.remove(at: oldest)
                }
                entries.append(Entry(event: event, expiresAt: transient ? now.advanced(by: .milliseconds(100)) : nil))
                wakeup.continuation.yield(())
            }
        }

        func next() async -> Event? {
            while !Task.isCancelled {
                let (event, finished): (Event?, Bool) = lock.withLock {
                    let now = ContinuousClock.now
                    entries.removeAll { $0.expiresAt.map { $0 <= now } ?? false }
                    return (entries.isEmpty ? nil : entries.removeFirst().event, isFinished)
                }
                if let event { return event }
                if finished { return nil }
                for await _ in wakeup.stream { break }
            }
            return nil
        }

        func finish() {
            lock.withLock { isFinished = true; wakeup.continuation.finish() }
        }
    }
}
