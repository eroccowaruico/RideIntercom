import AudioCore
import AVFAudio
import Synchronization
import Testing

private final class TransitionSignal: Sendable {
    let silent = Atomic<Bool>(false)
}

@Test func subSampleInputQuantaDoNotScheduleEmptyNativeBuffers() throws {
    let mixer = try AudioMixer(audioFormat: .init(sampleRate: 16000, channelCount: 1))
    let bus = try mixer.createBus("fractional-input")
    let source = try bus.addPCMSource(id: "voice")
    try mixer.routeToOutput(bus)
    try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 16)
    try mixer.start()
    defer { mixer.stop() }
    var emitted = 0
    for index in 0..<7 {
        let report = try source.schedule(.init(sequenceNumber: UInt64(index),
            format: .init(sampleRate: 96000, channelCount: 1), capturedAt: Double(index) / 96000,
            samples: [Float(0.1 + Double(index) * 0.001)]))
        emitted += report.outputSampleCount
    }
    #expect(emitted == 2)
    source.start()
    let output = try #require(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 16))
    #expect(try mixer.engine.renderOffline(2, to: output) == .success)
    #expect(abs(output.floatChannelData![0][0] - 0.1) < 0.000001)
    #expect(abs(output.floatChannelData![0][1] - 0.106) < 0.000001)
}

@Test(arguments: [16000.0, 24000.0, 44100.0])
func receiveResamplingDoesNotRepeatTheLastSampleOfEveryPacket(rate: Double) throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("resampled-peer")
    let source = try bus.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 4800)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let count = Int(rate / 100)
    for packet in 0..<10 {
        let frame = PCMFrame(sequenceNumber: UInt64(packet), format: .init(sampleRate: rate, channelCount: 1),
            capturedAt: Double(packet) / 100,
            samples: (0..<count).map { Float(0.1 + Double(packet * count + $0) / rate * 0.7) })
        try source.schedule(frame)
    }
    Thread.sleep(forTimeInterval: 0.01)
    let output = try #require(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 4800))
    #expect(try mixer.engine.renderOffline(4800, to: output) == .success)
    let samples = try #require(output.floatChannelData)[0]
    let reference = rate == 44100 ? try nativeFractionalReference(
        (0..<Int(rate / 10)).map { Float(0.1 + Double($0) / rate * 0.7) }, from: rate, to: 48000) : nil
    var error: Float = 0
    for index in 0..<4700 {
        let expected = reference?[index] ?? Float(0.1 + Double(index) / 48000.0 * 0.7)
        error = max(error, abs(samples[index + 96] - expected))
    }
    #expect(error < 0.000001, "Every received packet boundary must match uninterrupted conversion, including native filter startup")
    #expect(source.playbackResetCount == 0)
}

@Test func adaptivePlayoutRetainsLatePacketsAndRemovesDelayDuringSilence() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("adaptive")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.02, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    try source.schedule(.init(sequenceNumber: 0, capturedAt: 1000, samples: Array(repeating: 0.2, count: 960)))
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(2400, to: output) == .success) // 50 ms
    #expect((0..<960).allSatisfy { abs(output.floatChannelData![0][$0]) < 0.001 })
    #expect((960..<1920).allSatisfy { abs(output.floatChannelData![0][$0] - 0.2) < 0.001 })
    // A late packet must retain its end rather than lose 10 ms of speech.
    try source.schedule(.init(sequenceNumber: 1, capturedAt: 1000.02, samples: Array(repeating: 0.4, count: 960)))
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(2400, to: output) == .success)
    #expect((1056..<1920).allSatisfy { abs(output.floatChannelData![0][$0] - 0.4) < 0.001 })
    #expect(source.playoutAdjustmentCount == 1)
    // Three seconds later, the extra wait must not carry into a new reply.
    for index in 0..<30 { #expect(try engine.renderOffline(4800, to: output) == .success, "silence \(index)") }
    try source.schedule(.init(sequenceNumber: 2, capturedAt: 1003.1, samples: Array(repeating: 0.3, count: 960)))
    #expect(source.bufferedDuration <= 0.041)
    #expect(source.playbackResetCount == 0, "Natural conversation pauses are not corrupt clocks")
}
@testable import AudioMixer

