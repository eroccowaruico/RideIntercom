import AudioToolbox
@preconcurrency import AVFAudio

public enum DynamicsProcessorError: Error, Equatable, Sendable {
	case audioUnitUnavailable
	case missingParameter(DynamicsProcessorParameter)
}

public enum DynamicsProcessorParameter: Sendable {
	case threshold
	case headRoom
	case expansionRatio
	case expansionThreshold
	case attackTime
	case releaseTime
	case overallGain
}

public struct DynamicsProcessorConfiguration: Codable, Equatable, Sendable {
	public var threshold: Float
	public var headRoom: Float
	public var expansionRatio: Float
	public var expansionThreshold: Float
	public var attackTime: Float
	public var releaseTime: Float
	public var overallGain: Float

	public init(
		threshold: Float = -24,
		headRoom: Float = 6,
		expansionRatio: Float = 1,
		expansionThreshold: Float = -70,
		attackTime: Float = 0.01,
		releaseTime: Float = 0.12,
		overallGain: Float = 0
	) {
		self.threshold = Self.clamp(threshold, -60...0)
		self.headRoom = Self.clamp(headRoom, 0...40)
		self.expansionRatio = Self.clamp(expansionRatio, 1...50)
		self.expansionThreshold = Self.clamp(expansionThreshold, -120...0)
		self.attackTime = Self.clamp(attackTime, 0.001...0.2)
		self.releaseTime = Self.clamp(releaseTime, 0.01...3)
		self.overallGain = Self.clamp(overallGain, -40...40)
	}

	private static func clamp(_ value: Float, _ range: ClosedRange<Float>) -> Float {
		value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
	}
}

public enum DynamicsProcessorSupport {
	public static let componentDescription = AudioComponentDescription(
		componentType: kAudioUnitType_Effect,
		componentSubType: kAudioUnitSubType_DynamicsProcessor,
		componentManufacturer: kAudioUnitManufacturer_Apple,
		componentFlags: 0,
		componentFlagsMask: 0
	)

	public static var isAvailable: Bool {
		var description = componentDescription
		return AudioComponentFindNext(nil, &description) != nil
	}

	public static var snapshot: DynamicsProcessorSupportSnapshot {
		DynamicsProcessorSupportSnapshot(isAvailable: isAvailable)
	}
}

public struct DynamicsProcessorSupportSnapshot: Codable, Equatable, Sendable {
	public var isAvailable: Bool

	public init(isAvailable: Bool) {
		self.isAvailable = isAvailable
	}
}

public enum DynamicsProcessorRuntimeState: String, Codable, Equatable, Sendable {
	case active
	case unavailable
}

public struct DynamicsProcessorRuntimeSnapshot: Codable, Equatable, Sendable {
	public var configuration: DynamicsProcessorConfiguration
	public var support: DynamicsProcessorSupportSnapshot
	public var state: DynamicsProcessorRuntimeState

	public init(
		configuration: DynamicsProcessorConfiguration,
		support: DynamicsProcessorSupportSnapshot = DynamicsProcessorSupport.snapshot,
		state: DynamicsProcessorRuntimeState? = nil
	) {
		self.configuration = configuration
		self.support = support
		self.state = state ?? (support.isAvailable ? .active : .unavailable)
	}
}

public final class DynamicsProcessorEffect {
	private let effect: AVAudioUnitEffect

	public private(set) var configuration: DynamicsProcessorConfiguration

	public var node: AVAudioNode {
		effect
	}

	public var avAudioUnitEffect: AVAudioUnitEffect {
		effect
	}

	public var runtimeSnapshot: DynamicsProcessorRuntimeSnapshot {
		DynamicsProcessorRuntimeSnapshot(configuration: configuration)
	}

	public static func make(configuration: DynamicsProcessorConfiguration = DynamicsProcessorConfiguration()) throws -> DynamicsProcessorEffect {
		guard DynamicsProcessorSupport.isAvailable else {
			throw DynamicsProcessorError.audioUnitUnavailable
		}

		let effect = AVAudioUnitEffect(audioComponentDescription: DynamicsProcessorSupport.componentDescription)
		return try DynamicsProcessorEffect(effect: effect, configuration: configuration)
	}

	init(effect: AVAudioUnitEffect, configuration: DynamicsProcessorConfiguration) throws {
		self.effect = effect
		self.configuration = configuration
		try apply(configuration)
	}

	public func apply(_ configuration: DynamicsProcessorConfiguration) throws {
		let configuration = DynamicsProcessorConfiguration(threshold: configuration.threshold, headRoom: configuration.headRoom, expansionRatio: configuration.expansionRatio, expansionThreshold: configuration.expansionThreshold, attackTime: configuration.attackTime, releaseTime: configuration.releaseTime, overallGain: configuration.overallGain)
		try setValue(AUValue(configuration.threshold), for: AUParameterAddress(kDynamicsProcessorParam_Threshold), missingParameter: .threshold)
		try setValue(AUValue(configuration.headRoom), for: AUParameterAddress(kDynamicsProcessorParam_HeadRoom), missingParameter: .headRoom)
		try setValue(AUValue(configuration.expansionRatio), for: AUParameterAddress(kDynamicsProcessorParam_ExpansionRatio), missingParameter: .expansionRatio)
		try setValue(AUValue(configuration.expansionThreshold), for: AUParameterAddress(kDynamicsProcessorParam_ExpansionThreshold), missingParameter: .expansionThreshold)
		try setValue(AUValue(configuration.attackTime), for: AUParameterAddress(kDynamicsProcessorParam_AttackTime), missingParameter: .attackTime)
		try setValue(AUValue(configuration.releaseTime), for: AUParameterAddress(kDynamicsProcessorParam_ReleaseTime), missingParameter: .releaseTime)
		try setValue(AUValue(configuration.overallGain), for: AUParameterAddress(kDynamicsProcessorParam_OverallGain), missingParameter: .overallGain)
		self.configuration = configuration
	}

	private func setValue(_ value: AUValue, for address: AUParameterAddress, missingParameter: DynamicsProcessorParameter) throws {
		guard let parameter = effect.auAudioUnit.parameterTree?.parameter(withAddress: address) else {
			throw DynamicsProcessorError.missingParameter(missingParameter)
		}
		parameter.value = value
	}

}
