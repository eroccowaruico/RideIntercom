import AuthenticationServices
import SwiftUI

struct AppleSignInView: View {
    let account: AppleAccountSession
    var hasPendingInvite = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Welcome to RideIntercom")
                    .font(.largeTitle).fontWeight(.bold)
                    .accessibilityAddTraits(.isHeader)
                Text("Sign in with Apple to call your friends. Your groups and saved users stay with your account on this device.")
                Text("We do not request your email address or real name.")
                    .font(.callout).foregroundStyle(.secondary)
                if hasPendingInvite {
                    Label("Sign in to open your invitation.", systemImage: "envelope")
                        .accessibilityIdentifier("pendingInviteSignInLabel")
                }
                SignInWithAppleButton(.signIn, onRequest: account.prepare, onCompletion: account.complete)
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(maxWidth: 360).frame(height: 50)
                    .disabled(account.storageUnavailable || account.isSigningIn)
                    .accessibilityIdentifier("signInWithAppleButton")
                if let message = account.message {
                    Text(message).font(.callout)
                        .accessibilityIdentifier("accountMessage")
                    Button("Try Again") { Task { await account.reload() } }
                        .accessibilityIdentifier("retrySignInButton")
                }
                Text("After signing in, you can use nearby calls without an Internet connection.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: 540)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("appleSignInScreen")
    }
}

struct AccountSettingsPanel: View {
    let viewModel: IntercomViewModel
    private var account: AppleAccountSession { viewModel.accountSession }
    @State private var showsDeletion = false
    @State private var confirmsSignOut = false

    var body: some View {
        Section {
            Label("Signed in with Apple", systemImage: "person.crop.circle.badge.checkmark")
            if let message = account.message { Text(message).font(.footnote) }
            Button("Sign Out", role: .destructive) { confirmsSignOut = true }
                .accessibilityIdentifier("signOutButton")
                .confirmationDialog("Sign out and end the current call?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                    Button("Sign Out", role: .destructive) { account.signOut() }
                        .accessibilityIdentifier("confirmSignOutButton")
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Your groups and saved users stay on this device. Sign in with the same Apple Account to use them again.")
                }
            Button("Delete Account", role: .destructive) { showsDeletion = true }
                .accessibilityIdentifier("deleteAccountButton")
                .sheet(isPresented: $showsDeletion) { NavigationStack { AccountDeletionView(viewModel: viewModel) } }
        } header: { Text("Account") }
    }
}
