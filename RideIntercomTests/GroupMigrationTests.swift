import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct GroupMigrationTests {
    @Test func validJSONWithInvalidGroupIdentityOffersCorruptionRecovery() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try f.group()
        var snapshot = GroupSnapshot(groups: [.init(group)])
        snapshot.groups[0].name = ""
        try JSONEncoder().encode(snapshot).write(to: f.file.url)
        do {
            _ = try f.restart().load(localMemberID: "local")
            Issue.record("Invalid saved name must fail loading")
        } catch {
            #expect(GroupStorageIssue.classify(error) == .corrupted)
        }
    }

    @Test func interruptedMigrationRetriesFromLegacyAndSweepsPreparedKeys() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.file.url)
        let suite = "RideIntercom.fixture.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let group = try f.group()
        let original = try JSONEncoder().encode([GroupSnapshot.Record(group)])
        defaults.set(original, forKey: "RideIntercom.groups")
        let keychain = DictionaryKeychain()
        try keychain.saveSecret("legacy-key", service: "RideIntercom.GroupCredential", account: group.id.uuidString)
        let legacy = LegacyGroupReader(defaults: defaults, keychain: keychain)
        let repository = GroupRepository(store: f.store, credentials: f.keys, legacy: legacy)
        f.store.failCommit = true
        #expect(throws: (any Error).self) { try repository.load(localMemberID: "local") }
        #expect(defaults.data(forKey: "RideIntercom.groups") == original)
        #expect(try keychain.secret(service: "RideIntercom.GroupCredential", account: group.id.uuidString) == "legacy-key")
        #expect(f.keys.references().count == 1)
        f.store.failCommit = false
        _ = try repository.load(localMemberID: "local")
        #expect(try repository.credential(for: group.id)?.secret == "legacy-key")
        #expect(f.keys.references().count == 1)
        #expect(defaults.object(forKey: "RideIntercom.groups") == nil)
    }

    @Test func malformedLegacyResetArchivesOriginalBeforeRemovingDefaults() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.file.url)
        let suite = "RideIntercom.fixture.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unreadable-legacy", forKey: "RideIntercom.groups")
        let repository = GroupRepository(store: f.store, credentials: f.keys,
                                         legacy: LegacyGroupReader(defaults: defaults, keychain: DictionaryKeychain()))
        #expect(throws: IntercomGroupError.invalidStoredGroups) { try repository.load(localMemberID: "local") }
        f.store.failArchive = true
        #expect(throws: (any Error).self) { try repository.reset() }
        #expect(defaults.string(forKey: "RideIntercom.groups") == "unreadable-legacy")
        f.store.failArchive = false
        try repository.reset()
        #expect(defaults.object(forKey: "RideIntercom.groups") == nil)
        let archive = try #require(try FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "plist" })
        let restored = try PropertyListSerialization.propertyList(from: Data(contentsOf: archive), format: nil) as? [String: String]
        #expect(restored?["RideIntercom.groups"] == "unreadable-legacy")
        #expect(try repository.load(localMemberID: "local").isEmpty)
    }

    @Test func migrationCopiesKeysAndDoesNotRepeatOrTouchOtherSettings() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.file.url)
        let suite = "RideIntercom.fixture.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let group = try f.group()
        defaults.set(try JSONEncoder().encode([GroupSnapshot.Record(group)]), forKey: "RideIntercom.groups")
        defaults.set("local", forKey: "RideIntercom.localMemberID")
        let keychain = DictionaryKeychain()
        try keychain.saveSecret("old-key", service: "RideIntercom.GroupCredential", account: group.id.uuidString)
        try keychain.saveSecret("internet", service: "RideIntercom.InternetConnection", account: "current")
        let repository = GroupRepository(store: f.file, credentials: f.keys, legacy: LegacyGroupReader(defaults: defaults, keychain: keychain))
        #expect(try repository.load(localMemberID: "local").map(\.id) == [group.id])
        #expect(try repository.credential(for: group.id)?.secret == "old-key")
        #expect(defaults.object(forKey: "RideIntercom.groups") == nil)
        #expect(defaults.string(forKey: "RideIntercom.localMemberID") == "local")
        #expect(try keychain.secret(service: "RideIntercom.InternetConnection", account: "current") == "internet")
        let reference = try #require(try f.file.read()?.groups.first?.credentialReference)
        _ = try repository.load(localMemberID: "local")
        #expect(f.keys.references() == [reference])
        try repository.reset()
        #expect(try repository.load(localMemberID: "local").isEmpty)
        #expect(defaults.string(forKey: "RideIntercom.localMemberID") == "local")
        #expect(try keychain.secret(service: "RideIntercom.InternetConnection", account: "current") == "internet")
    }

    @Test func interruptionAfterCommitKeepsNewKeyAndNeverRollsBack() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try f.group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "old"))
        f.store.failAfterCommit = true
        #expect(throws: (any Error).self) { try f.repository.save([group], credential: .init(groupID: group.id, secret: "new")) }
        f.store.failAfterCommit = false
        let restarted = f.restart()
        _ = try restarted.load(localMemberID: "local")
        #expect(try restarted.credential(for: group.id)?.secret == "new")
        #expect(f.keys.values.values.sorted() == ["new"])
    }

    @Test func missingKeysAreDifferentFromTemporarilyUnavailableKeys() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try f.group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"))
        f.keys.failReading = true
        let restarted = f.restart()
        #expect(throws: (any Error).self) { try restarted.load(localMemberID: "local") }
        #expect(f.keys.values.count == 1)
        f.keys.failReading = false
        f.keys.values.removeAll()
        #expect(try restarted.load(localMemberID: "local").count == 1)
        #expect(restarted.missingCredentialGroupIDs == [group.id])
        #expect(try restarted.credential(for: group.id) == nil)
        try restarted.save([group], credential: .init(groupID: group.id, secret: "reinvited"))
        #expect(restarted.missingCredentialGroupIDs.isEmpty)
    }

    @Test func newerSchemaRefusesResetAndArchiveFailurePreservesManifest() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let newer = Data("{\"version\":99}".utf8)
        try newer.write(to: f.file.url)
        #expect(throws: GroupStorageError.unsupportedVersion) { try f.restart().reset() }
        #expect(try Data(contentsOf: f.file.url) == newer)
        let broken = Data("broken".utf8)
        try broken.write(to: f.file.url)
        f.store.failArchive = true
        #expect(throws: (any Error).self) { try f.restart().reset() }
        #expect(try Data(contentsOf: f.file.url) == broken)
    }

    @Test func concurrentStoreIsBusyAndStaleRepositoryMustReload() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let otherFile = FileGroupStore(directory: f.directory)
        try f.file.lock()
        #expect(throws: GroupStorageError.busy) { try otherFile.lock() }
        f.file.unlock()
        let other = GroupRepository(store: otherFile, credentials: f.keys)
        _ = try other.load(localMemberID: "local")
        let group = try f.group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"))
        #expect(throws: GroupStorageError.changedByAnotherProcess) { try other.save([]) }
        #expect(try other.load(localMemberID: "local").map(\.id) == [group.id])
        #expect(try other.credential(for: group.id)?.secret == "key")
    }

    @Test func realKeychainVersionedStoreListsOnlyItsOwnNamespace() throws {
        let namespace = "RideIntercom.fixture.\(UUID())"
        let store = KeychainGroupCredentialStore(namespace: namespace)
        let reference = UUID()
        defer { try? store.delete(reference: reference) }
        try store.saveSecret("fixture-secret", reference: reference)
        #expect(try store.secret(reference: reference) == "fixture-secret")
        #expect(try store.references() == [reference])
        #expect(throws: GroupStorageError.verificationFailed) { try store.saveSecret("overwrite", reference: reference) }
        try store.delete(reference: reference)
        #expect(try store.references().isEmpty)
    }
}

final class DictionaryKeychain: KeychainSecretStoring {
    private(set) var readCount = 0
    private var values: [String: [String: String]] = [:]
    func accounts(service: String) -> [String] { Array(values[service, default: [:]].keys) }
    func createSecretIfAbsent(_ value: String, service: String, account: String) throws -> String {
        if let retained = try secret(service: service, account: account) { return retained }
        try saveSecret(value, service: service, account: account)
        return value
    }
    func saveSecret(_ secret: String, service: String, account: String) throws { values[service, default: [:]][account] = secret }
    func secret(service: String, account: String) throws -> String? { readCount += 1; return values[service]?[account] }
    func deleteSecret(service: String, account: String) throws { values[service]?[account] = nil }
}
