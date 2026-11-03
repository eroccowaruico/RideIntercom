import SwiftUI

/// Both layouts export through the same revalidated invitation operation.
struct CallInvitationButton: View {
    let viewModel: IntercomViewModel
    let group: IntercomGroup
    var accessibilityIdentifier = "inviteButton"
    /// Settings and the add-members step share a named group, not whichever call is shown.
    var bindsToGroup = false

    var body: some View {
        ShareLink(item: bindsToGroup ? InvitationShare(viewModel: viewModel, settingsGroupID: group.id)
                                  : InvitationShare(viewModel: viewModel, groupID: group.id),
                  subject: Text("RideCom Invite"),
                  message: Text("Join me for a call on RideCom."),
                  preview: SharePreview(Text(viewModel.callTitle(for: group)))) {
            Label(LocalizedStringKey(group.kind == .direct ? "Share Call Invite" : "Invite"), systemImage: "square.and.arrow.up")
        }
        .accessibilityHint("Opens sharing options for this invitation.")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
