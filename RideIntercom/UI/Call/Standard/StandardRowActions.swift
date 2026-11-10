import SwiftUI

/// Standard's list and member row actions: a swipe, plus the same items in the screen the row opens.
/// No long-press menu (it is hard to find); a Mac, which cannot swipe with a mouse, gets them on right-click.
extension View {
    /// The swipe offers the settings entry, then Delete when the row can be deleted (Users). Delete always
    /// asks first: it only fills `pending`; the list shows the alert (`destinationDeleteConfirmation`).
    func standardDestinationRowActions(_ settingsTitle: LocalizedStringKey, settings: @escaping () -> Void,
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
        .macRightClickMenu {
            Button(action: settings) { Label(settingsTitle, systemImage: "gearshape") }
            if canDelete {
                Button(role: .destructive, action: ask) { Label("Delete", systemImage: "trash") }
            }
        }
    }

    /// A group member's swipe removes them (asks first); the row's tap opens the member's own page.
    func standardMemberRowActions(canRemove: Bool = true, pending: Binding<PendingMemberRemoval?>, name: String,
                                  remove: @escaping () -> Void) -> some View {
        let ask = { pending.wrappedValue = PendingMemberRemoval(name: name, perform: remove) }
        return swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canRemove { Button(role: .destructive, action: ask) { Label("Remove", systemImage: "person.badge.minus") } }
        }
        .macRightClickMenu {
            if canRemove { Button(role: .destructive, action: ask) { Label("Remove", systemImage: "person.badge.minus") } }
        }
    }
}
