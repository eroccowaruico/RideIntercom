import AudioCore
import AudioDevice
import Foundation
import SessionManager

extension IntercomViewModel {
    var canStartAudioCheck: Bool {
        canStartCalls && !hasAnyActiveGroupConnection && !isAudioReady && audioStartTask == nil && !audioCheckPhase.isInProgress
    }

    func startAudioCheck(recordDuration: Duration = .seconds(5), playbackDuration: Duration = .seconds(5)) {
        guard canStartAudioCheck else { return }

        cancelAudioCheck()
        bindAudioEvents(deliverEveryFrame: true)
        let generation = audioCheckGeneration, audio = audioGeneration
        resetAudioCheckMeters()
        audioCheckRecordedFrames = []
        audioCheckPhase = .preparing
        audioCheckStatusMessage = "Preparing microphone and speaker"
        audioCheckOwnsAudioPipeline = true
        guard configureAudioSession() else {
            audioCheckPhase = .failed
            audioCheckStatusMessage = audioErrorMessage ?? "Audio setup failed"
            stopAudioCheckOwnedPipeline()
            return
        }
        let activation = audioSessionManager.requestActive(true)
        audioCheckTask = Task { [weak self] in
            let report = await activation.value
            guard let self, !Task.isCancelled, self.audioCheckGeneration == generation,
                  self.audioGeneration == audio, self.canStartCalls,
                  !self.hasAnyActiveGroupConnection, self.audioCheckPhase == .preparing else { return }
            guard report.result != .ignored(.superseded) else { self.cancelAudioCheck(); return }
            guard self.applyAudioSessionActivationReport(report), self.startInputCapture(),
                  self.startOutputRenderer(), self.applyCurrentVoiceProcessingConfiguration() else {
                self.audioCheckPhase = .failed
                self.audioCheckStatusMessage = self.audioErrorMessage ?? "Audio setup failed"
                self.stopAudioCheckOwnedPipeline()
                return
            }
            self.audioCheckPhase = .recording
            self.audioCheckStatusMessage = "Recording microphone for 5 seconds"
            self.inputFrameDelivery?.activate()
            try? await Task.sleep(for: recordDuration)
            guard !Task.isCancelled, self.audioCheckGeneration == generation else { return }
            self.finishAudioCheckRecording(playbackDuration: playbackDuration)
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
        inputFrameDelivery?.finish()
        inputFrameDelivery = nil
        audioPipeline.stop()
        _ = audioInputCapture.stop()
        _ = audioOutputRenderer.stop()
        _ = audioSessionManager.requestActive(false)
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
