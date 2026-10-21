import Dispatch
import Testing
@testable import VADGate
import AVFAudio
import Foundation

@Test func defaultConfigurationUsesRealtimeVoiceGatePreset() {
    let configuration = VADGateConfiguration()

    #expect(configuration.attackDuration == 0.08)
    #expect(configuration.releaseDuration == 0.5)
    #expect(configuration.updateInterval == 0.02)
    #expect(configuration.speechThresholdOffsetDB == 12)
    #expect(configuration.silenceThresholdOffsetDB == 8)
    #expect(configuration.speechGain == 1)
    #expect(configuration.silenceGain == 0)
}

@Test func configurationClampsValuesToUsableRanges() {
    let configuration = VADGateConfiguration(
        attackDuration: 0,
        releaseDuration: 0,
        updateInterval: 1,
        speechThresholdOffsetDB: -1,
        silenceThresholdOffsetDB: 100,
        initialNoiseFloorDBFS: -200,
        minimumNoiseFloorDBFS: -90,
        maximumNoiseFloorDBFS: -20,
        noiseFloorAdaptation: 2,
        speechGain: 2,
        silenceGain: -1,
        gainAttackDuration: 0,
        gainReleaseDuration: 3
    )

    #expect(configuration.attackDuration == 0.01)
    #expect(configuration.releaseDuration == 0.05)
    #expect(configuration.updateInterval == 0.1)
    #expect(configuration.speechThresholdOffsetDB == 1)
    #expect(configuration.silenceThresholdOffsetDB == 1)
    #expect(configuration.initialNoiseFloorDBFS == -90)
    #expect(configuration.noiseFloorAdaptation == 1)
    #expect(configuration.speechGain == 1)
    #expect(configuration.silenceGain == 0)
    #expect(configuration.gainAttackDuration == 0.001)
    #expect(configuration.gainReleaseDuration == 2)
}

@Test func rmsDBFSComputesShortTimeEnergy() {
    #expect(VADGate.rms(samples: [1, -1, 1, -1]) == 1)
    #expect(VADGate.rmsDBFS(samples: [1, -1, 1, -1]) == 0)
}

@Test func stateChangesToSpeechAfterAttackDuration() {
    let gate = VADGate(configuration: VADGateConfiguration(attackDuration: 0.06, updateInterval: 0.02, initialNoiseFloorDBFS: -60))

    #expect(gate.process(rmsDBFS: -45).state == .silence)
    #expect(gate.process(rmsDBFS: -45).state == .silence)
    #expect(gate.process(rmsDBFS: -45).state == .speech)
}

@Test func stateUsesReleaseHangoverBeforeReturningToSilence() {
    let gate = VADGate(configuration: VADGateConfiguration(attackDuration: 0.02, releaseDuration: 0.06, updateInterval: 0.02, initialNoiseFloorDBFS: -60))
    _ = gate.process(rmsDBFS: -45)

    #expect(gate.state == .speech)
    #expect(gate.process(rmsDBFS: -58).state == .speech)
    #expect(gate.process(rmsDBFS: -58).state == .speech)
    #expect(gate.process(rmsDBFS: -58).state == .silence)
}

@Test func vadGateEffectExposesValidAVAudioNode() async throws {
    let effect = try await VADGateEffect.make()

    #expect(effect.node.numberOfInputs == 1)
    #expect(effect.node.numberOfOutputs == 1)
}

@Test func vadGateEffectAppliesConfigurationToVADGate() async throws {
    let config = VADGateConfiguration(attackDuration: 0.5)
    let effect = try await VADGateEffect.make(configuration: config)

    #expect(effect.vadGate.configuration.attackDuration == 0.5)
}

@Test func applyGateScalesSamplesByCurrentGain() {
    var samples: [Float] = [0.5, -0.5]
    let gate = VADGate(configuration: VADGateConfiguration(attackDuration: 0.02, updateInterval: 0.02, initialNoiseFloorDBFS: -60, gainAttackDuration: 0.02))

    let analysis = gate.applyGate(to: &samples, duration: 0.02)

    #expect(analysis.state == .speech)
    #expect(analysis.gain == 1)
    #expect(samples == [Float(0.5), Float(-0.5)])
}

@Test func runtimeSnapshotReportsConfigurationAndCurrentAnalysis() throws {
    let gate = VADGate(configuration: VADGateConfiguration(attackDuration: 0.02, updateInterval: 0.02, initialNoiseFloorDBFS: -60))

    let analysis = gate.process(rmsDBFS: -45)
    let snapshot = gate.runtimeSnapshot

    #expect(snapshot.configuration.attackDuration == 0.02)
    #expect(snapshot.state == .speech)
    #expect(snapshot.noiseFloorDBFS == -60)
    #expect(snapshot.gain == analysis.gain)
    #expect(snapshot.lastAnalysis == analysis)

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(VADGateRuntimeSnapshot.self, from: data)

    #expect(decoded == snapshot)
}

@Test func nonfiniteConfigurationAndSamplesRemainFinite() {
    var configuration = VADGateConfiguration(minimumNoiseFloorDBFS: .nan, maximumNoiseFloorDBFS: .infinity)
    configuration.attackDuration = .nan
    let gate = VADGate(configuration: configuration)
    var samples: [Float] = [.nan, .infinity, -.infinity, 0.1]
    let analysis = gate.applyGate(to: &samples, duration: .infinity)
    #expect(analysis.gain.isFinite)
    #expect(analysis.noiseFloorDBFS.isFinite)
    #expect(samples.allSatisfy { $0.isFinite })
}

@Test func concurrentSettingsAndAnalysisHaveConsistentSnapshots() {
    let gate = VADGate()
    DispatchQueue.concurrentPerform(iterations: 200) { i in
        if i.isMultiple(of: 3) { gate.apply(configuration: .init(speechGain: 0.7)) }
        else { _ = gate.process(rmsDBFS: -20) }
        #expect(gate.runtimeSnapshot.gain.isFinite)
    }
}
