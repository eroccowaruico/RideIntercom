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

    // A menu Picker cannot be scrolled when accessibility text fills a landscape screen,
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
            pagePicker.pickerStyle(.menu)
        }
        #else
        pagePicker.pickerStyle(.menu)
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
            pipelineOverview
            symptomButtons
        }
    }

    private var pagePicker: some View {
        Picker("Diagnostics", selection: $page) {
            ForEach(DiagnosticsPage.allCases) { item in Text(item.rawValue).tag(item) }
        }
        .accessibilityIdentifier("diagnosticsPagePicker")
    }

    private func stageOverview(_ name: String, steps: [PipelineStep]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(name).font(.headline)
            ForEach(steps) { step in
                Label {
                    Text("\(step.title): \(step.state.statusText)")
                } icon: {
                    Image(systemName: step.state.statusSymbol).foregroundStyle(step.state.color)
                }
            }
        }
    }

    private var symptomButtons: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            Button("Others can't hear me") { navigate(.tx, target: firstTransmitIssue) }
                .accessibilityIdentifier("diagnosticsOthersCannotHearButton")
            Button("I can't hear someone") { navigate(.rx, target: "receive-peers") }
                .accessibilityIdentifier("diagnosticsCannotHearButton")
            Button("Audio drops out") { navigate(.rx, target: "receive-peers") }
                .accessibilityIdentifier("diagnosticsAudioDropsButton")
            Button("Audio is delayed") { navigate(.rx, target: "receive-output") }
                .accessibilityIdentifier("diagnosticsAudioDelayedButton")
        }
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
        let input = DiagnosticsInput(viewModel)
        let tx = TransmitPipelinePresentation(input: input)
        let rx = ReceivePipelinePresentation(input: input)
        let txSteps = [tx.sessionStep, tx.inputStreamStep, tx.mixerBusStep, tx.mixerEffectChainStep, tx.codecStep, tx.rtcStep]
        let rxSteps = [rx.rtcReceiveStep, rx.codecDecodeStep, rx.peerBusStep, rx.receiveMixStep, rx.masterBusStep, rx.masterEffectChainStep, rx.outputStep]
        return GroupBox("Pipeline") {
            VStack(alignment: .leading, spacing: AppSpacing.m) {
                pipelineSummary("TX", steps: txSteps)
                pipelineSummary("RX", steps: rxSteps)
                stageOverview("TX", steps: txSteps)
                stageOverview("RX", steps: rxSteps)
                if let group = viewModel.selectedGroup {
                    ForEach(Array(group.members.dropFirst())) { member in
                        Text("\(member.resolvedDisplayName) / \(member.connectionState.rawValue) / RX packets/s: Not measured")
                            .lineLimit(2)
                    }
                }
                if let report = viewModel.networkDiagnostics {
                    ForEach(report.routes, id: \.route.rawValue) { route in
                        Text("\(route.route == .webRTC ? "Internet" : "Local") / \(report.peers.filter { $0.route == route.route }.count) peers / RTT \(route.statistics.roundTripTime.map { String(format: "%.0f ms", $0 * 1000) } ?? "Not measured")")
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pipelineSummary(_ name: String, steps: [PipelineStep]) -> some View {
        let blocked = steps.first { $0.state == .blocked || $0.state == .muted }
        let firstPending = steps.first { $0.state == .waiting || $0.state == .idle }
        let step = blocked ?? firstPending
        return Text("\(name): \(step.map { "\($0.title) — \($0.detail)" } ?? "Running")")
            .accessibilityIdentifier("diagnosticsPipelineSummary-\(name)")
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
