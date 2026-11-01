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

@Test func preparingRequestedEffectKeepsCurrentAudioAndReleasesDisabledResources() throws {
    var frames: [PCMFrame] = []
    let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init()) { frame, _ in frames.append(frame) }
    let effect = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    effect.bypass = true
    try processor.bus.addEffect(effect, id: "isolation", bypassed: true)
    try processor.start()
    defer { processor.stop() }
    #expect(!effect.auAudioUnit.renderResourcesAllocated)
    try processor.bus.prepareEffect(id: "isolation")
    #expect(effect.auAudioUnit.renderResourcesAllocated)
    #expect(processor.bus.processingLatency == 0)
    try processor.process(.init(sequenceNumber: 0, samples: Array(repeating: 0.2, count: 480)))
    #expect(frames.flatMap(\.samples).allSatisfy { abs($0 - 0.2) < 0.00001 })
    effect.bypass = false
    let start = ContinuousClock.now
    try processor.bus.setEffectBypassed(id: "isolation", bypassed: false)
    #expect(start.duration(to: .now) < .milliseconds(20),
        "Preparing the disabled unit must keep its slow model allocation out of the live graph swap")
    #expect(processor.bus.processingLatency > 0)
    effect.bypass = true
    try processor.bus.setEffectBypassed(id: "isolation", bypassed: true)
    #expect(!effect.auAudioUnit.renderResourcesAllocated, "Disabled effects must release their native resources")
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

@Test func inputGapDiscardsNativeTailWithoutRebuildingTheProcessorClock() throws {
    var frames: [PCMFrame] = []
    let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init(),
        suspendsDuringSilence: true) { frame, _ in frames.append(frame) }
    let delay = AVAudioUnitDelay()
    delay.delayTime = 0.05; delay.feedback = 0; delay.wetDryMix = 100
    try processor.bus.addEffect(delay, id: "native-delay")
    try processor.start()
    defer { processor.stop() }
    for index in 0..<2 {
        try processor.process(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) * 0.01,
            samples: (0..<480).map { Float(sin(Double(index * 480 + $0) * 0.07) * 0.2) }))
    }
    let beforeGapClock = processor.mixer.engine.manualRenderingSampleTime
    for index in 0..<10 {
        try processor.process(.init(sequenceNumber: UInt64(index + 2), capturedAt: 1 + Double(index) * 0.01,
            samples: Array(repeating: 0, count: 480)))
    }
    #expect(frames.filter { $0.capturedAt >= 1 }.flatMap(\.samples).allSatisfy { abs($0) < 0.000001 },
        "No samples from before the input gap may emerge on later silence")
    #expect(processor.mixer.engine.manualRenderingSampleTime == beforeGapClock + 4800)
    #expect(processor.mixer.engine.isRunning && processor.bus.effects.first === delay)
    #expect(abs(delay.delayTime - 0.05) < 0.000001 && delay.wetDryMix == 100)
    for index in 0..<10 {
        let samples = (0..<480).map { sample in
            index < 2 ? Float(sin(Double(index * 480 + sample) * 0.09) * 0.2) : 0
        }
        try processor.process(.init(sequenceNumber: UInt64(index + 12), capturedAt: 1.1 + Double(index) * 0.01, samples: samples))
    }
    #expect(frames.filter { $0.capturedAt >= 1.14 }.flatMap(\.samples).contains { abs($0) > 0.05 },
        "The same native effect must still process the next utterance")
}

@Test(arguments: [false, true])
func inputDiscontinuityDiscardsOwnedPartialPackets(_ formatChanges: Bool) throws {
    var frames: [PCMFrame] = []
    let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init()) { frame, _ in frames.append(frame) }
    try processor.start()
    defer { processor.stop() }
    let firstFormat = AudioFormat(sampleRate: formatChanges ? 24_000 : 48_000, channelCount: 1)
    try processor.process(.init(sequenceNumber: 0, format: firstFormat, capturedAt: 0,
        samples: Array(repeating: 0.3, count: 120)))
    #expect(frames.isEmpty)
    let nextTime = formatChanges ? 120.0 / 24_000 : 1
    try processor.process(.init(sequenceNumber: 1, capturedAt: nextTime,
        samples: Array(repeating: 0, count: 480)))
    #expect(frames.count == 1, "Old partial audio must be discarded, not emitted or prepended")
    #expect(frames.allSatisfy { abs($0.capturedAt - nextTime) < 1e-9 })
    #expect(frames.flatMap(\.samples).allSatisfy { $0 == 0 })
}

@Test(arguments: [false, true])
func nextUtteranceAfterDiscontinuityMatchesAFreshNativeEffect(_ formatChanges: Bool) throws {
    var resumed: [PCMFrame] = [], fresh: [PCMFrame] = []
    func make(_ receive: @escaping (PCMFrame) -> Void) throws -> AudioFrameProcessor {
        let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init()) { frame, _ in receive(frame) }
        let delay = AVAudioUnitDelay()
        delay.delayTime = 0.05; delay.feedback = 0; delay.wetDryMix = 100
        try processor.bus.addEffect(delay, id: "delay")
        try processor.start()
        return processor
    }
    let previous = try make { resumed.append($0) }, reference = try make { fresh.append($0) }
    defer { previous.stop(); reference.stop() }
    for index in 0..<2 {
        try previous.process(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) / 100,
            samples: Array(repeating: 0.4, count: 480)))
    }
    let nextTime = formatChanges ? 0.02 : 2
    let nextFormat = AudioFormat(sampleRate: formatChanges ? 24_000 : 48_000, channelCount: 1)
    let count = Int(nextFormat.sampleRate / 100)
    for index in 0..<12 {
        let frame = PCMFrame(sequenceNumber: UInt64(index + 2), format: nextFormat,
            capturedAt: nextTime + Double(index) / 100,
            samples: (0..<count).map { sample in
                index < 2 ? Float(sin(Double(index * count + sample) * 0.09) * 0.2) : 0
            })
        try previous.process(frame)
        try reference.process(frame)
    }
    let actual = resumed.filter { $0.capturedAt >= nextTime }.flatMap(\.samples)
    let expected = fresh.flatMap(\.samples)
    #expect(actual.count == expected.count)
    #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.000001 },
        "Input discontinuity must discard previous native history without altering the next utterance")
    #expect(expected.contains { abs($0) > 0.05 })
}

