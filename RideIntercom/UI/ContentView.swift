import SwiftUI
import RTC
import AuthenticationServices

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    let account: AppleAccountSession
    @Binding var viewModel: IntercomViewModel?
    var callPresentationID: UUID? = nil
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
        .onChange(of: callPresentationID) { _, _ in selectedTab = .call }
        .task { await account.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await account.refresh()
                    await viewModel?.storeAccess.refresh()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
            account.revoke()
        }
        .onChange(of: account.accessID, initial: true) { _, _ in
            // Every window shares one call owner. Opening another scene must
            // neither reconnect nor leave another account's media running.
            guard viewModel?.accountAccessID != account.accessID else { return }
            let previous = viewModel?.accountUserID
            viewModel?.stopCallAccessObservation()
            viewModel?.storeAccess.stop()
            viewModel?.disconnect()
            viewModel = IntercomViewModel.makeForCurrentProcess(accountSession: account)
            if previous != nil { pendingInviteURL = nil }
            if let viewModel, let pendingInviteURL {
                openInvitation(pendingInviteURL, in: viewModel)
                self.pendingInviteURL = nil
            }
        }
        .onOpenURL { url in
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
    ContentView(account: .makeForCurrentProcess(), viewModel: .constant(nil))
}
