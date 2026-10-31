import SwiftUI

/// Both layouts export through the same revalidated invitation operation.
struct CallInvitationButton: View {
    let viewModel: IntercomViewModel
    let group: IntercomGroup

    var body: some View {
        ShareLink(item: GroupInvitationShare(viewModel: viewModel, groupID: group.id),
                  subject: Text("RideIntercom Invite"),
                  message: Text("Join me for a call on RideIntercom."),
                  preview: SharePreview(Text(viewModel.callTitle(for: group)))) {
            Label(LocalizedStringKey(group.kind == .direct ? "Share Call Invite" : "Invite"), systemImage: "square.and.arrow.up")
        }
        .simultaneousGesture(TapGesture().onEnded {
            guard viewModel.selectedGroup?.id == group.id, viewModel.canShareSelectedGroup else { return }
            viewModel.reserveInviteMemberSlot()
        })
        .accessibilityHint("Opens sharing options for this invitation.")
        .accessibilityIdentifier("inviteButton")
    }
}
