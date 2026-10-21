import AudioToolbox
@preconcurrency import AVFAudio

public enum VoiceIsolationError: Error, Equatable, Sendable {
	case audioUnitUnavailable
	case unsupportedSoundType(VoiceIsolationSoundType)
	case missingParameter(VoiceIsolationParameter)
}

public enum VoiceIsolationParameter: Sendable {
	case wetDryMixPercent
	case soundToIsolate
}

public enum VoiceIsolationSoundType: String, Codable, Equatable, Sendable {
	case voice
	case highQualityVoice

	public var isSupportedOnCurrentOS: Bool {
		switch self {
		case .voice:
			true
		case .highQualityVoice:
			if #available(iOS 18, macOS 15, *) {
				true
			} else {
				false
			}
		}
	}

	var parameterValue: AUValue? {
		switch self {
		case .voice:
			AUValue(kAUSoundIsolationSoundType_Voice)
		case .highQualityVoice:
			if #available(iOS 18, macOS 15, *) {
				AUValue(kAUSoundIsolationSoundType_HighQualityVoice)
			} else {
				nil
			}
		}
	}
}

public struct VoiceIsolationConfiguration: Codable, Equatable, Sendable {
	public var soundType: VoiceIsolationSoundType
	public var mix: Float

	public init(soundType: VoiceIsolationSoundType = .voice, mix: Float = 1) {
		self.soundType = soundType
		self.mix = mix.isFinite ? min(max(mix, 0), 1) : 0
	}

	var wetDryMixPercent: AUValue {
		AUValue(mix * 100)
	}
}

public enum VoiceIsolationSupport {
	public static let componentDescription = AudioComponentDescription(
		componentType: kAudioUnitType_Effect,
		componentSubType: kAudioUnitSubType_AUSoundIsolation,
		componentManufacturer: kAudioUnitManufacturer_Apple,
		componentFlags: 0,
		componentFlagsMask: 0
	)

	public static var isAvailable: Bool {
		var description = componentDescription
		return AudioComponentFindNext(nil, &description) != nil
	}

	public static var snapshot: VoiceIsolationSupportSnapshot {
		let allSoundTypes: [VoiceIsolationSoundType] = [.voice, .highQualityVoice]
		return VoiceIsolationSupportSnapshot(
			isAvailable: isAvailable,
			supportedSoundTypes: allSoundTypes.filter(\.isSupportedOnCurrentOS),
			unsupportedSoundTypes: allSoundTypes.filter { !$0.isSupportedOnCurrentOS }
		)
	}
}

public struct VoiceIsolationSupportSnapshot: Codable, Equatable, Sendable {
	public var isAvailable: Bool
	public var supportedSoundTypes: [VoiceIsolationSoundType]
	public var unsupportedSoundTypes: [VoiceIsolationSoundType]

	public init(isAvailable: Bool, supportedSoundTypes: [VoiceIsolationSoundType], unsupportedSoundTypes: [VoiceIsolationSoundType]) {
		self.isAvailable = isAvailable
		self.supportedSoundTypes = supportedSoundTypes
		self.unsupportedSoundTypes = unsupportedSoundTypes
	}
}

public enum VoiceIsolationRuntimeState: String, Codable, Equatable, Sendable {
	case active
	case bypassed
	case unavailable
}

public struct VoiceIsolationRuntimeSnapshot: Codable, Equatable, Sendable {
	public var configuration: VoiceIsolationConfiguration
	public var support: VoiceIsolationSupportSnapshot
	public var state: VoiceIsolationRuntimeState

	public init(
		configuration: VoiceIsolationConfiguration,
		support: VoiceIsolationSupportSnapshot = VoiceIsolationSupport.snapshot,
		state: VoiceIsolationRuntimeState? = nil
	) {
		self.configuration = configuration
		self.support = support
		self.state = state ?? (support.isAvailable && configuration.soundType.isSupportedOnCurrentOS ? .active : .unavailable)
	}
}

public final class VoiceIsolationEffect {
	private let effect: AVAudioUnitEffect

	public private(set) var configuration: VoiceIsolationConfiguration

	public var node: AVAudioNode {
		effect
	}

	public var avAudioUnitEffect: AVAudioUnitEffect {
		effect
	}

	public var runtimeSnapshot: VoiceIsolationRuntimeSnapshot {
		VoiceIsolationRuntimeSnapshot(configuration: configuration, state: effect.bypass ? .bypassed : .active)
	}

	public static func make(configuration: VoiceIsolationConfiguration = VoiceIsolationConfiguration()) throws -> VoiceIsolationEffect {
		guard VoiceIsolationSupport.isAvailable else {
			throw VoiceIsolationError.audioUnitUnavailable
		}

		let effect = AVAudioUnitEffect(audioComponentDescription: VoiceIsolationSupport.componentDescription)
		return try VoiceIsolationEffect(effect: effect, configuration: configuration)
	}

	init(effect: AVAudioUnitEffect, configuration: VoiceIsolationConfiguration) throws {
		self.effect = effect
		self.configuration = configuration
		try apply(configuration)
	}

	public func apply(_ configuration: VoiceIsolationConfiguration) throws {
		let configuration = VoiceIsolationConfiguration(soundType: configuration.soundType, mix: configuration.mix)
		guard let soundTypeValue = configuration.soundType.parameterValue else {
			throw VoiceIsolationError.unsupportedSoundType(configuration.soundType)
		}

		try setValue(
			configuration.wetDryMixPercent,
			for: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent),
			missingParameter: .wetDryMixPercent
		)
		try setValue(
			soundTypeValue,
			for: AUParameterAddress(kAUSoundIsolationParam_SoundToIsolate),
			missingParameter: .soundToIsolate
		)
		self.configuration = configuration
	}

	private func setValue(_ value: AUValue, for address: AUParameterAddress, missingParameter: VoiceIsolationParameter) throws {
		guard let parameter = effect.auAudioUnit.parameterTree?.parameter(withAddress: address) else {
			throw VoiceIsolationError.missingParameter(missingParameter)
		}
		parameter.value = value
	}

}
