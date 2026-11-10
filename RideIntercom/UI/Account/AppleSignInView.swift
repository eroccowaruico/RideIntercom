import AuthenticationServices
import SwiftUI

struct AppleSignInView: View {
    let account: AppleAccountSession
    var hasPendingInvite = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    if geometry.size.width > geometry.size.height && geometry.size.width >= 600 {
                        HStack(alignment: .center, spacing: AppSpacing.l) {
                            brand.frame(maxWidth: .infinity)
                            signInContent.frame(maxWidth: 420)
                        }
                    } else {
                        // As in the design: the icon and name above, the reason right before the button at the bottom.
                        VStack(spacing: 32) {
                            brand
                            Spacer(minLength: 0)
                            signInContent
                        }
                        .frame(maxWidth: 420, maxHeight: .infinity)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .background(AppColorPalette.callScreenBackground)
        .accessibilityIdentifier("appleSignInScreen")
    }

    private var brand: some View {
        VStack(spacing: AppSpacing.l) {
            // The app icon itself, so the first screen shows the same mark as the Home Screen.
            Image("ridecom.appicon")
                .resizable().scaledToFit().frame(width: 112, height: 112)
                .accessibilityLabel("RideCom")
                .accessibilityIdentifier("signInBrandGlyph")
            Text("RideCom")
                .font(.largeTitle).fontWeight(.bold)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var signInContent: some View {
        VStack(spacing: AppSpacing.l) {
            Text("Sign in to verify you so only invited people can join your calls. We do not use your email address or real name.")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("signInReason")
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
                Text(LocalizedStringKey(message)).font(.callout)
                    .accessibilityIdentifier("accountMessage")
                Button("Try Again") { Task { await account.reload() } }
                    .accessibilityIdentifier("retrySignInButton")
            }
        }
        .multilineTextAlignment(.center)
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
            if let message = account.message { Text(LocalizedStringKey(message)).font(.footnote) }
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
