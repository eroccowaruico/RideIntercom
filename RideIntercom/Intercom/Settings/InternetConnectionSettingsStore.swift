import Foundation
import CryptoKit
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
    private struct Saved: Codable {
        let workerURL: URL; let accessToken: String; var identity: DeviceIdentityCertificate?
        var memberID: String?; var binding: AccountDeviceBinding?
    }
    enum ValidationError: Error { case invalidURL, missingToken, disabledDuringLocalTests }
    private func validated(url: String, token: String) throws -> Saved {
        guard let url = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { throw ValidationError.invalidURL }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= 256 else { throw ValidationError.missingToken }
        return Saved(workerURL: url, accessToken: token)
    }
    func save(url: String, token: String, identity: VerifiedDeviceIdentity? = nil) throws {
        guard permitsServiceAccess else { throw ValidationError.disabledDuringLocalTests }
        var saved = try validated(url: url, token: token)
        if let identity {
            guard let key = try storedDeviceSigningKey(), identity.issuer == IdentityEncoding.origin(saved.workerURL),
                  identity.deviceKey == IdentityEncoding.encode(key.publicKey.x963Representation) else { throw ValidationError.missingToken }
            saved.identity = identity.envelope
            saved.memberID = identity.memberID
            saved.binding = AccountDeviceBinding(principal: .init(issuer: identity.issuer, userID: identity.userID), publicKey: identity.deviceKey)
        }
        let data = try JSONEncoder().encode(saved)
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

    func deviceSigningKey() throws -> P256.Signing.PrivateKey {
        if let key = try storedDeviceSigningKey() { return key }
        let raw = try keychain.createSecretIfAbsent(P256.Signing.PrivateKey().rawRepresentation.base64EncodedString(), service: service, account: "identity-key")
        return try decodeSigningKey(raw)
    }
    private func storedDeviceSigningKey() throws -> P256.Signing.PrivateKey? {
        try keychain.secret(service: service, account: "identity-key").map(decodeSigningKey)
    }
    private func decodeSigningKey(_ raw: String) throws -> P256.Signing.PrivateKey {
        guard let bytes = Data(base64Encoded: raw) else { throw KeychainSecretStoreError.invalidData }
        return try P256.Signing.PrivateKey(rawRepresentation: bytes)
    }
    func loadIdentity(memberID: String) throws -> VerifiedDeviceIdentity? {
        guard permitsServiceAccess, !defaults.bool(forKey: deniedKey),
              let raw = try keychain.secret(service: service, account: "current") else { return nil }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(raw.utf8))
        guard let envelope = saved.identity else { return nil }
        let identity = try envelope.verify(origin: saved.workerURL, trustedIssuerKey: envelope.issuerKey)
        guard let key = try storedDeviceSigningKey(), identity.memberID == memberID,
              identity.deviceKey == IdentityEncoding.encode(key.publicKey.x963Representation) else { throw KeychainSecretStoreError.invalidData }
        return identity
    }

    /// Previously verified local identity survives certificate expiry for offline calls.
    /// This cache never certifies a new peer or signs a new account invitation.
    func loadPrincipal(memberID: String) throws -> AccountPrincipal? {
        guard permitsServiceAccess, !defaults.bool(forKey: deniedKey),
              let raw = try keychain.secret(service: service, account: "current") else { return nil }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(raw.utf8))
        if let binding = saved.binding {
            guard saved.memberID == memberID, binding.principal.isValid,
                  binding.principal.issuer == IdentityEncoding.origin(saved.workerURL),
                  let key = try storedDeviceSigningKey(), binding.publicKey == IdentityEncoding.encode(key.publicKey.x963Representation)
            else { throw KeychainSecretStoreError.invalidData }
            return binding.principal
        }
        return try loadIdentity(memberID: memberID).map { .init(issuer: $0.issuer, userID: $0.userID) }
    }

    func invitationSigner(memberID: String, expectedPublicKey: String? = nil) throws -> DeviceIdentitySigner {
        let key: P256.Signing.PrivateKey
        if let expectedPublicKey {
            guard let stored = try storedDeviceSigningKey(), IdentityEncoding.encode(stored.publicKey.x963Representation) == expectedPublicKey else {
                throw KeychainSecretStoreError.invalidData
            }
            key = stored
        } else { key = try deviceSigningKey() }
        return try DeviceIdentitySigner(memberID: memberID, key: key, identity: try? loadIdentity(memberID: memberID))
    }
    func identityTrust() throws -> DeviceIdentityTrust? {
        guard permitsServiceAccess, !defaults.bool(forKey: deniedKey),
              let raw = try keychain.secret(service: service, account: "current") else { return nil }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(raw.utf8))
        guard let certificate = saved.identity else { return nil }
        return DeviceIdentityTrust(origin: saved.workerURL, issuerKey: certificate.issuerKey)
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

    /// Never use a development fallback, manufacture a device ID, or mistake an
    /// unreadable saved credential for a local-only account during deletion.
    func deletionAccess() throws -> AccountDeletion.ServiceAccess? {
        guard permitsServiceAccess else { return nil }
        let current = try keychain.secret(service: service, account: "current")
        let raw: String
        let requiresAppleVerification: Bool
        if let current {
            raw = current; requiresAppleVerification = defaults.bool(forKey: deniedKey)
        } else if let retired = try keychain.secret(service: service, account: "deletion-account") {
            raw = retired; requiresAppleVerification = true
        } else { return nil }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(raw.utf8))
        let value = try validated(url: saved.workerURL.absoluteString, token: saved.accessToken)
        guard value.accessToken.hasPrefix("ri1.") else { return nil }
        let parts = value.accessToken.split(separator: ".").map(String.init)
        guard parts.count == 4, UUID(uuidString: parts[2]) != nil,
              let device = try keychain.secret(service: service, account: "device-id"), device.lowercased() == parts[2]
        else { throw KeychainSecretStoreError.invalidData }
        guard let principal = saved.binding?.principal, principal.isValid,
              principal.issuer == IdentityEncoding.origin(value.workerURL) else { throw KeychainSecretStoreError.invalidData }
        return .init(workerURL: value.workerURL, accessToken: value.accessToken, deviceID: device.lowercased(), userID: principal.userID, requiresAppleVerification: requiresAppleVerification)
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
        guard let pending = try pendingRevocation(), pending == retired,
              let raw = try keychain.secret(service: service, account: "current") else { return }
        // Preserve the target before removing the callable credential. This entry
        // is read only by explicit account deletion, which requires a fresh proof.
        try keychain.saveSecret(raw, service: service, account: "deletion-account")
        try keychain.deleteSecret(service: service, account: "current")
    }
}
