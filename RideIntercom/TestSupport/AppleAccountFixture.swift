#if DEBUG && RIDEINTERCOM_VALIDATION
import AuthenticationServices
import Foundation

/// Compiled only into explicitly isolated local validation builds. Ordinary
/// Debug, Release and Archive builds cannot select this provider with an env var.
@MainActor
enum AppleAccountFixture {
    static let userID = "local-validation-apple-user"

    static func makeForCurrentProcess(namespace: String) -> AppleAccountSession? {
        let environment = ProcessInfo.processInfo.environment
        guard namespace.hasPrefix("RideIntercom.Validation."),
              environment["RIDEINTERCOM_LOCAL_TESTING"] == "1",
              let mode = environment["RIDEINTERCOM_ACCOUNT_FIXTURE"],
              mode == "signed-in" || mode == "signed-out" else { return nil }
        let defaults = UserDefaults(suiteName: namespace + ".AccountFixture")!
        let session = AppleAccountSession(keychain: FixtureKeychain(defaults: defaults), defaults: defaults,
            namespace: namespace, credentialState: { _ in .authorized })
        if mode == "signed-in" {
            let request = ASAuthorizationAppleIDProvider().createRequest()
            session.prepare(request)
            _ = session.completeSignIn(userID: userID, state: request.state)
        } else {
            session.signOut()
        }
        return session
    }

    private final class FixtureKeychain: KeychainSecretStoring {
        let defaults: UserDefaults
        init(defaults: UserDefaults) { self.defaults = defaults }
        func accounts(service: String) throws -> [String] { [] }
        func secret(service: String, account: String) throws -> String? { defaults.string(forKey: "user") }
        func saveSecret(_ secret: String, service: String, account: String) throws { defaults.set(secret, forKey: "user") }
        func deleteSecret(service: String, account: String) throws { defaults.removeObject(forKey: "user") }
    }
}
#endif
