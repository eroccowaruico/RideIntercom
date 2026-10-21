import AudioCore
import Foundation

/// Bounded handoff from package callbacks to the App's actor. DSP stays in the
/// packages; this object owns only delivery and cancellation for one connection.
final class AudioFrameDelivery {
    private nonisolated let continuation: AsyncStream<(PCMFrame, ContinuousClock.Instant)>.Continuation
    private let task: Task<Void, Never>

    init(receive: @escaping @MainActor (PCMFrame) -> Void) {
        let stream = AsyncStream<(PCMFrame, ContinuousClock.Instant)>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuation = stream.continuation
        task = Task {
            for await (frame, queuedAt) in stream.stream {
                guard !Task.isCancelled else { return }
                if queuedAt.duration(to: .now) < .milliseconds(100) { receive(frame) }
            }
        }
    }

    nonisolated func yield(_ frame: PCMFrame) { continuation.yield((frame, .now)) }
    func finish() { continuation.finish(); task.cancel() }
    deinit { continuation.finish(); task.cancel() }
}
