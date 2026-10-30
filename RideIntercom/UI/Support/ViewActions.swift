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
        .contextMenu {
            if isEnabled {
                Button(role: .destructive, action: action) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}
