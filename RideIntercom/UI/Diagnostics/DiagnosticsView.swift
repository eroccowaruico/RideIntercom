import SwiftUI
import RTC

private enum DiagnosticsPage: String, CaseIterable, Identifiable {
    case overview = "Overview", tx = "TX", rx = "RX", network = "Network", applied = "Applied"
    var id: String { rawValue }
}

struct DiagnosticsView: View {
    @Bindable var viewModel: IntercomViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page: DiagnosticsPage = .overview
    @State private var expandedStage: String?
    @State private var scrollTarget: String?

    var body: some View {
        VStack(spacing: AppSpacing.l) {
            pageSelector
                .padding(.horizontal, AppSpacing.screen)
            GeometryReader { geometry in
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    ScrollViewReader { proxy in
                        ScrollView {
                            GlassEffectContainer(spacing: AppSpacing.l) {
                                Group {
                                    if geometry.size.width >= 600 && !dynamicTypeSize.isAccessibilitySize && page != .overview {
                                        HStack(alignment: .top, spacing: AppSpacing.l) {
                                            overviewContent
                                                .frame(maxWidth: AppSize.callColumnMaxWidth, alignment: .leading)
                                            pageContent
                                                .frame(maxWidth: AppSize.callColumnMaxWidth, alignment: .leading)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .top)
                                    } else {
                                        pageContent
                                            .frame(maxWidth: AppSize.singleColumnMaxWidth, alignment: .leading)
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .padding(AppSpacing.l)
                            }
                        }
                        .accessibilityIdentifier("diagnosticsScrollView")
                        .id(page)
                        .onChange(of: scrollTarget) { _, target in
                            guard let target else { return }
                            DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                        }
                    }
                }
            }
        }
        .background(AppColorPalette.standardScreenBackground)
        .onAppear {
            viewModel.isDiagnosticsVisible = true
            viewModel.publishRuntimePackageReports(force: true)
        }
        .onDisappear { viewModel.isDiagnosticsVisible = false }
    }

    // Every page is visible at once as segments. Accessibility text sizes don't fit five segments,
    // so those sizes open the pages as a pushed selection list instead.
    @ViewBuilder private var pageSelector: some View {
        #if os(iOS)
        if dynamicTypeSize.isAccessibilitySize {
            NavigationLink {
                DiagnosticsPageSelection(page: $page)
            } label: {
                LabeledContent("Diagnostics", value: page.rawValue)
            }
            .accessibilityIdentifier("diagnosticsPagePicker")
        } else {
            pagePicker.pickerStyle(.segmented).labelsHidden()
        }
        #else
        pagePicker.pickerStyle(.segmented).labelsHidden()
        #endif
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .overview:
            overviewContent
        case .tx:
            LiveTransmitPipelineView(viewModel: viewModel, expandedStage: $expandedStage)
        case .rx:
            LiveReceivePipelineView(viewModel: viewModel, expandedStage: $expandedStage)
        case .network:
            DiagnosticsNetworkView(viewModel: viewModel)
        case .applied:
            DiagnosticsAppliedView(viewModel: viewModel)
        }
    }

