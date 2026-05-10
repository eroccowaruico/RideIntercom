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
        let level = (try? AudioSignalMeter.measure(frame).rms) ?? AudioLevelMeter.rmsLevel(samples: frame.samples)
        processMicrophoneFrame(frame: frame, level: level)
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
            peerOutputVolumes: remoteOutputVolumes
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
            callSession.setAudioPolicy(currentAudioPipelineConfiguration().audioPolicy)
            return
        }
        if rebuildAudioPipeline() {
            callSession.setAudioPolicy(currentAudioPipelineConfiguration().audioPolicy)
            publishRuntimePackageReports(force: true)
        }
    }

    func updateAudioPipelineOutputSettings() {
        audioPipeline.updateOutput(
            masterVolume: masterOutputVolume,
            isMuted: isOutputMuted,
            peerOutputVolumes: remoteOutputVolumes
        )
    }

    func handleTransmitAudioPacket(_ packet: RTC.RTCAudioPacket) {
        sentVoicePacketCount += 1
        callSession.sendAudioPacket(packet)
    }

    func processMicrophoneFrame(level: Float, samples: [Float]) {
        let frameID = nextAudioFrameID
        nextAudioFrameID += 1
        processMicrophoneFrame(
            frame: PCMFrame(
                sequenceNumber: UInt64(max(0, frameID)),
                format: .intercomPacketAudio,
                capturedAt: Date().timeIntervalSince1970,
                samples: samples
            ),
            level: level
        )
    }

    func processMicrophoneFrame(frame: PCMFrame, level: Float) {
        processAudioCheckInput(level: level, samples: frame.samples)

        guard isAudioReady else { return }

        guard !isMuted else {
            setLocalVoiceLevel(0)
            setVoiceActive(false)
            return
        }

        setLocalVoiceLevel(level)
        let packets = audioTransmissionController.process(frame: frame, level: level)
        latestVADAnalysis = audioTransmissionController.lastAnalysis
        vadGateRuntimeSnapshot = audioTransmissionController.runtimeSnapshot
        for packet in packets {
            send(packet)
        }

        setVoiceActive(packets.contains { packet in
            if case .voice = packet {
                return true
            }
            return false
        })
        publishRuntimePackageReports(now: Date().timeIntervalSince1970)
    }

    private func receivePeerIDsForAudioPipeline() -> [String] {
        var peerIDs = Set(authenticatedPeerIDs)
        peerIDs.formUnion(connectedPeerIDs)
        peerIDs.formUnion(remoteOutputVolumes.keys)
        if let selectedGroup {
            peerIDs.formUnion(selectedGroup.members.map(\.id))
        }
        peerIDs.remove(localMemberIdentity.memberID)
        return peerIDs.sorted()
    }
}
