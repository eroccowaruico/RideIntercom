import Foundation
import CryptoKit
import RTC

extension IntercomViewModel {
    func makeInternetAccountAuthorization() throws -> InternetAccountAuthorization {
        guard canStartCalls, let accountUserID else { throw InternetAccountClient.Failure.rejected }
        #if DEBUG && RIDEINTERCOM_VALIDATION
        if let fixture = AppleAccountFixture.makeInternetAuthorization(viewModel: self) { return fixture }
        #endif
        return InternetAccountAuthorization(expectedUserID: accountUserID, deviceID: try internetSettingsStore.accountDeviceID(),
            memberID: localMemberIdentity.memberID, deviceKey: IdentityEncoding.encode(try internetSettingsStore.deviceSigningKey().publicKey.x963Representation),
            currentUser: { [weak self] in
                guard let self, self.canStartCalls else { return nil }
                return self.accountUserID
            }, save: { [weak self] origin, credential, identity in
                guard let self, self.canStartCalls else { throw InternetAccountClient.Failure.rejected }
                try self.saveInternetConnection(url: origin.absoluteString, token: credential.accessToken, identity: identity)
            })
    }
    func endAccountAccess() {
        disconnect()
        internetCheckGeneration = UUID()
        isCheckingInternet = false
        if accountSession.deletion.blocksSignIn {
            hasInternetCredentials = false
            localAccountPrincipal = nil
            return
        }
        // Disable saved Internet access before the asynchronous server request.
        do { _ = try internetSettingsStore.retireAppleCredential() }
        catch { internetCheckMessage = "Could not read Internet access for sign-out. Saved data has been preserved." }
        hasInternetCredentials = false
        localAccountPrincipal = nil
        Task { await retryInternetAccountRevocation() }
    }
    func retryInternetAccountRevocation(client: InternetAccountClient = .init()) async {
        let generation = internetCheckGeneration
        do {
            guard let pending = try internetSettingsStore.pendingRevocation() else { return }
            try await client.revoke(pending)
            try internetSettingsStore.finishRevocation(pending)
        } catch {
            guard generation == internetCheckGeneration else { return }
            internetCheckMessage = "Internet access is disabled on this device. Server sign-out is pending; retry when online."
        }
    }
    func saveInternetConnection(url: String, token: String, identity: VerifiedDeviceIdentity? = nil) throws {
        guard canStartCalls else { throw InternetAccountClient.Failure.rejected }
        try internetSettingsStore.save(url: url, token: token, identity: identity)
        localAccountPrincipal = try internetSettingsStore.loadPrincipal(memberID: localMemberIdentity.memberID)
        guard let configuration = try internetSettingsStore.load() else { throw InternetConnectionSettingsStore.ValidationError.missingToken }
        internetCheckGeneration = UUID()
        isCheckingInternet = false
        disconnect()
        callSession.updateInternetConfiguration(configuration)
        internetWorkerURL = configuration.workerURL.absoluteString
        hasInternetCredentials = true
        internetCheckMessage = "Device token saved. Service not checked."
    }

    func checkInternetService(session: URLSession = .shared) async {
        guard canStartCalls, !isCheckingInternet else { return }
        let stored: CloudflareRealtimeConfiguration?
        do { stored = try internetSettingsStore.load() }
        catch { internetCheckMessage = "Could not read saved Internet credentials. Try again."; return }
        guard let configuration = stored else {
            internetCheckMessage = "Configure Internet Connection in Settings first."
            return
        }
        let generation = internetCheckGeneration
        isCheckingInternet = true
        internetCheckMessage = "Checking device authorization and service configuration…"
        do {
            let status = try await CloudflareRealtimeSignalingClient.checkService(configuration, session: session)
            guard generation == internetCheckGeneration else { return }
            internetCheckMessage = "Authorized. \(status.activeSessions) active sessions. Reserved \(status.reservedParticipantSeconds) / \(status.monthlyParticipantSeconds) participant-seconds (\(status.month)). Media and audio have not been tested."
        } catch {
            guard generation == internetCheckGeneration else { return }
            internetCheckMessage = "Service check failed: \(error.localizedDescription)"
        }
        isCheckingInternet = false
    }
}
