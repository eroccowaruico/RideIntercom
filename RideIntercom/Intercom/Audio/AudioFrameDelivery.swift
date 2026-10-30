import AudioCore
import Foundation
import Synchronization

/// Bounded handoff from package callbacks to the App's actor. DSP stays in the
/// packages; this object owns only delivery and cancellation for one connection.
/// Calls deliver coalesced observations after synchronous DSP; Audio Check opts
/// into complete PCM delivery for recording.
final class AudioFrameDelivery {
    private nonisolated let continuation: AsyncStream<(PCMFrame, ContinuousClock.Instant)>.Continuation
    private let task: Task<Void, Never>
    private nonisolated let metrics: AudioDeliveryMetrics
    nonisolated var isActive: Bool { metrics.state.load(ordering: .acquiring) == 1 }
    nonisolated var droppedFrameCount: Int { metrics.dropped.load(ordering: .relaxed) }

    init(initiallyActive: Bool = true, coalescesObservations: Bool = false, receive: @escaping @MainActor (PCMFrame) -> Void) {
        metrics = AudioDeliveryMetrics(initiallyActive: initiallyActive, coalescesObservations: coalescesObservations)
        let stream = AsyncStream<(PCMFrame, ContinuousClock.Instant)>.makeStream(bufferingPolicy: .bufferingNewest(coalescesObservations ? 1 : 32))
        continuation = stream.continuation
        let metrics = metrics
        task = Task {
            for await (frame, queuedAt) in stream.stream {
                guard !Task.isCancelled, metrics.state.load(ordering: .acquiring) == 1 else { return }
                if coalescesObservations || queuedAt.duration(to: .now) < .milliseconds(100) { receive(frame) }
                else { metrics.dropped.wrappingAdd(frame.frameCount, ordering: .relaxed) }
            }
        }
    }

    nonisolated func yield(_ frame: PCMFrame) {
        guard isActive else { return }
        if metrics.coalescesObservations {
            let now = DispatchTime.now().uptimeNanoseconds
            let next = metrics.nextObservation.load(ordering: .relaxed)
            guard now >= next,
                  metrics.nextObservation.compareExchange(expected: next, desired: now + 50_000_000,
                    ordering: .relaxed).exchanged else { return }
        }
        if case .dropped(let previous) = continuation.yield((frame, .now)), !metrics.coalescesObservations {
            metrics.dropped.wrappingAdd(previous.0.frameCount, ordering: .relaxed)
        }
    }
    func activate() { _ = metrics.state.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing) }
    func finish() { metrics.state.store(2, ordering: .releasing); continuation.finish(); task.cancel() }
    deinit { metrics.state.store(2, ordering: .releasing); continuation.finish(); task.cancel() }
}

private nonisolated final class AudioDeliveryMetrics: Sendable {
    let dropped = Atomic<Int>(0)
    // Pending -> active -> finished; a cancelled connection cannot be revived.
    let state: Atomic<UInt8>
    let coalescesObservations: Bool
    let nextObservation = Atomic<UInt64>(0)
    init(initiallyActive: Bool, coalescesObservations: Bool) {
        state = Atomic(initiallyActive ? 1 : 0)
        self.coalescesObservations = coalescesObservations
    }
}
