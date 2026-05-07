import AudioCore
import Testing
@testable import AudioMixer
import AVFAudio

@Test func defaultFormatUsesStereoFloat32At48kHz() {
    let mixer = AudioMixer()

    #expect(mixer.format.commonFormat == .pcmFormatFloat32)
    #expect(mixer.format.sampleRate == 48_000)
    #expect(mixer.format.channelCount == 2)
    #expect(mixer.audioFormat == AudioFormat(sampleRate: 48_000, channelCount: 2))
    #expect(!mixer.format.isInterleaved)
}

@Test func mixerCanBeCreatedFromAudioCoreFormat() throws {
    let mixer = try AudioMixer(audioFormat: AudioFormat(sampleRate: 24_000, channelCount: 1))

    #expect(mixer.audioFormat == AudioFormat(sampleRate: 24_000, channelCount: 1))
    #expect(mixer.format.sampleRate == 24_000)
    #expect(mixer.format.channelCount == 1)
}

@Test func createBusReturnsExistingBusForSameID() throws {
    let mixer = AudioMixer()

    let first = try mixer.createBus("local")
    let second = try mixer.createBus("local")

    #expect(first === second)
    #expect(mixer.busIDs == ["local"])
}

@Test func createBusRejectsEmptyID() {
    let mixer = AudioMixer()

    do {
        _ = try mixer.createBus("")
        Issue.record("empty bus id should throw")
    } catch {
        #expect(error as? AudioMixerError == .emptyBusID)
    }
}

@Test func busVolumeUsesFaderMixerOutputVolume() throws {
    let mixer = AudioMixer()
    let bus = try mixer.createBus("remote")

    bus.volume = 0.42

    #expect(bus.volume == 0.42)
    #expect(bus.faderMixer.outputVolume == 0.42)
}

@Test func busStoresEffectsAndSupportsRemoval() throws {
    let mixer = AudioMixer()
    let bus = try mixer.createBus("voice")
    let firstEffect = AVAudioMixerNode()
    let secondEffect = AVAudioMixerNode()

    try bus.addEffect(firstEffect)
    try bus.addEffect(secondEffect)
    try bus.removeEffect(at: 0)

    #expect(bus.effects.count == 1)
    #expect(bus.effects.first === secondEffect)
}

@Test func removeEffectRejectsInvalidIndex() throws {
    let mixer = AudioMixer()
    let bus = try mixer.createBus("voice")

    do {
        try bus.removeEffect(at: 0)
        Issue.record("invalid effect index should throw")
    } catch {
        #expect(error as? AudioMixerError == .invalidEffectIndex(0))
    }
}

@Test func addEffectRejectsSinkNode() throws {
    let mixer = AudioMixer()
    let bus = try mixer.createBus("voice")

    do {
        // engine.outputNode has numberOfOutputs == 0, so it is a sink-only node
        try bus.addEffect(mixer.engine.outputNode)
        Issue.record("sink node should throw incompatibleEffectNode")
    } catch {
        #expect(error as? AudioMixerError == .incompatibleEffectNode)
    }
}

@Test func addSourceRejectsEngineInternalNode() throws {
    let mixer = AudioMixer()
    let bus = try mixer.createBus("voice")

    do {
        try bus.addSource(mixer.engine.mainMixerNode)
        Issue.record("engine internal node should throw incompatibleEffectNode")
    } catch {
        #expect(error as? AudioMixerError == .incompatibleEffectNode)
    }
}

@Test func routeRejectsCycles() throws {
    let mixer = AudioMixer()
    let local = try mixer.createBus("local")
    let master = try mixer.createBus("master")

    try mixer.route(local, to: master)

    do {
        try mixer.route(master, to: local)
        Issue.record("cycle route should throw")
    } catch {
        #expect(error as? AudioMixerError == .cycleDetected(source: "master", destination: "local"))
    }
}

@Test func routeRejectsMultipleParents() throws {
    let mixer = AudioMixer()
    let local = try mixer.createBus("local")
    let voiceMaster = try mixer.createBus("voiceMaster")
    let finalMaster = try mixer.createBus("finalMaster")

    try mixer.route(local, to: voiceMaster)

    do {
        try mixer.route(local, to: finalMaster)
        Issue.record("second parent route should throw")
    } catch {
        #expect(error as? AudioMixerError == .busAlreadyRouted("local"))
    }
}

