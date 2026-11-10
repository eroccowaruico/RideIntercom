import SwiftUI

/// A group member's page, opened by tapping the member in Group Settings: your name for them on this device,
/// then Remove from Group (asks first) for those who may change the group. Titled with their name.
struct StandardGroupMemberView: View {
    @Bindable var viewModel: IntercomViewModel
    let groupID: UUID
    let member: GroupMember
    /// Nil when this person may not change the group's members.
    let remove: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var confirmsRemove = false

    init(viewModel: IntercomViewModel, groupID: UUID, member: GroupMember, remove: (() -> Void)?) {
        self.viewModel = viewModel; self.groupID = groupID; self.member = member; self.remove = remove
        // Opens with your own name for them; empty shows (and returns to) the name they share.
        _name = State(initialValue: member.localName ?? "")
    }

    private var current: GroupMember {
        viewModel.groups.first { $0.id == groupID }?.members.first { $0.id == member.id } ?? member
    }
    private var typed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name on This Device") {
                    TextField("Name on This Device", text: $name, prompt: Text(verbatim: current.displayName))
                        .accessibilityIdentifier("groupMemberNameField")
                }
                if let message = viewModel.groupErrorMessage {
                    Section { Text(LocalizedStringKey(message)).foregroundStyle(AppColorPalette.danger) }
                }
                if remove != nil {
                    Section {
                        Button("Remove from Group", role: .destructive) { confirmsRemove = true }
                            .accessibilityIdentifier("removeGroupMemberButton")
                    }
                }
            }
            .formStyle(.grouped)
            .screenBackground(AppColorPalette.listScreenBackground)
            .navigationTitle(Text(verbatim: current.resolvedDisplayName))
            .accessibilityIdentifier("groupMemberView")
            .alert(Text("Remove \(current.resolvedDisplayName) from the group?"), isPresented: $confirmsRemove) {
                Button("Remove", role: .destructive) { remove?(); dismiss() }
                    .accessibilityIdentifier("confirmRemoveMemberButton")
                Button("Cancel", role: .cancel) { }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!typed.isEmpty && !IntercomGroup.isValidName(typed))
                        .accessibilityIdentifier("saveGroupMemberNameButton")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, idealWidth: 480, minHeight: 240)
        #endif
    }

    /// An empty name, or their own name, goes back to following the name they share.
    private func save() {
        let saved = typed.isEmpty || typed == current.displayName
            ? viewModel.resetGroupMemberName(member.id, in: groupID)
            : viewModel.renameGroupMember(member.id, in: groupID, displayName: typed)
        if saved { dismiss() }
    }
}
