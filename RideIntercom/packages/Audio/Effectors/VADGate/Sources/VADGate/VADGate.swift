import Foundation
import AudioToolbox
@preconcurrency import AVFAudio

public enum VADGateError: Error, Equatable, Sendable {
	case instantiationFailed(String)
}

public enum VADGateState: String, Codable, Equatable, Sendable {
	case silence
	case speech
}

public struct VADGateConfiguration: Codable, Equatable, Sendable {
	public var attackDuration: Double
	public var releaseDuration: Double
	public var updateInterval: Double
	public var speechThresholdOffsetDB: Float
	public var silenceThresholdOffsetDB: Float
	public var initialNoiseFloorDBFS: Float
	public var minimumNoiseFloorDBFS: Float
	public var maximumNoiseFloorDBFS: Float
	public var noiseFloorAdaptation: Float
	public var speechGain: Float
	public var silenceGain: Float
	public var gainAttackDuration: Double
	public var gainReleaseDuration: Double

	public init(
		attackDuration: Double = 0.08,
		releaseDuration: Double = 0.5,
		updateInterval: Double = 0.02,
		speechThresholdOffsetDB: Float = 12,
		silenceThresholdOffsetDB: Float = 8,
		initialNoiseFloorDBFS: Float = -60,
		minimumNoiseFloorDBFS: Float = -90,
		maximumNoiseFloorDBFS: Float = -20,
		noiseFloorAdaptation: Float = 0.05,
		speechGain: Float = 1,
		silenceGain: Float = 0,
		gainAttackDuration: Double = 0.03,
		gainReleaseDuration: Double = 0.12
	) {
		let minimumNoiseFloorDBFS = Self.clamp(minimumNoiseFloorDBFS.isFinite ? minimumNoiseFloorDBFS : -90, -120...0)
		let maximumNoiseFloorDBFS = Self.clamp(maximumNoiseFloorDBFS.isFinite ? maximumNoiseFloorDBFS : -20, -120...0)
		let noiseFloorLowerBound = min(minimumNoiseFloorDBFS, maximumNoiseFloorDBFS)
		let noiseFloorUpperBound = max(minimumNoiseFloorDBFS, maximumNoiseFloorDBFS)
		let normalizedSpeechThresholdOffsetDB = Self.clamp(speechThresholdOffsetDB, 1...40)

		self.attackDuration = Self.clamp(attackDuration, 0.01...1)
		self.releaseDuration = Self.clamp(releaseDuration, 0.05...2)
		self.updateInterval = Self.clamp(updateInterval, 0.005...0.1)
		self.speechThresholdOffsetDB = normalizedSpeechThresholdOffsetDB
		self.silenceThresholdOffsetDB = Self.clamp(silenceThresholdOffsetDB, 0...normalizedSpeechThresholdOffsetDB)
		self.initialNoiseFloorDBFS = Self.clamp(initialNoiseFloorDBFS, noiseFloorLowerBound...noiseFloorUpperBound)
		self.minimumNoiseFloorDBFS = noiseFloorLowerBound
		self.maximumNoiseFloorDBFS = noiseFloorUpperBound
		self.noiseFloorAdaptation = Self.clamp(noiseFloorAdaptation, 0...1)
		self.speechGain = Self.clamp(speechGain, 0...1)
		self.silenceGain = Self.clamp(silenceGain, 0...1)
		self.gainAttackDuration = Self.clamp(gainAttackDuration, 0.001...1)
		self.gainReleaseDuration = Self.clamp(gainReleaseDuration, 0.001...2)
	}

	fileprivate var normalized: Self {
		Self(attackDuration: attackDuration, releaseDuration: releaseDuration, updateInterval: updateInterval, speechThresholdOffsetDB: speechThresholdOffsetDB, silenceThresholdOffsetDB: silenceThresholdOffsetDB, initialNoiseFloorDBFS: initialNoiseFloorDBFS, minimumNoiseFloorDBFS: minimumNoiseFloorDBFS, maximumNoiseFloorDBFS: maximumNoiseFloorDBFS, noiseFloorAdaptation: noiseFloorAdaptation, speechGain: speechGain, silenceGain: silenceGain, gainAttackDuration: gainAttackDuration, gainReleaseDuration: gainReleaseDuration)
	}

	private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
		value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
	}

	private static func clamp(_ value: Float, _ range: ClosedRange<Float>) -> Float {
		value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
	}
}

public struct VADGateAnalysis: Codable, Equatable, Sendable {
	public var state: VADGateState
	public var rms: Float
	public var rmsDBFS: Float
	public var noiseFloorDBFS: Float
	public var speechThresholdDBFS: Float
	public var silenceThresholdDBFS: Float
	public var gain: Float
}

public struct VADGateRuntimeSnapshot: Codable, Equatable, Sendable {
	public var configuration: VADGateConfiguration
	public var state: VADGateState
	public var noiseFloorDBFS: Float
	public var gain: Float
	public var lastAnalysis: VADGateAnalysis?

