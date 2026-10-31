#if DEBUG && RIDEINTERCOM_VALIDATION
import AuthenticationServices
import Foundation
import CryptoKit

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
            if let seed = environment["RIDEINTERCOM_ACCOUNT_REPLACEMENT_FIXTURE"],
               defaults.string(forKey: "replacementSeed") != seed {
                let scoped = AppleAccountSession.storageNamespace(base: namespace, userID: userID)
                UserDefaults(suiteName: scoped)!.set(true, forKey: "InternetAccount.requiresDataReset")
                defaults.set(seed, forKey: "replacementSeed")
            }
        } else {
            session.signOut()
        }
        return session
    }

    private final class FixtureKeychain: KeychainSecretStoring {
        let defaults: UserDefaults
        init(defaults: UserDefaults) { self.defaults = defaults }
        private let system = SystemKeychainSecretStore()
        private func isFixtureService(_ service: String) -> Bool {
            service.hasSuffix(".AppleAccount") || service.hasSuffix(".AccountDeletion")
        }
        func accounts(service: String) throws -> [String] {
            if !isFixtureService(service) { return try system.accounts(service: service) }
            return Array((defaults.dictionary(forKey: service) ?? [:]).keys)
        }
        func secret(service: String, account: String) throws -> String? {
            if !isFixtureService(service) { return try system.secret(service: service, account: account) }
            return defaults.dictionary(forKey: service)?[account] as? String
        }
        func createSecretIfAbsent(_ value: String, service: String, account: String) throws -> String {
            if let retained = try secret(service: service, account: account) { return retained }
            try saveSecret(value, service: service, account: account)
            return value
        }
        func saveSecret(_ secret: String, service: String, account: String) throws {
            if !isFixtureService(service) { try system.saveSecret(secret, service: service, account: account); return }
            var values = defaults.dictionary(forKey: service) ?? [:]
            values[account] = secret; defaults.set(values, forKey: service)
        }
        func deleteSecret(service: String, account: String) throws {
            if !isFixtureService(service) { try system.deleteSecret(service: service, account: account); return }
            var values = defaults.dictionary(forKey: service) ?? [:]
            values[account] = nil; defaults.set(values, forKey: service)
        }
    }

    static func makeInternetAuthorization(viewModel: IntercomViewModel) -> InternetAccountAuthorization? {
        let environment = ProcessInfo.processInfo.environment
        guard let namespace = Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String,
              namespace.hasPrefix("RideIntercom.Validation."),
              environment["RIDEINTERCOM_LOCAL_TESTING"] == "1",
              environment["RIDEINTERCOM_INTERNET_ACCOUNT_FIXTURE"] == "throttled",
              viewModel.accountUserID == userID else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThrottledEnrollment.self]
        return InternetAccountAuthorization(expectedUserID: userID, deviceID: UUID().uuidString.lowercased(),
            memberID: "fixture-member", deviceKey: IdentityEncoding.encode(P256.Signing.PrivateKey().publicKey.x963Representation),
            client: .init(session: URLSession(configuration: configuration)),
            currentUser: { [weak viewModel] in viewModel?.accountSession.userID },
            save: { _, _, _ in throw InternetAccountClient.Failure.rejected })
    }

    // All requests stay in this process; the fixture cannot return a credential.
    private final class ThrottledEnrollment: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "60"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
}
#endif
