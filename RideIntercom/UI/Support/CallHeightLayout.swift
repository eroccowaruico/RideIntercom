import SwiftUI

/// Keeps platform-specific size-class access outside the call screen.
struct CallHeightLayout<Content: View>: View {
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        #if os(iOS)
        content(verticalSizeClass == .compact)
        #else
        content(false)
        #endif
    }
}