@Test func inputGapDiscardsBypassedNativeHistoryWithoutAllocatingUnusedUnits() throws {
    var frames: [PCMFrame] = []
    let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init()) { frame, _ in frames.append(frame) }
    let delay = AVAudioUnitDelay(), unused = AVAudioUnitDelay()
    delay.delayTime = 0.05; delay.feedback = 0; delay.wetDryMix = 100
    try processor.bus.addEffect(delay, id: "delay")
    try processor.bus.addEffect(unused, id: "unused", bypassed: true)
    try processor.start()
    defer { processor.stop() }
    for index in 0..<2 {
        try processor.process(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) / 100,
            samples: Array(repeating: 0.3, count: 480)))
    }
    try processor.bus.setEffectBypassed(id: "delay", bypassed: true)
    try processor.bus.prepareEffect(id: "delay")
    #expect(delay.auAudioUnit.renderResourcesAllocated)
    #expect(!unused.auAudioUnit.renderResourcesAllocated)
    try processor.process(.init(sequenceNumber: 2, capturedAt: 1, samples: Array(repeating: 0, count: 480)))
    #expect(delay.auAudioUnit.renderResourcesAllocated, "Reset retains prepared native resources")
    #expect(!unused.auAudioUnit.renderResourcesAllocated, "Reset does not allocate an unused effect")
    try processor.bus.setEffectBypassed(id: "delay", bypassed: false)
    for index in 0..<10 {
        try processor.process(.init(sequenceNumber: UInt64(index + 3), capturedAt: 1.01 + Double(index) / 100,
            samples: Array(repeating: 0, count: 480)))
    }
    #expect(frames.filter { $0.capturedAt >= 1 }.flatMap(\.samples).allSatisfy { abs($0) < 0.000001 })
}

@Test func finiteNativeEffectEmitsTheFinalMarker() throws {
    var frames: [PCMFrame] = []
    let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init(), suspendsDuringSilence: true) { frame, _ in frames.append(frame) }
    let effect = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    try processor.bus.addEffect(effect, id: "limiter")
    try processor.start()
    defer { processor.stop() }
    let latency = processor.bus.processingLatency
    print("finite effect latency=\(latency) tail=\(processor.bus.processingTailTime)")
    #expect(latency > 0)
    for index in 0..<500 {
        let samples = (0..<480).map { sample in
            index == 499 ? Float(0.2 * sin(Double(sample) * 2 * .pi * 997 / 48_000)) : 0
        }
        try processor.process(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) / 100, samples: samples))
    }
    try processor.finish()
    let afterFinish = frames.count
    try processor.finish()
    #expect(frames.count == afterFinish)
    let finalMarker = frames.filter { $0.capturedAt >= 5 }.flatMap(\.samples).filter { abs($0) > 0.01 }.count
    print("finite marker after input=\(finalMarker)")
    #expect(finalMarker > 20, "The native effect's delayed final marker must be recovered")
}

@Test func finiteProcessorStartsAFreshStreamAfterFinish() throws {
    var frames: [PCMFrame] = []
    let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init()) { frame, _ in frames.append(frame) }
    let delay = AVAudioUnitDelay()
    delay.delayTime = 0.05; delay.feedback = 0; delay.wetDryMix = 100
    try processor.bus.addEffect(delay, id: "delay")
    try processor.start()
    defer { processor.stop() }
    try processor.process(.init(sequenceNumber: 0, capturedAt: 0, samples: Array(repeating: 0.2, count: 480)))
    try processor.finish()
    let start = frames.count
    try processor.process(.init(sequenceNumber: 1, capturedAt: 1, samples: Array(repeating: 0, count: 480)))
    try processor.finish()
    #expect(frames.count > start)
    #expect(frames.dropFirst(start).flatMap(\.samples).allSatisfy { abs($0) < 0.000001 })
}

@Test func finiteProcessorFlushesPartialSinkPacketOnTheRenderClock() throws {
    var frames: [PCMFrame] = []
    let processor = try AudioFrameProcessor(format: .init(), outputFormat: .init()) { frame, _ in frames.append(frame) }
    try processor.start()
    defer { processor.stop() }
    try processor.process(.init(sequenceNumber: 0, capturedAt: 3, samples: Array(repeating: 0.2, count: 123)))
    #expect(frames.isEmpty)
    try processor.finish()
    #expect(frames.count == 1)
    let frame = try #require(frames.first)
    #expect(abs(frame.capturedAt - 3) < 1e-9)
    #expect(frame.samples.prefix(123).allSatisfy { abs($0 - 0.2) < 0.000001 })
    #expect(frame.samples.dropFirst(123).allSatisfy { $0 == 0 })
}
