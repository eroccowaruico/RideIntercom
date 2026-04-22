import SwiftUI

enum AppColorPalette {
    static let textSecondary: Color = .secondary
    static let textTertiary: Color = .secondary.opacity(0.72)

    static let danger: Color = .red
    static let success: Color = .green
    static let warning: Color = .orange
    static let info: Color = .blue
    static let neutral: Color = .secondary

    static let callScreenBackground: Color = Color.secondary.opacity(0.08)
    static let cardMaterial: Material = .regularMaterial
    static let cardBorder: Color = Color.secondary.opacity(0.35)

    static let meterTrack: Color = Color.secondary.opacity(0.16)
    static let connectorNeutral: Color = Color.secondary.opacity(0.5)

    static let buttonProminentBackground: Color = .accentColor
    static let buttonProminentForeground: Color = .white
}
