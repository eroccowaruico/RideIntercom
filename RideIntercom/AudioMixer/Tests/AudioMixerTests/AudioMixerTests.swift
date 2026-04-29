import Testing
@testable import AudioMixer
import AVFAudio

@Test func defaultFormatUsesStereoFloat32At48kHz() {
    let mixer = AudioMixer()

    #expect(mixer.format.commonFormat == .pcmFormatFloat32)
    #expect(mixer.format.sampleRate == 48_000)
    #expect(mixer.format.channelCount == 2)
    #expect(!mixer.format.isInterleaved)
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
