import Foundation
import Security

struct KeychainFunctions {
    var copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
    var update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
    var delete: (CFDictionary) -> OSStatus = SecItemDelete
}

final class SystemKeychainSecretStore: KeychainSecretStoring {
    private let isIOS: Bool
    private let functions: KeychainFunctions
    private static var isIOSPlatform: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
    init(isIOS: Bool = SystemKeychainSecretStore.isIOSPlatform, functions: KeychainFunctions = .init()) {
        self.isIOS = isIOS; self.functions = functions
    }
    private func accessibility(service: String) -> [String: Any] {
        // Only this app's account-scoped call data needs background access.
        // No Keychain access group or extension sharing is introduced.
        let services = [".AppleAccount", ".AccountDeletion", ".GroupCredential.v2", ".InternetConnection", ".DirectInvitations"]
        guard isIOS, services.contains(where: { service.hasSuffix($0) }) else { return [:] }
        return [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }

    func accounts(service: String) throws -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = functions.copy(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainSecretStoreError.unexpectedStatus(status) }
        guard let rows = result as? [[String: Any]] else { throw KeychainSecretStoreError.invalidData }
        return try rows.map {
            guard let account = $0[kSecAttrAccount as String] as? String else { throw KeychainSecretStoreError.invalidData }
            return account
        }
    }

    func deleteSecret(service: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = functions.delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.unexpectedStatus(status)
        }
    }

    func createSecretIfAbsent(_ secret: String, service: String, account: String) throws -> String {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8)]
        query.merge(accessibility(service: service)) { _, new in new }
        let status = functions.add(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw KeychainSecretStoreError.unexpectedStatus(status)
        }
        guard let retained = try self.secret(service: service, account: account) else {
            throw KeychainSecretStoreError.invalidData
        }
        return retained
    }

    func saveSecret(_ secret: String, service: String, account: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var attributes = accessibility(service: service)
        attributes[kSecValueData as String] = data
        let updateStatus = functions.update(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainSecretStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let addStatus = functions.add(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainSecretStoreError.unexpectedStatus(addStatus)
        }
    }

    func secret(service: String, account: String) throws -> String? {
        let attributes = accessibility(service: service)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !attributes.isEmpty { query[kSecReturnAttributes as String] = true }
        var result: CFTypeRef?
        let status = functions.copy(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainSecretStoreError.unexpectedStatus(status)
        }
        let row = result as? [String: Any]
        let bytes = attributes.isEmpty ? result as? Data : row?[kSecValueData as String] as? Data
        guard let data = bytes, let secret = String(data: data, encoding: .utf8) else {
            throw KeychainSecretStoreError.invalidData
        }
        if !attributes.isEmpty,
           row?[kSecAttrAccessible as String] as? String != kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String {
            // Upgrade existing items only after a successful read. A locked or
            // inaccessible item is never treated as absent or replaced.
            let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account]
            let updated = functions.update(identity as CFDictionary, attributes as CFDictionary)
            guard updated == errSecSuccess else { throw KeychainSecretStoreError.unexpectedStatus(updated) }
        }
        return secret
    }
}
