import Foundation

struct LocalMemberIdentity: Equatable {
    let memberID: String
    var displayName: String
}

protocol LocalMemberIdentityStoring: AnyObject {
    func loadOrCreate() -> LocalMemberIdentity
}


final class UserDefaultsLocalMemberIdentityStore: LocalMemberIdentityStoring {
    private let defaults: UserDefaults
    private let makeID: () -> String
    private let defaultDisplayName: () -> String
    private let memberIDKey = "RideIntercom.localMemberID"
    private let displayNameKey = "RideIntercom.localDisplayName"

    init(
        defaults: UserDefaults = .standard,
        makeID: @escaping () -> String = { "member-\(UUID().uuidString.prefix(8).lowercased())" },
        defaultDisplayName: @escaping () -> String = { "You" }
    ) {
        self.defaults = defaults
        self.makeID = makeID
        self.defaultDisplayName = defaultDisplayName
    }

    func loadOrCreate() -> LocalMemberIdentity {
        let storedMemberID = defaults.string(forKey: memberIDKey)
        let storedDisplayName = defaults.string(forKey: displayNameKey)
        if let storedMemberID, let storedDisplayName {
            return LocalMemberIdentity(memberID: storedMemberID, displayName: storedDisplayName)
        }

        let identity = LocalMemberIdentity(
            memberID: storedMemberID ?? makeID(),
            displayName: storedDisplayName ?? defaultDisplayName()
        )
        defaults.set(identity.memberID, forKey: memberIDKey)
        defaults.set(identity.displayName, forKey: displayNameKey)
        return identity
    }
}

protocol GroupStoring: AnyObject {
    func loadGroups() throws -> [IntercomGroup]
    func saveGroups(_ groups: [IntercomGroup]) throws
}


final class UserDefaultsGroupStore: GroupStoring {
    private let defaults: UserDefaults
    private let groupsKey = "RideIntercom.groups"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private struct MemberRecord: Codable { let id: String; let displayName: String }
    private struct GroupRecord: Codable { let id: UUID; let name: String; let members: [MemberRecord] }

    func loadGroups() throws -> [IntercomGroup] {
        guard let value = defaults.object(forKey: groupsKey) else { return [] }
        guard let data = value as? Data, data.count <= 1_048_576 else { throw IntercomGroupError.invalidStoredGroups }
        let records = try JSONDecoder().decode([GroupRecord].self, from: data)
        let groups = try records.map { record in
            try IntercomGroup(id: record.id, name: record.name,
                members: record.members.map { GroupMember(id: $0.id, displayName: $0.displayName) })
        }
        try validate(groups)
        return groups
    }

    func saveGroups(_ groups: [IntercomGroup]) throws {
        try validate(groups)
        let records = groups.map { group in
            GroupRecord(id: group.id, name: group.name, members: group.members.map { MemberRecord(id: $0.id, displayName: $0.displayName) })
        }
        let data = try JSONEncoder().encode(records)
        guard data.count <= 1_048_576 else { throw IntercomGroupError.invalidStoredGroups }
        defaults.set(data, forKey: groupsKey)
    }

    private func validate(_ groups: [IntercomGroup]) throws {
        guard groups.count <= 256, Set(groups.map(\.id)).count == groups.count else { throw IntercomGroupError.invalidStoredGroups }
        for group in groups { _ = try IntercomGroup(id: group.id, name: group.name, members: group.members) }
    }
}

protocol KeychainSecretStoring: AnyObject {
    func saveSecret(_ secret: String, service: String, account: String) throws
    func secret(service: String, account: String) throws -> String?
    func deleteSecret(service: String, account: String) throws
}

final class KeychainGroupCredentialStore: GroupCredentialStoring {
    private let keychain: KeychainSecretStoring
    private let service: String

    init(
        keychain: KeychainSecretStoring = SystemKeychainSecretStore(),
        service: String = "RideIntercom.GroupCredential"
    ) {
        self.keychain = keychain
        self.service = service
    }

    func save(_ credential: GroupAccessCredential) throws {
        try keychain.saveSecret(credential.secret, service: service, account: credential.groupID.uuidString)
    }

    func credential(for groupID: UUID) throws -> GroupAccessCredential? {
        guard let secret = try keychain.secret(service: service, account: groupID.uuidString) else {
            return nil
        }
        return GroupAccessCredential(groupID: groupID, secret: secret)
    }

    func delete(for groupID: UUID) throws {
        try keychain.deleteSecret(service: service, account: groupID.uuidString)
    }
}

enum KeychainSecretStoreError: Error, Equatable {
    case unexpectedStatus(Int32)
    case invalidData
}
