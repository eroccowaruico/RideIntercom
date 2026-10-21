import Foundation

/// Durable identity only. Runtime state and secrets never enter this format.
struct GroupSnapshot: Codable, Equatable {
    struct Member: Codable, Equatable { var id: String; var displayName: String }
    struct Record: Codable, Equatable {
        var id: UUID
        var name: String
        var members: [Member]
        var credentialReference: UUID?

        init(_ group: IntercomGroup, credentialReference: UUID? = nil) {
            id = group.id; name = group.name
            members = group.members.map { Member(id: $0.id, displayName: $0.displayName) }
            self.credentialReference = credentialReference
        }
        func group() throws -> IntercomGroup {
            try IntercomGroup(id: id, name: name, members: members.map { GroupMember(id: $0.id, displayName: $0.displayName) })
        }
    }
    var version = 1
    var generation = UUID()
    var groups: [Record] = []

    func validated() throws -> GroupSnapshot {
        guard version == 1 else { throw GroupStorageError.unsupportedVersion }
        guard groups.count <= 256, Set(groups.map(\.id)).count == groups.count else { throw IntercomGroupError.invalidStoredGroups }
        let references = groups.compactMap(\.credentialReference)
        guard Set(references).count == references.count else { throw IntercomGroupError.invalidStoredGroups }
        for record in groups { _ = try record.group() }
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
        guard try JSONDecoder().decode(Header.self, from: bytes).version == 1 else { throw GroupStorageError.unsupportedVersion }
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
