import AudioCore
@preconcurrency import AVFAudio
import Foundation
import Testing
import XCTest
@testable import AudioMixer

private final class QuantumFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [PCMFrame] = []
    func append(_ frame: PCMFrame) { lock.withLock { frames.append(frame) } }
    var snapshot: [PCMFrame] { lock.withLock { frames } }
}

@Test func mixerOutputPreservesOtherInputsOnTheSharedDeviceClock() throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let existing = AVAudioSourceNode(format: mixer.format) { _, _, count, list in
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.1, count: Int(count))
        }
        return noErr
    }
    mixer.engine.attach(existing)
    mixer.engine.connect(existing, to: mixer.engine.mainMixerNode, format: mixer.format)
    let bus = try mixer.createBus("shared")
    let source = try bus.addPCMSource(id: "peer")
    try mixer.routeToOutput(bus)
    try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 480)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    try source.schedule(.init(sequenceNumber: 0, samples: Array(repeating: 0.2, count: 480)))
    let output = AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 480)!
    #expect(try mixer.engine.renderOffline(480, to: output) == .success)
    #expect((0..<480).allSatisfy { abs(output.floatChannelData![0][$0] - 0.3) < 0.001 })
}

@Test func sinkDeliversEveryRenderQuantumWithoutHundredMillisecondBatching() async throws {
    let engine = AVAudioEngine()
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("quantum")
    let source = try bus.addPCMSource(id: "capture")
    let received = QuantumFrames()
    _ = try bus.installPCMSink(id: "network", targetFormat: .init(), bufferFrameCount: 128) { frame, _ in
        received.append(frame)
    }
    try mixer.routeToOutput(bus)
    try engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 480)
    try mixer.start()
    defer { mixer.stop() }
    let signal = (0..<4800).map { Float(sin(Double($0) * 0.031)) * 0.2 }
    try source.schedule(.init(sequenceNumber: 0, samples: signal))
    source.start()
    let output = try #require(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 480))
    for index in 0..<10 {
        #expect(try engine.renderOffline(480, to: output) == .success)
        let deadline = ContinuousClock.now + .milliseconds(30)
        while received.snapshot.count <= index && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(received.snapshot.count == index + 1, "10 ms must be delivered without waiting for another render")
    }
    let frames = received.snapshot
    #expect(frames.allSatisfy { $0.frameCount == 480 })
    let samples = frames.flatMap(\.samples)
    #expect(samples.count == signal.count)
    #expect(zip(samples, signal).allSatisfy { abs($0 - $1) < 0.00001 })
}

// Hardware-clock checks run in XCTest's serial phase, separately from the
// parallel offline graph tests that create and destroy many native Audio Units.
final class RealtimeRenderBoundaryTests: XCTestCase {
func testAdaptivePlayerPreparesItsClockBeforeTheFirstUtterance() async throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("ready-clock")
    let source = try bus.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    let received = QuantumFrames()
    _ = try bus.installPCMSink(id: "probe", targetFormat: .init()) { frame, _ in received.append(frame) }
    let muted = try mixer.createBus("muted"); muted.volume = 0
    try mixer.route(bus, to: muted); try mixer.routeToOutput(muted)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(source.playerNode.isPlaying)
    XCTAssertNotNil(source.playerNode.lastRenderTime)
    XCTAssertTrue(received.snapshot.flatMap(\.samples).allSatisfy { $0 == 0 })
    try source.schedule(.init(sequenceNumber: 0, capturedAt: 100,
        samples: Array(repeating: 0.2, count: 480)))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(received.snapshot.flatMap(\.samples).filter { $0 > 0.1 }.count, 480,
        "Starting the clock early must not place the first capture timestamp in the past")
}

func testFirstPacketDoesNotWaitForAnAlreadyRunningDeviceClock() async throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("first-packet")
    let source = try bus.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    let received = QuantumFrames()
    _ = try bus.installPCMSink(id: "probe", targetFormat: .init()) { frame, _ in received.append(frame) }
    let muted = try mixer.createBus("muted"); muted.volume = 0
    try mixer.route(bus, to: muted); try mixer.routeToOutput(muted)
    try mixer.start()
    defer { mixer.stop() }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(received.snapshot.isEmpty, "The native device must already be rendering")
    try source.schedule(.init(sequenceNumber: 0, capturedAt: 100,
        samples: Array(repeating: 0.2, count: 480)))
    XCTAssertEqual(source.bufferedDuration, 0.012, accuracy: 1 / 48000,
        "A stopped player starts with its prepared first buffer; it needs no asynchronous render handoff allowance")
    source.start()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(received.snapshot.flatMap(\.samples).filter { $0 > 0.1 }.count, 480)
}

