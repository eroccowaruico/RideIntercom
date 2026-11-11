import SwiftUI

/// Advanced user settings: the implementation's names, the stored shared name, call requests and the call invite.
struct AdvancedUserSettingsView: View {
    @Bindable var viewModel: IntercomViewModel
    let user: SavedUser
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var confirmsDelete = false

    init(viewModel: IntercomViewModel, user: SavedUser) {
        self.viewModel = viewModel; self.user = user
        _name = State(initialValue: user.resolvedDisplayName)
    }

    private var currentUser: SavedUser { viewModel.savedUsers.first { $0.id == user.id } ?? user }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name on this device", text: $name, prompt: Text(verbatim: currentUser.displayName)).accessibilityIdentifier("savedUserNameField")
                LabeledContent("Name shared by this person", value: currentUser.displayName)
                    .accessibilityIdentifier("savedUserOriginalName")
                Button("Use Shared Name") {
                    if viewModel.resetSavedUserName(user.id) { dismiss() }
                }
                .accessibilityIdentifier("resetUserNameButton")
                Text("Your name for this person stays on this device. Use Shared Name removes your edit and follows their name updates.").font(.footnote)
                if let call = viewModel.existingDirectCall(for: user.id), viewModel.canShareGroup(call.id) {
                    Section {
                        CallInvitationButton(viewModel: viewModel, group: call, accessibilityIdentifier: "userSettingsInviteButton",
                                             bindsToGroup: true)
                    }
                }
                Section {
                    Button("Delete User", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                        .disabled(!viewModel.canEditSavedGroups)
                        .accessibilityIdentifier("deleteUserButton")
                }
                if let message = viewModel.groupErrorMessage { Text(LocalizedStringKey(message)).foregroundStyle(AppColorPalette.danger) }
            }
            .formStyle(.grouped)
            .screenBackground(AppColorPalette.listScreenBackground)
            .navigationTitle("User Settings")
            .accessibilityIdentifier("userSettingsView")
            .alert("Delete User?", isPresented: $confirmsDelete) {
                Button("Delete User", role: .destructive) {
                    if viewModel.removeSavedUser(user.id) { dismiss() }
                }
                .accessibilityIdentifier("confirmDeleteUserButton")
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Groups and a call in progress are kept.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("closeUserSettingsButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if viewModel.renameSavedUser(user.id, displayName: name) { dismiss() }
                    }
                    .disabled(!IntercomGroup.isValidName(name))
                    .accessibilityIdentifier("saveUserNameButton")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, idealWidth: 480, minHeight: 280)
        #endif
    }
}
