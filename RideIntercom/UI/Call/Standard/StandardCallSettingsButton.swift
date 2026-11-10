import SwiftUI

/// Standard's one settings button in the call's toolbar: Group Settings for a group, User Settings for a person.
/// Invite Members is its own button under the members, never folded into a menu with the settings.
struct StandardCallSettingsButton: View {
    let viewModel: IntercomViewModel
    @Binding var settings: DestinationSettingsTarget?

    var body: some View {
        if let group = viewModel.selectedGroup {
            if group.kind == .group {
                Button("Group Settings", systemImage: "gearshape") { settings = .group(group.id) }
                    .accessibilityIdentifier("callGroupSettingsButton")
            } else {
                // A removed saved user leaves the button disabled rather than missing.
                let userID = viewModel.savedUserID(forDirectCall: group)
                Button("User Settings", systemImage: "gearshape") { settings = userID.map { .user($0) } }
                    .disabled(userID == nil)
                    .accessibilityIdentifier("callUserSettingsButton")
            }
        }
    }
}
