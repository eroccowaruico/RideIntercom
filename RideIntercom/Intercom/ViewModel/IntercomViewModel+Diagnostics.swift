import AVFoundation
import Codec
import CryptoKit
import Foundation
import Logging
import OSLog
import RTC
import SessionManager
import SoundIsolation
import VADGate

extension IntercomViewModel {
    var connectionLabel: String {
        if hasPresentedAuthenticatedConnection && !isAudioReady {
            return "\(connectionState.label) / Audio Idle"
        }
        return connectionState.label
    }

    var selectedGroupConnectionState: CallConnectionState {
        presentedConnectionState
    }

    var diagnosticsSnapshot: DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            audio: AudioDebugSnapshot(
                transmittedVoicePacketCount: sentVoicePacketCount,
                receivedVoicePacketCount: receivedVoicePacketCount,
                playedAudioFrameCount: playedAudioFrameCount
            ),
            playback: PlaybackDebugSnapshot(
                lastScheduledOutputRMS: lastScheduledOutputRMS,
                scheduledOutputBatchCount: scheduledOutputBatchCount,
                scheduledOutputFrameCount: scheduledOutputFrameCount
            ),
            connectedPeerCount: connectedPeerCount,
            authenticatedPeerCount: authenticatedPeerCount,
            localMemberID: localMemberIdentity.memberID,
            transportTypeName: callSession.activeRouteDebugTypeName,
            selectedGroupID: selectedGroup?.id,
            selectedGroupMemberCount: selectedGroup?.members.count ?? 0,
            groupHashPrefix: selectedGroup.map { String(credential(for: $0).groupHash.prefix(8)) },
            inviteStatusMessage: inviteStatusMessage,
            hasInviteURL: selectedGroupInviteURL != nil,
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

    var callPresenceLabel: String {
        let connectionState = presentedConnectionState
        let localNetworkStatus = presentedLocalNetworkStatus
        if connectionState == .idle, localNetworkStatus != .idle {
            return "Waiting for Riders"
        }
        if hasPresentedAuthenticatedConnection && !isAudioReady {
            return "Connected / Audio Idle"
        }
        return connectionState.label
    }

    var canDisconnectCall: Bool {
        guard selectedGroup?.id == activeGroupID else { return false }
        return connectionState != .idle || isAudioReady || !authenticatedPeerIDs.isEmpty || localNetworkStatus != .idle
    }

    var routeLabel: String {
        if hasPresentedAuthenticatedConnection && !isAudioReady {
            switch presentedConnectionState {
            case .localConnected, .localConnecting:
                return "Local / Control Only"
            case .internetConnected, .internetConnecting:
                return "Internet / Control Only"
            case .idle, .reconnectingOffline:
                return "Offline"
            }
        }
        return switch presentedConnectionState {
        case .localConnected, .localConnecting:
            TransportRoute.local.rawValue
        case .internetConnected, .internetConnecting:
            TransportRoute.internet.rawValue
        case .idle, .reconnectingOffline:
            "Offline"
        }
    }

    var supportsSoundIsolation: Bool {
        // Enable controls only after the App graph connects a real effect node.
        false
    }

    var selectedTransmitCodec: AudioCodecIdentifier {
        AudioCodecIdentifier(rawValue: codecRuntimeReport.selectedCodec.rawValue)
    }

    var vadAnalysisSummary: String {
        guard let latestVADAnalysis = vadGateRuntimeSnapshot.lastAnalysis else {
            return "Analysis waiting"
        }
        return String(
            format: "%@ / NF %.1f dBFS / TH %.1f dBFS / G %.2f",
            latestVADAnalysis.state == .speech ? "Speech" : "Silence",
            latestVADAnalysis.noiseFloorDBFS,
            latestVADAnalysis.speechThresholdDBFS,
            latestVADAnalysis.gain
        )
    }

