import AVFoundation
import Codec
import CryptoKit
import Foundation
import Logging
import OSLog
import RTC
import SessionManager
import VADGate

extension IntercomViewModel {
    func send(_ packet: OutboundAudioPacket) {
        switch packet {
        case .voice(let frame):
            do {
                try audioPipeline.processCapturedFrame(frame)
            } catch {
                AppLoggers.audio.warning(
                    "audio.pipeline.capture_failed",
                    metadata: .event("audio.pipeline.capture_failed", [
                        "errorType": "\(type(of: error))",
                        "isRecoverable": "true"
                    ])
                )
            }
        case .keepalive:
            callSession.sendControl(.keepalive)
        }
    }

    func broadcastControl(_ message: ControlMessage) {
        callSession.sendControl(message)
    }

    func broadcastMetadataKeepalive() {
        callSession.sendControl(.keepalive)
    }

    func sendStateMetadataSnapshot() {
        broadcastControl(.peerMuteState(isMuted: isMuted))
        broadcastMetadataKeepalive()
    }

    func handleTransportEvent(_ event: TransportEvent) {
        uiEventRevision += 1
        switch event {
        case .localNetworkStatus(let event):
            localNetworkStatus = event.status
            lastLocalNetworkPeerID = event.peerID
            lastLocalNetworkEventAt = event.occurredAt
        case .connected(let peerIDs):
            AppLoggers.rtc.info(
                "rtc.connection.started",
                metadata: .event("rtc.connection.started", [
                    "route": "local",
                    "peerCount": "\(peerIDs.count)"
                ])
            )
            connectedPeerIDs = peerIDs
            addDiscoveredMembersIfNeeded(peerIDs: peerIDs)
            removeDisconnectedAuthenticatedPeers(connectedPeerIDs: peerIDs)
            localNetworkStatus = .connected
            if isLocalStandbyOnly {
                connectionState = .idle
            } else {
                connectionState = .localConnected
            }
            markConnectedMembers(peerIDs: peerIDs)
            publishRuntimePackageReports(force: true)
        case .authenticated(let peerIDs):
            let authenticatedPeerIDSet = Set(peerIDs)
            authenticatedPeerIDs = Array(authenticatedPeerIDSet).sorted()
            connectedPeerIDs = Array(Set(connectedPeerIDs).union(authenticatedPeerIDSet)).sorted()
            addDiscoveredMembersIfNeeded(peerIDs: authenticatedPeerIDs)
            if !isLocalStandbyOnly {
                connectionState = .localConnected
            }
            markConnectedMembers(peerIDs: connectedPeerIDs)
            startActiveCallAfterAuthenticatedPeer()
            sendStateMetadataSnapshot()
            publishRuntimePackageReports(force: true)
        case .remotePeerMuteState(let peerID, let isMuted):
            setRemotePeerMuteState(peerID: peerID, isMuted: isMuted)
        case .remotePeerMetadata(let peerID, let activeCodec):
            if let activeCodec {
                setRemotePeerCodec(peerID, codec: activeCodec)
            }
        case .remoteRuntimeStatus(let peerID, let status):
            remoteRuntimeStatuses[peerID] = status
        case .receivedApplicationData:
            break
        case .disconnected:
            stopAudioPipeline()
            connectedPeerIDs = []
            authenticatedPeerIDs = []
            localNetworkStatus = .idle
            connectionState = .idle
            isVoiceActive = false
            markMembers(.offline)
            publishRuntimePackageReports(force: true)
        case .linkFailed(let internetAvailable):
            _ = internetAvailable
            AppLoggers.rtc.error(
                "rtc.connection.failed",
                metadata: .event("rtc.connection.failed", [
                    "route": "\(routeLabel)",
                    "isRecoverable": "true"
                ])
            )
            stopAudioPipeline()
            connectedPeerIDs = []
            authenticatedPeerIDs = []
            localNetworkStatus = .unavailable
            connectionState = .reconnectingOffline
            markMembers(.connecting)
            publishRuntimePackageReports(force: true)
        case .receivedAudioPacket(let received):
            handleReceivedAudioPacket(received)
        case .routeMetrics(let metrics):
            handleRouteMetrics(metrics)
        }
    }
}
