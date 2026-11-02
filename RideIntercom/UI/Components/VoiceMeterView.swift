import SwiftUI
import RTC

struct VoiceMeterView: View {
    let level: Float
    let peakLevel: Float
    let isMuted: Bool
    var showsValueText: Bool = true

    private var indicator: VoiceLevelIndicatorState {
        VoiceLevelIndicatorState(level: level, peakLevel: peakLevel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppColorPalette.meterTrack)
                    Capsule()
                        .fill(meterColor)
                        .frame(width: geometry.size.width * CGFloat(indicator.displayLevel))
                    Rectangle()
                        .fill(.primary)
                        .frame(width: AppSize.meterPeakWidth, height: AppSize.meterHeight)
                        .offset(x: max(0, geometry.size.width * CGFloat(indicator.displayPeakLevel) - 1))
                }
            }
            .frame(height: AppSize.meterHeight)

            if showsValueText {
                Text(isMuted ? "MUTED" : "LEVEL \(indicator.levelPercent)  PEAK \(indicator.peakPercent)")
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(AppColorPalette.textPrimary)
                    .accessibilityIdentifier("voiceMeterValueLabel")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio level")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if isMuted {
            return "Muted"
        }
        return "Level \(indicator.levelPercent), peak \(indicator.peakPercent)"
    }

    private var meterColor: Color {
        if isMuted {
            return AppColorPalette.danger
        }

        return indicator.intensity == .silent ? AppColorPalette.neutral : AppColorPalette.voiceLevel
    }
}
