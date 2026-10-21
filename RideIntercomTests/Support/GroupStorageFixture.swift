import Foundation
@testable import RideIntercom

@MainActor
final class GroupStorageFixture {
    let directory: URL
    let file: FileGroupStore
    let store: FailingFileGroupStore
    let keys = InMemoryGroupCredentialStore()
    let repository: GroupRepository
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RideIntercom-groups-\(UUID())")
        file = FileGroupStore(directory: directory)
        store = FailingFileGroupStore(file)
        repository = GroupRepository(store: store, credentials: keys)
        _ = try repository.load(localMemberID: "local")
    }
    func group() throws -> IntercomGroup { try IntercomGroup(name: "Saved", members: [.init(id: "local", displayName: "You")]) }
    func restart() -> GroupRepository { GroupRepository(store: store, credentials: keys) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

final class FailingFileGroupStore: GroupStoring {
    let file: FileGroupStore
    var failCommit = false
    var failAfterCommit = false
    var failArchive = false
    init(_ file: FileGroupStore) { self.file = file }
    func read() throws -> GroupSnapshot? { try file.read() }
    func commit(_ snapshot: GroupSnapshot) throws {
        if failCommit { throw IntercomGroupError.storageUnavailable }
        try file.commit(snapshot)
        if failAfterCommit { throw IntercomGroupError.storageUnavailable }
    }
    func lock() throws { try file.lock() }
    func unlock() { file.unlock() }
    func archive(legacyData: Data?) throws {
        if failArchive { throw IntercomGroupError.storageUnavailable }
        try file.archive(legacyData: legacyData)
    }
}
