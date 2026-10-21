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
        switch event {
        case .routesChanged(let snapshot):
            availableCallRoutes = snapshot.availableRoutes
            if !authenticatedPeerIDs.isEmpty {
                connectionState = isInternetOnlyCall ? .internetConnected : .localConnected
            } else if connectionState == .localConnecting || connectionState == .internetConnecting {
                connectionState = isInternetOnlyCall ? .internetConnecting : .localConnecting
            }
            if snapshot.availableRoutes.contains(.webRTC) {
                connectivityNotice = nil
                internetFailureDetail = nil
            }
        case .commandQueueFailed:
            disconnect()
            groupErrorMessage = "Too many pending operations. The call stopped; connect again to retry."
        case .serviceError(let reason):
            internetFailureDetail = reason
            connectivityNotice = "Internet is unavailable. Retrying automatically; reachable riders stay connected."
        case .localNetworkStatus(let event):
            localNetworkStatus = event.status
            lastLocalNetworkPeerID = event.peerID
            lastLocalNetworkEventAt = event.occurredAt
        case .connected(let peerIDs):
            AppLoggers.rtc.info(
                "rtc.connection.started",
                metadata: .event("rtc.connection.started", [
                    "route": "\(routeLabel)",
                    "peerCount": "\(peerIDs.count)"
                ])
            )
            connectedPeerIDs = peerIDs
            addDiscoveredMembersIfNeeded(peerIDs: peerIDs)
            removeDisconnectedAuthenticatedPeers(connectedPeerIDs: peerIDs)
            if authenticatedPeerIDs.isEmpty, isAudioReady { stopAudioPipeline() }
            localNetworkStatus = peerIDs.isEmpty ? .advertisingBrowsing : .connected
            connectionState = isInternetOnlyCall
                ? (peerIDs.isEmpty ? .internetConnecting : .internetConnected)
                : (peerIDs.isEmpty ? .localConnecting : .localConnected)
            markConnectedMembers(peerIDs: peerIDs)
            publishRuntimePackageReports(force: true)
        case .authenticated(let peerIDs):
            let authenticatedPeerIDSet = Set(peerIDs)
            authenticatedPeerIDs = Array(authenticatedPeerIDSet).sorted()
            connectedPeerIDs = Array(Set(connectedPeerIDs).union(authenticatedPeerIDSet)).sorted()
            addDiscoveredMembersIfNeeded(peerIDs: authenticatedPeerIDs)
            connectionState = isInternetOnlyCall ? .internetConnected : .localConnected
            markConnectedMembers(peerIDs: connectedPeerIDs)
            startActiveCallAfterAuthenticatedPeer()
            sendStateMetadataSnapshot()
            publishRuntimePackageReports(force: true)
        case .remotePeerMuteState(let peerID, let isMuted):
            guard authenticatedPeerIDs.contains(peerID) else { return }
            setRemotePeerMuteState(peerID: peerID, isMuted: isMuted)
        case .remotePeerMetadata(let peerID, let activeCodec):
            guard authenticatedPeerIDs.contains(peerID) else { return }
            if let activeCodec {
                setRemotePeerCodec(peerID, codec: activeCodec)
            }
        case .remoteRuntimeStatus(let peerID, let status):
            guard authenticatedPeerIDs.contains(peerID) else { return }
            remoteRuntimeStatuses[peerID] = status
        case .receivedApplicationData:
            break
        case .disconnected:
            networkDiagnostics = nil
            stopAudioPipeline()
            connectedPeerIDs = []
            authenticatedPeerIDs = []
            localNetworkStatus = .idle
            connectionState = .idle
            isVoiceActive = false
            markMembers(.offline)
            publishRuntimePackageReports(force: true)
        case .linkFailed(let internetAvailable):
            networkDiagnostics = nil
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
        case .networkDiagnostics(let report):
            networkDiagnostics = report
        case .routeMetrics(let metrics):
            handleRouteMetrics(metrics)
        }
    }
}