@Test func healthyConversationPauseKeepsItsClockButExcessWaitIsRemoved() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("pause-clock")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.02, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    try source.schedule(.init(sequenceNumber: 0, capturedAt: 1000, samples: Array(repeating: 0.2, count: 480)))
    for _ in 0..<3 { #expect(try engine.renderOffline(4800, to: output) == .success) }
    try source.schedule(.init(sequenceNumber: 1, capturedAt: 1000.305, samples: Array(repeating: 0.3, count: 480)))
    #expect(source.playoutAdjustmentCount == 0, "A healthy pause must not move the following syllable")
    #expect(abs(source.bufferedDuration - 0.035) < 1 / 48000.0)
    for _ in 0..<30 { #expect(try engine.renderOffline(4800, to: output) == .success) }
    try source.schedule(.init(sequenceNumber: 2, capturedAt: 1003.38, samples: Array(repeating: 0.4, count: 480)))
    #expect(source.playoutAdjustmentCount == 1, "Excess wait must still be removed after a pause")
    #expect(source.bufferedDuration <= 0.031)
    #expect(source.playbackResetCount == 0)
}

@Test func graphTransitionFadesTheDeviceOutputAndDoesNotOnlyModifyItsObserver() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("output-transition")
    let signal = TransitionSignal()
    let source = AVAudioSourceNode(format: format) { _, _, count, buffers in
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            buffer.mData!.assumingMemoryBound(to: Float.self).update(
                repeating: signal.silent.load(ordering: .relaxed) ? 0 : 0.25, count: Int(count))
        }
        return noErr
    }
    try bus.addSource(source, id: "continuous")
    _ = try bus.installPCMSink(id: "meter", targetFormat: .init()) { _, _ in }
    try mixer.routeToOutput(bus); try mixer.start()
    defer { mixer.stop() }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    #expect(try engine.renderOffline(480, to: output) == .success)
    bus.beginSinkTransition(settlingDuration: 0, holding: true)
    #expect(try engine.renderOffline(480, to: output) == .success)
    let down = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: 480))
    #expect(abs(down[0] - 0.25) < 0.00001)
    #expect(down[96...].allSatisfy { $0 == 0 })
    #expect(zip(down, down.dropFirst()).allSatisfy { abs($1 - $0) < 0.003 })
    for _ in 0..<3 {
        #expect(try engine.renderOffline(480, to: output) == .success)
        #expect((0..<480).allSatisfy { output.floatChannelData![0][$0] == 0 })
    }
    signal.silent.store(true, ordering: .relaxed) // Native reconfiguration can outlast declared DSP latency.
    bus.beginSinkTransition(settlingDuration: 0.01)
    for _ in 0..<3 {
        #expect(try engine.renderOffline(480, to: output) == .success)
        #expect((0..<480).allSatisfy { output.floatChannelData![0][$0] == 0 })
    }
    signal.silent.store(false, ordering: .relaxed)
    #expect(try engine.renderOffline(480, to: output) == .success)
    let up = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: 480))
    #expect(up[0] == 0)
    #expect(up[96...].allSatisfy { $0 == 0.25 })
    #expect(zip(up, up.dropFirst()).allSatisfy { abs($1 - $0) < 0.003 })
    #expect(try engine.renderOffline(480, to: output) == .success)
    #expect((0..<480).allSatisfy { output.floatChannelData![0][$0] == 0.25 })
}

@Test func twoPacketCaptureBatchesDoNotShortenNormalConversationPauses() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 960)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("batched-conversation")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.01, adaptivePlayout: true)
    try mixer.routeToOutput(bus); try mixer.start(); source.start()
    defer { mixer.stop() }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
    var rendered: [Float] = []
    for batch in 0..<50 {
        for packet in 0..<2 {
            let index = batch * 2 + packet
            try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) * 0.01,
                samples: Array(repeating: batch < 25 ? 0 : 0.2, count: 480)))
        }
        #expect(try engine.renderOffline(960, to: buffer) == .success)
        rendered += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 960))
    }
    #expect(source.playoutAdjustmentCount == 0, "Two 10 ms packets from one 20 ms capture are not stale backlog")
    #expect(rendered[0..<24480].allSatisfy { abs($0) < 0.00001 })
    #expect(rendered[24480..<48000].allSatisfy { abs($0 - 0.2) < 0.00001 })
}

