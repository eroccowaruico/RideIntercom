import Foundation

/// Erases only this native account's local namespace, under the repository lock.
/// An empty manifest changes its generation so an old repository cannot save stale data.
struct AccountDataEraser {
    static let keychainSuffixes = [".GroupCredential.v2", ".GroupCredential", ".InternetConnection", ".DirectInvitations"]
    let keychain: KeychainSecretStoring
    let namespace: String
    let applicationSupport: URL

    func erase(userID: String, retainingDeviceID: String? = nil) throws {
        if let retainingDeviceID, UUID(uuidString: retainingDeviceID) == nil { throw KeychainSecretStoreError.invalidData }
        let scoped = AppleAccountSession.storageNamespace(base: namespace, userID: userID)
        let directory = applicationSupport.appendingPathComponent(scoped, isDirectory: true)
        let groups = directory.appendingPathComponent("Groups", isDirectory: true)
        for url in [directory, groups] {
            if try url.resourceValuesIfPresent()?.isSymbolicLink == true { throw GroupStorageError.verificationFailed }
        }
        let store = FileGroupStore(directory: groups)
        try store.lock(); defer { store.unlock() }
        try store.commit(GroupSnapshot())
        for suffix in Self.keychainSuffixes {
            let service = scoped + suffix
            for account in try keychain.accounts(service: service) { try keychain.deleteSecret(service: service, account: account) }
            guard try keychain.accounts(service: service).isEmpty else { throw GroupStorageError.verificationFailed }
        }
        for url in try FileManager.default.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)
            where !["groups.json", "groups.lock"].contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent != "Groups" {
            try FileManager.default.removeItem(at: url)
        }
        // Replacement setup reuses the same server registration slot. A failed
        // best-effort revoke must not accumulate unreachable device registrations.
        // No bearer, membership, principal, or signing key survives this cleanup.
        if let retainingDeviceID {
            try keychain.saveSecret(retainingDeviceID, service: scoped + ".InternetConnection", account: "device-id")
        }
        UserDefaults(suiteName: scoped)!.removePersistentDomain(forName: scoped)
    }
}

private extension URL {
    func resourceValuesIfPresent() throws -> URLResourceValues? {
        do { return try resourceValues(forKeys: [.isSymbolicLinkKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
}
