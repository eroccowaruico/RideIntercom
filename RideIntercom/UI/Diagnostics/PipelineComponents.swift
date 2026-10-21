import SwiftUI
import AudioCore
import AudioMixer
import RTC
import SessionManager

extension PipelineStepState {
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
