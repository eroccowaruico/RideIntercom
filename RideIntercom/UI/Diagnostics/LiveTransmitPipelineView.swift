import SwiftUI
import AudioCore
import AudioMixer
import RTC
import SessionManager

struct LiveTransmitPipelineView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            CompactPipelineHeader(
                title: "Live TX Pipeline",
                systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                detail: "Session -> Input -> TX bus -> FX -> Codec -> RTC"
            )

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                CompactPipelineStepRow(step: sessionStep)
                CompactPipelineStepRow(step: inputStreamStep)
                CompactPipelineStepRow(step: mixerBusStep)
                CompactEffectChainGroup(
                    step: mixerEffectChainStep,
                    title: "TX Bus Effects",
                    accessibilityIdentifier: "pipeline-effects-step",
                    stageIdentifierPrefix: "pipeline-effect-stage",
                    stages: transmitEffectStages
                )
                .padding(.leading, CompactPipelineLayout.childIndent)
                CompactPipelineStepRow(step: codecStep)
                CompactPipelineStepRow(step: rtcStep)
            }
        }
        .appDiagnosticsCardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveTransmitPipelineView")
    }

    private var sessionStep: PipelineStep {
        if viewModel.audioErrorMessage != nil {
            return PipelineStep(
                id: "session",
                package: "SessionManager",
                title: "Session",
                detail: "Error",
                icon: "waveform.badge.exclamationmark",
                state: .blocked,
                accessibilityIdentifier: "pipeline-session-step"
            )
        }
        if viewModel.audioSessionSnapshot.isActive {
            return PipelineStep(
                id: "session",
                package: "SessionManager",
                title: "Session",
                detail: viewModel.audioSessionProfile.label,
                icon: "waveform",
                state: .passing,
                accessibilityIdentifier: "pipeline-session-step"
            )
        }
        if viewModel.lastAudioSessionConfigurationReport != nil {
            return PipelineStep(
                id: "session",
                package: "SessionManager",
                title: "Session",
                detail: "Configured",
                icon: "waveform",
                state: .waiting,
                accessibilityIdentifier: "pipeline-session-step"
            )
        }
        return PipelineStep(
            id: "session",
            package: "SessionManager",
            title: "Session",
            detail: "Idle",
            icon: "waveform",
            state: .idle,
            accessibilityIdentifier: "pipeline-session-step"
        )
    }

    private var inputStreamStep: PipelineStep {
        if viewModel.isMuted {
            return PipelineStep(
                id: "input",
                package: "SessionManager",
                title: "Input",
                detail: inputStreamDetail("Muted"),
                icon: "mic.slash.fill",
                state: .waiting,
                accessibilityIdentifier: "pipeline-input-step"
            )
        }
        guard viewModel.isAudioReady else {
            return PipelineStep(
                id: "input",
                package: "SessionManager",
                title: "Input",
                detail: "Idle",
                icon: "mic",
                state: .idle,
                accessibilityIdentifier: "pipeline-input-step"
            )
        }
        let snapshot = viewModel.lastInputStreamOperationReport?.snapshot ?? viewModel.lastVoiceProcessingOperationReport?.snapshot
        let isRunning = snapshot?.isRunning ?? viewModel.isMicrophoneCaptureRunning
        return PipelineStep(
            id: "input",
            package: "SessionManager",
            title: "Input",
            detail: inputStreamDetail(isRunning ? "Run" : "Starting"),
            icon: isRunning ? "mic.fill" : "mic",
            state: isRunning ? .passing : .waiting,
            accessibilityIdentifier: "pipeline-input-step"
        )
    }

    private var mixerBusStep: PipelineStep {
        guard viewModel.isAudioReady else {
            return PipelineStep(
                id: "mixer",
                package: "AudioMixer",
                title: "TX Bus",
                detail: "Idle",
                icon: "slider.horizontal.3",
                state: .idle,
                accessibilityIdentifier: "pipeline-mixer-step"
            )
        }
        let bus = viewModel.mixerBusSnapshot(id: "tx-bus")
        return PipelineStep(
            id: "mixer",
            package: "AudioMixer",
            title: "TX Bus",
            detail: bus.map { "\($0.sourceCount) in / \($0.effectCount) FX" } ?? "Snapshot waiting",
            icon: "slider.horizontal.3",
            state: .passing,
            accessibilityIdentifier: "pipeline-mixer-step"
        )
    }

    private var mixerEffectChainStep: PipelineStep {
        guard viewModel.isAudioReady else {
            return PipelineStep(
                id: "effect-chain",
                package: "AudioMixer",
                title: "FX Chain",
                detail: "Idle",
                icon: "wand.and.sparkles",
                state: .idle,
                accessibilityIdentifier: "pipeline-effects-step"
            )
        }
        let state = effectChainState
        return PipelineStep(
            id: "effect-chain",
            package: "AudioMixer",
            title: "FX Chain",
            detail: effectChainPipelineDetail,
            icon: "wand.and.sparkles",
            state: state,
            accessibilityIdentifier: "pipeline-effects-step"
        )
    }

    private var codecStep: PipelineStep {
        guard viewModel.isAudioReady else {
            return PipelineStep(
                id: "codec",
                package: "Codec",
                title: "Codec",
                detail: "Idle",
                icon: "cpu",
                state: .idle,
                accessibilityIdentifier: "pipeline-codec-step"
            )
        }
        let isFallback = viewModel.preferredTransmitCodec != viewModel.selectedTransmitCodec
        return PipelineStep(
            id: "codec",
            package: "Codec",
            title: "Codec",
            detail: isFallback ? "\(codecPipelineDetail) / Fallback" : codecPipelineDetail,
            icon: isFallback ? "cpu" : "cpu.fill",
            state: isFallback ? .waiting : codecState,
            accessibilityIdentifier: "pipeline-codec-step"
        )
    }

    private var rtcStep: PipelineStep {
        guard viewModel.isAudioReady else {
            return PipelineStep(
                id: "rtc",
                package: "RTC",
                title: "RTC",
                detail: "Media Idle",
                icon: "dot.radiowaves.left.and.right",
                state: .idle,
                accessibilityIdentifier: "pipeline-rtc-step"
            )
        }
        guard viewModel.selectedGroupConnectionState == .localConnected || viewModel.selectedGroupConnectionState == .internetConnected else {
            return PipelineStep(
                id: "rtc",
                package: "RTC",
                title: "RTC",
                detail: "Control Waiting",
                icon: "dot.radiowaves.left.and.right",
                state: .waiting,
                accessibilityIdentifier: "pipeline-rtc-step"
            )
        }
        guard viewModel.sentVoicePacketCount > 0 else {
            return PipelineStep(
                id: "rtc",
                package: "RTC",
                title: "RTC",
                detail: "\(viewModel.routeLabel) Ready",
                icon: "dot.radiowaves.left.and.right",
                state: .waiting,
                accessibilityIdentifier: "pipeline-rtc-step"
            )
        }
        return PipelineStep(
            id: "rtc",
            package: "RTC",
            title: "RTC",
            detail: "\(viewModel.routeLabel) TX \(viewModel.sentVoicePacketCount)",
            icon: "dot.radiowaves.left.and.right",
            state: .passing,
            accessibilityIdentifier: "pipeline-rtc-step"
        )
    }

    private var effectChainState: PipelineStepState {
        aggregateState(transmitEffectStages.map(\.state))
    }

    private var codecState: PipelineStepState {
        viewModel.isVoiceActive ? .passing : .waiting
    }

    private var transmitEffectStages: [EffectChainStage] {
        viewModel.transmitEffectChainSnapshot.stages.map(EffectChainStage.init(snapshot:))
    }

    private var effectChainPipelineDetail: String {
        viewModel.transmitEffectChainSnapshot.summary
    }

    private func inputStreamDetail(_ prefix: String) -> String {
        let snapshot = viewModel.lastInputStreamOperationReport?.snapshot ?? viewModel.lastVoiceProcessingOperationReport?.snapshot
        guard let snapshot else { return prefix }
        return "\(prefix) / \(streamFormatSummary(snapshot.actualHardwareFormat)) / F \(snapshot.processedFrameCount)"
    }

    private func streamFormatSummary(_ format: AudioFormat) -> String {
        "\(Int(format.sampleRate / 1_000))k/\(format.channelCount)ch"
    }

    private var codecPipelineDetail: String {
        let requested = codecShortLabel(viewModel.preferredTransmitCodec)
        let selected = codecShortLabel(viewModel.selectedTransmitCodec)
        if requested == selected { return selected }
        return "\(requested) -> \(selected)"
    }

    private func codecShortLabel(_ codec: AudioCodecIdentifier) -> String {
        if codec == .pcm16 { return "PCM" }
        if codec == .mpeg4AACELDv2 { return "AAC" }
        if codec == .opus { return "Opus" }
        return codec.rawValue
    }

    private func aggregateState(_ states: [PipelineStepState]) -> PipelineStepState {
        if states.contains(.blocked) { return .blocked }
        if states.contains(.waiting) { return .waiting }
        if states.contains(.passing) { return .passing }
        return .idle
    }
}

