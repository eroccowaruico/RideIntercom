import AudioCore
import AVFAudio
import Testing
@testable import AudioMixer

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
