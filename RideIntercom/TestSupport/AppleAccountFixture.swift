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
        func createSecretIfAbsent(_ value: String, service: String, account: String) throws -> String {
            if let retained = try secret(service: service, account: account) { return retained }
            try saveSecret(value, service: service, account: account)
            return value
        }
        func saveSecret(_ secret: String, service: String, account: String) throws { defaults.set(secret, forKey: "user") }
        func deleteSecret(service: String, account: String) throws { defaults.removeObject(forKey: "user") }
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
            client: .init(session: URLSession(configuration: configuration)),
            currentUser: { [weak viewModel] in viewModel?.accountSession.userID },
            save: { _, _ in throw InternetAccountClient.Failure.rejected })
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
