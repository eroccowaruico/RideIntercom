import Foundation
@testable import RideIntercom

final class InMemoryLocalMemberIdentityStore: LocalMemberIdentityStoring {
    private var identity: LocalMemberIdentity?
    private let makeID: () -> String
    private let defaultDisplayName: () -> String

    init(
        identity: LocalMemberIdentity? = nil,
        makeID: @escaping () -> String = { "member-\(UUID().uuidString.prefix(8).lowercased())" },
        defaultDisplayName: @escaping () -> String = { "You" }
    ) {
        self.identity = identity
        self.makeID = makeID
        self.defaultDisplayName = defaultDisplayName
    }

    func loadOrCreate() -> LocalMemberIdentity {
        if let identity {
            return identity
        }

        let identity = LocalMemberIdentity(memberID: makeID(), displayName: defaultDisplayName())
        self.identity = identity
        return identity
    }
}

final class InMemoryGroupStore: GroupStoring {
    var snapshot: GroupSnapshot
    private(set) var saveCount = 0
    var failSaving = false
    var readError: Error?
    init(groups: [IntercomGroup] = []) { snapshot = GroupSnapshot(groups: groups.map { .init($0) }) }
    func read() throws -> GroupSnapshot? {
        if let readError { throw readError }
        return try snapshot.validated()
    }
    func commit(_ snapshot: GroupSnapshot) throws {
        if failSaving { throw IntercomGroupError.storageUnavailable }
        self.snapshot = snapshot; saveCount += 1
    }
    func loadGroups() -> [IntercomGroup] { snapshot.groups.compactMap { try? $0.group() } }
    func lock() {}
    func unlock() {}
    func archive(legacyData: Data?) {}
}

final class InMemoryGroupCredentialStore: GroupCredentialStoring {
    var values: [UUID: String] = [:]
    var failDeleting = false
    var failReading = false
    func saveSecret(_ secret: String, reference: UUID) { values[reference] = secret }
    func secret(reference: UUID) throws -> String? {
        if failReading { throw IntercomGroupError.storageUnavailable }
        return values[reference]
    }
    func delete(reference: UUID) throws {
        if failDeleting { throw IntercomGroupError.storageUnavailable }
        values[reference] = nil
    }
    func references() -> Set<UUID> { Set(values.keys) }
}

final class InMemoryAppSettingsStore: AppSettingsStoring {
    private var settings: AppSettings

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    func load() -> AppSettings {
        settings
    }

    func save(_ settings: AppSettings) {
        self.settings = settings
    }
}
