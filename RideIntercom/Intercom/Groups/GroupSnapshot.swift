import Foundation

/// Durable identity only. Runtime state and secrets never enter this format.
struct GroupSnapshot: Codable, Equatable {
    struct Member: Codable, Equatable {
        var id: String
        var displayName: String
        var userID: UUID?
    }
    struct Record: Codable, Equatable {
        var id: UUID
        var name: String
        var members: [Member]
        var credentialReference: UUID?
        var pendingInvitation: DirectInvitationReceipt?
        var receivedInvitationIDs: [UUID] = []

        init(_ group: IntercomGroup, credentialReference: UUID? = nil) {
            id = group.id; name = group.name
            members = group.members.map { Member(id: $0.id, displayName: $0.displayName) }
            self.credentialReference = credentialReference
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, members, credentialReference, pendingInvitation, receivedInvitationIDs
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            members = try values.decode([Member].self, forKey: .members)
            credentialReference = try values.decodeIfPresent(UUID.self, forKey: .credentialReference)
            pendingInvitation = try values.decodeIfPresent(DirectInvitationReceipt.self, forKey: .pendingInvitation)
            receivedInvitationIDs = try values.decodeIfPresent([UUID].self, forKey: .receivedInvitationIDs) ?? []
        }
        func group() throws -> IntercomGroup {
            try IntercomGroup(id: id, name: name, members: members.map { GroupMember(id: $0.id, displayName: $0.displayName) })
        }
    }
    var version = 2
    var generation = UUID()
    var groups: [Record] = []
    var users: [SavedUser] = []

    init(groups: [Record] = [], users: [SavedUser] = []) {
        self.groups = groups
        self.users = users
        synchronizeUserReferences()
    }

    private enum CodingKeys: String, CodingKey { case version, generation, groups, users }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        generation = try values.decode(UUID.self, forKey: .generation)
        groups = try values.decode([Record].self, forKey: .groups)
        // A missing directory is valid only in the old format. Never replace
        // unreadable or missing current-format users with an empty directory.
        users = version == 1 ? [] : try values.decode([SavedUser].self, forKey: .users)
    }

    func upgraded() -> GroupSnapshot {
        guard version == 1 else { return self }
        return GroupSnapshot(groups: groups)
    }

    mutating func synchronizeUserReferences() {
        let directory = Dictionary(users.flatMap { user in user.memberIDs.map { ($0, user) } },
                               uniquingKeysWith: { first, _ in first })
        for groupIndex in groups.indices {
            for index in groups[groupIndex].members.indices {
                let member = groups[groupIndex].members[index]
                // Group presence is not a direct invitation. Keep group metadata
                // without copying unrelated riders into the address book.
                groups[groupIndex].members[index].userID = directory[member.id]?.id
                if let user = directory[member.id] { groups[groupIndex].members[index].displayName = user.displayName }
            }
        }
    }

    func validated() throws -> GroupSnapshot {
        guard version == 1 || version == 2 else { throw GroupStorageError.unsupportedVersion }
        guard groups.count <= 256, Set(groups.map(\.id)).count == groups.count else { throw IntercomGroupError.invalidStoredGroups }
        let references = groups.compactMap(\.credentialReference)
        guard Set(references).count == references.count else { throw IntercomGroupError.invalidStoredGroups }
        for record in groups { _ = try record.group() }
        for record in groups {
            guard Set(record.receivedInvitationIDs).count == record.receivedInvitationIDs.count,
                  record.receivedInvitationIDs.count <= 1024 else { throw IntercomGroupError.invalidStoredGroups }
            if let receipt = record.pendingInvitation {
                guard receipt.isValid, receipt.kind == .accepted, receipt.groupID == record.id else { throw IntercomGroupError.invalidStoredGroups }
            }
        }
        if version == 2 {
            let memberIDs = users.flatMap(\.memberIDs)
            guard Set(users.map(\.id)).count == users.count,
                  Set(memberIDs).count == memberIDs.count,
                  users.allSatisfy({ IntercomGroup.isValidName($0.displayName) && !$0.memberIDs.isEmpty }),
                  memberIDs.allSatisfy({ IntercomGroup.isValidMemberID($0) && !$0.hasPrefix(GroupMember.pendingInvitePrefix) })
            else { throw IntercomGroupError.invalidStoredGroups }
            let directory = Dictionary(uniqueKeysWithValues: users.flatMap { user in user.memberIDs.map { ($0, user) } })
            guard groups.flatMap(\.members).allSatisfy({
                if $0.id.hasPrefix(GroupMember.pendingInvitePrefix) { return $0.userID == nil }
                if $0.userID == nil { return directory[$0.id] == nil }
                return directory[$0.id]?.displayName == $0.displayName && directory[$0.id]?.id == $0.userID
            }) else { throw IntercomGroupError.invalidStoredGroups }
        }
        return self
    }
    func encoded() throws -> Data {
        _ = try validated()
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= 1_048_576 else { throw IntercomGroupError.invalidStoredGroups }
        return bytes
    }
    static func decode(_ bytes: Data) throws -> GroupSnapshot {
        guard bytes.count <= 1_048_576 else { throw IntercomGroupError.invalidStoredGroups }
        // Inspect the version first, even when a future schema has different fields.
        struct Header: Decodable { let version: Int }
        guard [1, 2].contains(try JSONDecoder().decode(Header.self, from: bytes).version) else { throw GroupStorageError.unsupportedVersion }
        do {
            return try JSONDecoder().decode(Self.self, from: bytes).validated()
        } catch is IntercomGroupError {
            // Only a decoded violation means stored data is corrupt. Invalid
            // proposed edits must not offer a reset of the valid old snapshot.
            throw IntercomGroupError.invalidStoredGroups
        }
    }
}

enum GroupStorageError: Error, Equatable {
    case busy, unsupportedVersion, changedByAnotherProcess, verificationFailed, invalidUpdate
}

protocol GroupStoring: AnyObject {
    func read() throws -> GroupSnapshot?
    func commit(_ snapshot: GroupSnapshot) throws
    func lock() throws
    func unlock()
    func archive(legacyData: Data?) throws
}

protocol GroupCredentialStoring: AnyObject {
    func saveSecret(_ secret: String, reference: UUID) throws
    func secret(reference: UUID) throws -> String?
    func delete(reference: UUID) throws
    func references() throws -> Set<UUID>
}
