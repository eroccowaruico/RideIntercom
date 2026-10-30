import Foundation
import RTC

/// Device access is stored separately from group invitations and audio preferences.
final class InternetConnectionSettingsStore {
    private let keychain: KeychainSecretStoring
    private let service: String
    private let developmentDefaults: [String: String]?
    private let permitsServiceAccess: Bool
    private let defaults: UserDefaults
    private let deniedKey = "InternetAccount.requiresSignIn"
    init(keychain: KeychainSecretStoring = SystemKeychainSecretStore(), namespace: String = "RideIntercom",
         developmentDefaults: [String: String]? = nil, permitsServiceAccess: Bool = true) {
        self.keychain = keychain; self.service = namespace + ".InternetConnection"
        self.developmentDefaults = developmentDefaults
        self.permitsServiceAccess = permitsServiceAccess
        defaults = UserDefaults(suiteName: namespace)!
    }

    static func makeForCurrentProcess(
        keychain: KeychainSecretStoring = SystemKeychainSecretStore(), namespace: String,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> InternetConnectionSettingsStore {
        let permitsServiceAccess = environment["RIDEINTERCOM_LOCAL_TESTING"] != "1"
            && environment["XCTestConfigurationFilePath"] == nil && environment["XCTestBundlePath"] == nil
        #if DEBUG
        let developmentDefaults = info["DevelopmentInternetConnection"] as? [String: String]
        #else
        let developmentDefaults: [String: String]? = nil
        #endif
        return .init(keychain: keychain, namespace: namespace, developmentDefaults: developmentDefaults,
                     permitsServiceAccess: permitsServiceAccess)
    }
    private struct Saved: Codable { let workerURL: URL; let accessToken: String }
    enum ValidationError: Error { case invalidURL, missingToken, disabledDuringLocalTests }
    private func validated(url: String, token: String) throws -> Saved {
        guard let url = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { throw ValidationError.invalidURL }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= 256 else { throw ValidationError.missingToken }
        return Saved(workerURL: url, accessToken: token)
    }
    func save(url: String, token: String) throws {
        guard permitsServiceAccess else { throw ValidationError.disabledDuringLocalTests }
        let data = try JSONEncoder().encode(validated(url: url, token: token))
        try keychain.saveSecret(String(decoding: data, as: UTF8.self), service: service, account: "current")
        defaults.set(false, forKey: deniedKey)
    }
    func load() throws -> RTC.CloudflareRealtimeConfiguration? {
        guard permitsServiceAccess, !defaults.bool(forKey: deniedKey) else { return nil }
        let saved: Saved
        if let value = try keychain.secret(service: service, account: "current") {
            let decoded = try JSONDecoder().decode(Saved.self, from: Data(value.utf8))
            saved = try validated(url: decoded.workerURL.absoluteString, token: decoded.accessToken)
        } else if let developmentDefaults {
            saved = try validated(url: developmentDefaults["workerURL"] ?? "", token: developmentDefaults["accessToken"] ?? "")
        } else {
            return nil
        }
        return .init(workerURL: saved.workerURL, accessToken: saved.accessToken)
    }

    func accountDeviceID() throws -> String {
        guard permitsServiceAccess else { throw ValidationError.disabledDuringLocalTests }
        if let stored = try keychain.secret(service: service, account: "device-id") {
            guard UUID(uuidString: stored) != nil else { throw KeychainSecretStoreError.invalidData }
            return stored.lowercased()
        }
        let id = UUID().uuidString.lowercased()
        try keychain.saveSecret(id, service: service, account: "device-id")
        return id
    }

    func retireAppleCredential() throws -> RTC.CloudflareRealtimeConfiguration? {
        guard permitsServiceAccess else { return nil }
        defaults.set(true, forKey: deniedKey)
        return try pendingRevocation()
    }
    func pendingRevocation() throws -> RTC.CloudflareRealtimeConfiguration? {
        guard permitsServiceAccess, defaults.bool(forKey: deniedKey),
              let raw = try keychain.secret(service: service, account: "current") else { return nil }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(raw.utf8))
        let value = try validated(url: saved.workerURL.absoluteString, token: saved.accessToken)
        guard value.accessToken.hasPrefix("ri1.") else { return nil }
        return .init(workerURL: value.workerURL, accessToken: value.accessToken)
    }
    func finishRevocation(_ retired: RTC.CloudflareRealtimeConfiguration) throws {
        guard let pending = try pendingRevocation(), pending == retired else { return }
        try keychain.deleteSecret(service: service, account: "current")
    }
}
