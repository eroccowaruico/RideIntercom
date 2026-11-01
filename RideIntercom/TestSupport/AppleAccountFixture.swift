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
        if let recovery = environment["RIDEINTERCOM_GROUP_RECOVERY_FIXTURE"] {
            do {
                try processGroupRecovery(recovery, namespace: namespace,
                    applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            } catch {
                // This code is absent from normal Debug/Release products. An
                // invalid local fixture must fail the UI launch, not pass silently.
                preconditionFailure("Local saved-group recovery fixture failed: \(error)")
            }
        }
        if let raw = environment["RIDEINTERCOM_INTERFACE_FIXTURE"], let layout = InterfaceMode(rawValue: raw) {
            UserDefaults(suiteName: AppleAccountSession.storageNamespace(base: namespace, userID: userID))!
                .set(layout.rawValue, forKey: "RideIntercom.settings.interfaceMode")
        }
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

    enum RecoveryFailure: Error { case invalidScope, unsafePath, verificationFailed }

    /// Only the validation account's real group manifest is prepared. No test
    /// state is persisted: the UI test explicitly selects prepare or verify.
    static func processGroupRecovery(_ mode: String, namespace: String, applicationSupport: URL) throws {
        let parts = mode.split(separator: ":")
        guard namespace.range(of: #"^RideIntercom\.Validation\.[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              parts.count == 2, parts[0] == "prepare" || parts[0] == "verify",
              let fixtureID = UUID(uuidString: String(parts[1])) else { throw RecoveryFailure.invalidScope }
        let corruptGroupBytes = Data("{broken-recovery-fixture:\(fixtureID.uuidString)".utf8)
        let root = applicationSupport.resolvingSymlinksInPath()
        let account = root.appending(path: AppleAccountSession.storageNamespace(base: namespace, userID: userID), directoryHint: .isDirectory)
        let directory = account.appending(path: "Groups", directoryHint: .isDirectory)
        let manifest = directory.appending(path: "groups.json")
        for path in [account, directory, manifest] {
            guard path.resolvingSymlinksInPath().standardizedFileURL.path == path.standardizedFileURL.path else { throw RecoveryFailure.unsafePath }
        }
        if parts[0] == "prepare" {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try corruptGroupBytes.write(to: manifest, options: .atomic)
        } else {
            let snapshot = try GroupSnapshot.decode(Data(contentsOf: manifest))
            let archives = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard snapshot.version == 8, snapshot.groups.isEmpty,
                  try archives.contains(where: { path in
                      guard path.lastPathComponent.hasPrefix("groups-corrupt-"), path.pathExtension == "json",
                            path.resolvingSymlinksInPath().standardizedFileURL.path == path.standardizedFileURL.path else { return false }
                      return try Data(contentsOf: path) == corruptGroupBytes
                  }) else { throw RecoveryFailure.verificationFailed }
        }
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
