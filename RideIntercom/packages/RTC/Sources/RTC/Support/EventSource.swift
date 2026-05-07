import Foundation

final class EventSource<Event: Sendable>: @unchecked Sendable {
    let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    init() {
        var continuation: AsyncStream<Event>.Continuation?
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation!
    }

    func yield(_ event: Event) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}