    var diagnosticsOverviewRows: [DiagnosticsOverviewRow] {
        [
            DiagnosticsOverviewRow(
                id: "call",
                title: "Call",
                icon: "checklist",
                summary: "CALL \(connectionLabel)",
                detail: diagnosticsSnapshot.selectedGroupSummary,
                severity: canDisconnectCall ? .ok : .neutral,
                accessibilityIdentifier: "realDeviceCallDebugSummaryLabel"
            ),
            DiagnosticsOverviewRow(
                id: "network",
                title: "Network Quality",
                icon: "clock.arrow.circlepath",
                summary: networkQualitySummary,
                detail: networkQualityDetail,
                severity: networkQualitySeverity,
                accessibilityIdentifier: "receptionDebugSummaryLabel"
            ),
            DiagnosticsOverviewRow(
                id: "invite",
                title: "Invite",
                icon: "square.and.arrow.up",
                summary: diagnosticsSnapshot.inviteSummary,
                detail: diagnosticsSnapshot.selectedGroupSummary,
                severity: selectedGroupInviteURL != nil ? .ok : .neutral,
                accessibilityIdentifier: "inviteDebugSummaryLabel"
            )
        ]
    }

    private var networkQualitySummary: String {
        guard let lastRouteMetrics else {
            return "NETWORK WAITING"
        }
        let rtt = lastRouteMetrics.rtt.map { String(format: "RTT %.0fms", $0 * 1_000) } ?? "RTT --"
        let loss = lastRouteMetrics.packetLoss.map { String(format: "LOSS %.1f%%", $0 * 100) } ?? "LOSS --"
        return "\(rtt) / \(loss)"
    }

    private var networkQualityDetail: String {
        guard let lastRouteMetrics else {
            return "No route metrics yet"
        }
        return lastRouteMetrics.jitter.map { String(format: "JITTER %.0fms", $0 * 1_000) } ?? "JITTER --"
    }

    private var networkQualitySeverity: DiagnosticsSeverity {
        guard let lastRouteMetrics else { return .neutral }
        if (lastRouteMetrics.packetLoss ?? 0) > 0.05 {
            return .warning
        }
        return .ok
    }

    var connectedPeerCount: Int {
        connectedPeerIDs.count
    }

    var connectionDebugSummary: String {
        diagnosticsSnapshot.connectionSummary
    }

    var audioDebugSummary: String {
        diagnosticsSnapshot.audio.summary
    }

    var callSessionDebugTypeName: String {
        callSession.activeRouteDebugTypeName
    }

    var transportDebugSummary: String {
        diagnosticsSnapshot.transportSummary
    }

    var authenticatedPeerCount: Int {
        authenticatedPeerIDs.count
    }

    var authenticationDebugSummary: String {
        diagnosticsSnapshot.authenticationSummary
    }

    var localMemberDebugSummary: String {
        diagnosticsSnapshot.localMemberSummary
    }

    var selectedGroupDebugSummary: String {
        diagnosticsSnapshot.selectedGroupSummary
    }

    var groupHashDebugSummary: String {
        diagnosticsSnapshot.groupHashSummary
    }

    var inviteDebugSummary: String {
        diagnosticsSnapshot.inviteSummary
    }

    var localNetworkDebugSummary: String {
        diagnosticsSnapshot.localNetwork.summary(now: Date().timeIntervalSince1970)
    }

    var selectedGroupInviteURL: URL? {
        guard let selectedGroup else { return nil }
        let inviterMemberID: String
        if selectedGroup.members.contains(where: { $0.id == localMemberIdentity.memberID }) {
            inviterMemberID = localMemberIdentity.memberID
        } else if let firstMemberID = selectedGroup.members.first?.id {
            inviterMemberID = firstMemberID
        } else {
            return nil
        }

        let credential = credential(for: selectedGroup)
        let token = try? GroupInviteToken.make(
            groupID: selectedGroup.id,
            groupName: selectedGroup.name,
            groupSecret: credential.secret,
            inviterMemberID: inviterMemberID,
            expiresAt: Date().timeIntervalSince1970 + 7 * 24 * 60 * 60
        )
        return token.flatMap { try? GroupInviteTokenCodec.joinURL(for: $0) }
    }
}

struct DiagnosticsOverviewRow: Equatable, Identifiable {
    let id: String
    let title: String
    let icon: String
    let summary: String
    let detail: String
    let severity: DiagnosticsSeverity
    let accessibilityIdentifier: String
}

enum DiagnosticsSeverity: Equatable {
    case neutral
    case ok
    case warning
    case error
}
