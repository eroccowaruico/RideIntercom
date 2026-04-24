import SwiftUI

enum AppColorPalette {
    static let textPrimary: Color = .primary
    static let textSecondary: Color = .secondary
    static let textTertiary: Color = .secondary.opacity(0.72)

    static let danger: Color = .red
    static let success: Color = .green
    static let warning: Color = .orange
    static let info: Color = .blue
    static let neutral: Color = .secondary

    static let callScreenBackground: Color = Color.secondary.opacity(0.08)
    static let cardMaterial: Material = .regularMaterial
    static let diagnosticsCardMaterial: Material = .thinMaterial
    #if canImport(AppKit)
    static let panelSurface: Color = Color(nsColor: .windowBackgroundColor)
    #elseif canImport(UIKit)
    static let panelSurface: Color = Color(uiColor: .systemBackground)
    #else
    static let panelSurface: Color = .white
    #endif
    static let cardBorder: Color = Color.secondary.opacity(0.35)

    static let meterTrack: Color = Color.secondary.opacity(0.16)
    static let connectorNeutral: Color = Color.secondary.opacity(0.5)

    static let buttonProminentBackground: Color = .accentColor
    static let buttonProminentForeground: Color = .white
}

enum AppSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 10
    static let xl: CGFloat = 12
    static let xxl: CGFloat = 14
    static let screen: CGFloat = 16
}

enum AppCornerRadius {
    static let card: CGFloat = 8
}

enum AppBorderWidth {
    static let card: CGFloat = 1
}

enum AppSize {
    static let tapPrimary = CGSize(width: 44, height: 44)
    static let buttonPrimaryMinHeight: CGFloat = 44
    static let buttonSecondaryMinHeight: CGFloat = 36
    static let buttonMacMinHeight: CGFloat = 28
    static let iconS: CGFloat = 24
    static let iconM: CGFloat = 28
    static let iconL: CGFloat = 32
    static let connector = CGSize(width: 10, height: 48)
    static let meterPeakWidth: CGFloat = 2
    static let meterHeight: CGFloat = 16
}

enum AppTypography {
    static let title: Font = .headline
    static let sectionTitle: Font = .headline
    static let rowTitle: Font = .headline
    static let bodyStrong: Font = .body.weight(.semibold)
    static let body: Font = .body
    static let subheadline: Font = .subheadline
    static let subheadlineStrong: Font = .subheadline.weight(.semibold)
    static let caption: Font = .caption
    static let captionStrong: Font = .caption.weight(.semibold)
    static let captionStrongMono: Font = .caption.weight(.semibold).monospacedDigit()
    static let caption2: Font = .caption2
    static let caption2Mono: Font = .caption2.monospacedDigit()
    static let bodyMono: Font = .body.monospacedDigit()
    static let footnoteMono: Font = .footnote.monospacedDigit()
    static let footnoteStrong: Font = .footnote.weight(.semibold)
    static let footnote: Font = .footnote
}
extension View {
    private var platformButtonMinHeight: CGFloat {
        #if canImport(AppKit)
        return AppSize.buttonMacMinHeight
        #else
        return AppSize.buttonPrimaryMinHeight
        #endif
    }

    func appProminentButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .tint(AppColorPalette.buttonProminentBackground)
            .foregroundStyle(AppColorPalette.buttonProminentForeground)
            .frame(minHeight: max(AppSize.buttonPrimaryMinHeight, platformButtonMinHeight))
    }

    func appSecondaryButtonStyle() -> some View {
        buttonStyle(.bordered)
            .frame(minHeight: max(AppSize.buttonSecondaryMinHeight, platformButtonMinHeight))
    }

    func appCallCardStyle() -> some View {
        appCardStyle(background: AnyShapeStyle(AppColorPalette.cardMaterial))
    }

    func appDiagnosticsCardStyle() -> some View {
        appCardStyle(background: AnyShapeStyle(AppColorPalette.diagnosticsCardMaterial))
    }

    func appPanelCardStyle(borderColor: Color? = nil) -> some View {
        appCardStyle(
            background: AnyShapeStyle(AppColorPalette.panelSurface),
            borderColor: borderColor ?? AppColorPalette.cardBorder
        )
    }

    private func appCardStyle(background: AnyShapeStyle, borderColor: Color = AppColorPalette.cardBorder) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppCornerRadius.card)
        return padding(AppSpacing.xl)
            .background(background)
            .overlay(shape.stroke(borderColor, lineWidth: AppBorderWidth.card))
            .clipShape(shape)
    }
}

