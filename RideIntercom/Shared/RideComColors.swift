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
    #if os(macOS)
    static let screenBackground = Color(nsColor: .windowBackgroundColor)
    #else
    static let screenBackground = LinearGradient(colors: [backgroundTop, backgroundBase],
                                                startPoint: .top, endPoint: .bottom)
    #endif
}
