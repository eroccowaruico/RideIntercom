import Foundation

/// Owns durable group metadata and keys. Runtime audio/member state stays in the
/// ViewModel. Failed reads never turn into permission to overwrite stored data.
final class GroupRepository {
    private let store: GroupStoring
    private let credentials: GroupCredentialStoring
    private var isWritable = true

    init(store: GroupStoring, credentials: GroupCredentialStoring) {
        self.store = store
        self.credentials = credentials
    }

    func load(localMemberID: String) throws -> [IntercomGroup] {
        do {
            let groups = try store.loadGroups().map { group in
                var group = group
                guard let local = group.members.firstIndex(where: { $0.id == localMemberID }) else {
                    throw IntercomGroupError.invalidStoredGroups
                }
                group.members.insert(group.members.remove(at: local), at: 0)
                return group
            }
            isWritable = true
            return groups
        } catch { isWritable = false; throw error }
    }

    func save(_ groups: [IntercomGroup]) throws {
        guard isWritable else { throw IntercomGroupError.storageUnavailable }
        try store.saveGroups(groups)
    }

    func credential(for id: UUID) throws -> GroupAccessCredential? { try credentials.credential(for: id) }

    func save(_ groups: [IntercomGroup], credential: GroupAccessCredential) throws {
        try changeKey(for: credential.groupID, groups: groups) {
            try credentials.save(credential)
            guard try credentials.credential(for: credential.groupID) == credential else {
                throw IntercomGroupError.credentialVerificationFailed
            }
        }
    }

    func delete(_ id: UUID, remaining: [IntercomGroup]) throws {
        try changeKey(for: id, groups: remaining) { try credentials.delete(for: id) }
    }

    private func changeKey(for id: UUID, groups: [IntercomGroup], change: () throws -> Void) throws {
        guard isWritable else { throw IntercomGroupError.storageUnavailable }
        let old = try credentials.credential(for: id)
        do {
            try change()
            try store.saveGroups(groups)
        } catch {
            do {
                if let old { try credentials.save(old) } else { try credentials.delete(for: id) }
            } catch {
                isWritable = false
                throw IntercomGroupError.rollbackFailed
            }
            throw error
        }
    }
}
