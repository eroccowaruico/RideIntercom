import Foundation

/// Durable identity only. Runtime state and secrets never enter this format.
struct GroupSnapshot: Codable, Equatable {
    struct Member: Codable, Equatable {
        var id: String
        var displayName: String
        var userID: UUID?
        var localName: String?
    }
    struct Record: Codable, Equatable {
        var id: UUID
        var name: String
        var members: [Member]
        var credentialReference: UUID?
        var kind: IntercomGroup.Kind?
        var accountPair: AccountCallPair?
        var accountDevices: [String: AccountDeviceBinding] = [:]
        var pendingInvitation: DirectInvitationReceipt?
        var receivedInvitationIDs: [UUID] = []

        init(_ group: IntercomGroup, credentialReference: UUID? = nil) {
            id = group.id; name = group.name
            members = group.members.map { Member(id: $0.id, displayName: $0.displayName, localName: $0.localName) }
            self.credentialReference = credentialReference
            kind = group.kind
            accountPair = group.accountPair; accountDevices = group.accountDevices
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, members, credentialReference, kind, pendingInvitation, receivedInvitationIDs, accountPair, accountDevices
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            members = try values.decode([Member].self, forKey: .members)
            credentialReference = try values.decodeIfPresent(UUID.self, forKey: .credentialReference)
            kind = try values.decodeIfPresent(IntercomGroup.Kind.self, forKey: .kind)
            accountPair = try values.decodeIfPresent(AccountCallPair.self, forKey: .accountPair)
            accountDevices = try values.decodeIfPresent([String: AccountDeviceBinding].self, forKey: .accountDevices) ?? [:]
            pendingInvitation = try values.decodeIfPresent(DirectInvitationReceipt.self, forKey: .pendingInvitation)
            receivedInvitationIDs = try values.decodeIfPresent([UUID].self, forKey: .receivedInvitationIDs) ?? []
        }
        func group() throws -> IntercomGroup {
            try IntercomGroup(id: id, name: name, members: members.map { GroupMember(id: $0.id, displayName: $0.displayName, localName: $0.localName) }, kind: kind ?? .group, accountPair: accountPair, accountDevices: accountDevices)
        }
    }
    var version = 6
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
        guard version < 6 else { return self }
        var records = groups
        if version < 3 { for index in records.indices { records[index].kind = .group } }
        if version < 5 { for index in records.indices { records[index].pendingInvitation = nil } }
        return GroupSnapshot(groups: records, users: users)
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
                if let user = directory[member.id] {
                    groups[groupIndex].members[index].displayName = user.displayName
                    groups[groupIndex].members[index].localName = user.localName
                }
            }
        }
    }

    func validated() throws -> GroupSnapshot {
        guard (1...6).contains(version) else { throw GroupStorageError.unsupportedVersion }
        guard version < 3 || groups.allSatisfy({ $0.kind != nil }) else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 3 || groups.allSatisfy({ $0.kind == nil || $0.kind == .group }) else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 6 || groups.allSatisfy({ $0.accountPair == nil && $0.accountDevices.isEmpty }) else { throw IntercomGroupError.invalidStoredGroups }
        guard groups.count <= 256, Set(groups.map(\.id)).count == groups.count else { throw IntercomGroupError.invalidStoredGroups }
        let references = groups.compactMap(\.credentialReference)
        guard Set(references).count == references.count else { throw IntercomGroupError.invalidStoredGroups }
        for record in groups { _ = try record.group() }
        for record in groups {
            guard Set(record.receivedInvitationIDs).count == record.receivedInvitationIDs.count,
                  record.receivedInvitationIDs.count <= 1024 else { throw IntercomGroupError.invalidStoredGroups }
            if let receipt = record.pendingInvitation {
                guard (version < 5 || receipt.isValid), receipt.kind == .accepted, receipt.groupID == record.id else { throw IntercomGroupError.invalidStoredGroups }
                if version >= 5 {
                    guard receipt.invitation != nil, receipt.proof != nil, let acceptance = receipt.acceptanceProof,
                          receipt.acknowledgementProof == nil,
                          (try? acceptance.verify(receipt.identityMessage(), purpose: .acceptInvitation, memberID: receipt.inviteeMemberID)) != nil else {
                        throw IntercomGroupError.invalidStoredGroups
                    }
                }
            }
        }
        if version >= 2 {
            let principals = users.compactMap(\.principal)
            guard Set(principals).count == principals.count, principals.allSatisfy(\.isValid), users.allSatisfy({ user in
                guard let keys = user.deviceKeys else { return user.principal == nil }
                return Set(keys.keys) == Set(user.memberIDs) && keys.values.allSatisfy(DeviceIdentityProof.isValidPublicKey)
            }) else { throw IntercomGroupError.invalidStoredGroups }
            let memberIDs = users.flatMap(\.memberIDs)
            guard Set(users.map(\.id)).count == users.count,
                  Set(memberIDs).count == memberIDs.count,
                  users.allSatisfy({ IntercomGroup.isValidName($0.displayName) && ($0.localName.map(IntercomGroup.isValidName) ?? true) && !$0.memberIDs.isEmpty }),
                  memberIDs.allSatisfy({ IntercomGroup.isValidMemberID($0) && !$0.hasPrefix(GroupMember.pendingInvitePrefix) })
            else { throw IntercomGroupError.invalidStoredGroups }
            let directory = Dictionary(uniqueKeysWithValues: users.flatMap { user in user.memberIDs.map { ($0, user) } })
            guard groups.flatMap(\.members).allSatisfy({
                if $0.id.hasPrefix(GroupMember.pendingInvitePrefix) { return $0.userID == nil }
                if $0.userID == nil { return directory[$0.id] == nil }
                return directory[$0.id]?.displayName == $0.displayName && directory[$0.id]?.id == $0.userID && directory[$0.id]?.localName == $0.localName
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
        guard (1...6).contains(try JSONDecoder().decode(Header.self, from: bytes).version) else { throw GroupStorageError.unsupportedVersion }
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
    case busy, unsupportedVersion, changedByAnotherProcess, verificationFailed, invalidUpdate, identityConflict
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
