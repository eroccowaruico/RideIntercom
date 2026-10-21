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
    func loadGroups() -> [IntercomGroup]
    func saveGroups(_ groups: [IntercomGroup])
}


final class UserDefaultsGroupStore: GroupStoring {
    private let defaults: UserDefaults
    private let groupsKey = "RideIntercom.groups"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadGroups() -> [IntercomGroup] {
        guard let data = defaults.data(forKey: groupsKey),
              let groups = try? JSONDecoder().decode([IntercomGroup].self, from: data) else {
            return []
        }
        return groups
    }

    func saveGroups(_ groups: [IntercomGroup]) {
        let persistableGroups = groups.map { group in
            var group = group
            group.accessSecret = nil
            return group
        }
        guard let data = try? JSONEncoder().encode(persistableGroups) else { return }
        defaults.set(data, forKey: groupsKey)
    }
}

protocol KeychainSecretStoring: AnyObject {
    func saveSecret(_ secret: String, service: String, account: String) throws
    func secret(service: String, account: String) throws -> String?
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

    func save(_ credential: GroupAccessCredential) {
        try? keychain.saveSecret(credential.secret, service: service, account: credential.groupID.uuidString)
    }

    func credential(for groupID: UUID) -> GroupAccessCredential? {
        guard let secret = (try? keychain.secret(service: service, account: groupID.uuidString)) ?? nil else {
            return nil
        }
        return GroupAccessCredential(groupID: groupID, secret: secret)
    }
}

enum KeychainSecretStoreError: Error, Equatable {
    case unexpectedStatus(Int32)
    case invalidData
}
