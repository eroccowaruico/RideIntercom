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
    var networkDiagnosticsSummary: String {
        guard let report = networkDiagnostics else { return "Not measured. Connect to a group to collect network diagnostics." }
        guard Date().timeIntervalSince1970 - report.generatedAt <= 15 else { return "Network report is stale. Waiting for a fresh measurement." }
        var lines = ["Event drops — session: overflow \(report.eventDrops.overflow), expired \(report.eventDrops.expired)"]
        for route in report.routes {
            let label = route.route == .webRTC ? "Internet" : "Local"
            let rtt = route.statistics.roundTripTime.map { String(format: "%.0f ms", $0 * 1000) } ?? "Not available"
            let buffered = route.statistics.bufferedBytes.map { "\($0) B" } ?? "Not available"
            lines.append("\(label): RTT \(rtt), send queue \(buffered)")
            lines.append(route.statistics.unavailableReason)
            for (name, drops) in route.eventDrops.sorted(by: { $0.key < $1.key }) {
                lines.append("\(label) / \(name) drops: overflow \(drops.overflow), expired \(drops.expired)")
            }
        }
        for peer in report.peers {
            let hops = peer.path.map { String($0.rawValue.prefix(8)) }.joined(separator: " → ")
            lines.append("\(peer.path.count > 2 ? "Relayed" : "Direct group path"): \(hops)")
        }
        return lines.joined(separator: "\n")
    }

    var isInternetOnlyCall: Bool {
        if !availableCallRoutes.isEmpty { return availableCallRoutes == [.webRTC] }
        return enabledRTCTransportRoutes == [.webRTC]
    }

    var connectionLabel: String {
        if hasPresentedAuthenticatedConnection && !isAudioReady {
            return "\(connectionState.label) / Audio Idle"
        }
        return connectionState.label
    }

    var selectedGroupConnectionState: CallConnectionState {
        presentedConnectionState
    }

    var callPresenceLabel: String {
        if selectedGroup?.id == activeGroupID, isAudioPausedForDeviceChange { return "Connected / Audio Paused" }
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
        if selectedGroup?.id == activeGroupID, !availableCallRoutes.isEmpty {
            let path = availableCallRoutes.contains(.multipeer)
                ? (availableCallRoutes.contains(.webRTC) ? "Local + Internet / Relay" : "Local / Relay available")
                : "Internet"
            return isAudioPausedForDeviceChange ? "\(path) / Audio Paused" : path
        }
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
        VoiceIsolationSupport.isAvailable
    }

    var selectedTransmitCodec: AudioCodecIdentifier {
        AudioCodecIdentifier(rawValue: codecRuntimeReport.selectedCodec.rawValue)
    }

    private var selectedGroupSummary: String {
        guard let selectedGroup else { return "GROUP -- / MEMBERS 0" }
        return "GROUP \(selectedGroup.id.uuidString.prefix(8)) / MEMBERS \(selectedGroup.members.count)"
    }

    private var inviteSummary: String {
        groupErrorMessage ?? inviteStatusMessage ?? (selectedGroupInviteURL != nil ? "INVITE READY" : "INVITE NONE")
    }

    var diagnosticsOverviewRows: [DiagnosticsOverviewRow] {
        [
            DiagnosticsOverviewRow(
                id: "media",
                title: "Audio Path",
                icon: "waveform",
                summary: "Shared packet audio",
                detail: "SessionManager → Mixer / effects → Codec → Local / Internet relay",
                severity: .neutral,
                accessibilityIdentifier: "audioPathSummary"
            ),
            DiagnosticsOverviewRow(
                id: "call",
                title: "Call",
                icon: "checklist",
                summary: "CALL \(connectionLabel)",
                detail: selectedGroupSummary,
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
                summary: inviteSummary,
                detail: selectedGroupSummary,
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
        if let internetFailureDetail { return "Internet: \(internetFailureDetail)" }
        guard let lastRouteMetrics else {
            return "No route metrics yet"
        }
        return lastRouteMetrics.jitter.map { String(format: "JITTER %.0fms", $0 * 1_000) } ?? "JITTER --"
    }

    private var networkQualitySeverity: DiagnosticsSeverity {
        if internetFailureDetail != nil { return .warning }
        guard let lastRouteMetrics, lastRouteMetrics.rtt != nil || lastRouteMetrics.packetLoss != nil || lastRouteMetrics.jitter != nil else { return .neutral }
        if (lastRouteMetrics.packetLoss ?? 0) > 0.05 {
            return .warning
        }
        return .ok
    }

    var connectedPeerCount: Int {
        connectedPeerIDs.count
    }

    var authenticatedPeerCount: Int {
        authenticatedPeerIDs.count
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

        guard let credential = try? credential(for: selectedGroup) else { return nil }
        let recipient = directCallRecipient(for: selectedGroup)
        guard selectedGroup.kind != .direct || recipient != nil else { return nil }
        let token = try? GroupInviteToken.make(
            groupID: selectedGroup.id,
            groupName: selectedGroup.name,
            groupSecret: credential.secret,
            inviterMemberID: inviterMemberID,
            recipientMemberID: recipient,
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
