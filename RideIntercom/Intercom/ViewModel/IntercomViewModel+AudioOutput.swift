import AudioCore
import Foundation
import Logging
import SessionManager

extension IntercomViewModel {
    func resetAudioDebugCounters() {
        sentVoicePacketCount = 0
        receivedVoicePacketCount = 0
        playedAudioFrameCount = 0
        lastScheduledOutputRMS = 0
        lastScheduledOutputPeakRMS = 0
        scheduledOutputBatchCount = 0
        scheduledOutputFrameCount = 0
        lastReceivedAudioAt = nil
        lastAudibleReceivedAudioAt = nil
        droppedAudioPacketCount = 0
        jitterQueuedFrameCount = 0
        playbackOutputPeakWindow = VoicePeakWindow()
    }

    func refreshOtherAudioDuckingState(now: TimeInterval = Date().timeIntervalSince1970) {
        setOtherAudioDuckingActive(shouldApplyOtherAudioDucking(now: now))
    }

    func shouldApplyOtherAudioDucking(now: TimeInterval) -> Bool {
        guard isDuckOthersEnabled,
              isAudioReady,
              audioCheckPhase == .idle,
              !isOutputMuted,
              masterOutputVolume > 0 else { return false }
        return hasRecentReceivedAudio(now: now)
    }

    func hasRecentReceivedAudio(now: TimeInterval) -> Bool {
        guard let lastAudibleReceivedAudioAt else { return false }
        return now - lastAudibleReceivedAudioAt <= Self.otherAudioDuckingHoldDuration
    }

    func setOtherAudioDuckingActive(_ isActive: Bool) {
        guard isOtherAudioDuckingActiveInternal != isActive else { return }
        isOtherAudioDuckingActiveInternal = isActive
        applyCurrentVoiceProcessingConfiguration()
    }

    func scheduleOutputFrame(frame: PCMFrame, receivedAt: TimeInterval) {
        guard !isOutputMuted, masterOutputVolume > 0 else {
            lastScheduledOutputRMS = 0
            lastScheduledOutputPeakRMS = playbackOutputPeakWindow.record(0)
            return
        }

        let level = AudioLevelMeter.rmsLevel(samples: frame.samples)
        lastScheduledOutputRMS = level
        lastScheduledOutputPeakRMS = playbackOutputPeakWindow.record(level)
        scheduledOutputBatchCount += 1
        scheduledOutputFrameCount += 1
        playedAudioFrameCount += 1
        let report = audioOutputRenderer.schedule(PCMFrame(
            sequenceNumber: frame.sequenceNumber,
            format: frame.format,
            capturedAt: receivedAt,
            samples: frame.samples
        ))
        lastOutputStreamOperationReport = report
        if !report.result.isContinuable {
            audioErrorMessage = "Audio output failed"
            AppLoggers.audio.warning(
                "audio.output.schedule_failed",
                metadata: .event("audio.output.schedule_failed", [
                    "errorType": "\(report.result)",
                    "isRecoverable": "true"
                ])
            )
        }
        if level > Self.audibleOutputLevelThreshold {
            lastAudibleReceivedAudioAt = receivedAt
        }
    }
}

private extension SessionManager.AudioStreamOperationResult {
    var isContinuable: Bool {
        switch self {
        case .applied, .ignored(_):
            true
        case .failed(_):
            false
        }
    }
}
