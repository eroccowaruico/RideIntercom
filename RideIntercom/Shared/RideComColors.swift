import SwiftUI

/// One asset catalog is compiled into App, Watch and Widget bundles.
/// Named colors preserve system appearance and increased-contrast adaptation.
enum RideComColors {
    #if os(macOS)
    static let accent = Color.accentColor
    #else
    static let accent = Color("AccentColor")
    #endif
    static let success = Color("RideGreen")
    static let warning = Color("Warning")
    static let danger = Color("Danger")
    static let voiceLevel = Color("VoiceAqua")
    static let deepNavy = Color("DeepNavy")
    static let backgroundTop = Color("BackgroundTop")
    static let backgroundBase = Color("BackgroundBase")
    /// The screen's backdrop: top to base until `end` (a fraction of the height), then base.
    /// macOS keeps the standard window background.
    #if os(macOS)
    static func screenBackground(endingAt end: Double) -> Color { Color(nsColor: .windowBackgroundColor) }
    #else
    static func screenBackground(endingAt end: Double) -> LinearGradient {
        LinearGradient(stops: [.init(color: backgroundTop, location: 0), .init(color: backgroundBase, location: end)],
                       startPoint: .top, endPoint: .bottom)
    }
    #endif
}
