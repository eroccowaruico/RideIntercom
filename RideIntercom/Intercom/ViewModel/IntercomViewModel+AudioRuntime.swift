import AudioCore
import Foundation
import Logging
import RTC
import SessionManager

extension IntercomViewModel {
    func expireRemoteTalkers(now: TimeInterval = Date().timeIntervalSince1970) {
        for (peerID, lastVoiceAt) in remoteVoiceReceivedAt where now - lastVoiceAt >= remoteTalkerTimeout {
            setRemotePeer(peerID, isTalking: false)
            remoteVoiceReceivedAt.removeValue(forKey: peerID)
        }
    }

    func clearLocalInputObservation() {
        localInputObservedAt = nil
        localVoicePeakWindow = VoicePeakWindow()
        setLocalVoiceLevel(0)
        setVoiceActive(false)
    }

    private func expireLocalInputObservation(now: TimeInterval) {
        guard let last = localInputObservedAt, now - last >= remoteTalkerTimeout else { return }
        clearLocalInputObservation()
    }

    func handleCallTick(now: TimeInterval) {
        guard !disconnectIfTimerExpired(now: now) else { return }
        sendPeerProfileChallenges(now: now)
        refreshCallAccess(retryMedia: false)
        expireRemoteTalkers(now: now)
        expireLocalInputObservation(now: now)
        refreshOtherAudioDuckingState(now: now)
        publishRuntimePackageReports(now: now)
    }

    func handleAudioStreamRuntimeEvent(_ event: SessionManager.AudioStreamRuntimeEvent) {
        switch event {
        case .inputFrame(let frame):
            handleMicrophoneFrame(frame)
        case .operation(let report):
            recordAudioStreamReport(report)
        case .outputFrameScheduled(_):
            break
        }
    }

    func recordAudioStreamReport(_ report: SessionManager.AudioStreamOperationReport) {
        switch report.snapshot.direction {
        case .input:
            if case .updateInputVoiceProcessing = report.operation {
                lastVoiceProcessingOperationReport = report
            } else {
                lastInputStreamOperationReport = report
            }
        case .output:
            lastOutputStreamOperationReport = report
        }
        publishRuntimePackageReports(force: true)
    }

    func handleMicrophoneFrame(_ frame: PCMFrame) {
        if audioCheckPhase == .recording {
            let rawLevel = (try? AudioSignalMeter.measure(frame).rms) ?? 0
            processAudioCheckInput(level: rawLevel, frame: frame)
        }
        guard isAudioReady else { return }
        // This is local observation time, never the remote capture clock.
        localInputObservedAt = callAccessNow().timeIntervalSince1970
        let observation = audioPipeline.inputObservation
        setLocalVoiceLevel(effectiveInputMuted ? 0 : observation.level)
        setVoiceActive(!effectiveInputMuted && observation.voiceActive)
        sentVoicePacketCount = max(0, observation.sentPackets - transmitPacketCounterBaseline)
        vadGateRuntimeSnapshot = audioPipeline.vadRuntimeSnapshot
        if let failure = observation.failure {
            AppLoggers.audio.warning("audio.pipeline.capture_failed",
                metadata: .event("audio.pipeline.capture_failed", ["errorType": "\(failure)", "isRecoverable": "true"]))
        }
        publishRuntimePackageReports(now: Date().timeIntervalSince1970)
    }

    func currentAudioPipelineConfiguration() -> AppAudioPipelineConfiguration {
        AppAudioPipelineConfiguration(
            rtcSendFormat: rtcAudioFormatPreset.audioFormat,
            outputHardwareFormat: lastOutputStreamOperationReport?.snapshot.actualHardwareFormat ?? .intercomHardwarePreferred,
            preferredCodec: preferredTransmitCodec,
            aacELDv2BitRate: aacELDv2BitRate,
            opusBitRate: opusBitRate,
            masterOutputVolume: masterOutputVolume,
            isOutputMuted: isOutputMuted,
            peerOutputVolumes: remoteOutputVolumes,
            transmitSoundIsolationEnabled: isSoundIsolationEnabled,
            receiveMasterSoundIsolationEnabled: receiveMasterSoundIsolationEnabled,
            peerSoundIsolationEnabled: remoteSoundIsolationEnabled,
            maximumBufferedDuration: 0.2,
            receiveMaximumBufferedDuration: AppAudioPipelineConfiguration.callReceiveMaximumBufferedDuration,
            receivePlayoutDelay: AppAudioPipelineConfiguration.callReceivePlayoutDelay
        )
    }

    @discardableResult
    func rebuildAudioPipeline(startsOutputClock: Bool = true) -> Bool {
        do {
            audioPipeline.setHardwareOutputEnabled(audioOutputRenderer.rendersToHardware)
            try audioPipeline.rebuild(
                configuration: currentAudioPipelineConfiguration(),
                peerIDs: receivePeerIDsForAudioPipeline(),
                startsOutputClock: startsOutputClock
            )
            return true
        } catch {
            audioErrorMessage = "Audio pipeline failed"
            AppLoggers.audio.warning(
                "audio.pipeline.rebuild_failed",
                metadata: .event("audio.pipeline.rebuild_failed", [
                    "errorType": "\(type(of: error))",
                    "isRecoverable": "true"
                ])
            )
            return false
        }
    }

    func rebuildAudioPipelineIfRunning() {
        guard isAudioReady else {
            callSession.setAudioPolicy(currentCallAudioPolicy())
            return
        }
        if rebuildAudioPipeline() {
            callSession.setAudioPolicy(currentCallAudioPolicy())
            publishRuntimePackageReports(force: true)
        } else {
            stopAudioPipeline()
        }
    }

    func updateAudioPipelineCodecSettings() {
        do {
            if isAudioReady {
                try audioPipeline.updateEncoding(preferred: preferredTransmitCodec,
                    format: rtcAudioFormatPreset.audioFormat,
                    aacELDv2BitRate: aacELDv2BitRate, opusBitRate: opusBitRate)
            }
            callSession.setAudioPolicy(currentCallAudioPolicy())
        } catch {
            audioErrorMessage = "Audio encoding change failed"
        }
    }

    func updateAudioPipelineOutputSettings() {
        audioPipeline.updateOutput(
            masterVolume: masterOutputVolume,
            isMuted: isOutputMuted,
            peerOutputVolumes: remoteOutputVolumes
        )
    }

    func updateAudioPipelineEffectSettings() {
        do {
            try audioPipeline.updateSoundIsolation(transmit: isSoundIsolationEnabled,
                receiveMaster: receiveMasterSoundIsolationEnabled, peers: remoteSoundIsolationEnabled)
        } catch {
            audioErrorMessage = "Audio effect configuration failed"
            stopAudioPipeline()
        }
        publishRuntimePackageReports(force: true)
    }

    private func receivePeerIDsForAudioPipeline() -> [String] {
        var peerIDs = Set(authenticatedPeerIDs)
        peerIDs.formUnion(connectedPeerIDs)
        peerIDs.remove(localMemberIdentity.memberID)
        return peerIDs.sorted()
    }
}