func testDelayedQuietBurstDoesNotCutTheReturningFade() async throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("delayed-pause")
    let source = try bus.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    let received = QuantumFrames()
    _ = try bus.installPCMSink(id: "probe", targetFormat: .init()) { frame, _ in received.append(frame) }
    let muted = try mixer.createBus("muted"); muted.volume = 0
    try mixer.route(bus, to: muted); try mixer.routeToOutput(muted)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let start = ContinuousClock.now
    var expected: [Float] = []
    let hostStart = ProcessInfo.processInfo.systemUptime
    var arrivals: [(index: Int, late: Double, buffered: Double, adjustments: Int)] = []
    for index in 0..<1000 {
        // A sender pauses for a native settings change, then delivers the
        // accumulated quiet packets. Speech resumes after that quiet burst.
        let position = index % 50
        let delay = position == 10 ? 50 : 0
        try await Task.sleep(until: start + .milliseconds(index * 10 + delay), clock: .continuous)
        let samples: [Float] = (0..<480).map { sample in
            guard position < 10 || (30..<40).contains(position) else { return 0 }
            if position == 0 || position == 30 { return 0.2 * Float(min(sample, 96)) / 96 }
            if position == 9 || position == 39 { return 0.2 * Float(min(479 - sample, 96)) / 96 }
            return 0.2
        }
        expected.append(contentsOf: samples.filter { $0 > 0 })
        try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: 100 + Double(index) * 0.01, samples: samples))
        arrivals.append((index, ProcessInfo.processInfo.systemUptime - hostStart - Double(index) / 100,
                         source.bufferedDuration, source.playoutAdjustmentCount))
    }
    try await Task.sleep(for: .milliseconds(150))
    let samples = received.snapshot.flatMap(\.samples)
    let voiced = samples.filter { $0 > 0.00001 }
    XCTAssertEqual(voiced.count, expected.count, "Every fade and voiced sample must survive delayed silence")
    XCTAssertTrue(zip(voiced, expected).allSatisfy { abs($0 - $1) < 0.00001 })
    let gaps = zip(samples, samples.dropFirst()).enumerated().filter { abs($0.element.0 - $0.element.1) >= 0.003 }
    if !gaps.isEmpty {
        let firstRender = (received.snapshot.first?.capturedAt ?? 0) - hostStart
        let moments = gaps.prefix(20).map { Double($0.offset) / 48000 + firstRender }
        let nearby = arrivals.filter { arrival in
            moments.contains { abs(Double(arrival.index) / 100 - $0) < 0.1 }
        }
        print("Native pause arrivals near gaps: \(nearby)")
        print("Native pause first render: \(firstRender)")
    }
    XCTAssertTrue(gaps.isEmpty, "Unexpected render edges: \(gaps.prefix(20).map { ($0.offset, $0.element.0, $0.element.1) })")
    XCTAssertEqual(source.playbackResetCount, 0)
}
func testQuietRecoveryKeepsTheCaptureClockAcrossOmittedSilence() async throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("pause-clock")
    let source = try bus.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    let received = QuantumFrames()
    _ = try bus.installPCMSink(id: "probe", targetFormat: .init()) { frame, _ in received.append(frame) }
    let muted = try mixer.createBus("muted"); muted.volume = 0
    try mixer.route(bus, to: muted); try mixer.routeToOutput(muted)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let start = ContinuousClock.now
    for index in 0..<170 {
        try await Task.sleep(until: start + .milliseconds(index * 10 + (index == 10 ? 50 : 0)), clock: .continuous)
        if (50..<150).contains(index) { continue }
        let audible = (30..<50).contains(index) || index >= 150
        try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: 100 + Double(index) / 100,
            samples: Array(repeating: audible ? 0.2 : 0, count: 480)))
    }
    try await Task.sleep(for: .milliseconds(100))
    let samples = received.snapshot.flatMap(\.samples)
    let onsets = samples.indices.filter { samples[$0] > 0.1 && ($0 == 0 || samples[$0 - 1] <= 0.1) }
    XCTAssertEqual(onsets.count, 2)
    if onsets.count == 2 {
        XCTAssertEqual(onsets[1] - onsets[0], 57600, accuracy: 2,
            "Quiet recovery must not leave implicit and explicit native reservations on different clocks")
    }
    XCTAssertEqual(samples.filter { $0 > 0.1 }.count, 19200)
    XCTAssertEqual(source.playbackResetCount, 0)
}

