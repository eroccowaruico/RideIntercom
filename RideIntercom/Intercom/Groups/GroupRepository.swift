import Foundation

/// The manifest replacement is the sole commit point. Keys are immutable versions;
/// failed work may leave orphan keys, but never changes a committed key in place.
final class GroupRepository {
    private let store: GroupStoring
    private let credentials: GroupCredentialStoring
    private let legacy: LegacyGroupReader?
    private var snapshot: GroupSnapshot?
    private var isWritable = false
    private var localMemberID: String?
    private(set) var missingCredentialGroupIDs: Set<UUID> = []
    private(set) var needsCleanup = false
    var users: [SavedUser] { snapshot?.users ?? [] }

    init(store: GroupStoring, credentials: GroupCredentialStoring, legacy: LegacyGroupReader? = nil) {
        self.store = store; self.credentials = credentials; self.legacy = legacy
    }

    func load(localMemberID: String) throws -> [IntercomGroup] {
        self.localMemberID = localMemberID
        try store.lock(); defer { store.unlock() }
        do {
            var current = try store.read() ?? migrate(localMemberID: localMemberID)
            _ = try validateIdentity(current, localMemberID: localMemberID)
            if current.version < 3 {
                current = current.upgraded()
                try store.commit(current)
                guard try store.read() == current else { throw GroupStorageError.verificationFailed }
            }
            let groups = try validateIdentity(current, localMemberID: localMemberID)
            var missing: Set<UUID> = []
            for record in current.groups {
                if let ref = record.credentialReference {
                    if try credentials.secret(reference: ref) == nil { missing.insert(record.id) }
                } else { missing.insert(record.id) }
            }
            snapshot = current; missingCredentialGroupIDs = missing; isWritable = true
            cleanup(current)
            return groups
        } catch { isWritable = false; throw error }
    }

    private func validateIdentity(_ current: GroupSnapshot, localMemberID: String) throws -> [IntercomGroup] {
        try current.groups.map { record in
            var group = try record.group()
            guard let index = group.members.firstIndex(where: { $0.id == localMemberID }) else { throw IntercomGroupError.invalidStoredGroups }
            group.members.insert(group.members.remove(at: index), at: 0)
            return group
        }
    }

    private func migrate(localMemberID: String) throws -> GroupSnapshot {
        let groups = try legacy?.read() ?? []
        var candidate = GroupSnapshot(groups: groups.map { .init($0) })
        _ = try validateIdentity(candidate, localMemberID: localMemberID)
        for index in candidate.groups.indices {
            if let secret = try legacy?.secret(for: candidate.groups[index].id) {
                candidate.groups[index].credentialReference = try prepareKey(secret)
            }
        }
        try store.commit(candidate)
        guard try store.read() == candidate else { throw GroupStorageError.verificationFailed }
        return candidate
    }

    func credential(for id: UUID) throws -> GroupAccessCredential? {
        guard isWritable, let snapshot else { throw IntercomGroupError.storageUnavailable }
        try store.lock(); defer { store.unlock() }
        guard try store.read() == snapshot else { isWritable = false; throw GroupStorageError.changedByAnotherProcess }
        guard let reference = snapshot.groups.first(where: { $0.id == id })?.credentialReference,
              let secret = try credentials.secret(reference: reference) else { return nil }
        return .init(groupID: id, secret: secret)
    }

    func save(_ groups: [IntercomGroup]) throws { try update(groups, credential: nil) }
    func save(_ groups: [IntercomGroup], credential: GroupAccessCredential, acceptedInvitationFrom inviter: GroupMember? = nil) throws {
        try update(groups, credential: credential) { next in
            guard let inviter, let localMemberID = self.localMemberID, inviter.id != localMemberID,
                  let index = next.groups.firstIndex(where: { $0.id == credential.groupID }),
                  let local = groups.first(where: { $0.id == credential.groupID })?.members.first(where: { $0.id == localMemberID }) else { return }
            Self.remember(inviter, in: &next)
            next.groups[index].pendingInvitation = .init(groupID: credential.groupID, inviterMemberID: inviter.id,
                                                        inviteeMemberID: localMemberID, displayName: local.displayName)
        }
    }
    func delete(_ id: UUID, remaining: [IntercomGroup]) throws { try update(remaining, credential: nil) }

    func renameUser(_ id: UUID, displayName: String) throws {
        guard let snapshot, let index = snapshot.users.firstIndex(where: { $0.id == id }),
              IntercomGroup.isValidName(displayName) else { throw GroupStorageError.invalidUpdate }
        var users = snapshot.users
        users[index].displayName = displayName
        try update(snapshot.groups.map { try $0.group() }, credential: nil, users: users)
    }

    func removeUser(_ id: UUID) throws {
        guard let snapshot, snapshot.users.contains(where: { $0.id == id }) else { throw GroupStorageError.invalidUpdate }
        try update(snapshot.groups.map { try $0.group() }, credential: nil, users: snapshot.users.filter { $0.id != id })
    }

    func acceptInvitation(from inviter: GroupMember, to groupID: UUID) throws {
        guard let snapshot, let localMemberID,
              let group = snapshot.groups.first(where: { $0.id == groupID }),
              let local = group.members.first(where: { $0.id == localMemberID }), inviter.id != localMemberID
        else { return }
        try update(snapshot.groups.map { try $0.group() }, credential: nil) { next in
            guard let index = next.groups.firstIndex(where: { $0.id == groupID }) else { throw GroupStorageError.invalidUpdate }
            Self.remember(inviter, in: &next)
            next.groups[index].pendingInvitation = .init(groupID: groupID, inviterMemberID: inviter.id,
                                                        inviteeMemberID: localMemberID, displayName: local.displayName)
        }
    }

