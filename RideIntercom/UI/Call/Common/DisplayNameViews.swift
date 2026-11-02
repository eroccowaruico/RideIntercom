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
                TextField("Name on this device", text: $name).accessibilityIdentifier("groupMemberNameField")
                LabeledContent("Name shared by this person", value: currentMember.displayName)
                    .accessibilityIdentifier("groupMemberOriginalName")
                Button("Use Shared Name") {
                    if viewModel.resetGroupMemberName(member.id, in: groupID) { dismiss() }
                }.accessibilityIdentifier("resetGroupMemberNameButton")
                Text("This edit stays on this device. People you have not invited directly remain in this group only.").font(.footnote)
                if let error = viewModel.groupErrorMessage { Text(LocalizedStringKey(error)).foregroundStyle(AppColorPalette.danger) }
            }
            .navigationTitle("Edit Name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if viewModel.renameGroupMember(member.id, in: groupID, displayName: name) { dismiss() }
                    }
                    .disabled(!IntercomGroup.isValidName(name.trimmingCharacters(in: .whitespacesAndNewlines)))
                    .accessibilityIdentifier("saveGroupMemberNameButton")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, idealWidth: 480, minHeight: 300)
        #endif
    }
}
