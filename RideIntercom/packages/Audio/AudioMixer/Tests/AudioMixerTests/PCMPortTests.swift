@testable import AudioMixer
import AVFAudio
import AudioCore
import Testing

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
    #expect(try engine.renderOffline(1024, to: output) == .success)
    let peak = (0..<Int(output.frameLength)).map { abs(output.floatChannelData![0][$0]) }.max() ?? 0
    #expect(peak > 0.79 && peak < 0.81, "First render after overflow, iteration \(iteration): \(peak)")
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
