import SwiftUI
import RTC

/// One card per route with label and value rows, then one row per observed path.
struct DiagnosticsNetworkView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        let report = viewModel.networkDiagnostics
        VStack(alignment: .leading, spacing: AppSpacing.l) {
            Text(report == nil ? "Not measured. Connect to a group to collect network diagnostics." : "Network diagnostics")
                .accessibilityIdentifier("networkDiagnosticsSummary")
            if let report {
                DiagnosticsValueRow("Session event drops", value: drops(report.eventDrops.overflow, report.eventDrops.expired),
                                    warns: report.eventDrops.expired > 0 || report.eventDrops.overflow > 0)
            }
            ForEach(RouteKind.allCases, id: \.rawValue) { kind in
                routeCard(kind, report: report)
            }
            pathsCard(report)
            Text("RTT measures this device's ICE connection, not audio delay. Event drops occur inside this device. Paths show the last authenticated reception, not guaranteed reachability.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func updated(_ report: RTCNetworkDiagnostics?) -> String? {
        guard let report else { return nil }
        let age = max(0, Date().timeIntervalSince1970 - report.generatedAt)
        return "Updated \(Int(age)) s ago\(age > 15 ? " · Stale" : "")"
    }

    private func drops(_ overflow: Int, _ expired: Int) -> String { "Overflow \(overflow) · Expired \(expired)" }

    private func routeCard(_ kind: RouteKind, report: RTCNetworkDiagnostics?) -> some View {
        let route = report?.routes.first { $0.route == kind }
        let metrics = viewModel.lastRouteMetrics.flatMap { $0.route == kind ? $0 : nil }
        let loss = (metrics?.packetLoss ?? route?.statistics.packetLoss).map { String(format: "%.1f%%", $0 * 100) } ?? "Not measured"
        let jitter = metrics?.jitter.map { String(format: "%.0f ms", $0 * 1000) } ?? "Not measured"
        return GroupBox {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                DiagnosticsValueRow("RTT", value: route?.statistics.roundTripTime.map { String(format: "%.0f ms", $0 * 1000) } ?? "Not measured")
                DiagnosticsValueRow("Loss", value: "\(loss) · Jitter \(jitter)")
                DiagnosticsValueRow("Send queue", value: route?.statistics.bufferedBytes.map { "\($0) B" } ?? "Not measured")
                if let route {
                    let names = route.eventDrops.keys.sorted()
                    if names.isEmpty { DiagnosticsValueRow("Event drops", value: "Not measured") }
                    ForEach(names, id: \.self) { name in
                        if let value = route.eventDrops[name] {
                            DiagnosticsValueRow(names.count == 1 ? "Event drops" : "Event drops (\(name))",
                                                value: drops(value.overflow, value.expired), warns: value.expired > 0 || value.overflow > 0)
                        }
                    }
                    if route.statistics.roundTripTime == nil && route.statistics.bufferedBytes == nil {
                        Text(route.statistics.unavailableReason).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    DiagnosticsValueRow("Event drops", value: "Not measured")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            DiagnosticsCardHeader(kind == .webRTC ? "Internet" : "Local", trailing: updated(report))
        }
        .accessibilityIdentifier(kind == .webRTC ? "diagnosticsNetworkInternet" : "diagnosticsNetworkLocal")
    }

    /// The last authenticated reception per peer: who, how, and the hops as short ids.
    private func pathsCard(_ report: RTCNetworkDiagnostics?) -> some View {
        let peers = report?.peers ?? []
        let members = viewModel.selectedGroup?.members ?? []
        return GroupBox {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                if peers.isEmpty { Text("Not measured").foregroundStyle(.secondary) }
                ForEach(peers, id: \.peerID) { peer in
                    let age = max(0, Date().timeIntervalSince1970 - peer.observedAt)
                    let name = members.first { $0.id == peer.peerID.rawValue }?.resolvedDisplayName ?? String(peer.peerID.rawValue.prefix(8))
                    let hops = peer.path.map { String($0.rawValue.prefix(8)) }.joined(separator: " → ")
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
                        Text(verbatim: name).font(.subheadline.bold()).lineLimit(2)
                        Text(verbatim: "\(peer.path.count > 2 ? "Relayed" : "Direct group path") · \(peer.route == .webRTC ? "Internet" : "Local")")
                            .font(.subheadline)
                        Spacer(minLength: AppSpacing.s)
                        Text(verbatim: "\(hops) · \(Int(age)) s\(age > 15 ? " · Stale" : "")")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            DiagnosticsCardHeader("Paths", trailing: nil)
        }
        .accessibilityIdentifier("diagnosticsNetworkPaths")
    }
}

/// A card heading with an optional trailing note, such as when the values were updated.
struct DiagnosticsCardHeader: View {
    let title: String
    let trailing: String?

    init(_ title: String, trailing: String?) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(verbatim: title)
            Spacer()
            if let trailing { Text(verbatim: trailing).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}

/// One label and its value, as the implementation reports it. A warning adds a symbol, not only a color.
struct DiagnosticsValueRow: View {
    let title: String
    let value: String
    var detail: String?
    var warns = false

    init(_ title: String, value: String, detail: String? = nil, warns: Bool = false) {
        self.title = title
        self.value = value
        self.detail = detail
        self.warns = warns
    }

    var body: some View {
        // Label on the left, value on the right, as a two-column table (LabeledContent only does this in a Form).
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            Text(verbatim: title)
            Spacer(minLength: AppSpacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: AppSpacing.xs) {
                    if warns { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppColorPalette.warning) }
                    Text(verbatim: value).monospacedDigit()
                }
                if let detail {
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}
