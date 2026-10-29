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
	private let captureTimePlayoutDelay: TimeInterval?
	private var playoutAnchor: (capturedAt: TimeInterval, sample: AVAudioFramePosition)?
	private var lastCapturedAt: TimeInterval?
	private var startRequested = false
	private var scheduledEndSample: AVAudioFramePosition = 0
	public private(set) var playbackResetCount = 0

	private var renderedSample: AVAudioFramePosition {
        guard playerNode.isPlaying else { return 0 }
		return playerNode.lastRenderTime.flatMap { time in
			guard time.isSampleTimeValid || time.isHostTimeValid,
			      let played = playerNode.playerTime(forNodeTime: time), played.isSampleTimeValid else { return nil }
			// Realtime playerTime is the last render quantum, not the current
			// device position. Use its host clock so a healthy boundary does not
			// spuriously cross the bounded capture-time playout window.
			let engine = playerNode.engine
			let elapsed = engine?.isInManualRenderingMode == false && engine?.isRunning == true
				&& playerNode.isPlaying && time.isHostTimeValid
				? max(0, ProcessInfo.processInfo.systemUptime - AVAudioTime.seconds(forHostTime: time.hostTime)) : 0
			return max(0, played.sampleTime + AVAudioFramePosition(elapsed * played.sampleRate))
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
		captureTimePlayoutDelay: TimeInterval?,
		recordSchedule: @escaping (PCMFrame, AudioProcessingReport?, String?) -> Void
	) {
		self.id = id
		self.playerNode = playerNode
		self.faderNode = faderNode
		self.mixerFormat = mixerFormat
		self.recordSchedule = recordSchedule
		self.maximumBufferedDuration = maximumBufferedDuration
		self.captureTimePlayoutDelay = captureTimePlayoutDelay
	}

	@discardableResult
	public func schedule(_ frame: PCMFrame) throws -> AudioProcessingReport {
		do {
			let normalized = try MixerPCMNormalizer.normalize(frame, to: mixerFormat, operation: .normalizeSource)
			let buffer = try normalized.frame.makePCMBuffer()
			let rendered = renderedSample
			var options: AVAudioPlayerNodeBufferOptions = []
			let duration = Double(buffer.frameLength) / mixerFormat.sampleRate
			if let limit = maximumBufferedDuration {
				guard limit.isFinite, limit > 0, duration <= limit,
					  limit * mixerFormat.sampleRate < Double(Int64.max) / 4 else {
					throw AudioMixerError.pcmSourceScheduleFailed("Frame exceeds live playback budget")
				}
			}
			let startSample: AVAudioFramePosition
			if let delay = captureTimePlayoutDelay, let limit = maximumBufferedDuration {
				guard frame.capturedAt.isFinite else {
					throw AudioMixerError.pcmSourceScheduleFailed("Invalid capture timestamp")
				}
				let delayedStart = rendered + AVAudioFramePosition((delay * mixerFormat.sampleRate).rounded())
				if playoutAnchor == nil { playoutAnchor = (frame.capturedAt, delayedStart) }
				let anchor = playoutAnchor!
				let target = Double(anchor.sample) + (frame.capturedAt - anchor.capturedAt) * mixerFormat.sampleRate
				// Remote and local clocks have unrelated epochs. Retain only their
				// relative mapping, and rebase after a restart or a discontinuity
				// outside the bounded playout window. Never reserve arbitrary future audio.
				if !target.isFinite || target < Double(rendered) - limit * mixerFormat.sampleRate
					|| target > Double(rendered) + limit * mixerFormat.sampleRate
					|| lastCapturedAt.map({ frame.capturedAt <= $0 }) == true {
					playoutAnchor = (frame.capturedAt, delayedStart)
					startSample = delayedStart
					if scheduledEndSample > rendered { options = .interrupts }
					playbackResetCount += 1
				} else {
					startSample = AVAudioFramePosition(target.rounded())
				}
				lastCapturedAt = frame.capturedAt
			} else {
				// Bound the wait before this frame starts, not its completion.
				// A full capture batch may overlap the previous batch's healthy tail.
				if let limit = maximumBufferedDuration,
				   scheduledEndSample - rendered >= AVAudioFramePosition(limit * mixerFormat.sampleRate) {
					options = .interrupts
					scheduledEndSample = rendered
					playbackResetCount += 1
				}
				startSample = max(scheduledEndSample, rendered)
			}
			scheduledEndSample = startSample + AVAudioFramePosition(buffer.frameLength)
			// Timestamped sources preserve omitted silence and absorb arrival jitter.
			// Consecutive sources follow the actual queue, including after underrun.
			// A last-render snapshot is already in the past when the render thread runs.
			let time = captureTimePlayoutDelay == nil
				? nil : AVAudioTime(sampleTime: startSample, atRate: mixerFormat.sampleRate)
			playerNode.scheduleBuffer(buffer, at: time, options: options)
            if startRequested && !playerNode.isPlaying { playerNode.play() }
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
        startRequested = true
        // A timestamped player starts with its first buffer so sample zero and
        // the capture anchor are established together, even during graph startup.
        guard !playerNode.isPlaying, captureTimePlayoutDelay == nil || playoutAnchor != nil else { return }
		playerNode.play()
	}

	public func stop() {
        startRequested = false
		playerNode.stop()
		scheduledEndSample = 0
		playoutAnchor = nil
		lastCapturedAt = nil
	}
}

public final class MixerPCMSink {
	public let id: String
	public let mixerFormat: AudioFormat
	public let targetFormat: AudioFormat

	private let onFrame: (PCMFrame, AudioProcessingReport) -> Void
	private let recordEmit: (AudioProcessingReport?, String?) -> Void
	private let maximumFrameDuration: TimeInterval?
	private var nextSequenceNumber: UInt64 = 0

	init(
		id: String,
		mixerFormat: AudioFormat,
		targetFormat: AudioFormat,
		maximumFrameDuration: TimeInterval?,
		onFrame: @escaping (PCMFrame, AudioProcessingReport) -> Void,
		recordEmit: @escaping (AudioProcessingReport?, String?) -> Void
	) {
		self.id = id
		self.mixerFormat = mixerFormat
		self.targetFormat = targetFormat
		self.maximumFrameDuration = maximumFrameDuration
		self.onFrame = onFrame
		self.recordEmit = recordEmit
	}

	@discardableResult
	func receive(_ mixerFrame: PCMFrame) throws -> AudioProcessingReport {
		guard let duration = maximumFrameDuration, !mixerFrame.samples.isEmpty else {
			return try emit(mixerFrame)
		}
		_ = try mixerFrame.validated()
		let count = max(1, Int((mixerFrame.format.sampleRate * duration).rounded(.down)))
		var report: AudioProcessingReport?
		for offset in stride(from: 0, to: mixerFrame.frameCount, by: count) {
			let end = min(mixerFrame.frameCount, offset + count)
			let channels = mixerFrame.format.channelCount
			let part = PCMFrame(sequenceNumber: nextSequenceNumber, format: mixerFrame.format,
				capturedAt: mixerFrame.capturedAt + Double(offset) / mixerFrame.format.sampleRate,
				samples: Array(mixerFrame.samples[(offset * channels)..<(end * channels)]))
			nextSequenceNumber &+= 1
			report = try emit(part)
		}
		return report!
	}

	private func emit(_ mixerFrame: PCMFrame) throws -> AudioProcessingReport {
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
