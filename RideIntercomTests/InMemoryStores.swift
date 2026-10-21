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
    private var groups: [IntercomGroup]

    init(groups: [IntercomGroup] = []) {
        self.groups = groups.map { group in
            var group = group
            group.accessSecret = nil
            return group
        }
    }

    func loadGroups() -> [IntercomGroup] {
        groups
    }

    func saveGroups(_ groups: [IntercomGroup]) {
        self.groups = groups.map { group in
            var group = group
            group.accessSecret = nil
            return group
        }
    }
}

final class InMemoryGroupCredentialStore: GroupCredentialStoring {
    private var credentialsByGroupID: [UUID: GroupAccessCredential] = [:]

    func save(_ credential: GroupAccessCredential) {
        credentialsByGroupID[credential.groupID] = credential
    }

    func credential(for groupID: UUID) -> GroupAccessCredential? {
        credentialsByGroupID[groupID]
    }
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
