import AVFAudio
import Foundation
import Synchronization

/// A bounded single-render-thread / single-delivery-thread handoff. The render
/// thread only copies into preallocated memory and signals the delivery queue;
/// conversion, allocation, locks and application callbacks run off that thread.
public final class AudioRenderCapture: @unchecked Sendable {
    private final class Slot {
        let samples: UnsafeMutablePointer<Float>
        var count = 0
        var capturedAt = 0.0
        var sequence: UInt64 = 0
        init(capacity: Int) { samples = .allocate(capacity: capacity) }
        deinit { samples.deallocate() }
    }

    private let format: AudioFormat
    private let maximumFrames: Int
    private let slots: [Slot]
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    private let active = Atomic<Bool>(true)
    private var sequence: UInt64 = 0 // render-thread owned
    private var clockAnchor: (sample: Double, host: Double)?
    private var previousSampleTime: Double?
    private let signal: DispatchSourceUserDataAdd
    private let onFrame: (PCMFrame) -> Void

    public var droppedFrameCount: Int { dropped.load(ordering: .relaxed) }

    public init(format: AudioFormat, maximumFrames: Int = 4096, capacity: Int = 32,
                onFrame: @escaping (PCMFrame) -> Void) {
        precondition(format.isValid && maximumFrames > 0 && capacity > 1)
        self.format = format
        self.maximumFrames = maximumFrames
        self.slots = (0..<capacity).map { _ in Slot(capacity: maximumFrames * format.channelCount) }
        self.onFrame = onFrame
        signal = DispatchSource.makeUserDataAddSource(queue: DispatchQueue(
            label: "RideIntercom.AudioRenderCapture", qos: .userInteractive))
        signal.setEventHandler { [weak self] in self?.drain() }
        signal.resume()
    }

    deinit { signal.cancel() }

    /// Stop accepting and delivering queued audio. An application callback
    /// already in progress may finish; shutdown never waits behind that callback.
    public func finish() {
        active.store(false, ordering: .releasing)
        signal.cancel()
    }

    /// Noninterleaved Float32, in the negotiated hardware / graph format.
    public func receive(timestamp: AudioTimeStamp, frameCount: UInt32, data: UnsafePointer<AudioBufferList>) {
        guard active.load(ordering: .acquiring) else { return }
        let number = sequence
        sequence &+= 1
        let head = written.load(ordering: .relaxed)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
        guard frameCount > 0, frameCount <= maximumFrames,
              buffers.count == format.channelCount,
              head - consumed.load(ordering: .acquiring) < slots.count else {
            dropped.wrappingAdd(Int(frameCount), ordering: .relaxed)
            return
        }
        let slot = slots[head % slots.count]
        for channel in 0..<format.channelCount {
            guard let pointer = buffers[channel].mData,
                  buffers[channel].mDataByteSize >= frameCount * 4 else {
                dropped.wrappingAdd(Int(frameCount), ordering: .relaxed)
                return
            }
            let input = pointer.assumingMemoryBound(to: Float.self)
            for sample in 0..<Int(frameCount) {
                slot.samples[sample * format.channelCount + channel] = input[sample]
            }
        }
        slot.count = Int(frameCount) * format.channelCount
        slot.sequence = number
        slot.capturedAt = captureTime(timestamp)
        written.store(head + 1, ordering: .releasing)
        signal.add(data: 1)
    }

    private func captureTime(_ timestamp: AudioTimeStamp) -> Double {
        let host = timestamp.mFlags.contains(.hostTimeValid)
            ? AVAudioTime.seconds(forHostTime: timestamp.mHostTime) : nil
        guard timestamp.mFlags.contains(.sampleTimeValid), timestamp.mSampleTime.isFinite else {
            clockAnchor = nil; previousSampleTime = nil
            return host ?? 0
        }
        let sample = timestamp.mSampleTime
        if clockAnchor == nil || previousSampleTime.map({ sample <= $0 }) == true {
            clockAnchor = (sample, host ?? sample / format.sampleRate)
        }
        previousSampleTime = sample
        let anchor = clockAnchor!
        // Timestamp observation jitter is not a gap in captured PCM. Preserve
        // the device's sample clock; forward gaps remain gaps and a reset
        // establishes a new host anchor instead of replaying an old epoch.
        return anchor.host + (sample - anchor.sample) / format.sampleRate
    }

    private func drain() {
        var tail = consumed.load(ordering: .relaxed)
        while active.load(ordering: .acquiring), tail < written.load(ordering: .acquiring) {
            let slot = slots[tail % slots.count]
            let frame = PCMFrame(sequenceNumber: slot.sequence, format: format,
                capturedAt: slot.capturedAt, samples: Array(UnsafeBufferPointer(start: slot.samples, count: slot.count)))
            tail += 1
            consumed.store(tail, ordering: .releasing)
            onFrame(frame)
        }
    }
}