func testLiveEffectInsertionKeepsTimestampedRemoteVoiceAudible() async throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let peer = try mixer.createBus("remote")
    let master = try mixer.createBus("master")
    let source = try peer.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.01, adaptivePlayout: true)
    let effect = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    effect.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?.value = 80
    effect.bypass = true
    try master.addEffect(effect, id: "isolation", bypassed: true)
    let observed = QuantumFrames()
    _ = try master.installPCMSink(id: "actual", targetFormat: .init()) { frame, _ in observed.append(frame) }
    let muted = try mixer.createBus("muted"); muted.volume = 0
    let sibling = try mixer.createBus("unchanged-peer")
    let siblingSource = try sibling.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.01, adaptivePlayout: true)
    let siblingFrames = QuantumFrames()
    _ = try sibling.installPCMSink(id: "actual", targetFormat: .init()) { frame, _ in siblingFrames.append(frame) }
    try mixer.route(sibling, to: muted)
    let stoppedSource = try peer.addPCMSource(id: "stopped")
    try mixer.route(peer, to: master); try mixer.route(master, to: muted); try mixer.routeToOutput(muted)
    try mixer.start(); source.start(); siblingSource.start()
    defer { mixer.stop() }
    let tone = (0..<480).map { Float(0.15 * sin(Double($0) * 2 * .pi * 600 / 48000)) }
    for stage in 0..<3 {
        if stage > 0 {
            effect.bypass = stage == 2
            try master.setEffectBypassed(id: "isolation", bypassed: stage == 2)
        }
        let start = ContinuousClock.now
        for packet in 0..<60 {
            try await Task.sleep(until: start + .milliseconds(packet * 10), clock: .continuous)
            let sequence = stage * 60 + packet
            try source.schedule(.init(sequenceNumber: UInt64(sequence), capturedAt: 100 + Double(sequence) * 0.01, samples: tone))
            try siblingSource.schedule(.init(sequenceNumber: UInt64(sequence), capturedAt: 100 + Double(sequence) * 0.01,
                samples: Array(repeating: 0.1, count: 480)))
        }
        let steady = Array(observed.snapshot.flatMap(\.samples).suffix(9600))
        XCTAssertEqual(steady.count, 9600)
        XCTAssertGreaterThan(sqrt(steady.reduce(Float(0)) { $0 + $1 * $1 } / Float(steady.count)), 0.01,
            "Stage \(stage): a live bypass change must not silence the already-playing peer")
        XCTAssertFalse(stoppedSource.playerNode.isPlaying, "A graph mutation must not start a stopped source")
        let unchanged = Array(siblingFrames.snapshot.flatMap(\.samples).suffix(9600))
        XCTAssertEqual(unchanged.count, 9600)
        XCTAssertEqual(unchanged.filter { abs($0 - 0.1) > 0.001 }.count, 0,
            "Another peer must retain its player clock and recover after native latency compensation")
        XCTAssertEqual(siblingSource.playbackResetCount, 0)
    }
}
func testSpeechAndPauseBoundariesRetainEveryVoicedSample() async throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("live-pauses")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    let received = QuantumFrames()
    _ = try bus.installPCMSink(id: "probe", targetFormat: .init()) { frame, _ in received.append(frame) }
    let muted = try mixer.createBus("muted")
    muted.volume = 0
    try mixer.route(bus, to: muted); try mixer.routeToOutput(muted)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let start = ContinuousClock.now
    var expectedVoiced = 0
    for index in 0..<300 {
        try await Task.sleep(until: start + .milliseconds(index * 10), clock: .continuous)
        let value: Float = (index / 10).isMultiple(of: 2) ? 0 : 0.2
        if value != 0 { expectedVoiced += 480 }
        try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: 1000 + Double(index) * 0.01,
            samples: Array(repeating: value, count: 480)))
    }
    try await Task.sleep(for: .milliseconds(200))
    let voiced = received.snapshot.flatMap(\.samples).filter { $0 > 0.1 }.count
    XCTAssertEqual(voiced, expectedVoiced, "Neither trim nor repeat samples when speech resumes")
    XCTAssertEqual(source.playbackResetCount, 0)
}
func testContiguousPacketsDoNotLoseSamplesAtRenderBoundaries() async throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("live")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    let received = QuantumFrames()
    _ = try bus.installPCMSink(id: "probe", targetFormat: .init()) { frame, _ in received.append(frame) }
    let muted = try mixer.createBus("muted")
    muted.volume = 0
    try mixer.route(bus, to: muted)
    try mixer.routeToOutput(muted)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let start = ContinuousClock.now
    for index in 0..<200 {
        try await Task.sleep(until: start + .milliseconds(index * 10), clock: .continuous)
        try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: 1000 + Double(index) * 0.01,
            samples: Array(repeating: 0.2, count: 480)))
    }
    let samples = received.snapshot.flatMap(\.samples)
    // Warm-up is bounded to 100 ms. Every later sample of a sustained voice
    // must survive small scheduling/render-boundary jitter without truncation.
    let steady = Array(samples.dropFirst(4800).dropLast(4800))
    XCTAssertGreaterThan(steady.count, 48_000)
    XCTAssertEqual(steady.filter { abs($0 - 0.2) > 0.001 }.count, 0,
        "Samples disappeared between contiguous packets")
    XCTAssertEqual(source.playbackResetCount, 0)
}
}
