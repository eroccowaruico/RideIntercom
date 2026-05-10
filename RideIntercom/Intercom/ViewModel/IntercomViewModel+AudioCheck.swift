import AudioCore
import Foundation
import SessionManager

extension IntercomViewModel {
    func startAudioCheck(recordDuration: Duration = .seconds(5), playbackDuration: Duration = .seconds(5)) {
        guard audioCheckPhase != .recording, audioCheckPhase != .playing else { return }

        audioCheckTask?.cancel()
        resetAudioCheckMeters()
        audioCheckRecordedSamples = []
        audioCheckPhase = .recording
        audioCheckStatusMessage = "Recording microphone for 5 seconds"
        audioCheckOwnsAudioPipeline = !isAudioReady

        if audioCheckOwnsAudioPipeline {
            guard configureAudioSession(active: true),
                  startInputCapture(),
                  startOutputRenderer() else {
                audioCheckPhase = .failed
                audioCheckStatusMessage = audioErrorMessage ?? "Audio setup failed"
                stopAudioCheckOwnedPipeline()
                return
            }
            applyCurrentVoiceProcessingConfiguration()
        }

        audioCheckTask = Task { [weak self] in
            try? await Task.sleep(for: recordDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishAudioCheckRecording(playbackDuration: playbackDuration)
            }
        }
    }

    func processAudioCheckInput(level: Float, samples: [Float]) {
        guard audioCheckPhase == .recording else { return }

        let clampedLevel = min(1, max(0, level))
        audioCheckInputLevel = clampedLevel
        audioCheckInputPeakLevel = audioCheckInputPeakWindow.record(clampedLevel)
        audioCheckRecordedSamples.append(contentsOf: samples)
    }

    func finishAudioCheckRecording(playbackDuration: Duration) {
        guard audioCheckPhase == .recording else { return }

        let recordedSamples = audioCheckRecordedSamples
        guard !recordedSamples.isEmpty else {
            audioCheckPhase = .failed
            audioCheckStatusMessage = "No microphone samples captured"
            stopAudioCheckOwnedPipeline()
            return
        }

        let outputLevel = AudioLevelMeter.rmsLevel(samples: recordedSamples)
        audioCheckOutputLevel = min(1, max(0, outputLevel))
        audioCheckOutputPeakLevel = audioCheckOutputPeakWindow.record(audioCheckOutputLevel)
        audioCheckPhase = .playing
        audioCheckStatusMessage = "Playing recorded audio for 5 seconds"
        _ = audioOutputRenderer.schedule(PCMFrame(
            sequenceNumber: 1,
            format: .intercomHardwarePreferred,
            capturedAt: Date().timeIntervalSince1970,
            samples: recordedSamples
        ))

        audioCheckTask?.cancel()
        audioCheckTask = Task { [weak self] in
            try? await Task.sleep(for: playbackDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.completeAudioCheckPlayback()
            }
        }
    }

    func completeAudioCheckPlayback() {
        guard audioCheckPhase == .playing else { return }

        audioCheckPhase = .completed
        audioCheckStatusMessage = "Audio check complete"
        audioCheckOutputLevel = 0
        stopAudioCheckOwnedPipeline()
    }

    func stopAudioCheckOwnedPipeline() {
        guard audioCheckOwnsAudioPipeline else { return }

        _ = audioInputCapture.stop()
        _ = audioOutputRenderer.stop()
        _ = try? audioSessionManager.setActive(false)
        audioCheckOwnsAudioPipeline = false
    }

    func resetAudioCheckMeters() {
        audioCheckInputLevel = 0
        audioCheckInputPeakLevel = 0
        audioCheckOutputLevel = 0
        audioCheckOutputPeakLevel = 0
        audioCheckInputPeakWindow = VoicePeakWindow()
        audioCheckOutputPeakWindow = VoicePeakWindow()
    }
}
