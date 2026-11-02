import SwiftUI

/// One asset catalog is compiled into App, Watch and Widget bundles.
/// Named colors preserve system appearance and increased-contrast adaptation.
enum RideComColors {
    static let accent = Color("AccentColor")
    static let success = Color("RideGreen")
    static let warning = Color("Warning")
    static let danger = Color("Danger")
    static let voiceLevel = Color("VoiceAqua")
    static let deepNavy = Color("DeepNavy")
    static let backgroundTop = Color("BackgroundTop")
    static let backgroundBase = Color("BackgroundBase")
    static let screenBackground = LinearGradient(colors: [backgroundTop, backgroundBase],
                                                startPoint: .top, endPoint: .bottom)
}
