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

    func handleCallTick(now: TimeInterval) {
        sendPeerProfileChallenges(now: now)
        refreshCallAccess(retryMedia: false)
        expireRemoteTalkers(now: now)
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
        let observation = audioPipeline.inputObservation
        setLocalVoiceLevel(isMuted ? 0 : observation.level)
        setVoiceActive(!isMuted && observation.voiceActive)
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
            receiveMaximumBufferedDuration: 0.12,
            receivePlayoutDelay: 0.002
        )
    }

    @discardableResult
    func rebuildAudioPipeline() -> Bool {
        do {
            try audioPipeline.rebuild(
                configuration: currentAudioPipelineConfiguration(),
                peerIDs: receivePeerIDsForAudioPipeline()
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