@Test func mixerSnapshotReportsGraphState() throws {
    let mixer = AudioMixer()
    let local = try mixer.createBus("local")
    let master = try mixer.createBus("master")
    try local.addSource(AVAudioPlayerNode(), id: "local-monitor")
    try local.addEffect(
        AVAudioMixerNode(),
        id: "local-limiter",
        state: .active,
        parameters: [
            MixerEffectParameterSnapshot(id: "preGain", value: "0", unit: "dB"),
        ]
    )
    local.volume = 0.5
    try mixer.route(local, to: master)
    try mixer.routeToOutput(master)

    let snapshot = mixer.snapshot()

    #expect(snapshot.busIDs == ["local", "master"])
    #expect(snapshot.buses.contains(MixerBusSnapshot(
        id: "local",
        volume: 0.5,
        sourceCount: 1,
        effectCount: 1,
        sources: [
            MixerSourceSnapshot(id: "local-monitor", typeName: "AVAudioPlayerNode", index: 0, inputBusIndex: 0),
        ],
        effectChain: [
            MixerEffectSnapshot(
                id: "local-limiter",
                typeName: "AVAudioMixerNode",
                index: 0,
                state: .active,
                parameters: [
                    MixerEffectParameterSnapshot(id: "preGain", value: "0", unit: "dB"),
                ]
            ),
        ]
    )))
    #expect(snapshot.routes == [
        MixerRouteSnapshot(sourceBusID: "local", destinationBusID: "master", destinationInputBusIndex: 0),
    ])
    #expect(snapshot.outputBusID == "master")
    #expect(snapshot.graph.nodes.contains(MixerGraphNodeSnapshot(
        id: "bus:local:source:local-monitor",
        kind: .source,
        label: "local-monitor",
        busID: "local",
        index: 0,
        typeName: "AVAudioPlayerNode"
    )))
    #expect(snapshot.graph.nodes.contains(MixerGraphNodeSnapshot(
        id: "bus:local:effect:local-limiter",
        kind: .effect,
        label: "local-limiter",
        busID: "local",
        index: 0,
        typeName: "AVAudioMixerNode"
    )))
    #expect(snapshot.graph.edges.contains(MixerGraphEdgeSnapshot(
        id: "source:local:local-monitor",
        sourceNodeID: "bus:local:source:local-monitor",
        destinationNodeID: "bus:local:input",
        kind: .sourceToBusInput,
        sourceBusID: nil,
        destinationBusID: "local",
        destinationInputBusIndex: 0
    )))
    #expect(snapshot.graph.edges.contains(MixerGraphEdgeSnapshot(
        id: "chain:local:input->local-limiter",
        sourceNodeID: "bus:local:input",
        destinationNodeID: "bus:local:effect:local-limiter",
        kind: .busSignal,
        sourceBusID: "local",
        destinationBusID: "local",
        destinationInputBusIndex: nil
    )))
    #expect(snapshot.graph.edges.contains(MixerGraphEdgeSnapshot(
        id: "route:local->master",
        sourceNodeID: "bus:local:fader",
        destinationNodeID: "bus:master:input",
        kind: .busRoute,
        sourceBusID: "local",
        destinationBusID: "master",
        destinationInputBusIndex: 0
    )))
    #expect(snapshot.graph.edges.contains(MixerGraphEdgeSnapshot(
        id: "output:master",
        sourceNodeID: "bus:master:fader",
        destinationNodeID: "mixer:output",
        kind: .outputRoute,
        sourceBusID: "master",
        destinationBusID: nil,
        destinationInputBusIndex: nil
    )))
}

@Test func mixerSnapshotReportsEffectChainOrderAndDefaultIDs() throws {
    let mixer = AudioMixer()
    let bus = try mixer.createBus("voice")

    try bus.addEffect(AVAudioMixerNode(), id: "gate")
    try bus.addEffect(AVAudioMixerNode())

    #expect(bus.snapshot().effectChain == [
        MixerEffectSnapshot(id: "gate", typeName: "AVAudioMixerNode", index: 0),
        MixerEffectSnapshot(id: "effect-0", typeName: "AVAudioMixerNode", index: 1),
    ])
}

@Test func effectSnapshotStateCanBeUpdatedWithoutKnowingEffectorPackage() throws {
    let mixer = AudioMixer()
    let bus = try mixer.createBus("voice")

    try bus.addEffect(AVAudioMixerNode(), id: "vad", state: .active)
    try bus.updateEffectSnapshot(
        id: "vad",
        state: .bypassed,
        parameters: [
            MixerEffectParameterSnapshot(id: "gain", value: "0.25"),
        ]
    )

    #expect(bus.snapshot().effectChain == [
        MixerEffectSnapshot(
            id: "vad",
            typeName: "AVAudioMixerNode",
            index: 0,
            state: .bypassed,
            parameters: [
                MixerEffectParameterSnapshot(id: "gain", value: "0.25"),
            ]
        ),
    ])
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

    try bus.emitToSinksForTesting(PCMFrame(
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
