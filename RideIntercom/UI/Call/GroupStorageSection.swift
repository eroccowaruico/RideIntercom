import SwiftUI

struct GroupStorageSection: View {
    let message: String
    let canReset: Bool
    let canReload: Bool
    let reloadRequiresDisconnect: Bool
    let reload: () -> Void
    let reset: () -> Void
    @State private var confirmingReset = false

    var body: some View {
        Section("Saved Groups") {
            Label(message, systemImage: "externaldrive.badge.exclamationmark")
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("groupStorageStatus")
            Button("Reload Saved Groups", action: reload)
                .disabled(!canReload)
                .accessibilityIdentifier("reloadSavedGroupsButton")
            if reloadRequiresDisconnect {
                Text("Disconnect before reloading saved groups.").font(.footnote)
            }
            if canReset {
                Button("Reset Saved Groups…", role: .destructive) { confirmingReset = true }
                    .accessibilityIdentifier("resetSavedGroupsButton")
            }
        }
        .alert("Reset all saved groups?", isPresented: $confirmingReset) {
            Button("Reset Saved Groups", role: .destructive, action: reset)
                .accessibilityIdentifier("confirmResetSavedGroupsButton")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("cancelResetSavedGroupsButton")
        } message: {
            Text("This ends the current call and removes the group list and its keys. Unreadable data is preserved first. Your rider identity, audio settings, and Internet credentials stay unchanged. You will need new invitations.")
        }
    }
}
