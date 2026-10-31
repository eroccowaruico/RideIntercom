import Foundation
import Security
import Testing
@testable import RideIntercom

@MainActor
struct BackgroundCallStorageTests {
    @Test func backgroundCredentialWritesAndExistingReadsUseDeviceOnlyFirstUnlockProtection() throws {
        let fixture = BackgroundKeychainFixture()
        let store = SystemKeychainSecretStore(isIOS: true, functions: fixture.functions)
        try store.saveSecret("original", service: "Test.InternetConnection", account: "identity-key")
        #expect(fixture.lastAttributes?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        let beforeReads = fixture.updateCount
        let retained = try store.createSecretIfAbsent("replacement", service: "Test.InternetConnection", account: "identity-key")
        #expect(retained == "original" && fixture.data == Data("original".utf8))
        #expect(fixture.updateCount == beforeReads)
    }

    @Test func existingCredentialProtectionMigratesOnceWithoutReplacingKeyBytes() throws {
        let fixture = BackgroundKeychainFixture(); fixture.data = Data("original".utf8)
        let store = SystemKeychainSecretStore(isIOS: true, functions: fixture.functions)
        #expect(try store.secret(service: "Test.GroupCredential.v2", account: "key") == "original")
        #expect(fixture.updateCount == 1 && fixture.lastAttributes?[kSecValueData as String] == nil)
        #expect(fixture.protection == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(try store.secret(service: "Test.GroupCredential.v2", account: "key") == "original")
        #expect(fixture.updateCount == 1 && fixture.data == Data("original".utf8))
    }

    @Test func failedProtectionUpgradeDoesNotReplaceTheExistingKey() throws {
        let fixture = BackgroundKeychainFixture(); fixture.data = Data("original".utf8); fixture.updateFails = true
        let store = SystemKeychainSecretStore(isIOS: true, functions: fixture.functions)
        #expect(throws: KeychainSecretStoreError.self) { try store.secret(service: "Test.GroupCredential.v2", account: "key") }
        #expect(fixture.addCount == 0 && fixture.data == Data("original".utf8))
    }

    @Test func inaccessibleCredentialNeverGeneratesAReplacement() throws {
        let fixture = BackgroundKeychainFixture(); fixture.locked = true
        let store = SystemKeychainSecretStore(isIOS: true, functions: fixture.functions)
        let internet = InternetConnectionSettingsStore(keychain: store, namespace: "BackgroundLocked.\(UUID())")
        #expect(throws: KeychainSecretStoreError.self) { try internet.deviceSigningKey() }
        #expect(fixture.addCount == 0 && fixture.updateCount == 0 && fixture.data == nil)
        fixture.locked = false
        _ = try internet.deviceSigningKey()
        #expect(fixture.addCount == 1)
    }

    @Test(arguments: [false, true])
    func unrelatedCredentialsAndMacProtectionAreUnchanged(isIOS: Bool) throws {
        let fixture = BackgroundKeychainFixture()
        let store = SystemKeychainSecretStore(isIOS: isIOS, functions: fixture.functions)
        try store.saveSecret("secret", service: isIOS ? "unrelated-service" : "Test.AppleAccount", account: "current")
        #expect(fixture.lastAttributes?[kSecAttrAccessible as String] == nil)
    }

    @Test func fileProtectionFailurePreservesExistingGroupsAndCanRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "BackgroundGroups-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = FileGroupStore(directory: directory)
        let expected = GroupSnapshot(groups: [])
        try initial.lock(); try initial.commit(expected); initial.unlock()
        let bytes = try Data(contentsOf: initial.url)
        var unavailable = true
        let store = FileGroupStore(directory: directory, prepareProtection: { _ in
            if unavailable { throw CocoaError(.fileReadNoPermission) }
        })
        #expect(throws: (any Error).self) { try store.lock() }
        #expect(try Data(contentsOf: initial.url) == bytes)
        unavailable = false
        try store.lock(); defer { store.unlock() }
        #expect(try store.read() == expected)
    }
}

private final class BackgroundKeychainFixture {
    var data: Data?
    var locked = false
    var updateFails = false
    var protection: String?
    var addCount = 0
    var updateCount = 0
    var lastAttributes: [String: Any]?
    var functions: KeychainFunctions {
        .init(copy: { [self] query, result in
            if locked { return errSecInteractionNotAllowed }
            guard let data else { return errSecItemNotFound }
            let attributes = query as! [String: Any]
            if attributes[kSecReturnAttributes as String] as? Bool == true {
                var row: [String: Any] = [kSecValueData as String: data]
                if let protection { row[kSecAttrAccessible as String] = protection }
                result?.pointee = row as CFDictionary
            } else { result?.pointee = data as CFData }
            return errSecSuccess
        }, add: { [self] query, _ in
            addCount += 1
            if data != nil { return errSecDuplicateItem }
            let attributes = query as! [String: Any]
            data = attributes[kSecValueData as String] as? Data
            lastAttributes = attributes
            if let value = attributes[kSecAttrAccessible as String] as? String { protection = value }
            return errSecSuccess
        }, update: { [self] _, values in
            updateCount += 1
            if updateFails { return errSecInteractionNotAllowed }
            guard data != nil else { return errSecItemNotFound }
            let attributes = values as! [String: Any]
            if let changed = attributes[kSecValueData as String] as? Data { data = changed }
            lastAttributes = attributes
            if let value = attributes[kSecAttrAccessible as String] as? String { protection = value }
            return errSecSuccess
        }, delete: { _ in errSecSuccess })
    }
}
