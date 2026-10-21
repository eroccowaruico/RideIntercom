import AudioCore
@preconcurrency import AVFAudio
import Foundation

public final class MixerPCMSource {
	public let id: String
	public let playerNode: AVAudioPlayerNode
	public let faderNode: AVAudioMixerNode
	public let mixerFormat: AudioFormat

	private let recordSchedule: (PCMFrame, AudioProcessingReport?, String?) -> Void
	private let maximumBufferedDuration: TimeInterval?
	private var scheduledEndSample: AVAudioFramePosition = 0
	public private(set) var playbackResetCount = 0

	private var renderedSample: AVAudioFramePosition {
		playerNode.lastRenderTime.flatMap { time in
			guard time.isSampleTimeValid || time.isHostTimeValid,
			      let played = playerNode.playerTime(forNodeTime: time), played.isSampleTimeValid else { return nil }
			return played.sampleTime
		} ?? 0
	}
	public var bufferedDuration: TimeInterval {
		Double(max(0, scheduledEndSample - renderedSample)) / mixerFormat.sampleRate
	}

	public var volume: Float {
		get { faderNode.outputVolume }
		set { faderNode.outputVolume = min(1, max(0, newValue)) }
	}

	init(
		id: String,
		playerNode: AVAudioPlayerNode,
		faderNode: AVAudioMixerNode,
		mixerFormat: AudioFormat,
		maximumBufferedDuration: TimeInterval?,
		recordSchedule: @escaping (PCMFrame, AudioProcessingReport?, String?) -> Void
	) {
		self.id = id
		self.playerNode = playerNode
		self.faderNode = faderNode
		self.mixerFormat = mixerFormat
		self.recordSchedule = recordSchedule
		self.maximumBufferedDuration = maximumBufferedDuration
	}

	@discardableResult
	public func schedule(_ frame: PCMFrame) throws -> AudioProcessingReport {
		do {
			let normalized = try MixerPCMNormalizer.normalize(frame, to: mixerFormat, operation: .normalizeSource)
			let buffer = try normalized.frame.makePCMBuffer()
			var shouldResumePlayback = false
			if let limit = maximumBufferedDuration {
				let duration = Double(buffer.frameLength) / mixerFormat.sampleRate
				guard limit.isFinite, limit > 0, duration <= limit else {
					throw AudioMixerError.pcmSourceScheduleFailed("Frame exceeds live playback budget")
				}
				if bufferedDuration + duration > limit {
					shouldResumePlayback = playerNode.isPlaying
					stop()
					playbackResetCount += 1
				}
			}
			scheduledEndSample = max(scheduledEndSample, renderedSample) + AVAudioFramePosition(buffer.frameLength)
			playerNode.scheduleBuffer(buffer, completionHandler: nil)
			// Resume only after the replacement buffer is queued; an empty
			// running player can otherwise render silence after a backlog reset.
			if shouldResumePlayback { start() }
			recordSchedule(frame, normalized.report, nil)
			return normalized.report
		} catch let failure as AudioProcessingFailure {
			recordSchedule(frame, nil, failure.reason)
			throw failure
		} catch {
			recordSchedule(frame, nil, String(describing: error))
			throw AudioMixerError.pcmSourceScheduleFailed(String(describing: error))
		}
	}

	public func start() {
		playerNode.play()
	}

	public func stop() {
		playerNode.stop()
		scheduledEndSample = 0
	}
}

public final class MixerPCMSink {
	public let id: String
	public let mixerFormat: AudioFormat
	public let targetFormat: AudioFormat

	private let onFrame: (PCMFrame, AudioProcessingReport) -> Void
	private let recordEmit: (AudioProcessingReport?, String?) -> Void

	init(
		id: String,
		mixerFormat: AudioFormat,
		targetFormat: AudioFormat,
		onFrame: @escaping (PCMFrame, AudioProcessingReport) -> Void,
		recordEmit: @escaping (AudioProcessingReport?, String?) -> Void
	) {
		self.id = id
		self.mixerFormat = mixerFormat
		self.targetFormat = targetFormat
		self.onFrame = onFrame
		self.recordEmit = recordEmit
	}

	@discardableResult
	func receive(_ mixerFrame: PCMFrame) throws -> AudioProcessingReport {
		do {
			let normalized = try MixerPCMNormalizer.normalize(mixerFrame, to: targetFormat, operation: .normalizeSink)
			recordEmit(normalized.report, nil)
			onFrame(normalized.frame, normalized.report)
			return normalized.report
		} catch let failure as AudioProcessingFailure {
			recordEmit(nil, failure.reason)
			throw failure
		} catch {
			recordEmit(nil, String(describing: error))
			throw AudioMixerError.pcmSinkInstallFailed(String(describing: error))
		}
	}
}
