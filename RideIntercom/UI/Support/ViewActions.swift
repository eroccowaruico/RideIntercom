import SwiftUI
import RTC

extension View {
    func appListCardRowStyle() -> some View {
        listRowInsets(EdgeInsets(top: AppSpacing.m, leading: AppSpacing.screen, bottom: AppSpacing.m, trailing: AppSpacing.screen))
            .listRowBackground(Color.clear)
    }

    func appDeleteActions(isEnabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isEnabled {
                Button(role: .destructive, action: action) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .macRightClickMenu {
            if isEnabled {
                Button(role: .destructive, action: action) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// A row's swipe items on a Mac's right-click. iPhone and iPad get no long-press menu.
    @ViewBuilder func macRightClickMenu(@ViewBuilder _ items: () -> some View) -> some View {
        #if os(macOS)
        contextMenu { items() }
        #else
        self
        #endif
    }
}
