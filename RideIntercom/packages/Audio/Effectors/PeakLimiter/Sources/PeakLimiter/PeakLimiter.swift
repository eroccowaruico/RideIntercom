import AudioToolbox
@preconcurrency import AVFAudio

public enum PeakLimiterError: Error, Equatable, Sendable {
	case audioUnitUnavailable
	case missingParameter(PeakLimiterParameter)
}

public enum PeakLimiterParameter: Sendable {
	case attackTime
	case decayTime
	case preGain
}

public struct PeakLimiterConfiguration: Codable, Equatable, Sendable {
	public var attackTime: Float
	public var decayTime: Float
	public var preGain: Float

	public init(attackTime: Float = 0.012, decayTime: Float = 0.024, preGain: Float = 0) {
		self.attackTime = Self.clamp(attackTime, 0.001...0.03)
		self.decayTime = Self.clamp(decayTime, 0.001...0.06)
		self.preGain = Self.clamp(preGain, -40...40)
	}

	private static func clamp(_ value: Float, _ range: ClosedRange<Float>) -> Float {
		value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
	}
}

public enum PeakLimiterSupport {
	public static let componentDescription = AudioComponentDescription(
		componentType: kAudioUnitType_Effect,
		componentSubType: kAudioUnitSubType_PeakLimiter,
		componentManufacturer: kAudioUnitManufacturer_Apple,
		componentFlags: 0,
		componentFlagsMask: 0
	)

	public static var isAvailable: Bool {
		var description = componentDescription
		return AudioComponentFindNext(nil, &description) != nil
	}

	public static var snapshot: PeakLimiterSupportSnapshot {
		PeakLimiterSupportSnapshot(isAvailable: isAvailable)
	}
}

public struct PeakLimiterSupportSnapshot: Codable, Equatable, Sendable {
	public var isAvailable: Bool

	public init(isAvailable: Bool) {
		self.isAvailable = isAvailable
	}
}

public enum PeakLimiterRuntimeState: String, Codable, Equatable, Sendable {
	case active
	case unavailable
}

public struct PeakLimiterRuntimeSnapshot: Codable, Equatable, Sendable {
	public var configuration: PeakLimiterConfiguration
	public var support: PeakLimiterSupportSnapshot
	public var state: PeakLimiterRuntimeState

	public init(
		configuration: PeakLimiterConfiguration,
		support: PeakLimiterSupportSnapshot = PeakLimiterSupport.snapshot,
		state: PeakLimiterRuntimeState? = nil
	) {
		self.configuration = configuration
		self.support = support
		self.state = state ?? (support.isAvailable ? .active : .unavailable)
	}
}

public final class PeakLimiterEffect {
	private let effect: AVAudioUnitEffect

	public private(set) var configuration: PeakLimiterConfiguration

	public var node: AVAudioNode {
		effect
	}

	public var avAudioUnitEffect: AVAudioUnitEffect {
		effect
	}

	public var runtimeSnapshot: PeakLimiterRuntimeSnapshot {
		PeakLimiterRuntimeSnapshot(configuration: configuration)
	}

	public static func make(configuration: PeakLimiterConfiguration = PeakLimiterConfiguration()) throws -> PeakLimiterEffect {
		guard PeakLimiterSupport.isAvailable else {
			throw PeakLimiterError.audioUnitUnavailable
		}

		let effect = AVAudioUnitEffect(audioComponentDescription: PeakLimiterSupport.componentDescription)
		return try PeakLimiterEffect(effect: effect, configuration: configuration)
	}

	init(effect: AVAudioUnitEffect, configuration: PeakLimiterConfiguration) throws {
		self.effect = effect
		self.configuration = configuration
		try apply(configuration)
	}

	public func apply(_ configuration: PeakLimiterConfiguration) throws {
		let configuration = PeakLimiterConfiguration(attackTime: configuration.attackTime, decayTime: configuration.decayTime, preGain: configuration.preGain)
		try setValue(AUValue(configuration.attackTime), for: AUParameterAddress(kLimiterParam_AttackTime), missingParameter: .attackTime)
		try setValue(AUValue(configuration.decayTime), for: AUParameterAddress(kLimiterParam_DecayTime), missingParameter: .decayTime)
		try setValue(AUValue(configuration.preGain), for: AUParameterAddress(kLimiterParam_PreGain), missingParameter: .preGain)
		self.configuration = configuration
	}

	private func setValue(_ value: AUValue, for address: AUParameterAddress, missingParameter: PeakLimiterParameter) throws {
		guard let parameter = effect.auAudioUnit.parameterTree?.parameter(withAddress: address) else {
			throw PeakLimiterError.missingParameter(missingParameter)
		}
		parameter.value = value
	}

}
