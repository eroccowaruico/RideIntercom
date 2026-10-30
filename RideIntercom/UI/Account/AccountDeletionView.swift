import AuthenticationServices
import SwiftUI

struct AccountDeletionView: View {
    let viewModel: IntercomViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var access: AccountDeletion.ServiceAccess?
    @State private var authorization: AccountDeletionAuthorization?
    @State private var loaded = false
    @State private var message: String?
    @State private var confirmsManualDeletion = false

    var body: some View {
        Form {
            Section {
                Text("Delete your account?").font(.title2).accessibilityAddTraits(.isHeader)
                Text("This ends your call and permanently removes your saved users, groups, settings and keys from this device. This cannot be undone.")
                Text("If a saved Internet account is found, all device registrations at that service are deleted. Copies on other devices and information shared with friends remain. Deletion does not cancel purchases or subscriptions.")
            }
            if loaded {
                if access != nil {
                    Section("Verify with Apple to delete") {
                        Text("Continue with the same Apple Account to also remove its authorization for RideIntercom.")
                        if let authorization { DeletionAppleVerification(authorization: authorization) }
                    }
                } else {
                    Section {
                        Text("Internet calling is not connected on this device. Only this device's data will be deleted. Any Internet registration on another device is unaffected.")
                    }
                }
                if access?.requiresAppleVerification == true {
                    Text("Internet access has been signed out. Verify with Apple to delete the saved account; signing out did not delete it.")
                } else {
                    Section {
                        Button(access == nil ? "Delete Data on This Device" : "Delete Without Apple Verification", role: .destructive) {
                            confirmsManualDeletion = true
                        }
                        .disabled(authorization?.isBusy == true)
                        .accessibilityIdentifier("deleteWithoutAppleButton")
                        Text("Without verification, remove RideIntercom from Sign in with Apple in your Apple Account settings yourself.").font(.footnote)
                    }
                }
            }
            if let message { Section { Text(message); Button("Try Again", action: load) } }
        }
        .navigationTitle("Delete Account")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { authorization?.cancel(); dismiss() } } }
        .confirmationDialog("Permanently delete this account's data?", isPresented: $confirmsManualDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { begin(proof: nil) }
            Button("Cancel", role: .cancel) { }
        } message: { Text("You will need to remove the Apple authorization yourself. Your data cannot be restored by signing in again.") }
        .task { load() }
        .onDisappear { authorization?.cancel() }
        .accessibilityIdentifier("accountDeletionConfirmation")
    }
    private func load() {
        guard viewModel.canStartCalls else { dismiss(); return }
        do {
            access = try viewModel.internetSettingsStore.deletionAccess()
            if let access, let user = viewModel.accountUserID {
                authorization = AccountDeletionAuthorization(userID: user, access: access,
                    isCurrent: { viewModel.canStartCalls }, accept: { proof in try start(proof: proof) })
            }
            loaded = true; message = nil
        } catch { message = "Could not verify your saved Internet account. Your data has been preserved. Reconnect Internet calling with Apple in Settings, then try again." }
    }
    private func start(proof: InternetAccountDeletionProof?) throws {
        guard viewModel.canStartCalls, let user = viewModel.accountUserID,
              try viewModel.internetSettingsStore.deletionAccess() == access else { throw InternetAccountClient.Failure.rejected }
        let account = viewModel.accountSession
        try account.deletion.begin(userID: user, access: access, proof: proof)
        account.signOut()
        dismiss()
        Task { await account.resumeDeletion() }
    }
    private func begin(proof: InternetAccountDeletionProof?) {
        do { try start(proof: proof) }
        catch { message = "Could not save the deletion request. Your data has been preserved. Try again." }
    }
}

struct DeletionAppleVerification: View {
    let authorization: AccountDeletionAuthorization
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        if authorization.isReady {
            SignInWithAppleButton(.continue, onRequest: authorization.configure, onCompletion: authorization.complete)
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(maxWidth: 360).frame(height: 50)
                .accessibilityIdentifier("verifyAppleDeletionButton")
        } else {
            Button("Prepare Apple Verification") { Task { await authorization.prepare() } }
                .disabled(authorization.isBusy)
        }
        if authorization.isBusy { ProgressView("Verifying…") }
        if let message = authorization.message { Text(message).font(.callout) }
    }
}

struct AccountDeletionProgressView: View {
    let account: AppleAccountSession
    @State private var authorization: AccountDeletionAuthorization?
    @State private var message: String?
    @State private var confirmsManualDeletion = false
    private var deletion: AccountDeletion { account.deletion }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(deletion.canFinish ? "Account Data Deleted" : "Account Deletion").font(.largeTitle).accessibilityAddTraits(.isHeader)
                if deletion.isBusy { ProgressView("Deleting…") }
                if let text = deletion.message { Text(text) }
                if let text = account.message { Text(text) }
                if let message { Text(message) }
                if deletion.canFinish {
                    if deletion.record?.serverResult?.newerAccountPreserved == true {
                        Text("Your previous account is deleted. A newer account is registered with Apple; its registration and Apple authorization have been kept.")
                    } else if deletion.requiresManualAppleRemoval {
                        Text("Apple authorization has not been removed. Open your Apple Account settings, choose Sign in with Apple, and remove RideIntercom.")
                        Link("Open Apple Account", destination: URL(string: "https://account.apple.com/")!)
                    }
                    Text("Copies on other devices and information already shared with friends remain. Purchases and subscriptions are not cancelled.")
                    Button("Return to Sign In") {
                        do { try deletion.finish() }
                        catch { message = "Could not finish the deletion record. Try again." }
                    }.accessibilityIdentifier("finishAccountDeletionButton")
                } else if !deletion.isBusy {
                    Button("Retry Deletion") { Task { await account.resumeDeletion(); prepareAuthorization() } }
                    if let record = deletion.record, record.access != nil, record.serverResult == nil {
                        if let authorization { DeletionAppleVerification(authorization: authorization) }
                        if record.access?.requiresAppleVerification != true {
                            Button("Continue Without Apple Verification", role: .destructive) { confirmsManualDeletion = true }
                                .disabled(authorization?.isBusy == true)
                        }
                    }
                }
            }.padding(32).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .task {
            await account.resumeDeletion()
            prepareAuthorization()
        }
        .onChange(of: deletion.record?.serverResult?.deleted) { _, _ in prepareAuthorization() }
        .onDisappear { authorization?.cancel() }
        .confirmationDialog("Continue without removing Apple authorization?", isPresented: $confirmsManualDeletion, titleVisibility: .visible) {
            Button("Continue Deletion", role: .destructive) {
                do { try deletion.replaceProof(nil); Task { await account.resumeDeletion() } }
                catch { message = "Could not update the deletion request. Try again." }
            }
        } message: { Text("You must remove RideIntercom from Sign in with Apple in your Apple Account settings yourself.") }
        .accessibilityIdentifier("accountDeletionProgress")
    }
    private func prepareAuthorization() {
        guard let record = deletion.record, record.serverResult == nil, let access = record.access else { authorization = nil; return }
        authorization = AccountDeletionAuthorization(userID: record.userID, access: access,
            isCurrent: { deletion.record?.userID == record.userID && deletion.record?.serverResult == nil && !deletion.isBusy },
            accept: { proof in try deletion.replaceProof(proof); Task { await account.resumeDeletion() } })
    }
}
