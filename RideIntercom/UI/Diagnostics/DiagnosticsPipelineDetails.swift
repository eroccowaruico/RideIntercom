import SwiftUI
import AudioCore
import RTC
import Codec
import VADGate
import SoundIsolation

struct DiagnosticsTransmitRoutes: View {
    @Bindable var viewModel: IntercomViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text("Packets/s: Not measured")
            ForEach(RouteKind.allCases, id: \.rawValue) { route in
                let paths = viewModel.networkDiagnostics?.peers.filter { $0.route == route } ?? []
                VStack(alignment: .leading) {
                    Text(route == .webRTC ? "Internet" : "Local").font(.headline)
                    if paths.isEmpty { Text("Destinations: Not measured") }
                    ForEach(paths, id: \.peerID) { path in
                        Text("\(path.path.count > 2 ? "Relayed" : "Direct group path"): \(path.path.map { String($0.rawValue.prefix(8)) }.joined(separator: " → "))")
                    }
                    if route == .webRTC {
                        Text("Send queue: \(viewModel.networkDiagnostics?.routes.first { $0.route == route }?.statistics.bufferedBytes.map { "\($0) B" } ?? "Not measured")")
                    }
                }
            }
        }
    }
}

struct DiagnosticsReceiveDetails: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var expandedStage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            Text("Participants").font(.headline).accessibilityIdentifier("receive-mix-topology")
            if let group = viewModel.selectedGroup {
                ForEach(Array(group.members.dropFirst())) { member in
                    DisclosureGroup(isExpanded: Binding(get: { expandedStage == "receive-peers" || expandedStage == member.id }, set: { expandedStage = $0 ? member.id : nil })) {
                        peer(member)
                    } label: { Text(member.resolvedDisplayName).lineLimit(2) }
                    .id(member.id)
                }
            } else { Text("No participants") }

        }.font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diagnosticsReceiveDetails")
    }

    private func peer(_ member: GroupMember) -> some View {
        let status = viewModel.remoteRuntimeStatuses[member.id]
        let paths = viewModel.networkDiagnostics?.peers.filter { $0.peerID.rawValue == member.id } ?? []
        let codecReport = status?.packageReports.first { $0.package == "Codec" }.flatMap { try? $0.decodeJSON(CodecRuntimeReport.self) }
        let vad = status?.packageReports.first { $0.package == "VADGate" }.flatMap { try? $0.decodeJSON(VADGateRuntimeSnapshot.self) }
        let effects = viewModel.receivePeerEffectChainSnapshot(peerID: member.id)
        let isolation = status?.packageReports.first { $0.package == "SoundIsolation" && $0.kind == "transmitRuntimeSnapshot" }.flatMap { try? $0.decodeJSON(VoiceIsolationRuntimeSnapshot.self) }
        return VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if member.connectionState != .offline {
                if status?.localMute == true {
                    Label { Text("Muted") } icon: { Image(systemName: "mic.slash.fill").foregroundStyle(AppColorPalette.danger) }
                }
                Text("Sender: \(status.map { $0.localMute ? "Muted" : "Unmuted" } ?? "Not measured") / codec \(codecReport.map { $0.activeConfiguration.codec.rawValue } ?? "Not measured") / bitrate \(codecReport?.activeConfiguration.activeBitRate.map { "\($0) bps" } ?? "Not measured") / VAD \(vad?.lastAnalysis.map { String(describing: $0.state) } ?? "Not measured") / Isolation \(isolation.map { String(describing: $0.state) } ?? "Not measured")")
                if let status {
                    let age = max(0, Date().timeIntervalSince1970 - status.generatedAt)
                    Text("Sender updated \(Int(age))s ago\(age > 15 ? " / Stale" : "")")
                }
                Text("RTC RX: \(member.connectionState.rawValue) / \(member.authenticationState.rawValue) / \(paths.isEmpty ? "Path not measured" : paths.map { $0.route == .webRTC ? "Internet" : ($0.path.count > 2 ? "Local relayed" : "Local direct") }.joined(separator: ", "))")
                Text("Decode: \(member.activeCodec?.rawValue ?? "Not measured") / packets/s: Not measured")
                Text("Peer Bus: volume \(Int(viewModel.remoteOutputVolume(for: member.id) * 100))% / FX \(effects.summary) / queued \(member.queuedAudioFrameCount) frames")
            } else { Text("Offline").foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
