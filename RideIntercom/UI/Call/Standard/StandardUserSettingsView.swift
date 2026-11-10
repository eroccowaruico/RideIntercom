import SwiftUI

/// The person's settings: your name for them, their own name, whether they can ring you, and deleting.
struct StandardUserSettingsView: View {
    @Bindable var viewModel: IntercomViewModel
    let user: SavedUser
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var confirmsDelete = false

    init(viewModel: IntercomViewModel, user: SavedUser) {
        self.viewModel = viewModel
        self.user = user
        // Opens with your own name for them; empty shows (and returns to) their own name.
        _name = State(initialValue: user.localName ?? "")
    }

    private var current: SavedUser { viewModel.savedUsers.first { $0.id == user.id } ?? user }
    private var typed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name on This Device") {
                    TextField("Name on This Device", text: $name, prompt: Text(verbatim: current.displayName))
                        .accessibilityIdentifier("savedUserNameField")
                    LabeledContent("Their Own Name", value: current.displayName)
                        .accessibilityIdentifier("savedUserOriginalName")
                }
                Section {
                    Toggle("Receive Calls from This Person", isOn: Binding(
                        get: { viewModel.notifications.allowsIncoming(from: user.id) },
                        set: { allowed in Task { await viewModel.setCallNotificationsAllowed(allowed, for: user.id) } }))
                        .disabled(!viewModel.notifications.canUseNotifications || viewModel.notifications.isBusy)
                        .accessibilityIdentifier("allowCallRequests-\(user.id)")
                    // Choosing this person rings them; the call sheet shows how it went.
                    if let message = viewModel.notifications.message { Text(LocalizedStringKey(message)).foregroundStyle(.secondary) }
                }
                if let message = viewModel.groupErrorMessage {
                    Section { Text(LocalizedStringKey(message)).foregroundStyle(AppColorPalette.danger) }
                }
                Section {
                    Button("Delete User", role: .destructive) { confirmsDelete = true }
                        .disabled(!viewModel.canEditSavedGroups)
                        .accessibilityIdentifier("deleteUserButton")
                }
            }
            .formStyle(.grouped)
            .screenBackground(AppColorPalette.listScreenBackground)
            .navigationTitle("User Settings")
            .accessibilityIdentifier("userSettingsView")
            .alert("Delete \(current.resolvedDisplayName)?", isPresented: $confirmsDelete) {
                Button("Delete", role: .destructive) {
                    if viewModel.removeSavedUser(user.id) { dismiss() }
                }
                .accessibilityIdentifier("confirmDeleteUserButton")
                Button("Cancel", role: .cancel) { }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("closeUserSettingsButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!typed.isEmpty && !IntercomGroup.isValidName(typed))
                        .accessibilityIdentifier("saveUserNameButton")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, idealWidth: 480, minHeight: 280)
        #endif
    }

    /// An empty name, or their own name, goes back to following their own name.
    private func save() {
        let saved = typed.isEmpty || typed == current.displayName
            ? viewModel.resetSavedUserName(user.id)
            : viewModel.renameSavedUser(user.id, displayName: typed)
        if saved { dismiss() }
    }
}
