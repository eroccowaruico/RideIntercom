@testable import AudioMixer
import AVFAudio
import AudioCore
import Testing

@Test(arguments: [16_000.0, 24_000.0, 48_000.0])
func sinkBoundsHardwareTapFramesWithoutLosingDuration(_ rate: Double) throws {
    let mixer = try AudioMixer(audioFormat: AudioFormat(sampleRate: 48_000, channelCount: 1))
    let bus = try mixer.createBus("live")
    var emitted: [PCMFrame] = []
    _ = try bus.installPCMSink(id: "packets", targetFormat: .init(sampleRate: rate, channelCount: 1),
        maximumFrameDuration: 0.02) { frame, _ in emitted.append(frame) }
    for number in 0..<2 {
        try bus.deliverToSinks(.init(sequenceNumber: UInt64(number), format: mixer.audioFormat,
            capturedAt: 10 + Double(number) * 0.1, samples: Array(repeating: Float(number + 1) / 4, count: 4800)))
    }
    #expect(emitted.count == 10)
    #expect(emitted.map(\.sequenceNumber) == Array(UInt64(0)..<10))
    #expect(emitted.reduce(0) { $0 + $1.frameCount } == Int(rate * 0.2))
    for (index, frame) in emitted.enumerated() {
        #expect(frame.frameCount == Int(rate * 0.02))
        #expect(abs(frame.capturedAt - (10 + Double(index) * 0.02)) < 0.000001)
        #expect(frame.samples.allSatisfy { $0 == (index < 5 ? 0.25 : 0.5) })
    }
}

@Test func pcmSourceNormalizesMixedFormatFramesBeforeBusInput() throws {
    let mixer = try AudioMixer(audioFormat: AudioFormat(sampleRate: 48_000, channelCount: 1))
    let bus = try mixer.createBus("remote")
    let source = try bus.addPCMSource(id: "peer-a")

    let report = try source.schedule(PCMFrame(
        sequenceNumber: 1,
        format: AudioFormat(sampleRate: 24_000, channelCount: 2),
        capturedAt: 10,
        samples: [0.1, -0.1, 0.3, -0.3]
    ))

    let snapshot = try #require(bus.snapshot().sources.first)
    #expect(report.sourceFormat == AudioFormat(sampleRate: 24_000, channelCount: 2))
    #expect(report.targetFormat == AudioFormat(sampleRate: 48_000, channelCount: 1))
    #expect(report.result == .applied)
    #expect(snapshot.id == "peer-a")
    #expect(snapshot.typeName == "MixerPCMSource")
    #expect(snapshot.originalFormat == AudioFormat(sampleRate: 24_000, channelCount: 2))
    #expect(snapshot.mixerFormat == AudioFormat(sampleRate: 48_000, channelCount: 1))
    #expect(snapshot.scheduledFrameCount == 1)
    #expect(snapshot.normalizationReport == report)
    #expect(snapshot.lastFailure == nil)
}

@Test func pcmSourceReportsConversionFailureWithoutScheduling() throws {
    let mixer = try AudioMixer(audioFormat: AudioFormat(sampleRate: 48_000, channelCount: 1))
    let bus = try mixer.createBus("remote")
    let source = try bus.addPCMSource(id: "peer-a")

    do {
        _ = try source.schedule(PCMFrame(
            sequenceNumber: 1,
            format: AudioFormat(sampleRate: 24_000, channelCount: 2),
            capturedAt: 10,
            samples: [0.1]
        ))
        Issue.record("PCM source must reject invalid source frame")
    } catch {
        let snapshot = try #require(bus.snapshot().sources.first)
        #expect(snapshot.scheduledFrameCount == 0)
        #expect(snapshot.originalFormat == AudioFormat(sampleRate: 24_000, channelCount: 2))
        #expect(snapshot.lastFailure == "sample count is not divisible by channel count")
    }
}

@Test func pcmSourceVolumeIsPerPeerAndClamped() throws {
    let mixer = AudioMixer()
    let bus = try mixer.createBus("remote")
    let source = try bus.addPCMSource(id: "peer-a")

    source.volume = 2
    #expect(source.volume == 1)

    source.volume = -1
    #expect(source.volume == 0)
}

@Test func pcmSinkNormalizesBusFormatForConsumerTarget() throws {
    let mixer = try AudioMixer(audioFormat: AudioFormat(sampleRate: 48_000, channelCount: 2))
    let bus = try mixer.createBus("capture")
    var emitted: [PCMFrame] = []
    var reports: [AudioProcessingReport] = []
    _ = try bus.installPCMSink(
        id: "send",
        targetFormat: AudioFormat(sampleRate: 24_000, channelCount: 1)
    ) { frame, report in
        emitted.append(frame)
        reports.append(report)
    }

    try bus.deliverToSinks(PCMFrame(
        sequenceNumber: 7,
        format: AudioFormat(sampleRate: 48_000, channelCount: 2),
        capturedAt: 20,
        samples: [1, -1, 0.5, -0.5]
    ))

    let snapshot = try #require(bus.snapshot().sinks.first)
    #expect(emitted.count == 1)
    #expect(emitted.first?.format == AudioFormat(sampleRate: 24_000, channelCount: 1))
    #expect(emitted.first?.samples.count == 1)
    #expect(reports.first?.operation == .normalizeSink)
    #expect(snapshot.id == "send")
    #expect(snapshot.mixerFormat == AudioFormat(sampleRate: 48_000, channelCount: 2))
    #expect(snapshot.targetFormat == AudioFormat(sampleRate: 24_000, channelCount: 1))
    #expect(snapshot.emittedFrameCount == 1)
    #expect(snapshot.normalizationReport == reports.first)
    #expect(snapshot.lastFailure == nil)
}

