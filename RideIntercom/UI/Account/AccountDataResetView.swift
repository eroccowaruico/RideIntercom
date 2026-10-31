import SwiftUI

/// A confirmed replacement needs only local cleanup, not another server deletion.
struct AccountDataResetView: View {
    let viewModel: IntercomViewModel
    @State private var confirmsRemoval = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Set Up Your Account Again")
                    .font(.largeTitle).accessibilityAddTraits(.isHeader)
                Text("Your previous account was deleted and a new account was registered. This device still has data from the previous account.")
                Text("Remove its saved users, groups, settings and keys from this device, then sign in and set up Internet calling again. You will need new invitations to reconnect with friends.")
                Text("Your new account, Apple authorization and purchases will be kept. This cleanup does not need an Internet connection.")
                Button("Remove Previous Account Data", role: .destructive) { confirmsRemoval = true }
                    .accessibilityIdentifier("removePreviousAccountDataButton")
                Button("Sign Out") { viewModel.accountSession.signOut() }
                    .accessibilityIdentifier("accountResetSignOutButton")
                if let message { Text(LocalizedStringKey(message)).font(.callout) }
            }
            .padding(32).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .alert("Remove the previous account data from this device?", isPresented: $confirmsRemoval) {
            Button("Remove Data", role: .destructive) {
                do { try viewModel.beginAccountDataReset() }
                catch { message = "Could not start removing the data. Your saved data has been preserved. Try again." }
            }.accessibilityIdentifier("confirmAccountDataResetButton")
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Saved users, groups, settings and keys on this device will be permanently removed. Your new account will be kept.")
        }
        .accessibilityIdentifier("accountDataResetScreen")
    }
}
