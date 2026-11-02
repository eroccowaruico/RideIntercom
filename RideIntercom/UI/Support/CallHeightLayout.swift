import SwiftUI

/// Keeps platform-specific size-class access outside the call screen.
struct CallHeightLayout<Content: View>: View {
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @ViewBuilder let content: (Bool, Bool) -> Content

    var body: some View {
        GeometryReader { geometry in
            #if os(iOS)
            content(verticalSizeClass == .compact, geometry.size.width >= AppSize.twoColumnMinimumWidth)
            #else
            content(false, geometry.size.width >= AppSize.twoColumnMinimumWidth)
            #endif
        }
    }
}

extension View {
    func appDetailedCallHeroStyle() -> some View {
        #if os(macOS)
        self.padding(AppSpacing.xl).appCallHeroStyle()
        #else
        self.appCallCardStyle()
        #endif
    }
}
