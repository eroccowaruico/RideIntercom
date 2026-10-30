import AudioCore
import Foundation
import Logging
import RTC

extension IntercomViewModel {
    func handleReceivedAudioPacket(_ received: RTC.ReceivedAudioPacket, reception: AudioPacketReception) {
        let peerID = received.peerID.rawValue
        guard isAudioReady, authenticatedPeerIDs.contains(peerID) else {
            return
        }

        let level: Float
        switch reception {
        case .processed(let measured): level = measured
        case .unavailable: return
        case .failed(let errorType):
            AppLoggers.audio.warning(
                "audio.pipeline.receive_failed",
                metadata: .event("audio.pipeline.receive_failed", [
                    "errorType": "\(errorType)",
                    "isRecoverable": "true"
                ])
            )
            return
        }
        // A remote clock is untrusted and is not comparable with this device's
        // local activity/ducking timers. Arrival time owns local UI activity.
        let receivedAt = Date().timeIntervalSince1970
        receivedVoicePacketCount += 1
        lastReceivedAudioAt = receivedAt
        if level >= 0.0001 { remoteVoiceReceivedAt[peerID] = receivedAt }
        applyReceivedVoiceMemberState(peerID: peerID, voiceLevel: level)
        if !isOutputMuted, masterOutputVolume > 0, remoteOutputVolume(for: peerID) > 0 {
            markPlayedAudioFrame(peerID: peerID)
        }
        setRemotePeerCodec(peerID, codec: received.packet.codec)
        refreshOtherAudioDuckingState(now: receivedAt)
    }

    func handleRouteMetrics(_ metrics: RTC.RouteMetrics) {
        lastRouteMetrics = metrics
        droppedAudioPacketCount = metrics.droppedAudioFrameCount
        jitterQueuedFrameCount = metrics.queuedAudioFrameCount
        receivedVoicePacketCount = max(receivedVoicePacketCount, metrics.receivedAudioFrameCount)
        if metrics.droppedAudioFrameCount > 0 || (metrics.packetLoss ?? 0) > 0.05 {
            AppLoggers.rtc.warning(
                "rtc.route.degraded",
                metadata: .event("rtc.route.degraded", [
                    "route": "\(metrics.route.rawValue)",
                    "packetLoss": "\(metrics.packetLoss ?? 0)",
                    "drop": "\(metrics.droppedAudioFrameCount)"
                ])
            )
        }
    }

    func applyReceivedVoiceMemberState(peerID: String, voiceLevel: Float) {
        let clampedLevel = min(1, max(0, voiceLevel))
        let peakLevel = remoteVoicePeakWindows[peerID, default: VoicePeakWindow()].record(clampedLevel)
        withActiveGroup { group in
            guard let memberIndex = group.members.firstIndex(where: { $0.id == peerID }) else { return }
            group.members[memberIndex].isTalking = remoteVoiceReceivedAt[peerID] != nil
            group.members[memberIndex].voiceLevel = clampedLevel
            group.members[memberIndex].voicePeakLevel = peakLevel
            group.members[memberIndex].receivedAudioPacketCount += 1
            group.members[memberIndex].queuedAudioFrameCount += 1
        }
    }

    func removeDisconnectedAuthenticatedPeers(connectedPeerIDs: [String]) {
        let connectedPeerIDSet = Set(connectedPeerIDs)
        let disconnectedPeerIDs = authenticatedPeerIDs.filter { !connectedPeerIDSet.contains($0) }
        authenticatedPeerIDs.removeAll { !connectedPeerIDSet.contains($0) }
        peerProfiles = peerProfiles.filter { connectedPeerIDSet.contains($0.key) }

        for peerID in disconnectedPeerIDs {
            do { try audioPipeline.stopReceivePeer(peerID) }
            catch { audioErrorMessage = "Could not release the rider's audio. Reconnect to reset audio." }
            remoteVoiceReceivedAt.removeValue(forKey: peerID)
            remoteRuntimeStatuses.removeValue(forKey: peerID)
            setRemotePeer(peerID, isTalking: false)
        }
    }
}