	public init(
		configuration: VADGateConfiguration,
		state: VADGateState,
		noiseFloorDBFS: Float,
		gain: Float,
		lastAnalysis: VADGateAnalysis? = nil
	) {
		self.configuration = configuration
		self.state = state
		self.noiseFloorDBFS = noiseFloorDBFS
		self.gain = gain
		self.lastAnalysis = lastAnalysis
	}
}

public final class VADGate {
	private let lock = NSRecursiveLock()
	private var _configuration: VADGateConfiguration
	public var configuration: VADGateConfiguration { lock.withLock { _configuration } }
	private var _state: VADGateState = .silence
	public var state: VADGateState { lock.withLock { _state } }
	private var _noiseFloorDBFS: Float
	public var noiseFloorDBFS: Float { lock.withLock { _noiseFloorDBFS } }
	private var _gain: Float
	public var gain: Float { lock.withLock { _gain } }
	private var _lastAnalysis: VADGateAnalysis?
	public var lastAnalysis: VADGateAnalysis? { lock.withLock { _lastAnalysis } }

	private var attackElapsed: Double = 0
	private var releaseElapsed: Double = 0

	public init(configuration: VADGateConfiguration = VADGateConfiguration()) {
		self._configuration = configuration.normalized
		self._noiseFloorDBFS = configuration.normalized.initialNoiseFloorDBFS
		self._gain = configuration.normalized.silenceGain
	}

	public func apply(configuration: VADGateConfiguration) {
		lock.lock()
		defer { lock.unlock() }
		self._configuration = configuration.normalized
	}

	public func reset(noiseFloorDBFS: Float? = nil) {
		lock.lock()
		defer { lock.unlock() }
		_state = .silence
		attackElapsed = 0
		releaseElapsed = 0
		let floor = noiseFloorDBFS.flatMap { $0.isFinite ? $0 : nil } ?? configuration.initialNoiseFloorDBFS
		self._noiseFloorDBFS = min(configuration.maximumNoiseFloorDBFS, max(configuration.minimumNoiseFloorDBFS, floor))
		_gain = configuration.silenceGain
		_lastAnalysis = nil
	}

	public var runtimeSnapshot: VADGateRuntimeSnapshot {
		lock.lock()
		defer { lock.unlock() }
		return VADGateRuntimeSnapshot(
			configuration: configuration,
			state: state,
			noiseFloorDBFS: noiseFloorDBFS,
			gain: gain,
			lastAnalysis: lastAnalysis
		)
	}

	@discardableResult
	public func process(samples: [Float], duration: Double? = nil) -> VADGateAnalysis {
		process(rmsDBFS: Self.rmsDBFS(samples: samples), duration: duration)
	}

	@discardableResult
	public func process(rmsDBFS: Float, duration: Double? = nil) -> VADGateAnalysis {
		lock.lock()
		defer { lock.unlock() }
		let rmsDBFS = rmsDBFS.isFinite ? min(0, max(-120, rmsDBFS)) : -120
		let frameDuration = duration.flatMap { $0.isFinite && $0 > 0 ? min(1, $0) : nil } ?? configuration.updateInterval
		let speechThreshold = noiseFloorDBFS + configuration.speechThresholdOffsetDB
		let silenceThreshold = noiseFloorDBFS + configuration.silenceThresholdOffsetDB

		switch state {
		case .silence:
			if rmsDBFS > speechThreshold {
				attackElapsed += frameDuration
				if attackElapsed >= configuration.attackDuration {
					_state = .speech
					attackElapsed = 0
					releaseElapsed = 0
				}
			} else {
				attackElapsed = 0
				adaptNoiseFloor(toward: rmsDBFS)
			}
		case .speech:
			if rmsDBFS < silenceThreshold {
				releaseElapsed += frameDuration
				if releaseElapsed >= configuration.releaseDuration {
					_state = .silence
					releaseElapsed = 0
					attackElapsed = 0
				}
			} else {
				releaseElapsed = 0
			}
		}

		updateGain(duration: frameDuration)
		let analysis = makeAnalysis(rmsDBFS: rmsDBFS)
		_lastAnalysis = analysis
		return analysis
	}

	@discardableResult
	public func applyGate(to samples: inout [Float], duration: Double? = nil) -> VADGateAnalysis {
		let analysis = process(samples: samples, duration: duration)
		for index in samples.indices {
			samples[index] = samples[index].isFinite ? samples[index] * analysis.gain : 0
		}
		return analysis
	}

	public static func rms(samples: [Float]) -> Float {
		guard !samples.isEmpty else { return 0 }
		let sumOfSquares = samples.reduce(Double(0)) { $0 + ($1.isFinite ? Double($1) * Double($1) : 0) }
		return Float((sumOfSquares / Double(samples.count)).squareRoot())
	}

	public static func rmsDBFS(samples: [Float]) -> Float {
		20 * log10(max(rms(samples: samples), 0.000_001))
	}