@Test func pcmSourceAndSinkSnapshotsAreSymmetric() throws {
    let mixer = try AudioMixer(audioFormat: AudioFormat(sampleRate: 48_000, channelCount: 1))
    let bus = try mixer.createBus("voice")
    _ = try bus.addPCMSource(id: "mic")
    _ = try bus.installPCMSink(id: "send", targetFormat: AudioFormat(sampleRate: 16_000, channelCount: 1)) { _, _ in }

    let snapshot = bus.snapshot()

    #expect(snapshot.sourceCount == 1)
    #expect(snapshot.sinkCount == 1)
    #expect(snapshot.sources.first?.mixerFormat == AudioFormat(sampleRate: 48_000, channelCount: 1))
    #expect(snapshot.sinks.first?.mixerFormat == AudioFormat(sampleRate: 48_000, channelCount: 1))
    #expect(snapshot.sinks.first?.targetFormat == AudioFormat(sampleRate: 16_000, channelCount: 1))
}

@Test(arguments: 0..<20) func liveSourceDiscardsBacklogAndPlaysNewestBuffer(_ iteration: Int) throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init(sampleRate: 48000, channelCount: 1))
    let bus = try mixer.createBus("live")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.1)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    for sequence in 0..<6 {
        _ = try source.schedule(.init(sequenceNumber: UInt64(sequence), format: mixer.audioFormat, capturedAt: 0,
            samples: Array(repeating: sequence == 5 ? Float(0.8) : Float(0.1), count: 960)))
    }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    // AVAudioPlayerNode applies interrupts asynchronously at a render boundary.
    // Require fresh audio within 64 ms, and no old backlog after it arrives.
    var rendered: [Float] = []
    for _ in 0..<3 {
        #expect(try engine.renderOffline(1024, to: output) == .success)
        rendered += (0..<Int(output.frameLength)).map { abs(output.floatChannelData![0][$0]) }
    }
    let fresh = try #require(rendered.firstIndex { $0 > 0.79 && $0 < 0.81 },
        "Replacement must arrive within 64 ms, iteration \(iteration)")
    #expect(!rendered[fresh...].contains { abs($0 - 0.1) < 0.001 },
        "Old backlog must never resume after fresh audio")
    #expect(source.playbackResetCount == 1)
    #expect(source.bufferedDuration == 0)
    #expect(bus.snapshot().sources.first?.playbackResetCount == 1)
    #expect(throws: (any Error).self) {
        try source.schedule(.init(sequenceNumber: 9, format: mixer.audioFormat, capturedAt: 0, samples: Array(repeating: 0.2, count: 9600)))
    }
    _ = try source.schedule(.init(sequenceNumber: 10, format: mixer.audioFormat, capturedAt: 0, samples: Array(repeating: 0.3, count: 960)))
    mixer.stop()
    #expect(source.bufferedDuration == 0)
    try mixer.start(); source.start()
    #expect(try engine.renderOffline(1024, to: output) == .success)
    #expect((0..<Int(output.frameLength)).allSatisfy { abs(output.floatChannelData![0][$0]) < 0.001 })
}

@Test func rejectsInvalidSinkFormatBeforeInstallingTap() throws {
    let mixer = try AudioMixer(audioFormat: AudioFormat())
    let bus = try mixer.createBus("test")
    var invalid = AudioFormat()
    invalid.channelCount = -1
    #expect(throws: AudioMixerError.self) {
        try bus.installPCMSink(id: "invalid", targetFormat: invalid) { _, _ in }
    }
    #expect(bus.snapshot().sinkCount == 0)
}

@Test func overflowReplacesBuffersWithoutResettingTheLivePlayerClock() throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("live-clock")
    let source = try bus.addPCMSource(id: "mic", maximumBufferedDuration: 0.1)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    var positions: [AVAudioFramePosition] = []
    for _ in 0..<2 {
        for index in 0..<6 {
            try source.schedule(.init(sequenceNumber: UInt64(index), format: mixer.audioFormat,
                samples: Array(repeating: 0.2, count: 960)))
        }
        #expect(try engine.renderOffline(1024, to: output) == .success)
        let time = try #require(source.playerNode.lastRenderTime)
        positions.append(try #require(source.playerNode.playerTime(forNodeTime: time)).sampleTime)
    }
    #expect(positions[1] > positions[0], "Overflow must not stop/restart the player clock")
}
