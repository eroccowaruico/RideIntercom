import SwiftUI

/// Advanced's list and member row actions.
extension View {
    /// Long-press and swipe offer the settings entry first, then Delete, which always asks first:
    /// Delete only fills `pending`; the list shows the alert (`destinationDeleteConfirmation`).
    func advancedDestinationRowActions(_ settingsTitle: LocalizedStringKey, settings: @escaping () -> Void,
                                       canDelete: Bool = true, pending: Binding<PendingDestinationDelete?>,
                                       name: String, endsCall: Bool = false,
                                       delete: @escaping () -> Void) -> some View {
        let ask = { pending.wrappedValue = PendingDestinationDelete(name: name, endsCall: endsCall, perform: delete) }
        return swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canDelete {
                Button(role: .destructive, action: ask) { Label("Delete", systemImage: "trash") }
            }
            Button(action: settings) { Label(settingsTitle, systemImage: "gearshape") }
        }
        .contextMenu {
            Button(action: settings) { Label(settingsTitle, systemImage: "gearshape") }
            if canDelete {
                Button(role: .destructive, action: ask) { Label("Delete", systemImage: "trash") }
            }
        }
    }

    /// Member names are changed from the row's menu or swipe, not a pencil button.
    func advancedMemberRowActions(edit: @escaping () -> Void, canRemove: Bool = true,
                                  pending: Binding<PendingMemberRemoval?>, name: String,
                                  remove: @escaping () -> Void) -> some View {
        let ask = { pending.wrappedValue = PendingMemberRemoval(name: name, perform: remove) }
        return swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canRemove { Button(role: .destructive, action: ask) { Label("Remove", systemImage: "person.badge.minus") } }
            Button(action: edit) { Label("Edit Name", systemImage: "pencil") }
        }
        .contextMenu {
            Button(action: edit) { Label("Edit Name", systemImage: "pencil") }
            if canRemove { Button(role: .destructive, action: ask) { Label("Remove", systemImage: "person.badge.minus") } }
        }
    }
}