struct EffectChainStage: Equatable, Identifiable {
    let id: String
    let package: String
    let name: String
    let shortLabel: String
    let detail: String
    let state: PipelineStepState

    nonisolated init(
        id: String,
        package: String,
        name: String,
        shortLabel: String,
        detail: String,
        state: PipelineStepState
    ) {
        self.id = id
        self.package = package
        self.name = name
        self.shortLabel = shortLabel
        self.detail = detail
        self.state = state
    }
}

extension EffectChainStage {
    nonisolated init(snapshot: AudioEffectStageSnapshot) {
        self.init(
            id: snapshot.id,
            package: snapshot.package,
            name: snapshot.name,
            shortLabel: snapshot.shortLabel,
            detail: snapshot.detail,
            state: PipelineStepState(snapshot.state)
        )
    }
}

struct PipelineStep: Equatable, Identifiable {
    let id: String
    let package: String
    let title: String
    let detail: String
    let icon: String
    let state: PipelineStepState
    let accessibilityIdentifier: String
}

enum PipelineStepState: Equatable {
    case passing
    case waiting
    case blocked
    case idle

    var color: Color {
        switch self {
        case .passing:
            AppColorPalette.success
        case .waiting:
            AppColorPalette.warning
        case .blocked:
            AppColorPalette.danger
        case .idle:
            AppColorPalette.neutral
        }
    }
}

