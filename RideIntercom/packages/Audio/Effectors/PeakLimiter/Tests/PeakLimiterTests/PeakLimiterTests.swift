import Testing
@testable import PeakLimiter
import AudioToolbox
import Foundation

@Test func componentDescriptionTargetsApplePeakLimiterEffect() {
    let description = PeakLimiterSupport.componentDescription

    #expect(description.componentType == kAudioUnitType_Effect)
    #expect(description.componentSubType == kAudioUnitSubType_PeakLimiter)
    #expect(description.componentManufacturer == kAudioUnitManufacturer_Apple)
    #expect(description.componentFlags == 0)
    #expect(description.componentFlagsMask == 0)
}

@Test func defaultConfigurationUsesRideIntercomVoicePreset() {
    let configuration = PeakLimiterConfiguration()

    #expect(configuration.attackTime == 0.012)
    #expect(configuration.decayTime == 0.024)
    #expect(configuration.preGain == 0)
}

@Test func configurationClampsParametersToSupportedRanges() {
    let low = PeakLimiterConfiguration(attackTime: 0, decayTime: 0, preGain: -100)
    let high = PeakLimiterConfiguration(attackTime: 1, decayTime: 1, preGain: 100)

    #expect(low.attackTime == 0.001)
    #expect(low.decayTime == 0.001)
    #expect(low.preGain == -40)
    #expect(high.attackTime == 0.03)
    #expect(high.decayTime == 0.06)
    #expect(high.preGain == 40)
}

@Test func runtimeSnapshotIsCodableAndIndependentFromMixer() throws {
    let snapshot = PeakLimiterRuntimeSnapshot(
        configuration: PeakLimiterConfiguration(attackTime: 0.01, decayTime: 0.02, preGain: 3),
        support: PeakLimiterSupportSnapshot(isAvailable: true),
        state: .active
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(PeakLimiterRuntimeSnapshot.self, from: data)

    #expect(decoded == snapshot)
}

@Test func realAudioUnitAcceptsConfigurationAndReportsIt() throws {
    #expect(PeakLimiterSupport.isAvailable)
    let effect = try PeakLimiterEffect.make()
    let configuration = PeakLimiterConfiguration(preGain: -6)
    try effect.apply(configuration)
    #expect(effect.configuration == configuration)
    #expect(effect.runtimeSnapshot.configuration == configuration)
    #expect(effect.node.numberOfInputs > 0)
    #expect(effect.node.numberOfOutputs > 0)
}
