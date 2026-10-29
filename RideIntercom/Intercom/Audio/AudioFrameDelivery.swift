import AudioCore
import Foundation
import Synchronization

/// Bounded handoff from package callbacks to the App's actor. DSP stays in the
/// packages; this object owns only delivery and cancellation for one connection.
final class AudioFrameDelivery {
    private nonisolated let continuation: AsyncStream<(PCMFrame, ContinuousClock.Instant)>.Continuation
    private let task: Task<Void, Never>
    private nonisolated let metrics = AudioDeliveryMetrics()
    nonisolated var isActive: Bool { !metrics.finished.load(ordering: .acquiring) }
    nonisolated var droppedFrameCount: Int { metrics.dropped.load(ordering: .relaxed) }

    init(receive: @escaping @MainActor (PCMFrame) -> Void) {
        let stream = AsyncStream<(PCMFrame, ContinuousClock.Instant)>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuation = stream.continuation
        let metrics = metrics
        task = Task {
            for await (frame, queuedAt) in stream.stream {
                guard !Task.isCancelled else { return }
                if queuedAt.duration(to: .now) < .milliseconds(100) { receive(frame) }
                else { metrics.dropped.wrappingAdd(frame.frameCount, ordering: .relaxed) }
            }
        }
    }

    nonisolated func yield(_ frame: PCMFrame) {
        if case .dropped(let previous) = continuation.yield((frame, .now)) {
            metrics.dropped.wrappingAdd(previous.0.frameCount, ordering: .relaxed)
        }
    }
    func finish() { metrics.finished.store(true, ordering: .releasing); continuation.finish(); task.cancel() }
    deinit { metrics.finished.store(true, ordering: .releasing); continuation.finish(); task.cancel() }
}

private nonisolated final class AudioDeliveryMetrics: Sendable {
    let dropped = Atomic<Int>(0)
    let finished = Atomic<Bool>(false)
}
