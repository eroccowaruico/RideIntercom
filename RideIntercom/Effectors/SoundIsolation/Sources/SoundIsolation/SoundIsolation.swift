import AudioToolbox
@preconcurrency import AVFAudio

public enum VoiceIsolationError: Error, Equatable, Sendable {
	case audioUnitUnavailable
	case instantiationFailed(String)
	case unsupportedSoundType(VoiceIsolationSoundType)
	case missingParameter(VoiceIsolationParameter)
}

public enum VoiceIsolationParameter: Sendable {
	case wetDryMixPercent
	case soundToIsolate
}

public enum VoiceIsolationSoundType: Sendable {
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

public struct VoiceIsolationConfiguration: Equatable, Sendable {
	public var soundType: VoiceIsolationSoundType
	public var mix: Float

	public init(soundType: VoiceIsolationSoundType = .voice, mix: Float = 1) {
		self.soundType = soundType
		self.mix = min(max(mix, 0), 1)
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

	public static func make(configuration: VoiceIsolationConfiguration = VoiceIsolationConfiguration()) async throws -> VoiceIsolationEffect {
		guard VoiceIsolationSupport.isAvailable else {
			throw VoiceIsolationError.audioUnitUnavailable
		}

		let effect = try await instantiateAudioUnitEffect()
		return try VoiceIsolationEffect(effect: effect, configuration: configuration)
	}

	init(effect: AVAudioUnitEffect, configuration: VoiceIsolationConfiguration) throws {
		self.effect = effect
		self.configuration = configuration
		try apply(configuration)
	}

	public func apply(_ configuration: VoiceIsolationConfiguration) throws {
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

	private static func instantiateAudioUnitEffect() async throws -> AVAudioUnitEffect {
		try await withCheckedThrowingContinuation { continuation in
			AVAudioUnitEffect.instantiate(with: VoiceIsolationSupport.componentDescription, options: []) { audioUnit, error in
				if let effect = audioUnit as? AVAudioUnitEffect {
					continuation.resume(returning: effect)
				} else {
					continuation.resume(throwing: VoiceIsolationError.instantiationFailed(error?.localizedDescription ?? "Unknown AVAudioUnitEffect error"))
				}
			}
		}
	}
}
