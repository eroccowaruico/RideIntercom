import Foundation
import RTC

/// One bounded media worker, independent of the actor that owns UI and control.
/// Suspend revokes queued audio immediately; an in-flight backend call must
/// finish before a new generation can send, preserving backend call ordering.
nonisolated final class AudioPacketDelivery: @unchecked Sendable {
    private struct Entry {
        let packet: RTCAudioPacket
        let queuedAt: ContinuousClock.Instant
        let duration: TimeInterval
    }
    private let lock = NSLock()
    private var accepting = false
    private var session: RTC.CallSession?
    private var pending: [Entry] = []
    private var pendingDuration: TimeInterval = 0
    private var worker: Task<Void, Never>?
    private var dropped = 0
    var droppedPacketCount: Int { lock.withLock { dropped } }

    func enqueue(_ packet: RTCAudioPacket) {
        let samplesDuration = Double(packet.sampleCount ?? 0)
            / Double(packet.format.channelCount) / packet.format.sampleRate
        let duration = samplesDuration.isFinite && samplesDuration > 0 ? samplesDuration : 0.02
        lock.withLock {
            guard accepting else { return }
            while !pending.isEmpty && (pending.count >= 64 || pendingDuration + duration > 0.100001) {
                pendingDuration -= pending.removeFirst().duration
                dropped += 1
            }
            pending.append(Entry(packet: packet, queuedAt: .now, duration: duration))
            pendingDuration += duration
            startWorker()
        }
    }

    func begin() { lock.withLock { accepting = true } }

    func resume(with session: RTC.CallSession) {
        lock.withLock { accepting = true; self.session = session; startWorker() }
    }

    func suspend() {
        lock.withLock {
            accepting = false
            session = nil
            pending.removeAll(keepingCapacity: true)
            pendingDuration = 0
            worker?.cancel()
        }
    }

    // These two methods are called only while holding the lock. No backend
    // operation or suspension point executes with the lock held.
    private func startWorker() {
        guard worker == nil, session != nil, !pending.isEmpty else { return }
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            while let next = self?.takeNext() {
                await next.0.sendAudioPacket(next.1)
            }
        }
    }

    private func takeNext() -> (RTC.CallSession, RTCAudioPacket)? {
        lock.withLock {
            if !Task.isCancelled, let session {
                while !pending.isEmpty {
                    let entry = pending.removeFirst()
                    pendingDuration = max(0, pendingDuration - entry.duration)
                    if entry.queuedAt.duration(to: .now) < .milliseconds(100) {
                        return (session, entry.packet)
                    }
                    dropped += 1
                }
            }
            worker = nil
            startWorker()
            return nil
        }
    }

    deinit { worker?.cancel() }
}
