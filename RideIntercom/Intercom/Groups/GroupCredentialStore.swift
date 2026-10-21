import Foundation

final class KeychainGroupCredentialStore: GroupCredentialStoring {
    private let service: String
    private let keychain: KeychainSecretStoring
    init(keychain: KeychainSecretStoring = SystemKeychainSecretStore(), namespace: String = "RideIntercom") {
        self.keychain = keychain; self.service = namespace + ".GroupCredential.v2"
    }
    func saveSecret(_ secret: String, reference: UUID) throws {
        guard try keychain.secret(service: service, account: reference.uuidString) == nil else { throw GroupStorageError.verificationFailed }
        try keychain.saveSecret(secret, service: service, account: reference.uuidString)
    }
    func secret(reference: UUID) throws -> String? { try keychain.secret(service: service, account: reference.uuidString) }
    func delete(reference: UUID) throws { try keychain.deleteSecret(service: service, account: reference.uuidString) }
    func references() throws -> Set<UUID> { Set(try keychain.accounts(service: service).compactMap(UUID.init(uuidString:))) }
}

/// Read-only migration boundary; the current app never writes the legacy format.
final class LegacyGroupReader {
    private let defaults: UserDefaults
    private let keychain: KeychainSecretStoring
    private let service: String
    init(defaults: UserDefaults = .standard, keychain: KeychainSecretStoring = SystemKeychainSecretStore(), namespace: String = "RideIntercom") {
        self.defaults = defaults; self.keychain = keychain; self.service = namespace + ".GroupCredential"
    }
    func read() throws -> [IntercomGroup] {
        guard let value = defaults.object(forKey: "RideIntercom.groups") else { return [] }
        guard let data = value as? Data, data.count <= 1_048_576 else { throw IntercomGroupError.invalidStoredGroups }
        let records = try JSONDecoder().decode([GroupSnapshot.Record].self, from: data)
        do {
            _ = try GroupSnapshot(groups: records).validated()
            return try records.map { try $0.group() }
        } catch is IntercomGroupError { throw IntercomGroupError.invalidStoredGroups }
    }
    func secret(for id: UUID) throws -> String? { try keychain.secret(service: service, account: id.uuidString) }
    func cleanup() throws {
        // Remove only this app's legacy group service, never Internet or identity data.
        for account in try keychain.accounts(service: service) where UUID(uuidString: account) != nil {
            try keychain.deleteSecret(service: service, account: account)
        }
        defaults.removeObject(forKey: "RideIntercom.groups")
    }
    func archiveData() throws -> Data? {
        guard let value = defaults.object(forKey: "RideIntercom.groups") else { return nil }
        return try PropertyListSerialization.data(fromPropertyList: ["RideIntercom.groups": value], format: .binary, options: 0)
    }
}