@Test func overlappingCaptureBatchesPreserveUnplayedTail() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("capture-overlap")
    let source = try bus.addPCMSource(id: "input", maximumBufferedDuration: 0.1)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    try source.schedule(.init(sequenceNumber: 0, format: mixer.audioFormat,
                              samples: Array(repeating: 0.2, count: 4800)))
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(4560, to: output) == .success)
    #expect((0..<4560).allSatisfy { abs(output.floatChannelData![0][$0] - 0.2) < 0.001 })
    // A 100 ms capture arrives 5 ms before the previous one finishes.
    // It must wait behind that tail instead of interrupting it.
    for i in 1...10 {
        let value: Float = i.isMultiple(of: 2) ? 0.2 : 0.4
        try source.schedule(.init(sequenceNumber: UInt64(i), format: mixer.audioFormat,
                                  samples: Array(repeating: value, count: 4800)))
        // Let the player command queue settle without advancing the offline clock.
        Thread.sleep(forTimeInterval: 0.01)
        #expect(try engine.renderOffline(4800, to: output) == .success)
        let samples = output.floatChannelData![0]
        #expect((0..<240).allSatisfy { abs(samples[$0] - (0.6 - value)) < 0.001 })
        #expect((240..<4800).allSatisfy { abs(samples[$0] - value) < 0.001 })
    }
    #expect(source.playbackResetCount == 0)
}

@Test func renderedCaptureBatchesDoNotCountAsPendingPlayback() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init(sampleRate: 48000, channelCount: 1))
    let bus = try mixer.createBus("capture")
    let source = try bus.addPCMSource(id: "input", maximumBufferedDuration: 0.1)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    for i in 0..<10 {
        try source.schedule(.init(sequenceNumber: UInt64(i), format: mixer.audioFormat,
                                  samples: Array(repeating: 0.2, count: 4800)))
        #expect(try engine.renderOffline(4800, to: output) == .success)
        #expect(source.bufferedDuration < 1 / 48000.0, "Rendered samples cannot consume the next batch's budget")
    }
    #expect(source.playbackResetCount == 0)
}

@Test func consecutiveFramesPreserveDurationAndMixOtherSpeakerOffline() throws {
    let mixer = try AudioMixer(audioFormat: AudioFormat(sampleRate: 48_000, channelCount: 1))
    let master = try mixer.createBus("master")
    let a = try mixer.createBus("a")
    let b = try mixer.createBus("b")
    let sourceA = try a.addPCMSource(id: "speaker-a")
    let sourceB = try b.addPCMSource(id: "speaker-b")
    try mixer.route(a, to: master)
    try mixer.route(b, to: master)
    try mixer.routeToOutput(master)
    try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 1024)
    try mixer.start()
    defer { mixer.stop() }
    for number in 1...2 {
        try sourceA.schedule(PCMFrame(sequenceNumber: UInt64(number), format: mixer.audioFormat,
                                      capturedAt: Double(number) * 0.01,
                                      samples: Array(repeating: Float(number) * 0.1, count: 480)))
    }
    try sourceB.schedule(PCMFrame(sequenceNumber: 1, format: mixer.audioFormat, capturedAt: 0.01,
                                  samples: Array(repeating: 0.3, count: 960)))
    sourceA.start()
    sourceB.start()
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 960))
    #expect(try mixer.engine.renderOffline(960, to: buffer) == .success)
    #expect(buffer.frameLength == 960)
    let samples = try #require(buffer.floatChannelData)[0]
    for index in 0..<960 {
        let expected: Float = index < 480 ? 0.4 : 0.5
        #expect(abs(samples[index] - expected) < 0.001)
    }
}

