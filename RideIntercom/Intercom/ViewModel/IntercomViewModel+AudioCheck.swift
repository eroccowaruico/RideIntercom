import AudioCore
import AudioDevice
import AVFAudio
import Foundation
import SessionManager

extension IntercomViewModel {
    var canPrepareAudioCheck: Bool {
        canStartCalls && !hasAnyActiveGroupConnection && !isAudioReady && audioStartTask == nil
    }
    var canStartAudioCheck: Bool {
        canPrepareAudioCheck && !audioCheckPhase.isInProgress && !isUsingWatchAudio
            && audioInputCapture === nativeAudioInputCapture && audioOutputRenderer === nativeAudioOutputRenderer
    }

    @discardableResult
    func startAudioCheck(recordDuration: Duration = .seconds(5), playbackDuration: Duration = .seconds(5), watchSessionID: UUID? = nil) -> Bool {
        let preparedWatch = watchSessionID != nil && watchSessionID == audioCheckWatchSessionID
            && audioCheckPhase == .preparing && watchAudioLink?.sessionID == watchSessionID
        guard canPrepareAudioCheck, (watchSessionID == nil ? canStartAudioCheck : preparedWatch) else { return false }

        if !preparedWatch { cancelAudioCheck() }
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
        if watchSessionID == nil && ProcessInfo.processInfo.environment["RIDEINTERCOM_LOCAL_TESTING"] == "1" {
            audioCheckObservation = AudioCheckValidationObservation(generation: audioCheckGeneration)
        }
        #endif
        audioCheckWatchSessionID = watchSessionID
        audioCheckRecordDuration = recordDuration
        audioCheckPlaybackDuration = playbackDuration
        audioCheckRecordedFrameCount = 0; audioCheckRecordedNonzeroSamples = 0
        audioCheckRecording = AudioCheckRecording(format: rtcAudioFormatPreset.audioFormat)
        bindAudioEvents(finiteRecordingDuration: 5)
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
            return false
        }
        let activation = audioSessionManager.requestActive(true)
        audioCheckTask = Task { [weak self] in
            let report = await activation.value
            guard let self, !Task.isCancelled, self.audioCheckGeneration == generation else { return }
            guard self.audioGeneration == audio, self.canPrepareAudioCheck, self.audioCheckPhase == .preparing else {
                self.cancelAudioCheck(); return
            }
            guard report.result != .ignored(.superseded) else { self.cancelAudioCheck(); return }
            guard self.applyAudioSessionActivationReport(report), self.prepareAudioCheckPipeline(),
                  self.applyCurrentVoiceProcessingConfiguration(), self.startInputCapture(), self.startPreparedAudioOutput() else {
                self.audioCheckPhase = .failed
                self.audioCheckStatusMessage = self.audioErrorMessage ?? "Audio setup failed"
                self.stopAudioCheckOwnedPipeline()
                return
            }
            // Native stream setup may resolve the selected Auto route after
            // activation. Freeze the actual route before accepting samples.
            if let actual = try? self.audioSessionManager.snapshot() { self.applyAudioSessionSnapshot(actual) }
            self.audioCheckPhase = .recording
            self.audioCheckStatusMessage = watchSessionID == nil ? "Recording microphone for 5 seconds" : "Recording Watch microphone for 5 seconds"
            self.inputFrameDelivery?.activate()
            // Count captured samples rather than completing a short recording when
            // activation or delivery takes part of the wall-clock interval.
            try? await Task.sleep(for: recordDuration + .seconds(1))
            guard !Task.isCancelled, self.audioCheckGeneration == generation else { return }
            guard self.audioCheckPhase == .recording else { return }
            self.audioCheckPhase = .failed
            self.audioCheckStatusMessage = "Incomplete microphone recording"
            self.stopAudioCheckOwnedPipeline()
        }
        return true
    }

    func processAudioCheckInput(level: Float, frame: PCMFrame) {
        guard audioCheckPhase == .recording, frame.frameCount > 0,
              (try? frame.validated()) != nil else { return }

        if audioCheckRecordedFrameCount == 0 {
            audioCheckTask?.cancel()
            let generation = audioCheckGeneration
            let timeout = audioCheckRecordDuration + .seconds(1)
            audioCheckTask = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, !Task.isCancelled, self.audioCheckGeneration == generation,
                      self.audioCheckPhase == .recording else { return }
                self.audioCheckPhase = .failed
                self.audioCheckStatusMessage = "Incomplete microphone recording"
                self.stopAudioCheckOwnedPipeline()
            }
        }
        let clampedLevel = min(1, max(0, level))
        audioCheckInputLevel = clampedLevel
        audioCheckInputPeakLevel = audioCheckInputPeakWindow.record(clampedLevel)
        audioCheckRecordedFrames.append(frame)
        audioCheckRecordedFrameCount += frame.frameCount
        if audioCheckRecordedFrameCount == Int(frame.format.sampleRate * 5) {
            finishAudioCheckRecording(playbackDuration: audioCheckPlaybackDuration)
        }
    }

    func finishAudioCheckRecording(playbackDuration: Duration) {
        guard audioCheckPhase == .recording else { return }

        inputFrameDelivery?.finish()
        let recordedFrames: [PCMFrame]
        do {
            try audioPipeline.finishMicrophone()
            guard audioPipeline.transmitEncodingFailureCount == audioCheckTransmitFailureBaseline else {
                throw AppAudioPipelineError.transmitFailed
            }
            recordedFrames = try audioCheckRecording?.recordedFrames() ?? []
        } catch {
            audioCheckPhase = .failed
            audioCheckStatusMessage = "Audio recording processing failed"
            stopAudioCheckOwnedPipeline()
            return
        }
        audioCheckRecordedFrames = recordedFrames
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
        audioCheckObservation?.setInput(recordedFrames)
        #endif
        audioCheckRecordedFrameCount = recordedFrames.reduce(0) { $0 + $1.frameCount }
        audioCheckRecordedNonzeroSamples = recordedFrames.reduce(0) { $0 + $1.samples.filter { abs($0) > 0.00001 }.count }
        guard !recordedFrames.isEmpty else {
            audioCheckPhase = .failed
            audioCheckStatusMessage = "No microphone samples captured"
            stopAudioCheckOwnedPipeline()
            return
        }

        if audioCheckWatchSessionID != nil {
            // Reuse preparing for the control handoff: nonzero recordedFrames
            // distinguishes recorded audio from initial device preparation.
            audioCheckPhase = .preparing
            audioCheckStatusMessage = "Waiting for Watch playback"
            let generation = audioCheckGeneration
            audioCheckTask?.cancel()
            audioCheckTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, audioCheckGeneration == generation, audioCheckPhase == .preparing else { return }
                audioCheckPhase = .failed; audioCheckStatusMessage = "Watch playback did not start"
                stopAudioCheckOwnedPipeline()
            }
            return
        }
        beginAudioCheckPlayback(recordedFrames, playbackDuration: playbackDuration)
    }

    @discardableResult
    func playWatchAudioCheck(sessionID: UUID) -> Bool {
        guard audioCheckWatchSessionID == sessionID, watchAudioLink?.sessionID == sessionID,
              audioCheckPhase == .preparing, !audioCheckRecordedFrames.isEmpty,
              canPrepareAudioCheck else { return false }
        beginAudioCheckPlayback(audioCheckRecordedFrames, playbackDuration: .seconds(5))
        return audioCheckPhase == .playing
    }

    private func beginAudioCheckPlayback(_ recordedFrames: [PCMFrame], playbackDuration: Duration) {
        audioCheckRecordedFrames.removeAll()
        let outputLevel = AudioLevelMeter.rmsLevel(samples: recordedFrames.flatMap(\.samples))
        audioCheckOutputLevel = min(1, max(0, outputLevel))
        audioCheckOutputPeakLevel = audioCheckOutputPeakWindow.record(audioCheckOutputLevel)
        audioCheckPhase = .playing
        audioCheckStatusMessage = audioCheckWatchSessionID == nil ? "Playing recorded audio for 5 seconds" : "Playing recorded audio on Watch"
        do {
            audioPipeline.setHardwareOutputEnabled(audioCheckWatchSessionID == nil)
            watchAudioLink?.setSendingAllowed(audioCheckWatchSessionID != nil)
            audioPipeline.beginFinitePlayback()
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

    private func prepareAudioCheckPipeline() -> Bool {
        do {
            var configuration = currentAudioPipelineConfiguration()
            configuration.receiveMasterSoundIsolationEnabled = false
            configuration.peerSoundIsolationEnabled = [:]
            configuration.receiveMaximumBufferedDuration = 5
            configuration.finitePlaybackDuration = 6
            audioPipeline.setHardwareOutputEnabled(audioOutputRenderer.rendersToHardware)
            try audioPipeline.rebuild(configuration: configuration, peerIDs: ["audio-check"], startsOutputClock: false)
            audioCheckTransmitFailureBaseline = audioPipeline.transmitEncodingFailureCount
            audioCheckRecording?.setProcessingLatency(audioPipeline.transmitProcessingLatency)
            return true
        } catch { return false }
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
        audioCheckWatchSessionID = nil
        audioCheckPhase = .idle
        audioCheckStatusMessage = "Audio check idle"
        resetAudioCheckMeters()
    }

    func stopAudioCheckOwnedPipeline() {
        guard audioCheckOwnsAudioPipeline else { return }

        audioGeneration = UUID()
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
        let observationInputDrops = inputFrameDelivery?.droppedFrameCount ?? 0
        #endif
        inputFrameDelivery?.finish()
        inputFrameDelivery = nil
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
        let observationDrops = audioPipeline.droppedRenderFrameCount
        #endif
        audioPipeline.stop()
        audioPipeline.onTransmitPacket = callSession.audioPacketSink
        audioCheckRecording = nil
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
        let inputStop = audioInputCapture.stop()
        let outputStop = audioOutputRenderer.stop()
        #else
        _ = audioInputCapture.stop()
        _ = audioOutputRenderer.stop()
        #endif
        _ = audioSessionManager.requestActive(false)
        audioCheckOwnsAudioPipeline = false
        if audioCheckWatchSessionID != nil, isUsingWatchAudio {
            stopWatchAudioLink()
            audioInputCapture = nativeAudioInputCapture
            audioOutputRenderer = nativeAudioOutputRenderer
            isUsingWatchAudio = false
            audioPipeline.setHardwareOutputEnabled(true)
            applyEffectiveInputMute()
        }
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
        if let observation = audioCheckObservation {
            let phase = audioCheckPhase.isInProgress ? "Cancelled" : audioCheckPhase.rawValue
            let record = observation.record(phase: phase, drops: observationDrops, inputDrops: observationInputDrops,
                inputStopped: !inputStop.snapshot.isRunning, outputStopped: !outputStop.snapshot.isRunning,
                nativeBackends: audioInputCapture === nativeAudioInputCapture && audioOutputRenderer === nativeAudioOutputRenderer,
                watchRoute: isUsingWatchAudio, engineRunning: audioOutputRenderer.renderingEngine?.isRunning)
            audioCheckObservationRecords.append(record)
            if let data = try? JSONSerialization.data(withJSONObject: audioCheckObservationRecords, options: [.sortedKeys]) {
                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("phone-audio-check-observation.json"), options: .atomic)
            }
            audioCheckObservation = nil
        }
        #endif
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

#if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
/// Ephemeral measurement only: PCM never leaves memory or enters the evidence file.
struct AudioCheckValidationObservation {
    let generation: UUID
    private var input: [Float] = []
    private var output: [Float] = []
    private var rate: Double = 0
    private var channels: Int = 0
    private var incompatible = false
    private var overflow = false
    private var firstOutputAt: Double?
    private var lastOutputAt: Double?
    private var lastOutputEnd: Double?
    private var timestampGapCount = 0
    private var inputTimestampGapCount = 0

    mutating func setInput(_ frames: [PCMFrame]) {
        guard let first = frames.first else { return }
        rate = first.format.sampleRate
        channels = first.format.channelCount
        var previousEnd: Double?
        for frame in frames {
            if frame.format.sampleRate != rate || frame.format.channelCount != channels { incompatible = true }
            if let end = previousEnd, abs(frame.capturedAt - end) > 2 / rate { inputTimestampGapCount += 1 }
            previousEnd = frame.capturedAt + Double(frame.frameCount) / rate
            let remaining = max(0, Int(rate * 6) * channels - input.count)
            if frame.samples.count > remaining { overflow = true }
            input.append(contentsOf: frame.samples.prefix(remaining))
        }
    }

    mutating func appendOutput(_ frame: PCMFrame) {
        guard rate > 0, channels > 0 else { return }
        guard frame.format.sampleRate == rate, frame.format.channelCount > 0, channels == 1 else { incompatible = true; return }
        // Hardware output can be stereo after route negotiation or restart.
        // Compare its mono fold-down with the recorded mono input.
        let samples: [Float]
        if frame.format.channelCount == 1 { samples = frame.samples }
        else {
            samples = (0..<frame.frameCount).map { index in
                let start = index * frame.format.channelCount
                return frame.samples[start..<(start + frame.format.channelCount)].reduce(0, +) / Float(frame.format.channelCount)
            }
        }
        if let end = lastOutputEnd, abs(frame.capturedAt - end) > 2 / rate { timestampGapCount += 1 }
        if firstOutputAt == nil { firstOutputAt = frame.capturedAt }
        lastOutputAt = frame.capturedAt
        lastOutputEnd = frame.capturedAt + Double(frame.frameCount) / rate
        let remaining = max(0, Int(rate * 6) * channels - output.count)
        if samples.count > remaining { overflow = true }
        output.append(contentsOf: samples.prefix(remaining))
    }

    func record(phase: String, drops: Int, inputDrops: Int, inputStopped: Bool, outputStopped: Bool,
                nativeBackends: Bool, watchRoute: Bool, engineRunning: Bool?) -> [String: Any] {
        let inputFrames = channels > 0 ? input.count / channels : 0
        let outputFrames = channels > 0 ? output.count / channels : 0
        var result: [String: Any] = ["generation": generation.uuidString, "phase": phase, "recordedAt": Date().timeIntervalSince1970,
            "sampleRate": rate, "channels": channels, "inputFrames": inputFrames,
            "outputFrames": outputFrames, "inputNonzero": input.filter { abs($0) > 0.00001 }.count,
            "outputNonzero": output.filter { abs($0) > 0.00001 }.count,
            "inputDuration": rate > 0 ? Double(inputFrames) / rate : 0,
            "outputDuration": rate > 0 ? Double(outputFrames) / rate : 0,
            "outputFirstAt": firstOutputAt.map { $0 as Any } ?? NSNull(), "outputLastAt": lastOutputAt.map { $0 as Any } ?? NSNull(),
            "outputEndAt": lastOutputEnd.map { $0 as Any } ?? NSNull(), "timestampGapCount": timestampGapCount,
            "droppedRenderFramesCombined": drops, "inputDroppedFrames": inputDrops,
            "inputTimestampGapCount": inputTimestampGapCount, "overflow": overflow,
            "inputStopped": inputStopped, "outputStopped": outputStopped,
            "nativeBackends": nativeBackends, "watchRoute": watchRoute, "engineRunning": engineRunning as Any? ?? NSNull(),
            "comparison": "unidentifiable"]
        guard !incompatible, rate > 0, channels == 1 else { result["comparison"] = "unsupportedFormat"; return result }
        let window = Int(rate * 0.2), full = Int(rate * 5)
        guard window > 0, input.count >= full, output.count >= window else { return result }
        func correlation(_ inputStart: Int, _ outputStart: Int, sampleStride: Int = 1) -> Double? {
            guard inputStart >= 0, outputStart >= 0, inputStart + window <= input.count, outputStart + window <= output.count else { return nil }
            var dot = 0.0, x2 = 0.0, y2 = 0.0
            for i in stride(from: 0, to: window, by: sampleStride) { let x = Double(input[inputStart+i]), y = Double(output[outputStart+i]); dot += x*y; x2 += x*x; y2 += y*y }
            guard x2 > 1e-10, y2 > 1e-10 else { return nil }
            return dot / sqrt(x2*y2)
        }
        // VAD can leave any fixed window silent. Align on the strongest
        // recorded window, retaining unidentifiable for an all-silent input.
        var anchor = 0, anchorEnergy = 0.0
        for start in stride(from: 0, through: full - window, by: max(1, window / 2)) {
            let energy = stride(from: start, to: start + window, by: 16).reduce(0.0) {
                $0 + Double(input[$1]) * Double(input[$1])
            }
            if energy > anchorEnergy { anchor = start; anchorEnergy = energy }
        }
        guard anchorEnergy > 1e-10 else { return result }
        let maxLag = min(Int(rate * 0.25), output.count - window)
        var bestLag = 0, best = -Double.infinity
        for lag in 0...maxLag {
            if let score = correlation(anchor, anchor + lag, sampleStride: 16), score > best { best = score; bestLag = lag }
        }
        guard best.isFinite else { return result }
        let lower = max(0, bestLag - 16), upper = min(maxLag, bestLag + 16)
        best = -Double.infinity
        for lag in lower...upper {
            if let score = correlation(anchor, anchor + lag), score > best { best = score; bestLag = lag }
        }
        result["lagSeconds"] = Double(bestLag) / rate
        result["fullCoverage"] = bestLag + full <= output.count
        let offsets = [0, full / 2 - window / 2, full - window]
        let scores = offsets.map { correlation($0, bestLag + $0) }
        result["windowCorrelations"] = scores.map { $0 as Any? ?? NSNull() }
        guard bestLag + full <= output.count else { return result }
        var dot = 0.0, x2 = 0.0, y2 = 0.0
        for index in 0..<full {
            let x = Double(input[index]), y = Double(output[bestLag + index])
            dot += x * y; x2 += x * x; y2 += y * y
        }
        guard x2 > 1e-10, y2 > 1e-10 else { return result }
        let gain = dot / x2
        var residual = 0.0, silentResidual = 0.0, silentCount = 0
        for index in 0..<full {
            let error = Double(output[bestLag + index]) - gain * Double(input[index])
            residual += error * error
            if abs(input[index]) <= 0.00001 { silentResidual += error * error; silentCount += 1 }
        }
        result["fullSignalCorrelation"] = min(1, max(-1, dot / sqrt(x2 * y2)))
        result["fullSignalNormalizedRMSError"] = sqrt(residual / y2)
        result["silentComparedSampleCount"] = silentCount
        result["silentResidualRMS"] = silentCount > 0 ? sqrt(silentResidual / Double(silentCount)) : 0
        result["comparison"] = "measured"
        return result
    }
}
#endif
