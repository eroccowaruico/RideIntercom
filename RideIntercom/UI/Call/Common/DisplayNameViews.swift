import SwiftUI

struct LocalDisplayNameSection: View {
    @Bindable var viewModel: IntercomViewModel
    @State private var name = ""
    @State private var saved = false

    var body: some View {
        Section {
            TextField("Your name", text: $name)
                .accessibilityIdentifier("localDisplayNameField")
            Button("Save Name") { saved = viewModel.setLocalDisplayName(name) }
                .disabled(!IntercomGroup.isValidName(name.trimmingCharacters(in: .whitespacesAndNewlines)))
                .accessibilityIdentifier("saveLocalDisplayNameButton")
            if saved { Text("Name saved.").accessibilityIdentifier("localDisplayNameSaved") }
        } header: { Text("Your Display Name") }
        footer: { Text("Choose the name you share with people in your groups. They can keep a different name for you on their own device.") }
        .onAppear { name = viewModel.localMemberIdentity.displayName }
        .onChange(of: name) { saved = false }
    }
}

struct GroupMemberNameView: View {
    @Bindable var viewModel: IntercomViewModel
    let groupID: UUID
    let member: GroupMember
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    private var currentMember: GroupMember {
        viewModel.groups.first { $0.id == groupID }?.members.first { $0.id == member.id } ?? member
    }
    init(viewModel: IntercomViewModel, groupID: UUID, member: GroupMember) {
        self.viewModel = viewModel; self.groupID = groupID; self.member = member
        _name = State(initialValue: member.resolvedDisplayName)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Name on this device") {
                    // Empty shows and saves the name this person shares.
                    TextField("Name on this device", text: $name, prompt: Text(verbatim: currentMember.displayName))
                        .accessibilityIdentifier("groupMemberNameField")
                }
                LabeledContent("Name shared by this person", value: currentMember.displayName)
                    .accessibilityIdentifier("groupMemberOriginalName")
                Button("Use Shared Name") {
                    if viewModel.resetGroupMemberName(member.id, in: groupID) { dismiss() }
                }.accessibilityIdentifier("resetGroupMemberNameButton")
                Text("This edit stays on this device. People you have not invited directly remain in this group only.").font(.footnote)
                if let error = viewModel.groupErrorMessage { Text(LocalizedStringKey(error)).foregroundStyle(AppColorPalette.danger) }
            }
            .screenBackground(AppColorPalette.listScreenBackground)
            .navigationTitle("Edit Name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let saved = trimmed.isEmpty ? viewModel.resetGroupMemberName(member.id, in: groupID)
                                                    : viewModel.renameGroupMember(member.id, in: groupID, displayName: trimmed)
                        if saved { dismiss() }
                    }
                    .disabled({ let t = name.trimmingCharacters(in: .whitespacesAndNewlines); return !t.isEmpty && !IntercomGroup.isValidName(t) }())
                    .accessibilityIdentifier("saveGroupMemberNameButton")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, idealWidth: 480, minHeight: 300)
        #endif
    }
}

/// Shown once after sign-in until a name is saved, so people are not all called "You".
struct DisplayNameChoiceView: View {
    @Bindable var viewModel: IntercomViewModel
    @State private var name = ""
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Nao", text: $name)
                        .focused($focused)
                        #if os(iOS)
                        .textContentType(.nickname)
                        #endif
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("displayNameChoiceField")
                } footer: {
                    Text("People see this name. It does not have to be your real name.")
                }
                if let failure {
                    Section {
                        Label(LocalizedStringKey(failure), systemImage: "exclamationmark.triangle.fill")
                            .accessibilityIdentifier("displayNameChoiceError")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(failure == nil ? "Get Started" : "Try Again", action: save)
                    .appProminentButtonStyle()
                    .disabled(!IntercomGroup.isValidName(trimmed))
                    .padding()
                    .accessibilityIdentifier("displayNameChoiceSaveButton")
            }
            .screenBackground(AppColorPalette.callScreenBackground)
            .navigationTitle("Your Name")
        }
        .interactiveDismissDisabled()
        .onAppear { focused = true }
        .accessibilityIdentifier("displayNameChoice")
    }

    private func save() {
        guard IntercomGroup.isValidName(trimmed) else { return }
        failure = viewModel.setLocalDisplayName(trimmed) ? nil : viewModel.groupErrorMessage ?? "Could not save the name."
    }
}
