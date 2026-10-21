import SwiftUI

struct DiagnosticsOverviewGrid: View {
    let rows: [DiagnosticsOverviewRow]

    private let columns = [
        GridItem(.adaptive(minimum: 260), spacing: AppSpacing.l, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            Text("Current Overview")
                .font(AppTypography.sectionTitle)

            LazyVGrid(columns: columns, alignment: .leading, spacing: AppSpacing.l) {
                ForEach(rows) { row in
                    DiagnosticsOverviewCard(row: row)
                }
            }
        }
        .accessibilityIdentifier("diagnosticsOverviewGrid")
    }
}

private struct DiagnosticsOverviewCard: View {
    let row: DiagnosticsOverviewRow

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.l) {
            Image(systemName: row.icon)
                .frame(width: AppSize.iconS)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(row.title)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AppColorPalette.textSecondary)
                Text(row.summary)
                    .font(AppTypography.footnoteStrong)
                    .foregroundStyle(AppColorPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.detail)
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(AppColorPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appDiagnosticsCardStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        .accessibilityValue("\(row.summary), \(row.detail)")
        .accessibilityIdentifier(row.accessibilityIdentifier)
    }

    private var color: Color {
        switch row.severity {
        case .neutral:
            AppColorPalette.neutral
        case .ok:
            AppColorPalette.success
        case .warning:
            AppColorPalette.warning
        case .error:
            AppColorPalette.danger
        }
    }
}