    private static func remember(_ member: GroupMember, in snapshot: inout GroupSnapshot) {
        guard !snapshot.users.contains(where: { $0.memberIDs.contains(member.id) }) else { return }
        snapshot.users.append(SavedUser(displayName: member.displayName, memberIDs: [member.id]))
    }

    func pendingInvitation(for groupID: UUID) -> DirectInvitationReceipt? {
        snapshot?.groups.first { $0.id == groupID }?.pendingInvitation
    }

    func receiveInvitation(_ receipt: DirectInvitationReceipt) throws {
        guard receipt.isValid, receipt.kind == .accepted, receipt.inviterMemberID == localMemberID,
              let snapshot, let record = snapshot.groups.first(where: { $0.id == receipt.groupID }) else { throw GroupStorageError.invalidUpdate }
        // Persist receipt IDs even if the contact is later deleted. Retrying an
        // already accepted invitation must not silently recreate that contact.
        guard !record.receivedInvitationIDs.contains(receipt.id) else { return }
        try update(snapshot.groups.map { try $0.group() }, credential: nil) { next in
            guard let index = next.groups.firstIndex(where: { $0.id == receipt.groupID }) else { throw GroupStorageError.invalidUpdate }
            Self.remember(.init(id: receipt.inviteeMemberID, displayName: receipt.displayName), in: &next)
            next.groups[index].receivedInvitationIDs.append(receipt.id)
        }
    }

    func acknowledgeInvitation(_ receipt: DirectInvitationReceipt) throws {
        guard receipt.kind == .acknowledged, let snapshot,
              let index = snapshot.groups.firstIndex(where: { $0.id == receipt.groupID }),
              let pending = snapshot.groups[index].pendingInvitation,
              pending.id == receipt.id, pending.inviterMemberID == receipt.inviterMemberID,
              pending.inviteeMemberID == receipt.inviteeMemberID else { return }
        try update(snapshot.groups.map { try $0.group() }, credential: nil) { next in next.groups[index].pendingInvitation = nil }
    }

    private func prepareKey(_ secret: String) throws -> UUID {
        let reference = UUID()
        try credentials.saveSecret(secret, reference: reference)
        guard try credentials.secret(reference: reference) == secret else { throw IntercomGroupError.credentialVerificationFailed }
        return reference
    }

    private func update(_ groups: [IntercomGroup], credential: GroupAccessCredential?, users: [SavedUser]? = nil,
                        modify: (inout GroupSnapshot) throws -> Void = { _ in }) throws {
        guard isWritable, let previous = snapshot else { throw IntercomGroupError.storageUnavailable }
        try store.lock(); defer { store.unlock() }
        guard try store.read() == previous else { isWritable = false; throw GroupStorageError.changedByAnotherProcess }
        // Validate the requested edit before directory names are reapplied.
        do { for group in groups { _ = try GroupSnapshot.Record(group).group() } }
        catch { throw GroupStorageError.invalidUpdate }
        var next = GroupSnapshot(groups: groups.map { group in
            let old = previous.groups.first(where: { $0.id == group.id })
            var record = GroupSnapshot.Record(group, credentialReference: old?.credentialReference)
            record.pendingInvitation = old?.pendingInvitation
            record.receivedInvitationIDs = old?.receivedInvitationIDs ?? []
            return record
        }, users: users ?? previous.users)
        try modify(&next)
        next.synchronizeUserReferences()
        do { _ = try next.encoded() }
        catch { throw GroupStorageError.invalidUpdate }
        if let credential {
            guard let index = next.groups.firstIndex(where: { $0.id == credential.groupID }) else { throw GroupStorageError.invalidUpdate }
            next.groups[index].credentialReference = try prepareKey(credential.secret)
        }
        do {
            try store.commit(next)
            guard try store.read() == next else { throw GroupStorageError.verificationFailed }
        } catch {
            // The operation can fail after rename. Re-read before allowing another
            // write; never roll a committed manifest back or delete its new key.
            isWritable = false
            throw error
        }
        snapshot = next
        missingCredentialGroupIDs.formIntersection(Set(next.groups.map(\.id)))
        if let credential { missingCredentialGroupIDs.remove(credential.groupID) }
        cleanup(next)
    }

    private func cleanup(_ current: GroupSnapshot) {
        do {
            let live = Set(current.groups.compactMap(\.credentialReference))
            for reference in try credentials.references().subtracting(live) { try credentials.delete(reference: reference) }
            try legacy?.cleanup()
            needsCleanup = false
        } catch { needsCleanup = true }
    }

    func reset() throws {
        try store.lock(); defer { store.unlock() }
        // A newer schema must be opened by the matching app, not reset by this one.
        do { _ = try store.read() }
        catch GroupStorageError.unsupportedVersion { throw GroupStorageError.unsupportedVersion }
        catch { /* Preserve malformed bytes before replacing them. */ }
        try store.archive(legacyData: legacy?.archiveData())
        let empty = GroupSnapshot()
        try store.commit(empty)
        guard try store.read() == empty else { isWritable = false; throw GroupStorageError.verificationFailed }
        snapshot = empty; isWritable = true; missingCredentialGroupIDs = []
        cleanup(empty)
    }
}
