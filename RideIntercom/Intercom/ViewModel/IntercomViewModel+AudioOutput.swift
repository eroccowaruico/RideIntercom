import AudioCore
import Foundation
import Logging
import SessionManager

extension IntercomViewModel {
    func resetAudioDebugCounters() {
        sentVoicePacketCount = 0
        transmitPacketCounterBaseline = audioPipeline.inputObservation.sentPackets
        lastObservedKeepaliveCount = audioPipeline.inputObservation.keepalives
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
        // With a shared engine this callback observes audio already rendered
        // by the device. Metering must not enqueue another copy for playback.
        if !audioPipeline.rendersToHardware {
            let report = audioOutputRenderer.schedule(frame)
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
            guard case .applied = report.result else { return }
        }
        scheduledOutputBatchCount += 1
        scheduledOutputFrameCount += 1
        playedAudioFrameCount += 1
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
