import SwiftUI

/// New Group and Invite Members: pick from your users, then one prominent action.
/// Rows only select; renaming and deleting stay in each person's settings.
struct StandardMemberSelection: View {
    @Bindable var viewModel: IntercomViewModel
    let groupID: UUID?
    let onSaved: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: MemberSelection

    init(viewModel: IntercomViewModel, groupID: UUID?, onSaved: @escaping (UUID?) -> Void) {
        self.viewModel = viewModel
        self.groupID = groupID
        self.onSaved = onSaved
        _selection = State(initialValue: MemberSelection(viewModel: viewModel, groupID: groupID))
    }

    /// Inviting says what it does; creating says whether it also connects.
    private var actionTitle: LocalizedStringKey {
        if groupID != nil { return "Send Invitation" }
        return viewModel.hasAnyActiveGroupConnection ? "Create Group" : "Create and Connect"
    }

    var body: some View {
        Form {
            if groupID == nil {
                Section("Group name") {
                    TextField("Group name", text: $selection.typedName, prompt: selection.suggestedName.map { Text(verbatim: $0) })
                        .accessibilityIdentifier("savedUsersGroupNameField")
                }
            }
            if !selection.users.isEmpty {
                Section("Your Users") {
                    ForEach(selection.users) { user in
                        let isSelected = selection.selected.contains(user.id)
                        Button { selection.toggle(user.id) } label: {
                            HStack(spacing: AppSpacing.m) {
                                DestinationAvatar(isGroup: false).accessibilityHidden(true)
                                Text(verbatim: user.resolvedDisplayName).foregroundStyle(Color.primary).lineLimit(2)
                                Spacer(minLength: AppSpacing.s)
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("selectUser-\(user.id)")
                    }
                }
            }
            if let message = viewModel.groupErrorMessage {
                Section {
                    Text(LocalizedStringKey(message)).foregroundStyle(AppColorPalette.danger)
                        .accessibilityIdentifier("savedUsersErrorLabel")
                }
            }
        }
        .formStyle(.grouped)
        // The count and the one action stay below the list, reachable however long it is.
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: AppSpacing.s) {
                Text("\(selection.memberCount)/8 people including you")
                    .font(.footnote).foregroundStyle(Color.secondary)
                    .accessibilityIdentifier("memberSelectionCount")
                Button(actionTitle) {
                    if case .some(let added) = selection.save() { onSaved(added) }
                }
                .appProminentButtonStyle()
                .frame(maxWidth: .infinity)
                .disabled(!selection.canSave)
                .accessibilityIdentifier("saveUserSelectionButton")
            }
            .padding(.horizontal, AppSpacing.screen)
            .padding(.vertical, AppSpacing.s)
        }
        .navigationTitle(LocalizedStringKey(groupID == nil ? "New Group" : "Invite Members"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.accessibilityIdentifier("closeSavedUsersButton")
            }
        }
    }
}