@Test func captureTimePlayoutPreservesOmittedSilenceAndBurstTiming() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 7680)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("network")
    let source = try bus.addPCMSource(id: "received", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: 0.04)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    // Both packets arrive together. Their capture clock has an arbitrary epoch
    // and an 80 ms pause between them; arrival order alone cannot preserve it.
    try source.schedule(.init(sequenceNumber: 0, format: .init(), capturedAt: 9000,
                              samples: Array(repeating: 0.2, count: 960)))
    try source.schedule(.init(sequenceNumber: 1, format: .init(), capturedAt: 9000.1,
                              samples: Array(repeating: 0.4, count: 960)))
    Thread.sleep(forTimeInterval: 0.01)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 7680)!
    #expect(try engine.renderOffline(7680, to: output) == .success)
    let samples = output.floatChannelData![0]
    #expect((0..<1920).allSatisfy { abs(samples[$0]) < 0.001 })
    #expect((1920..<2880).allSatisfy { abs(samples[$0] - 0.2) < 0.001 })
    #expect((2880..<6720).allSatisfy { abs(samples[$0]) < 0.001 })
    #expect((6720..<7680).allSatisfy { abs(samples[$0] - 0.4) < 0.001 })
    #expect(source.playbackResetCount == 0)
}

@Test func captureTimePlayoutRebasesClockJumpsWithinBudget() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("discontinuity")
    let source = try bus.addPCMSource(id: "received", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: 0.04)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    try source.schedule(.init(sequenceNumber: 0, format: .init(), capturedAt: 10,
                              samples: Array(repeating: 0.2, count: 960)))
    try source.schedule(.init(sequenceNumber: 1, format: .init(), capturedAt: 10000,
                              samples: Array(repeating: 0.4, count: 960)))
    #expect(source.bufferedDuration <= 0.06)
    #expect(source.playbackResetCount == 1)
    Thread.sleep(forTimeInterval: 0.01)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    #expect(try engine.renderOffline(4800, to: output) == .success)
    let samples = output.floatChannelData![0]
    #expect((0..<1920).allSatisfy { abs(samples[$0]) < 0.001 })
    #expect((1920..<2880).allSatisfy { abs(samples[$0] - 0.4) < 0.001 })
    #expect((2880..<4800).allSatisfy { abs(samples[$0]) < 0.001 })
    source.stop()
    try source.schedule(.init(sequenceNumber: 0, format: .init(), capturedAt: -10,
                              samples: Array(repeating: 0.3, count: 960)))
    source.start()
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(4800, to: output) == .success)
    #expect((1920..<2880).allSatisfy { abs(samples[$0] - 0.3) < 0.001 })
    #expect(source.playbackResetCount == 1, "stop clears the old capture clock")
}

@Test func captureTimePlayoutRejectsUnboundedConfigurationAndInvalidTimestamp() throws {
    let mixer = AudioMixer()
    let bus = try mixer.createBus("invalid-playout")
    for delay in [Double.nan, .infinity, -0.1, 0.2] {
        #expect(throws: (any Error).self) { try bus.addPCMSource(id: "invalid", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: delay) }
    }
    #expect(throws: (any Error).self) { try bus.addPCMSource(id: "unbounded", captureTimePlayoutDelay: 0.1) }
    let source = try bus.addPCMSource(id: "valid", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: 0.1)
    #expect(throws: (any Error).self) { try source.schedule(.init(sequenceNumber: 0, format: .init(), capturedAt: .nan, samples: [0])) }
}

@Test func latePacketDoesNotShiftTheFollowingSpeech() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("late-packet")
    let source = try bus.addPCMSource(id: "received", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: 0.04)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    try source.schedule(.init(sequenceNumber: 0, format: .init(), capturedAt: 10, samples: Array(repeating: 0.1, count: 960)))
    Thread.sleep(forTimeInterval: 0.01)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    #expect(try engine.renderOffline(3360, to: output) == .success) // 70 ms
    // Packet 1 belongs at 60 ms: its first half is already late. Packet 2 must
    // still play at 80 ms, without shifting the entire stream by another delay.
    try source.schedule(.init(sequenceNumber: 1, format: .init(), capturedAt: 10.02,
        samples: Array(repeating: 0.2, count: 480) + Array(repeating: 0.4, count: 480)))
    try source.schedule(.init(sequenceNumber: 2, format: .init(), capturedAt: 10.04, samples: Array(repeating: 0.6, count: 960)))
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(1920, to: output) == .success)
    let samples = output.floatChannelData![0]
    #expect((0..<480).allSatisfy { abs(samples[$0] - 0.4) < 0.001 })
    #expect((480..<1440).allSatisfy { abs(samples[$0] - 0.6) < 0.001 })
    #expect((1440..<1920).allSatisfy { abs(samples[$0]) < 0.001 })
    #expect(source.playbackResetCount == 0)
}

