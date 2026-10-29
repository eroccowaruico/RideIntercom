import AVFAudio
import Foundation
import Testing
@testable import AudioCore

private final class CapturedFrames: @unchecked Sendable {
    let lock = NSLock()
    var frames: [PCMFrame] = []
    var snapshot: [PCMFrame] { lock.withLock { frames } }
    func append(_ frame: PCMFrame) { lock.withLock { frames.append(frame) } }
}

private func waitForEntry(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 1) == .success
}

@Test func finishingCaptureDiscardsQueuedAudioWithoutWaitingForTheCurrentCallback() async throws {
    let received = CapturedFrames()
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let capture = AudioRenderCapture(format: .init()) { frame in
        if frame.sequenceNumber == 0 { entered.signal(); release.wait() }
        received.append(frame)
    }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 480
    buffer.floatChannelData![0].update(repeating: 0.2, count: 480)
    var time = AudioTimeStamp()
    time.mFlags = .sampleTimeValid
    capture.receive(timestamp: time, frameCount: 480, data: buffer.audioBufferList)
    #expect(await Task.detached { waitForEntry(entered) }.value)
    for number in 1...3 {
        time.mSampleTime = Double(number * 480)
        capture.receive(timestamp: time, frameCount: 480, data: buffer.audioBufferList)
    }
    let start = ContinuousClock.now
    capture.finish()
    #expect(start.duration(to: .now) < .milliseconds(20))
    release.signal()
    time.mSampleTime = 1920
    capture.receive(timestamp: time, frameCount: 480, data: buffer.audioBufferList)
    try await Task.sleep(for: .milliseconds(50))
    #expect(received.snapshot.map(\.sequenceNumber) == [0], "Only the callback already in progress may finish")
    capture.finish()
    #expect(capture.droppedFrameCount == 0, "Explicit shutdown is not a capture overrun")
}

@Test func captureTimeFollowsTheSampleClockWhilePreservingRealGapsAndRestarts() async throws {
    let received = CapturedFrames()
    let capture = AudioRenderCapture(format: .init(), onFrame: received.append)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 480
    buffer.floatChannelData![0].update(repeating: 0.2, count: 480)
    for (sample, host): (Double, Double) in [(0, 10), (480, 10.012), (1440, 10.032), (0, 15)] {
        var time = AudioTimeStamp()
        time.mFlags = [.sampleTimeValid, .hostTimeValid]
        time.mSampleTime = sample
        time.mHostTime = AVAudioTime.hostTime(forSeconds: host)
        capture.receive(timestamp: time, frameCount: 480, data: buffer.audioBufferList)
    }
    let deadline = ContinuousClock.now + .seconds(1)
    while received.snapshot.count < 4 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    let frames = received.snapshot
    #expect(frames.count == 4)
    for (frame, expected) in zip(frames, [10.0, 10.01, 10.03, 15]) {
        #expect(abs(frame.capturedAt - expected) < 1e-6)
        #expect(frame.samples == Array(repeating: 0.2, count: 480))
    }
}

@Test func renderHandoffNeverWaitsForAStalledConsumerOrOverwritesUnreadAudio() async throws {
    let received = CapturedFrames()
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let capture = AudioRenderCapture(format: .init(), maximumFrames: 512, capacity: 4) { frame in
        if frame.sequenceNumber == 0 { entered.signal(); release.wait() }
        received.append(frame)
    }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    buffer.frameLength = 512
    func render(_ number: Int) {
        for sample in 0..<512 { buffer.floatChannelData![0][sample] = Float(number) / 10 }
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid
        time.mSampleTime = Double(number * 512)
        capture.receive(timestamp: time, frameCount: 512, data: buffer.audioBufferList)
    }
    render(0)
    let didEnter = await Task.detached { waitForEntry(entered) }.value
    #expect(didEnter)
    let start = ContinuousClock.now
    for number in 1...5 { render(number) }
    #expect(start.duration(to: .now) < .milliseconds(20), "The hardware thread must not wait for delivery")
    #expect(capture.droppedFrameCount == 512)
    release.signal()
    let deadline = ContinuousClock.now + .seconds(1)
    while received.snapshot.count < 5 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    render(6)
    while received.snapshot.count < 6 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    let frames = received.snapshot
    #expect(frames.map(\.sequenceNumber) == [0, 1, 2, 3, 4, 6])
    for frame in frames {
        #expect(frame.samples.count == 512)
        #expect(frame.samples.allSatisfy { $0 == Float(frame.sequenceNumber) / 10 })
    }
}
