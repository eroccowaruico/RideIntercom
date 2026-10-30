import AudioCore
import AVFAudio
import Foundation
import Testing
@testable import AudioMixer

@Test func silenceSuspendsRenderingWithoutLosingDelayedTailOrQuietOnset() throws {
    var frames: [PCMFrame] = []
    let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init(),
        suspendsDuringSilence: true) { frame, _ in frames.append(frame) }
    let delay = AVAudioUnitDelay()
    delay.delayTime = 0.4; delay.feedback = 0; delay.wetDryMix = 100
    try processor.bus.addEffect(delay, id: "delay")
    try processor.start()
    defer { processor.stop() }
    for index in 0..<300 {
        let voiced = (0..<10).contains(index) || (200..<210).contains(index)
        let samples = (0..<480).map { sample in
            voiced ? Float(sin(Double(index * 480 + sample) * 2 * .pi * 400 / 48000) * 0.01) : 0
        }
        try processor.process(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) / 100, samples: samples))
    }
    #expect(processor.mixer.engine.manualRenderingSampleTime < 48000 * 2,
        "Idle quanta must skip native rendering, not merely discard its output")
    for start in [0.4, 2.4] {
        let audible = frames.filter { $0.capturedAt >= start - 0.01 && $0.capturedAt < start + 0.11 }
            .flatMap(\.samples).filter { abs($0) > 0.001 }.count
        #expect(audible > 4000, "The delayed tail and the returning quiet utterance must both survive")
    }
}

@Test func bypassedEffectDoesNotRenderOrAddLatency() throws {
    let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init()) { _, _ in }
    let delay = AVAudioUnitDelay()
    delay.delayTime = 0.4
    try processor.bus.addEffect(delay, id: "delay", bypassed: true)
    try processor.start()
    defer { processor.stop() }
    #expect(processor.bus.processingLatency == 0)
    #expect(processor.bus.processingTailTime == 0)
    #expect(!delay.auAudioUnit.renderResourcesAllocated, "Disabled effects must be outside the active native graph")
}

@Test func enablingNativeEffectPublishesLatencyBeforeTheNextFrame() throws {
    let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init()) { _, _ in }
    let effect = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    effect.bypass = true
    try processor.bus.addEffect(effect, id: "isolation", bypassed: true)
    try processor.start()
    defer { processor.stop() }
    #expect(processor.bus.processingLatency == 0)
    #expect(!effect.auAudioUnit.renderResourcesAllocated, "Disabled SoundIsolation must not allocate a native render chain")
    effect.bypass = false
    try processor.bus.setEffectBypassed(id: "isolation", bypassed: false)
    #expect(processor.bus.processingLatency > 0, "The caller needs initialized native latency to bound the transition")
}

@Test func frameProcessorPreservesSamplesAndClockWithoutWaitingForHardware() throws {
    var received: [PCMFrame] = []
    let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init(sampleRate: 16000, channelCount: 1),
        packetDuration: 0.01) { frame, _ in received.append(frame) }
    try processor.start()
    defer { processor.stop() }
    let start = ContinuousClock.now
    for index in 0..<300 {
        let samples = (0..<256).map { Float(sin(Double(index * 256 + $0) * 2 * .pi * 400 / 48000) * 0.2) }
        try processor.process(.init(sequenceNumber: UInt64(index), capturedAt: Double(index * 256) / 48000, samples: samples))
        #expect(received.count == (index + 1) * 256 / 480)
    }
    #expect(start.duration(to: .now) < .seconds(1), "1.6 s of audio must not wait for a device playback clock")
    #expect(received.count == 160)
    for (index, frame) in received.enumerated() {
        #expect(frame.frameCount == 160)
        #expect(abs(frame.capturedAt - Double(index) * 0.01) < 1.0 / 48000)
        for (sample, value) in frame.samples.enumerated() {
            let expected = Float(sin(Double(index * 160 + sample) * 2 * .pi * 400 / 16000) * 0.2)
            #expect(abs(value - expected) < 0.0001)
        }
    }
}

@Test func transitionDoesNotRestartTheProcessorOrAccumulateFrames() throws {
    var frames: [PCMFrame] = []
    let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init()) { frame, _ in frames.append(frame) }
    try processor.start()
    defer { processor.stop() }
    for index in 0..<300 {
        if index == 100 { processor.bus.beginSinkTransition(settlingDuration: 0.02) }
        try processor.process(.init(sequenceNumber: UInt64(index), capturedAt: Double(index * 256) / 48000,
            samples: Array(repeating: 0.2, count: 256)))
    }
    #expect(frames.count == 160)
    for (index, frame) in frames.enumerated() { #expect(abs(frame.capturedAt - Double(index) / 100) < 1e-9) }
    let silent = frames.filter { $0.samples.allSatisfy { $0 == 0 } }.count
    #expect((1...3).contains(silent))
    let samples = frames.flatMap(\.samples)
    #expect(zip(samples, samples.dropFirst()).allSatisfy { abs($0 - $1) < 0.003 })
    #expect(frames.last?.samples.allSatisfy { $0 == 0.2 } == true)
}

@Test func outputFormatSwitchKeepsPartialPacketAndDSPClock() throws {
    var frames: [PCMFrame] = []
    let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init()) { frame, _ in frames.append(frame) }
    try processor.start()
    defer { processor.stop() }
    for index in 0..<12 {
        if index == 3 { try processor.updateOutputFormat(.init(sampleRate: 16000, channelCount: 1)) }
        try processor.process(.init(sequenceNumber: UInt64(index), capturedAt: Double(index * 240) / 48000,
            samples: Array(repeating: 0.2, count: 240)))
    }
    #expect(frames.count == 6)
    #expect(frames[0].frameCount == 480)
    #expect(frames.dropFirst().allSatisfy { $0.frameCount == 160 })
    for (index, frame) in frames.enumerated() {
        #expect(abs(frame.capturedAt - Double(index) / 100) < 1e-9)
        #expect(frame.samples.allSatisfy { abs($0 - 0.2) < 1e-6 })
    }
    #expect(processor.mixer.engine.isRunning)
}