@Test func expiredPacketDoesNotReplayOrDelayFreshSpeech() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("expired-packet")
    let source = try bus.addPCMSource(id: "received", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: 0.04)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    try source.schedule(.init(sequenceNumber: 0, format: .init(), capturedAt: 10, samples: Array(repeating: 0.1, count: 960)))
    Thread.sleep(forTimeInterval: 0.01)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    #expect(try engine.renderOffline(4800, to: output) == .success)
    try source.schedule(.init(sequenceNumber: 1, format: .init(), capturedAt: 10.02, samples: Array(repeating: 0.2, count: 960)))
    try source.schedule(.init(sequenceNumber: 2, format: .init(), capturedAt: 10.06, samples: Array(repeating: 0.6, count: 960)))
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(1920, to: output) == .success)
    let samples = output.floatChannelData![0]
    #expect((0..<960).allSatisfy { abs(samples[$0] - 0.6) < 0.001 })
    #expect((960..<1920).allSatisfy { abs(samples[$0]) < 0.001 })
    #expect(source.playbackResetCount == 0)
}

@Test func captureClockStartsWhenTheFirstAudioIsScheduled() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("deferred-clock")
    let source = try bus.addPCMSource(id: "input", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: 0.04)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    #expect(!source.playerNode.isPlaying, "Do not establish a player epoch before the first capture timestamp")
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    #expect(try engine.renderOffline(4800, to: output) == .success)
    try source.schedule(.init(sequenceNumber: 0, format: .init(), capturedAt: 100,
        samples: Array(repeating: 0.3, count: 960)))
    #expect(source.playerNode.isPlaying)
    source.start() // Repeated start must not restart the clock.
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(4800, to: output) == .success)
    #expect((0..<1920).allSatisfy { abs(output.floatChannelData![0][$0]) < 0.001 })
    #expect((1920..<2880).allSatisfy { abs(output.floatChannelData![0][$0] - 0.3) < 0.001 })
    #expect(source.playbackResetCount == 0)
    source.stop(); source.start()
    #expect(!source.playerNode.isPlaying, "Restart waits for a new capture clock")
}

@Test func adaptivePlayoutRecoversDuringQuietCodecTailWithoutTrimmingSpeech() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("quiet-recovery")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    // A network burst contains a quiet native-codec tail, not absolute zeros.
    var quiet = [Float](repeating: 0.00001, count: 480)
    quiet[0] = 0.0004
    for index in 0..<8 {
        try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) * 0.01, samples: quiet))
    }
    #expect(try engine.renderOffline(480, to: output) == .success)
    try source.schedule(.init(sequenceNumber: 8, capturedAt: 0.08, samples: quiet))
    #expect(source.bufferedDuration <= 0.021, "Only inaudible queued tails may be replaced to recover low latency")
    // Real quiet speech must still follow the queued voice, never interrupt it.
    let before = source.playoutAdjustmentCount
    for index in 9..<13 {
        try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) * 0.01,
            samples: Array(repeating: 0.002, count: 480)))
    }
    #expect(source.playoutAdjustmentCount == before)
    #expect(source.bufferedDuration >= 0.04)
    #expect(source.playbackResetCount == 0)
}

@Test func silenceRecoveryPreservesEverySampleOfTheReturningFade() throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("returning-fade")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 4800)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 4800))
    for index in 0..<8 {
        try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) / 100,
            samples: Array(repeating: 0, count: 480)))
    }
    #expect(source.playoutAdjustmentCount > 0)
    #expect(try mixer.engine.renderOffline(480, to: output) == .success)
    try source.schedule(.init(sequenceNumber: 8, capturedAt: 0.08, samples: Array(repeating: 0, count: 480)))
    let fade = (0..<480).map { Float(min(1, Double($0) / 96)) * 0.2 }
    try source.schedule(.init(sequenceNumber: 9, capturedAt: 0.09, samples: fade))
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try mixer.engine.renderOffline(2400, to: output) == .success)
    let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: 2400))
    let first = try #require(samples.firstIndex { $0 > 0.0001 })
    #expect(samples[first] < 0.003, "Never trim the fade-in into an audible step")
    #expect(samples.filter { $0 > 0.0001 }.count == 479)
    #expect(zip(samples[(first - 1)..<(first + 479)], fade).allSatisfy { abs($0 - $1) < 0.000001 })
}

