import SwiftUI
import RTC

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var owner: AppCallOwner
    private var account: AppleAccountSession { owner.account }
    private var viewModel: IntercomViewModel? { owner.viewModel }
    @State private var pendingInviteURL: URL?
    @State private var selectedTab: AppTab = .call

    var body: some View {
        Group {
            if account.deletion.blocksSignIn {
                AccountDeletionProgressView(account: account)
            } else if let viewModel, viewModel.hasCurrentAccountAccess {
                if viewModel.requiresAccountDataReset {
                    AccountDataResetView(viewModel: viewModel)
                } else {
                    SignedInContentView(viewModel: viewModel, selectedTab: $selectedTab)
                }
            } else {
                AppleSignInView(account: account, hasPendingInvite: pendingInviteURL != nil)
            }
        }
        .onChange(of: owner.callPresentationID) { _, _ in selectedTab = .call }
        .task { await owner.refreshAccountForForeground() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await owner.refreshAccountForForeground() } }
        }
        .onChange(of: owner.viewModel?.accountAccessID) { previous, _ in
            if previous != nil { pendingInviteURL = nil }
            if let viewModel, let pendingInviteURL {
                openInvitation(pendingInviteURL, in: viewModel)
                self.pendingInviteURL = nil
            }
        }
        .onOpenURL { url in
            if url.scheme == "rideintercom", url.host == "call" { selectedTab = .call; return }
            guard !account.deletion.blocksSignIn, url.scheme == "rideintercom", url.host == "join" else { return }
            if let viewModel, viewModel.canStartCalls { openInvitation(url, in: viewModel) }
            else { pendingInviteURL = url }
        }
    }

    private func openInvitation(_ url: URL, in viewModel: IntercomViewModel) {
        selectedTab = .call
        do { try viewModel.acceptInviteURL(url) }
        catch {
            if viewModel.groupErrorMessage == nil {
                viewModel.groupErrorMessage = "This invitation could not be opened or saved. Ask for a valid invite and try again."
            }
        }
    }
}

#Preview {
    ContentView(owner: AppCallOwner(account: .makeForCurrentProcess(), viewModel: nil))
}
