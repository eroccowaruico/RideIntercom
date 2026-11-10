import SwiftUI

/// Standard's More menu: a group's settings and Invite Members, or the person's settings.
struct StandardCallMoreMenu: View {
    let viewModel: IntercomViewModel
    @Binding var settings: DestinationSettingsTarget?
    @Binding var addingMembers: IntercomGroup?

    var body: some View {
        if let group = viewModel.selectedGroup {
            Menu {
                if group.kind == .group {
                    Button("Group Settings", systemImage: "gearshape") { settings = .group(group.id) }
                        .accessibilityIdentifier("callGroupSettingsButton")
                    Button("Invite Members", systemImage: "person.badge.plus") { addingMembers = group }
                        .disabled(!viewModel.canEditSavedGroups || viewModel.availableUsers(for: group.id).isEmpty
                                  || group.members.count >= IntercomGroup.maximumMemberCount)
                        .accessibilityIdentifier("callAddMembersButton")
                    // Temporary: a link without a recipient is the only way to bring someone new into a
                    // group until Invite Members can invite new people (see the design-difference backlog).
                    if viewModel.canShareSelectedGroup {
                        CallInvitationButton(viewModel: viewModel, group: group)
                    }
                } else {
                    // A removed saved user leaves the entry disabled, so the menu is never empty.
                    let userID = viewModel.savedUserID(forDirectCall: group)
                    Button("User Settings", systemImage: "gearshape") { settings = userID.map { .user($0) } }
                        .disabled(userID == nil)
                        .accessibilityIdentifier("callUserSettingsButton")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("callMoreMenu")
        }
    }
}