	private func adaptNoiseFloor(toward rmsDBFS: Float) {
		let adapted = noiseFloorDBFS + (rmsDBFS - noiseFloorDBFS) * configuration.noiseFloorAdaptation
		_noiseFloorDBFS = min(max(adapted, configuration.minimumNoiseFloorDBFS), configuration.maximumNoiseFloorDBFS)
	}

	private func updateGain(duration: Double) {
		let targetGain = _state == .speech ? configuration.speechGain : configuration.silenceGain
		let rampDuration = _state == .speech ? configuration.gainAttackDuration : configuration.gainReleaseDuration
		let step = rampDuration <= 0 ? 1 : min(1, Float(duration / rampDuration))
		_gain += (targetGain - gain) * step
		_gain = min(max(gain, min(configuration.silenceGain, configuration.speechGain)), max(configuration.silenceGain, configuration.speechGain))
	}

	private func makeAnalysis(rmsDBFS: Float) -> VADGateAnalysis {
		VADGateAnalysis(
			state: state,
			rms: pow(10, rmsDBFS / 20),
			rmsDBFS: rmsDBFS,
			noiseFloorDBFS: noiseFloorDBFS,
			speechThresholdDBFS: noiseFloorDBFS + configuration.speechThresholdOffsetDB,
			silenceThresholdDBFS: noiseFloorDBFS + configuration.silenceThresholdOffsetDB,
			gain: gain
		)
	}
}

extension VADGate: @unchecked Sendable {}

// MARK: - VADGateEffect

public final class VADGateEffect {
	private let auNode: AVAudioUnit

	public private(set) var configuration: VADGateConfiguration

	public var node: AVAudioNode { auNode }
	public var avAudioUnit: AVAudioUnit { auNode }
	public var vadGate: VADGate { (auNode.auAudioUnit as! AudioUnit).vadGate }

	private static let componentDescription = AudioComponentDescription(
		componentType: kAudioUnitType_Effect,
		componentSubType: 0x76_61_64_67, // 'vadg'
		componentManufacturer: 0x52_64_49_63, // 'RdIc'
		componentFlags: 0,
		componentFlagsMask: 0
	)

	private static let registration: Void = {
		AUAudioUnit.registerSubclass(AudioUnit.self, as: componentDescription, name: "VADGate", version: 1)
	}()

	public static func make(configuration: VADGateConfiguration = VADGateConfiguration()) async throws -> VADGateEffect {
		_ = registration
		return VADGateEffect(
			auNode: try await withCheckedThrowingContinuation { continuation in
				AVAudioUnit.instantiate(with: componentDescription) { avAudioUnit, error in
					if let avAudioUnit {
						continuation.resume(returning: avAudioUnit)
					} else {
						continuation.resume(throwing: VADGateError.instantiationFailed(error?.localizedDescription ?? ""))
					}
				}
			},
			configuration: configuration
		)
	}

	init(auNode: AVAudioUnit, configuration: VADGateConfiguration) {
		self.auNode = auNode
		self.configuration = configuration
		apply(configuration)
	}

	public func apply(_ configuration: VADGateConfiguration) {
		vadGate.apply(configuration: configuration)
		self.configuration = configuration
	}

	public var runtimeSnapshot: VADGateRuntimeSnapshot {
		vadGate.runtimeSnapshot
	}

	private final class AudioUnit: AUAudioUnit {
		let vadGate = VADGate()
		private var _inputBusses: AUAudioUnitBusArray!
		private var _outputBusses: AUAudioUnitBusArray!

		override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
			try super.init(componentDescription: componentDescription, options: options)
			let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
			_inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)])
			_outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
		}

		override var inputBusses: AUAudioUnitBusArray { _inputBusses }
		override var outputBusses: AUAudioUnitBusArray { _outputBusses }
		override var canProcessInPlace: Bool { true }

		override var internalRenderBlock: AUInternalRenderBlock {
			let vad = vadGate
			return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
				guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
				var flags: AudioUnitRenderActionFlags = []
				let status = pullInputBlock(&flags, timestamp, frameCount, 0, outputData)
				guard status == noErr else { return status }

				let buffers = UnsafeMutableAudioBufferListPointer(outputData)
				let n = Int(frameCount)
				var ss: Float = 0, count = 0
				for b in buffers {
					guard let d = b.mData else { continue }
					let p = UnsafeBufferPointer<Float>(start: d.assumingMemoryBound(to: Float.self), count: min(n, Int(b.mDataByteSize) / MemoryLayout<Float>.size))
					for s in p { ss += s * s }
					count += p.count
				}
				let rms = count > 0 ? (ss / Float(count)).squareRoot() : 0
				let gain = vad.process(rmsDBFS: 20 * log10(max(rms, 0.000_001)), duration: Double(frameCount) / 48_000.0).gain
				for b in buffers {
					guard let d = b.mData else { continue }
					let p = UnsafeMutableBufferPointer<Float>(start: d.assumingMemoryBound(to: Float.self), count: min(n, Int(b.mDataByteSize) / MemoryLayout<Float>.size))
					for i in p.indices { p[i] *= gain }
				}
				return noErr
			}
		}
	}
}
