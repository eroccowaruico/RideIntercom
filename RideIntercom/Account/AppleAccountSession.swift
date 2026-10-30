import AuthenticationServices
import CryptoKit
import Foundation
import Observation

enum AppleCredentialState: Sendable {
    case authorized, revoked, notFound, transferred
}

/// Native Apple authorization for this device. This identifier is never a peer ID
/// or proof of identity for the signaling/notification server.
@MainActor
@Observable
final class AppleAccountSession {
    let deletion: AccountDeletion
    private(set) var userID: String?
    // A new login must never reactivate work retained from a retired session.
    private(set) var accessID = UUID()
    private(set) var isSigningIn = false
    private(set) var storageUnavailable = false
    private(set) var message: String?
    var onAccessRevoked: (() -> Void)?

    private let keychain: KeychainSecretStoring
    private let defaults: UserDefaults
    private let service: String
    private let credentialState: @MainActor (String) async throws -> AppleCredentialState
    private var cachedUserID: String?
    private var requestState: String?
    private var generation = UUID()
    private var refreshing = false
    private var needsCredentialRemoval = false
    private static let requiresSignInKey = "AppleAccount.requiresSignIn"

    init(keychain: KeychainSecretStoring, defaults: UserDefaults, namespace: String,
         applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
         credentialState: @escaping @MainActor (String) async throws -> AppleCredentialState) {
        deletion = AccountDeletion(keychain: keychain, namespace: namespace, applicationSupport: applicationSupport)
        self.keychain = keychain
        self.defaults = defaults
        service = namespace + ".AppleAccount"
        self.credentialState = credentialState
        load()
    }

    static func makeForCurrentProcess() -> AppleAccountSession {
        let namespace = Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String ?? "RideIntercom"
        #if DEBUG && RIDEINTERCOM_VALIDATION
        if let fixture = AppleAccountFixture.makeForCurrentProcess(namespace: namespace) { return fixture }
        #endif
        return AppleAccountSession(keychain: SystemKeychainSecretStore(),
            defaults: UserDefaults(suiteName: namespace)!, namespace: namespace) { userID in
                switch try await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID) {
                case .authorized: return .authorized
                case .revoked: return .revoked
                case .notFound: return .notFound
                case .transferred: return .transferred
                @unknown default: return .notFound
                }
            }
    }

    static func storageNamespace(base: String, userID: String) -> String {
        base + ".Account." + SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func load() {
        if deletion.storageUnavailable {
            storageUnavailable = true
            message = deletion.message
            return
        }
        guard !deletion.blocksSignIn, !defaults.bool(forKey: Self.requiresSignInKey) else { return }
        do {
            let saved = try keychain.secret(service: service, account: "current")
            if let saved, !Self.validIdentifier(saved) { throw KeychainSecretStoreError.invalidData }
            if userID != saved {
                accessID = UUID()
                if userID != nil { onAccessRevoked?() }
            }
            cachedUserID = saved
            userID = saved
            storageUnavailable = false
        } catch {
            storageUnavailable = true
            message = "Could not read your saved sign-in. Your data has been preserved. Try again."
        }
    }

    func reload() async {
        guard !isSigningIn else { return }
        if deletion.storageUnavailable { deletion.reload() }
        if needsCredentialRemoval { signOut(); return }
        message = nil
        load()
        await refresh()
    }

    func refresh() async {
        guard !deletion.blocksSignIn, !refreshing, !isSigningIn, !storageUnavailable, let cachedUserID else { return }
        refreshing = true
        let expectedGeneration = generation
        defer { refreshing = false }
        do {
            let state = try await credentialState(cachedUserID)
            guard expectedGeneration == generation else { return }
            switch state {
            case .authorized:
                userID = cachedUserID
                message = nil
            case .revoked, .notFound, .transferred:
                revoke()
            }
        } catch {
            guard expectedGeneration == generation else { return }
            // A previously completed native login remains usable offline.
            // A negative credential state above always removes this permission.
            userID = cachedUserID
            message = "Apple sign-in could not be checked. Your saved sign-in remains available."
        }
    }

    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = []
        guard !deletion.blocksSignIn, !storageUnavailable else { return }
        generation = UUID()
        requestState = UUID().uuidString
        request.state = requestState
        isSigningIn = true
        message = nil
    }

    func complete(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                failSignIn(); return
            }
            _ = completeSignIn(userID: credential.user, state: credential.state)
        case .failure(let error):
            let cancelled = (error as? ASAuthorizationError)?.code == .canceled
            failSignIn(cancelled: cancelled)
        }
    }

    @discardableResult
    func completeSignIn(userID: String, state: String?) -> Bool {
        guard !deletion.blocksSignIn, !storageUnavailable, let requestState, state == requestState, Self.validIdentifier(userID) else {
            failSignIn(); return false
        }
        self.requestState = nil
        isSigningIn = false
        do {
            try keychain.saveSecret(userID, service: service, account: "current")
            defaults.set(false, forKey: Self.requiresSignInKey)
            if self.userID != userID {
                accessID = UUID()
                if self.userID != nil { onAccessRevoked?() }
            }
            generation = UUID()
            cachedUserID = userID
            self.userID = userID
            message = nil
            return true
        } catch {
            message = "Could not save your sign-in. Try signing in again."
            return false
        }
    }

    private func failSignIn(cancelled: Bool = false) {
        requestState = nil
        isSigningIn = false
        message = cancelled ? nil : "Sign-in could not be completed. Try again."
    }

    func signOut() {
        // Persist the denial before touching Keychain: a failed delete must not
        // resurrect the session on the next offline launch.
        defaults.set(true, forKey: Self.requiresSignInKey)
        accessID = UUID()
        generation = UUID()
        requestState = nil
        userID = nil
        cachedUserID = nil
        isSigningIn = false
        onAccessRevoked?()
        do {
            try keychain.deleteSecret(service: service, account: "current")
            storageUnavailable = false
            needsCredentialRemoval = false
            message = nil
        } catch {
            storageUnavailable = true
            needsCredentialRemoval = true
            message = "You are signed out. The saved sign-in could not be removed from this device. Try again."
        }
    }

    func resumeDeletion(client: InternetAccountClient = .init()) async {
        if deletion.storageUnavailable { deletion.reload() }
        guard deletion.record != nil, !deletion.isBusy else { return }
        signOut()
        guard !storageUnavailable else { return }
        await deletion.resume(client: client)
    }

    func revoke() {
        signOut()
        if message == nil { message = "Your Apple sign-in is no longer valid. Sign in again to call." }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && !value.contains(where: { $0.isWhitespace || $0.isNewline })
    }
}