extension PipelineStepState {
    nonisolated init(_ effectState: AudioEffectStageRuntimeState) {
        switch effectState {
        case .active:
            self = .passing
        case .waiting, .unavailable:
            self = .waiting
        case .bypassed, .idle:
            self = .idle
        }
    }
}

struct CompactPipelineHeader: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.m) {
                titleLabel

                Spacer(minLength: AppSpacing.m)

                detailText(lineLimit: 1, fixedHorizontal: true)
            }

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                titleLabel
                detailText(lineLimit: 2, fixedHorizontal: false)
            }
        }
    }

    private var titleLabel: some View {
        Label(title, systemImage: systemImage)
            .font(AppTypography.sectionTitle)
    }

    private func detailText(lineLimit: Int, fixedHorizontal: Bool) -> some View {
        Text(detail)
            .font(AppTypography.caption2Mono)
            .foregroundStyle(AppColorPalette.textSecondary)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: fixedHorizontal, vertical: true)
    }
}

struct CompactPipelineStepRow: View {
    let step: PipelineStep
    let accessibilityIdentifier: String

    init(step: PipelineStep, accessibilityIdentifier: String? = nil) {
        self.step = step
        self.accessibilityIdentifier = accessibilityIdentifier ?? step.accessibilityIdentifier
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideRow
            narrowRow
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.package) \(step.title)")
        .accessibilityValue(step.detail)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var wideRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.m) {
            statusDot(size: 8, topPadding: 0)

            Image(systemName: step.icon)
                .font(AppTypography.caption)
                .foregroundStyle(step.state.color)
                .frame(width: AppSize.iconS, alignment: .center)
                .accessibilityHidden(true)

            Text(title)
                .font(AppTypography.captionStrong)
                .foregroundStyle(AppColorPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 82, alignment: .leading)

            Text(step.package)
                .font(AppTypography.caption2)
                .foregroundStyle(AppColorPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: 104, alignment: .leading)

            Text(step.detail)
                .font(AppTypography.caption2Mono)
                .foregroundStyle(step.state.color)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var narrowRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.s) {
            statusDot(size: 8, topPadding: 5)

            Image(systemName: step.icon)
                .font(AppTypography.caption)
                .foregroundStyle(step.state.color)
                .frame(width: AppSize.iconS, alignment: .center)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
                    Text(step.title)
                        .font(AppTypography.captionStrong)
                        .foregroundStyle(AppColorPalette.textPrimary)
                        .lineLimit(1)

                    Text(step.package)
                        .font(AppTypography.caption2)
                        .foregroundStyle(AppColorPalette.textTertiary)
                        .lineLimit(1)
                }

                Text(step.detail)
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(step.state.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusDot(size: CGFloat, topPadding: CGFloat) -> some View {
        Circle()
            .fill(step.state.color)
            .frame(width: size, height: size)
            .padding(.top, topPadding)
            .accessibilityHidden(true)
    }

    private var title: String {
        step.title
    }
}

struct CompactEffectChainGroup: View {
    let step: PipelineStep
    let title: String
    let accessibilityIdentifier: String
    let stageIdentifierPrefix: String
    let stages: [EffectChainStage]

    private let columns = [
        GridItem(.adaptive(minimum: 124), spacing: AppSpacing.xs, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            CompactPipelineStepRow(step: step, accessibilityIdentifier: "\(accessibilityIdentifier)-summary")

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
                    Text(title)
                        .font(AppTypography.caption2)
                        .foregroundStyle(AppColorPalette.textTertiary)

                    Text("\(stages.count) stages")
                        .font(AppTypography.caption2Mono)
                        .foregroundStyle(step.state.color)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: AppSpacing.xs) {
                    ForEach(stages) { stage in
                        EffectChainStageChip(stage: stage)
                            .accessibilityIdentifier("\(stageIdentifierPrefix)-\(stage.id)")
                    }
                }
            }
            .padding(.leading, CompactPipelineLayout.childIndent)
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

enum CompactPipelineLayout {
    static let childIndent: CGFloat = AppSize.iconS + AppSpacing.l + 8
}

struct EffectChainStageChip: View {
    let stage: EffectChainStage

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.s) {
            Circle()
                .fill(stage.state.color)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(stage.name)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AppColorPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(stage.detail)
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(stage.state.color)
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.s)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColorPalette.panelSurface.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stage.name)
        .accessibilityValue("\(stage.package), \(stage.detail)")
    }
}
