import SwiftUI

/// Both layouts export through the same revalidated invitation operation.
struct CallInvitationButton: View {
    let viewModel: IntercomViewModel
    let group: IntercomGroup

    var body: some View {
        ShareLink(item: InvitationShare(viewModel: viewModel, groupID: group.id),
                  subject: Text("RideCom Invite"),
                  message: Text("Join me for a call on RideCom."),
                  preview: SharePreview(Text(viewModel.callTitle(for: group)))) {
            Label(LocalizedStringKey(group.kind == .direct ? "Share Call Invite" : "Invite"), systemImage: "square.and.arrow.up")
        }
        .accessibilityHint("Opens sharing options for this invitation.")
        .accessibilityIdentifier("inviteButton")
    }
}
