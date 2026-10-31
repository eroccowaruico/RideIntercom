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
    func broadcastControl(_ message: ControlMessage) {
        callSession.sendControl(message)
    }

    func broadcastMetadataKeepalive() {
        callSession.sendControl(.keepalive)
        sendPendingInvitationReceipt()
    }

    func sendStateMetadataSnapshot() {
        sendPeerProfileChallenges()
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
        case .serviceBlocked(let reason):
            internetFailureDetail = reason
            connectivityNotice = reason
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
            refreshCallAccess()
            localNetworkStatus = peerIDs.isEmpty ? .advertisingBrowsing : .connected
            connectionState = isInternetOnlyCall
                ? (peerIDs.isEmpty ? .internetConnecting : .internetConnected)
                : (peerIDs.isEmpty ? .localConnecting : .localConnected)
            markConnectedMembers(peerIDs: peerIDs)
            publishRuntimePackageReports(force: true)
        case .authenticated(let members):
            let peerIDs = members.filter { $0.isConnected && $0.peer.id.rawValue != localMemberIdentity.memberID }
                .map { $0.peer.id.rawValue }
            if let group = groups.first(where: { $0.id == activeGroupID }), group.kind == .direct, group.accountPair == nil,
               !Set(peerIDs).isSubset(of: Set(group.members.filter { $0.id != localMemberIdentity.memberID }.map(\.id))) {
                disconnect()
                groupErrorMessage = "An unexpected participant joined this individual call. The call was stopped."
                return
            }
            let authenticatedPeerIDSet = Set(peerIDs)
            authenticatedPeerIDs = Array(authenticatedPeerIDSet).sorted()
            synchronizePeerProfiles(members: members)
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
        case .receivedApplicationData(let peerID, let message):
            receivePeerProfileChallenge(peerID: peerID, message: message)
            receiveSharedDisplayName(peerID: peerID, message: message)
            receiveInvitationReceipt(peerID: peerID, message: message)
            receiveCallAccess(peerID: peerID, message: message)
        case .disconnected:
            networkDiagnostics = nil
            callTicker.stop()
            stopAudioPipeline()
            connectedPeerIDs = []
            authenticatedPeerIDs = []
            peerProfiles.removeAll()
            localNetworkStatus = .idle
            connectionState = .idle
            isVoiceActive = false
            markMembers(.offline)
            publishRuntimePackageReports(force: true)
        case .linkFailed(let willRetry):
            networkDiagnostics = nil
            if !willRetry { callTicker.stop() }
            AppLoggers.rtc.error(
                "rtc.connection.failed",
                metadata: .event("rtc.connection.failed", [
                    "route": "\(routeLabel)",
                    "isRecoverable": "\(willRetry)"
                ])
            )
            stopAudioPipeline()
            connectedPeerIDs = []
            authenticatedPeerIDs = []
            peerProfiles.removeAll()
            localNetworkStatus = willRetry ? .unavailable : .idle
            connectionState = willRetry ? .reconnectingOffline : .idle
            markMembers(willRetry ? .connecting : .offline)
            publishRuntimePackageReports(force: true)
        case .receivedAudioPacket(let received, let reception):
            handleReceivedAudioPacket(received, reception: reception)
        case .networkDiagnostics(let report):
            networkDiagnostics = report
        case .routeMetrics(let metrics):
            handleRouteMetrics(metrics)
        }
    }
}
