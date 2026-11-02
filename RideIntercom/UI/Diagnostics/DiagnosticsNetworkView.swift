import SwiftUI
import RTC

struct DiagnosticsNetworkView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        let report = viewModel.networkDiagnostics
        VStack(alignment: .leading, spacing: AppSpacing.l) {
            Text(report == nil ? "Not measured. Connect to a group to collect network diagnostics." : "Network diagnostics")
                .accessibilityIdentifier("networkDiagnosticsSummary")
            if let report {
                let age = max(0, Date().timeIntervalSince1970 - report.generatedAt)
                Text("Updated \(Int(age))s ago\(age > 15 ? " / Stale" : "")")
                    .foregroundStyle(age > 15 ? .secondary : .primary)
                Text("Session event drops: overflow \(report.eventDrops.overflow), expired \(report.eventDrops.expired)")
            }
            ForEach(RouteKind.allCases, id: \.rawValue) { kind in
                routeCard(kind, report: report)
            }
            Text("RTT measures this device's ICE connection, not audio delay. Event drops occur inside this device. Paths show the last authenticated reception, not guaranteed reachability.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func routeCard(_ kind: RouteKind, report: RTCNetworkDiagnostics?) -> some View {
        let route = report?.routes.first { $0.route == kind }
        let metrics = viewModel.lastRouteMetrics.flatMap { $0.route == kind ? $0 : nil }
        let paths = report?.peers.filter { $0.route == kind } ?? []
        return GroupBox(kind == .webRTC ? "Internet" : "Local") {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                Text("RTT: \(route?.statistics.roundTripTime.map { String(format: "%.0f ms", $0 * 1000) } ?? "Not measured")")
                Text("Loss: \((metrics?.packetLoss ?? route?.statistics.packetLoss).map { String(format: "%.1f%%", $0 * 100) } ?? "Not measured")")
                Text("Jitter: \(metrics?.jitter.map { String(format: "%.0f ms", $0 * 1000) } ?? "Not measured")")
                Text("Send queue: \(route?.statistics.bufferedBytes.map { "\($0) B" } ?? "Not measured")")
                if let route {
                    if route.statistics.roundTripTime == nil && route.statistics.bufferedBytes == nil {
                        Text(route.statistics.unavailableReason).font(.footnote)
                    }
                    ForEach(route.eventDrops.keys.sorted(), id: \.self) { name in
                        if let drops = route.eventDrops[name] {
                            Text("\(name) event drops: overflow \(drops.overflow), expired \(drops.expired)")
                        }
                    }
                } else {
                    Text("Event drops: Not measured")
                }
                if paths.isEmpty { Text("Paths: Not measured") }
                ForEach(paths, id: \.peerID) { peer in
                    let age = max(0, Date().timeIntervalSince1970 - peer.observedAt)
                    let hops = peer.path.map { String($0.rawValue.prefix(8)) }.joined(separator: " → ")
                    Text("\(peer.path.count > 2 ? "Relayed" : "Direct group path"): \(hops) / \(Int(age))s ago\(age > 15 ? " / Stale" : "")")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(kind == .webRTC ? "diagnosticsNetworkInternet" : "diagnosticsNetworkLocal")
    }
}
