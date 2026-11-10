import SwiftUI

enum AppColorPalette {
    static let textPrimary: Color = .primary
    static let textSecondary: Color = .secondary
    static let textTertiary: Color = .secondary.opacity(0.72)

    static let danger = RideComColors.danger
    static let success = RideComColors.success
    static let warning = RideComColors.warning
    static let info = RideComColors.accent
    static let voiceLevel = RideComColors.voiceLevel
    static let neutral: Color = .secondary

    /// The call sheet, sign-in and name input: the change reaches 45%, under the glass hero and controls.
    static let callScreenBackground = RideComColors.screenBackground(endingAt: 0.45)
    /// Lists, Settings and every Advanced screen: the change ends at 25%, so rows sit on one even color.
    static let listScreenBackground = RideComColors.screenBackground(endingAt: 0.25)
    #if os(macOS)
    static let panelSurface: Color = Color(nsColor: .windowBackgroundColor)
    #else
    static let panelSurface: Color = Color(uiColor: .systemBackground)
    #endif
    static let cardBorder: Color = Color.secondary.opacity(0.35)

    static let meterTrack: Color = Color.secondary.opacity(0.16)

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
    /// The system's side margin at regular width.
    static let regularMargin: CGFloat = 20
    static let callControls: CGFloat = 24
    static let destructiveSeparation: CGFloat = 32
}

enum AppCornerRadius {
    static let card: CGFloat = 8
}

enum AppBorderWidth {
    static let card: CGFloat = 1
}

enum AppSize {
    static let twoColumnMinimumWidth: CGFloat = 600
    static let callControlDiameter: CGFloat = 64
    static let callControlCompactDiameter: CGFloat = 56
    /// What `.glass`/`.glassProminent` add around a circular button's label (measured: a 64pt label drew a 78pt circle).
    static let callControlGlassPadding: CGFloat = 7
    static let singleColumnMaxWidth: CGFloat = 640
    /// One focused group: sign-in, name input, an empty state.
    static let focusedMaxWidth: CGFloat = 420
    static let callColumnMaxWidth: CGFloat = 560
    static let tapPrimary = CGSize(width: 44, height: 44)
    static let buttonPrimaryMinHeight: CGFloat = 44
    static let buttonSecondaryMinHeight: CGFloat = 36
    static let buttonMacMinHeight: CGFloat = 28
    static let iconS: CGFloat = 24
    static let iconM: CGFloat = 28
    static let meterPeakWidth: CGFloat = 2
    static let meterHeight: CGFloat = 16
}

enum AppTypography {
    static let destinationTitle: Font = .title.bold()
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
    static let footnoteStrong: Font = .footnote.weight(.semibold)
    static let footnote: Font = .footnote
}
extension View {
    private var platformButtonMinHeight: CGFloat {
        #if os(macOS)
        return AppSize.buttonMacMinHeight
        #else
        return AppSize.buttonPrimaryMinHeight
        #endif
    }

    func appProminentButtonStyle() -> some View {
        buttonStyle(.glassProminent)
            .controlSize(.large)
            .font(AppTypography.bodyStrong)
            .tint(AppColorPalette.buttonProminentBackground)
            .foregroundStyle(AppColorPalette.buttonProminentForeground)
            .frame(minHeight: max(AppSize.buttonPrimaryMinHeight, platformButtonMinHeight))
            // The full width of where it sits, never a capsule as wide as its words.
            .buttonSizing(.flexible)
            .frame(maxWidth: .infinity)
    }

    func appSecondaryButtonStyle() -> some View {
        buttonStyle(.glass)
            .frame(minHeight: max(AppSize.buttonSecondaryMinHeight, platformButtonMinHeight))
    }

    /// Only the call hero carries a subtle brand surface on native macOS.
    func appCallHeroStyle() -> some View {
        #if os(macOS)
        self.glassEffect(.regular.tint(RideComColors.accent.opacity(0.08)),
                         in: RoundedRectangle(cornerRadius: AppCornerRadius.card))
        #else
        self
        #endif
    }

    func appCallCardStyle() -> some View { appCardStyle() }

    func appDiagnosticsCardStyle() -> some View { appCardStyle() }

    private func appCardStyle() -> some View {
        let shape = RoundedRectangle(cornerRadius: AppCornerRadius.card)
        return padding(AppSpacing.xl)
            .glassEffect(.regular, in: shape)
            .overlay(shape.stroke(AppColorPalette.cardBorder, lineWidth: AppBorderWidth.card))
    }
}

/// Caps scroll content at the single-column width and centers it in the visible area, while the List
/// or Form itself (background and scroll indicator) still spans the whole area. A horizontal content
/// margin replaces the list's safe-area inset (the floating iPad sidebar), so the inset is added back.
private struct ReadableScrollWidth: ViewModifier {
    /// Nil keeps the system's margins (compact 16pt, regular 20pt), so sections stay inset rounded groups.
    @State private var margins: EdgeInsets?
    func body(content: Content) -> some View {
        content
            .contentMargins(.leading, margins?.leading, for: .scrollContent)
            .contentMargins(.trailing, margins?.trailing, for: .scrollContent)
            .onGeometryChange(for: EdgeInsets?.self) { proxy in
                let extra = max(0, (proxy.size.width - AppSize.singleColumnMaxWidth) / 2)
                // Only centre once the space beside the column is wider than the system's margin.
                guard extra > AppSpacing.regularMargin else { return nil }
                return EdgeInsets(top: 0, leading: proxy.safeAreaInsets.leading + extra,
                                  bottom: 0, trailing: proxy.safeAreaInsets.trailing + extra)
            } action: { margins = $0 }
    }
}

extension View {
    func readableScrollWidth() -> some View { modifier(ReadableScrollWidth()) }
}

extension View {
    /// The fixed backdrop behind a screen; a List or Form keeps its standard rows over it.
    func screenBackground(_ background: some ShapeStyle) -> some View {
        scrollContentBackground(.hidden).background(background)
    }
}