    // The former summary cards are retired; Overview is the pipeline summary and the symptom actions.
    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: AppSpacing.l) {
            verdicts
            pipelineOverview
            participantsOverview
            networkOverview
            symptomButtons
        }
    }

    private var pipelineSteps: (tx: [PipelineStep], rx: [PipelineStep]) {
        let input = DiagnosticsInput(viewModel)
        let tx = TransmitPipelinePresentation(input: input)
        let rx = ReceivePipelinePresentation(input: input)
        return ([tx.sessionStep, tx.inputStreamStep, tx.mixerBusStep, tx.mixerEffectChainStep, tx.codecStep, tx.rtcStep],
                [rx.rtcReceiveStep, rx.codecDecodeStep, rx.peerBusStep, rx.receiveMixStep, rx.masterBusStep, rx.masterEffectChainStep, rx.outputStep])
    }

    /// The conclusion first: one verdict per direction with the reason the stages report.
    private var verdicts: some View {
        let steps = pipelineSteps
        return GroupBox {
            VStack(alignment: .leading, spacing: AppSpacing.m) {
                verdictRow("TX", verdict: PipelineVerdict(steps: steps.tx))
                verdictRow("RX", verdict: PipelineVerdict(steps: steps.rx))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func verdictRow(_ name: String, verdict: PipelineVerdict) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Label {
                Text(verbatim: "\(name): \(verdict.text)").font(.headline)
            } icon: {
                PipelineStateDot(state: verdict.state)
            }
            if let reason = verdict.reason {
                Text(verbatim: reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diagnosticsVerdict-\(name)")
    }

    private var pagePicker: some View {
        Picker("Diagnostics", selection: $page) {
            ForEach(DiagnosticsPage.allCases) { item in Text(item.rawValue).tag(item) }
        }
        .accessibilityIdentifier("diagnosticsPagePicker")
    }

    /// One line per direction: the direction, then every stage as a state dot and its name, wrapping.
    private func stageDots(_ name: String, steps: [PipelineStep]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            Text(verbatim: name).font(.subheadline.bold()).frame(minWidth: 28, alignment: .leading)
            WrappingRow(spacing: AppSpacing.m, lineSpacing: AppSpacing.xs) {
                ForEach(steps) { step in
                    HStack(spacing: AppSpacing.xs) {
                        PipelineStateDot(state: step.state)
                        Text(verbatim: step.title).lineLimit(1)
                    }
                }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(name): " + steps.map { "\($0.title) \($0.state.statusText)" }.joined(separator: ", ")))
        .accessibilityIdentifier("diagnosticsStageDots-\(name)")
    }

    private var symptomButtons: some View {
        WrappingRow(spacing: AppSpacing.s, lineSpacing: AppSpacing.s) {
            Button("Others can't hear me") { navigate(.tx, target: firstTransmitIssue) }
                .accessibilityIdentifier("diagnosticsOthersCannotHearButton")
            Button("I can't hear someone") { navigate(.rx, target: "receive-peers") }
                .accessibilityIdentifier("diagnosticsCannotHearButton")
            Button("Audio drops out") { navigate(.rx, target: "receive-peers") }
                .accessibilityIdentifier("diagnosticsAudioDropsButton")
            Button("Audio is delayed") { navigate(.rx, target: "receive-output") }
                .accessibilityIdentifier("diagnosticsAudioDelayedButton")
        }
        .buttonStyle(.glass)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func navigate(_ destination: DiagnosticsPage, target: String) {
        expandedStage = target
        scrollTarget = nil
        page = destination
        DispatchQueue.main.async { scrollTarget = target }
    }

    private var firstTransmitIssue: String {
        let tx = TransmitPipelinePresentation(input: DiagnosticsInput(viewModel))
        let steps = [tx.sessionStep, tx.inputStreamStep, tx.mixerBusStep, tx.codecStep, tx.rtcStep]
        return steps.first { $0.state != .passing }?.id ?? "session"
    }

    private var pipelineOverview: some View {
        let (txSteps, rxSteps) = pipelineSteps
        return GroupBox("Pipeline") {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                stageDots("TX", steps: txSteps)
                Divider()
                stageDots("RX", steps: rxSteps)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One row per other member: name, the measured path, and `PeerConnectionState` as stored.
    private var participantsOverview: some View {
        let members = Array(viewModel.selectedGroup?.members.dropFirst() ?? [])
        let peers = viewModel.networkDiagnostics?.peers ?? []
        return GroupBox {
            VStack(spacing: AppSpacing.s) {
                if members.isEmpty { Text("No participants").foregroundStyle(.secondary) }
                ForEach(members) { member in
                    let paths = peers.filter { $0.peerID.rawValue == member.id }
                        .map { $0.route == .webRTC ? "Internet" : ($0.path.count > 2 ? "Local · relayed" : "Local · direct") }
                    overviewRow(member.resolvedDisplayName, value: paths.isEmpty ? "—" : paths.joined(separator: ", "),
                                state: PipelineStepState(member.connectionState), status: member.connectionState.rawValue)
                        .opacity(member.connectionState == .offline ? 0.5 : 1)
                }
            }
        } label: {
            HStack {
                Text("Participants")
                Spacer()
                Text(verbatim: "\(members.count) \(members.count == 1 ? "member" : "members")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("diagnosticsOverviewParticipants")
    }

    /// One row per route: the route, how many peers use it, and its RTT.
    @ViewBuilder private var networkOverview: some View {
        if let report = viewModel.networkDiagnostics, !report.routes.isEmpty {
            GroupBox("Network") {
                VStack(spacing: AppSpacing.s) {
                    ForEach(report.routes, id: \.route.rawValue) { route in
                        let count = report.peers.filter { $0.route == route.route }.count
                        overviewRow(route.route == .webRTC ? "Internet" : "Local",
                                    value: "\(count) \(count == 1 ? "participant" : "participants")",
                                    state: count > 0 ? .passing : .idle,
                                    status: "RTT " + (route.statistics.roundTripTime.map { String(format: "%.0f ms", $0 * 1000) } ?? "Not measured"))
                    }
                }
            }
            .accessibilityIdentifier("diagnosticsOverviewNetwork")
        }
    }

    private func overviewRow(_ name: String, value: String, state: PipelineStepState, status: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            Text(verbatim: name).font(.subheadline.bold()).lineLimit(2)
            Text(verbatim: value).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: AppSpacing.s)
            HStack(spacing: AppSpacing.xs) {
                PipelineStateDot(state: state)
                Text(verbatim: status).font(.subheadline.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

}

private extension PipelineStepState {
    init(_ connection: PeerConnectionState) {
        switch connection {
        case .connected: self = .passing
        case .connecting: self = .waiting
        case .offline: self = .idle
        }
    }
}

/// Places children left to right and wraps to a new line when the width runs out.
private struct WrappingRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let proposal = ProposedViewSize(width: bounds.width, height: nil)
        for (subview, origin) in zip(subviews, arrange(width: bounds.width, subviews: subviews).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: proposal)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            // Never wider than the line, so a long item wraps its own text instead of overflowing.
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0 && x + size.width > width {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: min(widest, width), height: y + lineHeight))
    }
}

/// Eight-point state dot; Idle is a dashed ring so state never relies on color alone.
private struct PipelineStateDot: View {
    let state: PipelineStepState
    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 8
    var body: some View {
        Group {
            if state == .idle {
                Circle().strokeBorder(state.color, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            } else {
                Circle().fill(state.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#if os(iOS)
private struct DiagnosticsPageSelection: View {
    @Binding var page: DiagnosticsPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(DiagnosticsPage.allCases) { item in
            Button {
                page = item
                dismiss()
            } label: {
                HStack {
                    Text(item.rawValue)
                    Spacer()
                    if page == item { Image(systemName: "checkmark") }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .accessibilityIdentifier("diagnosticsPageSelection")
    }
}
#endif
