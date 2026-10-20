import Testing
@testable import DynamicsProcessor
import AudioToolbox
import Foundation

@Test func componentDescriptionTargetsAppleDynamicsProcessorEffect() {
    let description = DynamicsProcessorSupport.componentDescription

    #expect(description.componentType == kAudioUnitType_Effect)
    #expect(description.componentSubType == kAudioUnitSubType_DynamicsProcessor)
    #expect(description.componentManufacturer == kAudioUnitManufacturer_Apple)
    #expect(description.componentFlags == 0)
    #expect(description.componentFlagsMask == 0)
}

@Test func defaultConfigurationUsesRideIntercomVoicePreset() {
    let configuration = DynamicsProcessorConfiguration()

    #expect(configuration.threshold == -24)
    #expect(configuration.headRoom == 6)
    #expect(configuration.expansionRatio == 1)
    #expect(configuration.expansionThreshold == -70)
    #expect(configuration.attackTime == 0.01)
    #expect(configuration.releaseTime == 0.12)
    #expect(configuration.overallGain == 0)
}

@Test func configurationClampsParametersToSupportedRanges() {
    let low = DynamicsProcessorConfiguration(
        threshold: -100,
        headRoom: -1,
        expansionRatio: 0,
        expansionThreshold: -200,
        attackTime: 0,
        releaseTime: 0,
        overallGain: -100
    )
    let high = DynamicsProcessorConfiguration(
        threshold: 20,
        headRoom: 80,
        expansionRatio: 100,
        expansionThreshold: 20,
        attackTime: 1,
        releaseTime: 10,
        overallGain: 100
    )

    #expect(low.threshold == -60)
    #expect(low.headRoom == 0)
    #expect(low.expansionRatio == 1)
    #expect(low.expansionThreshold == -120)
    #expect(low.attackTime == 0.001)
    #expect(low.releaseTime == 0.01)
    #expect(low.overallGain == -40)
    #expect(high.threshold == 0)
    #expect(high.headRoom == 40)
    #expect(high.expansionRatio == 50)
    #expect(high.expansionThreshold == 0)
    #expect(high.attackTime == 0.2)
    #expect(high.releaseTime == 3)
    #expect(high.overallGain == 40)
}

@Test func runtimeSnapshotIsCodableAndIndependentFromMixer() throws {
    let snapshot = DynamicsProcessorRuntimeSnapshot(
        configuration: DynamicsProcessorConfiguration(threshold: -20, headRoom: 8, overallGain: 2),
        support: DynamicsProcessorSupportSnapshot(isAvailable: true),
        state: .active
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(DynamicsProcessorRuntimeSnapshot.self, from: data)

    #expect(decoded == snapshot)
}

@Test func realAudioUnitAcceptsConfigurationAndReportsIt() throws {
    #expect(DynamicsProcessorSupport.isAvailable)
    let effect = try DynamicsProcessorEffect.make()
    let configuration = DynamicsProcessorConfiguration(threshold: -18)
    try effect.apply(configuration)
    #expect(effect.configuration == configuration)
    #expect(effect.runtimeSnapshot.configuration == configuration)
    #expect(effect.node.numberOfInputs > 0)
    #expect(effect.node.numberOfOutputs > 0)
}
