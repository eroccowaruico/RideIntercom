import AudioCore
import Foundation
import SessionManager

extension IntercomViewModel {
    var canStartAudioCheck: Bool {
        !hasAnyActiveGroupConnection && !isAudioReady && audioCheckPhase != .recording && audioCheckPhase != .playing
    }

    func startAudioCheck(recordDuration: Duration = .seconds(5), playbackDuration: Duration = .seconds(5)) {
        guard canStartAudioCheck else { return }

        cancelAudioCheck()
        bindAudioEvents()
        let generation = audioCheckGeneration
        resetAudioCheckMeters()
        audioCheckRecordedFrames = []
        audioCheckPhase = .recording
        audioCheckStatusMessage = "Recording microphone for 5 seconds"
        audioCheckOwnsAudioPipeline = !isAudioReady

        if audioCheckOwnsAudioPipeline {
            guard configureAudioSession(active: true),
                  startInputCapture(),
                  startOutputRenderer(),
                  applyCurrentVoiceProcessingConfiguration() else {
                audioCheckPhase = .failed
                audioCheckStatusMessage = audioErrorMessage ?? "Audio setup failed"
                stopAudioCheckOwnedPipeline()
                return
            }
        }

        audioCheckTask = Task { [weak self] in
            try? await Task.sleep(for: recordDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.audioCheckGeneration == generation else { return }
                self?.finishAudioCheckRecording(playbackDuration: playbackDuration)
            }
        }
    }

    func processAudioCheckInput(level: Float, frame: PCMFrame) {
        guard audioCheckPhase == .recording else { return }

        let clampedLevel = min(1, max(0, level))
        audioCheckInputLevel = clampedLevel
        audioCheckInputPeakLevel = audioCheckInputPeakWindow.record(clampedLevel)
        audioCheckRecordedFrames.append(frame)
    }

    func finishAudioCheckRecording(playbackDuration: Duration) {
        guard audioCheckPhase == .recording else { return }

        let recordedFrames = audioCheckRecordedFrames
        audioCheckRecordedFrames.removeAll()
        guard !recordedFrames.isEmpty else {
            audioCheckPhase = .failed
            audioCheckStatusMessage = "No microphone samples captured"
            stopAudioCheckOwnedPipeline()
            return
        }

        let outputLevel = AudioLevelMeter.rmsLevel(samples: recordedFrames.flatMap(\.samples))
        audioCheckOutputLevel = min(1, max(0, outputLevel))
        audioCheckOutputPeakLevel = audioCheckOutputPeakWindow.record(audioCheckOutputLevel)
        audioCheckPhase = .playing
        audioCheckStatusMessage = "Playing recorded audio for 5 seconds"
        do {
            try audioPipeline.rebuild(configuration: AppAudioPipelineConfiguration(
                outputHardwareFormat: lastOutputStreamOperationReport?.snapshot.actualHardwareFormat ?? .intercomHardwarePreferred,
                transmitSoundIsolationEnabled: false
            ), peerIDs: ["audio-check"])
            for frame in recordedFrames { try audioPipeline.processPlaybackFrame(frame) }
        } catch {
            audioCheckPhase = .failed
            audioCheckStatusMessage = "Audio playback failed"
            stopAudioCheckOwnedPipeline()
            return
        }
        let generation = audioCheckGeneration

        audioCheckTask?.cancel()
        audioCheckTask = Task { [weak self] in
            try? await Task.sleep(for: playbackDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.audioCheckGeneration == generation else { return }
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

    func cancelAudioCheck() {
        audioCheckGeneration = UUID()
        audioCheckTask?.cancel()
        audioCheckTask = nil
        stopAudioCheckOwnedPipeline()
        audioCheckRecordedFrames.removeAll()
        audioCheckPhase = .idle
        audioCheckStatusMessage = "Audio check idle"
        resetAudioCheckMeters()
    }

    func stopAudioCheckOwnedPipeline() {
        guard audioCheckOwnsAudioPipeline else { return }

        audioGeneration = UUID()
        audioPipeline.stop()
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
