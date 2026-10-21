import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct GroupTransactionTests {
    @Test func invalidProposedGroupDoesNotMakeCommittedDataCorrupt() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        var group = try f.group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"))
        let original = try Data(contentsOf: f.file.url)
        group.name = ""
        do {
            try f.repository.save([group])
            Issue.record("Invalid proposed group must not be saved")
        } catch {
            #expect(GroupStorageIssue.classify(error) != .corrupted)
        }
        #expect(try Data(contentsOf: f.file.url) == original)
        let saved = try #require(try f.restart().load(localMemberID: "local").first)
        #expect(saved.name == "Saved")
        #expect(throws: GroupStorageError.invalidUpdate) { try f.repository.save([saved, saved]) }
        #expect(try Data(contentsOf: f.file.url) == original)
    }

    @Test func committedSnapshotKeepsOldKeyUntilReplacementAndSweepsOrphans() throws {
        let f = try GroupStorageFixture()
        defer { f.remove() }
        let group = try f.group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "old"))
        let old = try #require(try f.store.read()?.groups.first?.credentialReference)
        f.store.failCommit = true
        #expect(throws: (any Error).self) { try f.repository.save([group], credential: .init(groupID: group.id, secret: "new")) }
        #expect(try f.keys.secret(reference: old) == "old")
        f.store.failCommit = false
        let restarted = f.restart()
        #expect(try restarted.load(localMemberID: "local").count == 1)
        #expect(try restarted.credential(for: group.id)?.secret == "old")
        #expect(f.keys.references() == [old])
        try restarted.save([group], credential: .init(groupID: group.id, secret: "new"))
        #expect(try restarted.credential(for: group.id)?.secret == "new")
        #expect(try f.keys.secret(reference: old) == nil)
    }

    @Test func cleanupFailureDoesNotRollBackCommitOrReviveDeletedGroup() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try f.group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"))
        f.keys.failDeleting = true
        try f.repository.delete(group.id, remaining: [])
        #expect(try f.restart().load(localMemberID: "local").isEmpty)
        #expect(!f.keys.references().isEmpty)
        f.keys.failDeleting = false
        _ = try f.restart().load(localMemberID: "local")
        #expect(f.keys.references().isEmpty)
    }

    @Test func corruptManifestPreservesKeysUntilExplicitReset() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try f.group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"))
        let bytes = Data("{broken".utf8)
        try bytes.write(to: f.file.url)
        let restarted = f.restart()
        #expect(throws: (any Error).self) { try restarted.load(localMemberID: "local") }
        #expect(!f.keys.references().isEmpty)
        try restarted.reset()
        #expect(try restarted.load(localMemberID: "local").isEmpty)
        #expect(f.keys.references().isEmpty)
        let archives = try FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("groups-corrupt-") }
        #expect(archives.count == 1)
        #expect(try Data(contentsOf: #require(archives.first)) == bytes)
    }
}
