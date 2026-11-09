import SwiftUI

/// Advanced's More menu, named as the implementation's operations: settings, Add Saved Users,
/// and the group invitation (`Invite`, or `Share Call Invite` for a direct group).
struct AdvancedCallMoreMenu: View {
    let viewModel: IntercomViewModel
    @Binding var settings: DestinationSettingsTarget?
    @Binding var addingMembers: IntercomGroup?

    var body: some View {
        if let group = viewModel.selectedGroup {
            Menu {
                if group.kind == .group {
                    Button("Group Settings", systemImage: "gearshape") { settings = .group(group.id) }
                        .accessibilityIdentifier("callGroupSettingsButton")
                    Button("Add Saved Users", systemImage: "person.badge.plus") { addingMembers = group }
                        .disabled(!viewModel.canEditSavedGroups || viewModel.availableUsers(for: group.id).isEmpty
                                  || group.members.count >= IntercomGroup.maximumMemberCount)
                        .accessibilityIdentifier("callAddMembersButton")
                } else {
                    let userID = viewModel.savedUserID(forDirectCall: group)
                    Button("User Settings", systemImage: "gearshape") { settings = userID.map { .user($0) } }
                        .disabled(userID == nil)
                        .accessibilityIdentifier("callUserSettingsButton")
                }
                if viewModel.canShareSelectedGroup {
                    CallInvitationButton(viewModel: viewModel, group: group)
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("callMoreMenu")
        }
    }
}
