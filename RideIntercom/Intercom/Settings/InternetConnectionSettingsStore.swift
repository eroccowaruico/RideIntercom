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
    private let resetKey = "InternetAccount.requiresDataReset"
    var requiresAccountDataReset: Bool { defaults.bool(forKey: resetKey) }
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
    enum ValidationError: Error { case invalidURL, missingToken, disabledDuringLocalTests, accountReplaced }
    private func validated(url: String, token: String) throws -> Saved {
        guard let url = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { throw ValidationError.invalidURL }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= 256 else { throw ValidationError.missingToken }
        return Saved(workerURL: url, accessToken: token)
    }
    func save(url: String, token: String, identity: VerifiedDeviceIdentity? = nil) throws {
        guard permitsServiceAccess else { throw ValidationError.disabledDuringLocalTests }
        guard !requiresAccountDataReset else { throw ValidationError.accountReplaced }
        var saved = try validated(url: url, token: token)
        if let identity {
            guard let key = try storedDeviceSigningKey(), identity.issuer == IdentityEncoding.origin(saved.workerURL),
                  identity.deviceKey == IdentityEncoding.encode(key.publicKey.x963Representation) else { throw ValidationError.missingToken }
            if let previous = try verifiedRegistration()?.saved.binding?.principal,
               previous.issuer == identity.issuer, previous.userID != identity.userID {
                // The authenticated service confirmed a new account generation.
                // Preserve the old data and target until the user clears them.
                defaults.set(true, forKey: resetKey)
                defaults.set(true, forKey: deniedKey)
                throw ValidationError.accountReplaced
            }
            saved.identity = identity.envelope
            saved.memberID = identity.memberID
            saved.binding = AccountDeviceBinding(principal: .init(issuer: identity.issuer, userID: identity.userID), publicKey: identity.deviceKey)
        }
        if identity == nil, let current = try registration(account: "current"), current.saved.binding != nil {
            try validateBinding(current.saved)
            // A manual credential must not erase the last verified account or
            // let a later Apple registration bypass generation comparison.
            try keychain.saveSecret(current.raw, service: service, account: "deletion-account")
        }
        let data = try JSONEncoder().encode(saved)
        try keychain.saveSecret(String(decoding: data, as: UTF8.self), service: service, account: "current")
        defaults.set(false, forKey: deniedKey)
    }
    func load() throws -> RTC.CloudflareRealtimeConfiguration? {
        guard permitsServiceAccess, !requiresAccountDataReset, !defaults.bool(forKey: deniedKey) else { return nil }
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
        guard permitsServiceAccess, !requiresAccountDataReset, !defaults.bool(forKey: deniedKey),
              let raw = try keychain.secret(service: service, account: "current") else { return nil }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(raw.utf8))
        guard let envelope = saved.identity else { return nil }
        let identity = try envelope.verify(origin: saved.workerURL, trustedIssuerKey: envelope.issuerKey)
        guard let key = try storedDeviceSigningKey(), identity.memberID == memberID,
              identity.deviceKey == IdentityEncoding.encode(key.publicKey.x963Representation) else { throw KeychainSecretStoreError.invalidData }
        return identity
    }

    /// Previously verified local identity survives certificate expiry and Internet
    /// sign-out. The native login still gates calls in the account-scoped model.
    /// This cache never certifies a new peer or signs a new account invitation.
    func loadPrincipal(memberID: String) throws -> AccountPrincipal? {
        guard let saved = try retainedRegistration() else { return nil }
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
        guard let saved = try retainedRegistration(), let certificate = saved.identity else { return nil }
        return DeviceIdentityTrust(origin: saved.workerURL, issuerKey: certificate.issuerKey)
    }

    /// Identity and issuer verification keys are not Internet credentials. A
    /// replacement current record takes precedence, including one without proof.
    private func retainedRegistration() throws -> Saved? {
        guard permitsServiceAccess, !requiresAccountDataReset,
              let raw = try keychain.secret(service: service, account: "current")
                ?? keychain.secret(service: service, account: "deletion-account") else { return nil }
        return try JSONDecoder().decode(Saved.self, from: Data(raw.utf8))
    }

    private func registration(account: String) throws -> (saved: Saved, raw: String)? {
        guard let raw = try keychain.secret(service: service, account: account) else { return nil }
        return (try JSONDecoder().decode(Saved.self, from: Data(raw.utf8)), raw)
    }

    private func validateBinding(_ saved: Saved) throws {
        // Deletion recovery must still work if this device's signing key was
        // lost. Calls validate that key separately in loadPrincipal/loadIdentity.
        guard let binding = saved.binding, binding.principal.isValid,
              binding.principal.issuer == IdentityEncoding.origin(saved.workerURL)
        else { throw KeychainSecretStoreError.invalidData }
    }

    /// Current verified registration wins. A manual current record does not hide
    /// the last verified registration retained for deletion and generation checks.
    private func verifiedRegistration() throws -> (saved: Saved, archived: Bool)? {
        for account in ["current", "deletion-account"] {
            if let value = try registration(account: account), value.saved.binding != nil {
                try validateBinding(value.saved)
                return (value.saved, account != "current")
            }
        }
        return nil
    }

    func accountDeviceID() throws -> String {
        guard permitsServiceAccess else { throw ValidationError.disabledDuringLocalTests }
        if let stored = try existingAccountDeviceID() { return stored }
        let id = UUID().uuidString.lowercased()
        try keychain.saveSecret(id, service: service, account: "device-id")
        return id
    }

    func existingAccountDeviceID() throws -> String? {
        guard permitsServiceAccess, let stored = try keychain.secret(service: service, account: "device-id") else { return nil }
        guard UUID(uuidString: stored) != nil else { throw KeychainSecretStoreError.invalidData }
        return stored.lowercased()
    }

    /// Never use a development fallback, manufacture a device ID, or mistake an
    /// unreadable saved credential for a local-only account during deletion.
    func deletionAccess() throws -> AccountDeletion.ServiceAccess? {
        guard permitsServiceAccess else { return nil }
        let verified = try verifiedRegistration()
        let saved: Saved
        let requiresAppleVerification: Bool
        if let verified {
            saved = verified.saved
            requiresAppleVerification = requiresAccountDataReset || verified.archived || defaults.bool(forKey: deniedKey)
        } else {
            // Preserve the existing rejection of unverified ri1 credentials. A
            // missing reset target must never turn into local-only deletion.
            guard !requiresAccountDataReset else { throw KeychainSecretStoreError.invalidData }
            guard let unverified = try registration(account: "current") ?? registration(account: "deletion-account") else { return nil }
            saved = unverified.saved
            requiresAppleVerification = defaults.bool(forKey: deniedKey)
        }
        let value = try validated(url: saved.workerURL.absoluteString, token: saved.accessToken)
        guard value.accessToken.hasPrefix("ri1.") else {
            if requiresAccountDataReset { throw KeychainSecretStoreError.invalidData }
            return nil
        }
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
        guard permitsServiceAccess, !requiresAccountDataReset, defaults.bool(forKey: deniedKey),
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
        // supplies offline identity and explicit account deletion, never access.
        // Deletion of this retired registration requires a fresh Apple proof.
        // An unverified manual credential may also use ri1. Its sign-out must
        // not replace a previously verified account retained for recovery.
        if try verifiedRegistration()?.archived != true {
            try keychain.saveSecret(raw, service: service, account: "deletion-account")
        }
        try keychain.deleteSecret(service: service, account: "current")
    }

    var notificationRegistrationEnabled: Bool {
        get { defaults.bool(forKey: "CallNotifications.enabled") }
        set { defaults.set(newValue, forKey: "CallNotifications.enabled") }
    }
    var notificationRemovalPending: Bool {
        get { defaults.bool(forKey: "CallNotifications.removalPending") }
        set { defaults.set(newValue, forKey: "CallNotifications.removalPending") }
    }
    private func notificationIssuedRevision() throws -> UInt64 {
        guard let raw = defaults.object(forKey: "CallNotifications.issuedRevision") else { return 0 }
        guard let text = raw as? String, let value = UInt64(text), String(value) == text,
              value < UInt64.max else { throw KeychainSecretStoreError.invalidData }
        return value
    }
    func retainNotificationRevision(atLeast revision: UInt64) throws {
        guard revision < UInt64.max else { throw KeychainSecretStoreError.invalidData }
        let value = max(try notificationIssuedRevision(), revision)
        defaults.set(String(value), forKey: "CallNotifications.issuedRevision")
    }
    func nextNotificationRevision(after revision: UInt64) throws -> UInt64 {
        let previous = max(try notificationIssuedRevision(), revision)
        guard previous < UInt64.max - 1 else { throw KeychainSecretStoreError.invalidData }
        let next = previous + 1
        defaults.set(String(next), forKey: "CallNotifications.issuedRevision")
        return next
    }
    func notificationAccess(memberID: String) throws -> CallNotificationServiceAccess? {
        guard let configuration = try load(), let principal = try loadPrincipal(memberID: memberID),
              principal.issuer == IdentityEncoding.origin(configuration.workerURL),
              let deviceID = try existingAccountDeviceID() else { return nil }
        let parts = configuration.accessToken.split(separator: ".").map(String.init)
        guard parts.count == 4, parts[0] == "ri1", parts[2] == deviceID else { return nil }
        return .init(origin: configuration.workerURL, accessToken: configuration.accessToken, principal: principal)
    }
    func notificationPermissions() throws -> [CallNotificationPermission] {
        guard permitsServiceAccess, let raw = try keychain.secret(service: service, account: "notification-permissions") else { return [] }
        let records = try JSONDecoder().decode([CallNotificationPermission].self, from: Data(raw.utf8))
        guard records.count <= 256, Set(records.map(\.contactID)).count == records.count,
              Set(records.map { $0.owner.issuer + "|" + $0.owner.userID + "|" + $0.peer.userID }).count == records.count,
              records.allSatisfy(\.isValid) else { throw KeychainSecretStoreError.invalidData }
        return records
    }
    func saveNotificationPermissions(_ records: [CallNotificationPermission]) throws {
        guard permitsServiceAccess, records.count <= 256, Set(records.map(\.contactID)).count == records.count,
              Set(records.map { $0.owner.issuer + "|" + $0.owner.userID + "|" + $0.peer.userID }).count == records.count,
              records.allSatisfy(\.isValid) else { throw KeychainSecretStoreError.invalidData }
        let data = try JSONEncoder().encode(records)
        try keychain.saveSecret(String(decoding: data, as: UTF8.self), service: service, account: "notification-permissions")
    }

}
