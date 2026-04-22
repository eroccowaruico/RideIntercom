import SwiftUI

extension View {
    func appProminentButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .tint(AppColorPalette.buttonProminentBackground)
            .foregroundStyle(AppColorPalette.buttonProminentForeground)
    }
}
