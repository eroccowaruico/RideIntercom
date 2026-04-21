import Foundation

struct AudioDebugSnapshot: Equatable {
    let transmittedVoicePacketCount: Int
    let receivedVoicePacketCount: Int
    let playedAudioFrameCount: Int

    var summary: String {
        "TX \(transmittedVoicePacketCount) / RX \(receivedVoicePacketCount) / PLAY \(playedAudioFrameCount)"
    }
}

struct ReceptionDebugSnapshot: Equatable {
    let lastReceivedAudioAt: TimeInterval?
    let droppedAudioPacketCount: Int
    let jitterQueuedFrameCount: Int

    func summary(now: TimeInterval) -> String {
        let lastRX: String
        if let lastReceivedAudioAt {
            lastRX = String(format: "%.1fs", max(0, now - lastReceivedAudioAt))
        } else {
            lastRX = "--"
        }
        return "LAST RX \(lastRX) / DROP \(droppedAudioPacketCount) / JIT \(jitterQueuedFrameCount)"
    }
}

struct LocalNetworkDebugSnapshot: Equatable {
    let status: LocalNetworkStatus
    let peerID: String?
    let occurredAt: TimeInterval?

    func summary(now: TimeInterval) -> String {
        var parts = [status.label]
        if let peerID {
            parts.append("peer \(peerID)")
        }
        if let occurredAt {
            parts.append(String(format: "%.1fs", max(0, now - occurredAt)))
        }
        return parts.joined(separator: " / ")
    }
}

struct DiagnosticsSnapshot: Equatable {
    let audio: AudioDebugSnapshot
    let connectedPeerCount: Int
    let authenticatedPeerCount: Int
    let localMemberID: String
    let transportTypeName: String
    let selectedGroupID: UUID?
    let selectedGroupMemberCount: Int
    let groupHashPrefix: String?
    let inviteStatusMessage: String?
    let hasInviteURL: Bool
    let localNetwork: LocalNetworkDebugSnapshot
    let reception: ReceptionDebugSnapshot

    var connectionSummary: String {
        "PEERS \(connectedPeerCount)"
    }

    var authenticationSummary: String {
        "AUTH \(authenticatedPeerCount)"
    }

    var localMemberSummary: String {
        "LOCAL \(localMemberID)"
    }

    var transportSummary: String {
        "TRANSPORT \(transportTypeName)"
    }

    var selectedGroupSummary: String {
        guard let selectedGroupID else {
            return "GROUP -- / MEMBERS 0"
        }
        return "GROUP \(selectedGroupID.uuidString.prefix(8)) / MEMBERS \(selectedGroupMemberCount)"
    }

    var groupHashSummary: String {
        guard let groupHashPrefix else {
            return "HASH --"
        }
        return "HASH \(groupHashPrefix)"
    }

    var inviteSummary: String {
        if let inviteStatusMessage {
            return inviteStatusMessage
        }
        return hasInviteURL ? "INVITE READY" : "INVITE NONE"
    }

    func realDeviceCallSummary(connectionLabel: String, isAudioReady: Bool, now: TimeInterval) -> String {
        let audioState = isAudioReady ? "AUDIO READY" : "AUDIO IDLE"
        return "CALL \(connectionLabel) / \(audioState) / \(audio.summary) / \(authenticationSummary) / \(reception.summary(now: now))"
    }
}

enum DiagnosticsSnapshotBuilder {
    static func make(
        sentVoicePacketCount: Int,
        receivedVoicePacketCount: Int,
        playedAudioFrameCount: Int,
        connectedPeerCount: Int,
        authenticatedPeerCount: Int,
        localMemberID: String,
        transportTypeName: String,
        selectedGroupID: UUID?,
        selectedGroupMemberCount: Int,
        groupHashPrefix: String?,
        inviteStatusMessage: String?,
        hasInviteURL: Bool,
        localNetworkStatus: LocalNetworkStatus,
        lastLocalNetworkPeerID: String?,
        lastLocalNetworkEventAt: TimeInterval?,
        lastReceivedAudioAt: TimeInterval?,
        droppedAudioPacketCount: Int,
        jitterQueuedFrameCount: Int
    ) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            audio: AudioDebugSnapshot(
                transmittedVoicePacketCount: sentVoicePacketCount,
                receivedVoicePacketCount: receivedVoicePacketCount,
                playedAudioFrameCount: playedAudioFrameCount
            ),
            connectedPeerCount: connectedPeerCount,
            authenticatedPeerCount: authenticatedPeerCount,
            localMemberID: localMemberID,
            transportTypeName: transportTypeName,
            selectedGroupID: selectedGroupID,
            selectedGroupMemberCount: selectedGroupMemberCount,
            groupHashPrefix: groupHashPrefix,
            inviteStatusMessage: inviteStatusMessage,
            hasInviteURL: hasInviteURL,
            localNetwork: LocalNetworkDebugSnapshot(
                status: localNetworkStatus,
                peerID: lastLocalNetworkPeerID,
                occurredAt: lastLocalNetworkEventAt
            ),
            reception: ReceptionDebugSnapshot(
                lastReceivedAudioAt: lastReceivedAudioAt,
                droppedAudioPacketCount: droppedAudioPacketCount,
                jitterQueuedFrameCount: jitterQueuedFrameCount
            )
        )
    }
}