import SwiftUI
import AudioCore
import AudioMixer
import RTC
import SessionManager

extension PipelineStepState {
    var statusSymbol: String {
        switch self {
        case .passing: "checkmark.circle.fill"
        case .waiting: "pause.circle.fill"
        case .blocked: "xmark.octagon.fill"
        case .idle: "circle.dashed"
        }
    }

    var statusText: String {
        switch self {
        case .passing: "Passing"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        case .idle: "Idle"
        }
    }

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
                detailText(lineLimit: nil, fixedHorizontal: false)
            }
        }
    }

    private var titleLabel: some View {
        Label(title, systemImage: systemImage)
            .font(AppTypography.sectionTitle)
    }

    private func detailText(lineLimit: Int?, fixedHorizontal: Bool) -> some View {
        Text(detail)
            .font(AppTypography.caption2Mono)
            .foregroundStyle(AppColorPalette.textSecondary)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: fixedHorizontal, vertical: true)
    }
}

struct CompactPipelineStepRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let step: PipelineStep
    let accessibilityIdentifier: String

    init(step: PipelineStep, accessibilityIdentifier: String? = nil) {
        self.step = step
        self.accessibilityIdentifier = accessibilityIdentifier ?? step.accessibilityIdentifier
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                narrowRow
            } else {
                ViewThatFits(in: .horizontal) {
                    wideRow
                    narrowRow
                }
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.package) \(step.title)")
        .accessibilityValue("\(step.state.statusText), \(step.detail)")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var wideRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.m) {
            statusSymbol(topPadding: 0)

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
            statusSymbol(topPadding: 5)

            Image(systemName: step.icon)
                .font(AppTypography.caption)
                .foregroundStyle(step.state.color)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(step.title)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AppColorPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.package)
                    .font(AppTypography.caption2)
                    .foregroundStyle(AppColorPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.detail)
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(step.state.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusSymbol(topPadding: CGFloat) -> some View {
        Image(systemName: step.state.statusSymbol)
            .font(AppTypography.caption)
            .foregroundStyle(step.state.color)
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
            Image(systemName: stage.state.statusSymbol)
                .font(AppTypography.caption)
                .foregroundStyle(stage.state.color)
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(stage.name)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AppColorPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(stage.detail)
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(stage.state.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.s)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColorPalette.panelSurface.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stage.name)
        .accessibilityValue("\(stage.state.statusText), \(stage.package), \(stage.detail)")
    }
}