@Test func fractionalRatePauseReusesTheNativeFilterAndClearsItsHistory() throws {
    let normalizer = MixerPCMStreamNormalizer()
    let target = AudioFormat(sampleRate: 44100, channelCount: 1)
    _ = try normalizer.normalize(.init(sequenceNumber: 0, capturedAt: 0, samples: Array(repeating: 0.5, count: 480)),
        to: target, operation: .normalizeSource)
    let native = try #require(Mirror(reflecting: normalizer).descendant("converter") as? AVAudioConverter)
    let frame = PCMFrame(sequenceNumber: 1, capturedAt: 3, samples: (0..<480).map { Float(sin(Double($0) * 0.03) * 0.1) })
    let resumed = try normalizer.normalize(frame, to: target, operation: .normalizeSource).frame
    let independent = try MixerPCMStreamNormalizer().normalize(frame, to: target, operation: .normalizeSource).frame
    #expect((Mirror(reflecting: normalizer).descendant("converter") as? AVAudioConverter) === native)
    #expect(resumed.capturedAt == independent.capturedAt)
    #expect(resumed.samples == independent.samples)
}

@Test func omittedSilenceAtTheExactRenderSampleIsNotExpiredByFloatingPointRounding() throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("exact-pause-boundary")
    let source = try bus.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 14496)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    try source.schedule(.init(sequenceNumber: 0, capturedAt: 100, samples: Array(repeating: 0.1, count: 480)))
    let output = try #require(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 14496))
    #expect(try mixer.engine.renderOffline(14496, to: output) == .success)
    // (100.3 - 100) * 48000 is slightly below 14400 in binary floating
    // point. Native scheduling rounds to a sample, so expiry must do so too.
    try source.schedule(.init(sequenceNumber: 1, capturedAt: 100.3, samples: Array(repeating: 0.2, count: 480)))
    #expect(source.playoutAdjustmentCount == 0)
    Thread.sleep(forTimeInterval: 0.01) // Drain the native command queue before advancing the offline clock.
    #expect(try mixer.engine.renderOffline(480, to: output) == .success)
    #expect((0..<480).allSatisfy { abs(output.floatChannelData![0][$0] - 0.2) < 0.00001 })
}

@Test func thirtyMillisecondCodecFramesFromTwentyMillisecondCaptureRemainSampleAdjacent() throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("codec-cadence")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 480)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 480))
    var rendered: [Float] = []
    var packet = 0
    for tick in 0..<30 {
        // A 30 ms AAC frame filled by 20 ms input arrives 40/20/40/20 ms apart.
        if tick % 6 == 0 || tick % 6 == 4 {
            let frame = PCMFrame(sequenceNumber: UInt64(packet), capturedAt: Double(packet) * 0.03,
                samples: (0..<1440).map { Float(0.1 * sin(Double(packet * 1440 + $0) * 2 * .pi * 1270 / 48000)) })
            try source.schedule(frame, packetizationJitter: 0.01)
            packet += 1
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(try mixer.engine.renderOffline(480, to: output) == .success)
        rendered += Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: 480))
    }
    let lead = 576 // 2 ms network margin + the measured 10 ms codec/capture remainder.
    var error: Float = 0
    let angularStep = 2.0 * Double.pi * 1270.0 / 48000.0
    for i in lead..<rendered.count {
        let expected = Float(0.1 * sin(Double(i - lead) * angularStep))
        error = max(error, abs(rendered[i] - expected))
    }
    #expect(error < 0.00001)
    #expect(source.playoutAdjustmentCount == 0)
    #expect(source.playbackResetCount == 0)
}
