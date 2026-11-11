import SwiftUI

/// The person's settings: your name for them, their own name, and deleting. Everyone you registered may notify
/// you; notifications are set in the OS alone, so there is no switch per person.
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
                }
                // Their own name, its own group as in the design: read only, in the secondary color.
                Section("Their Own Name") {
                    Text(verbatim: current.displayName).foregroundStyle(.secondary)
                        .accessibilityIdentifier("savedUserOriginalName")
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
