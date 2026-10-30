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
            if current.version < 6 {
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
    func save(_ groups: [IntercomGroup], credential: GroupAccessCredential, acceptedInvitation: AcceptedDirectInvitation? = nil) throws {
        try update(groups, credential: credential) { next in
            if let receipt = acceptedInvitation { try self.storeAcceptedInvitation(receipt, in: &next) }
        }
    }
    func delete(_ id: UUID, remaining: [IntercomGroup]) throws { try update(remaining, credential: nil) }

    func renameUser(_ id: UUID, displayName: String) throws {
        guard let snapshot, let index = snapshot.users.firstIndex(where: { $0.id == id }),
              IntercomGroup.isValidName(displayName) else { throw GroupStorageError.invalidUpdate }
        var users = snapshot.users
        users[index].localName = displayName
        try update(snapshot.groups.map { try $0.group() }, credential: nil, users: users)
    }

    func resetUserName(_ id: UUID) throws {
        guard let snapshot, let index = snapshot.users.firstIndex(where: { $0.id == id }) else { throw GroupStorageError.invalidUpdate }
        var users = snapshot.users
        users[index].localName = nil
        try update(snapshot.groups.map { try $0.group() }, credential: nil, users: users)
    }

    func storedMembers(in groupID: UUID) -> [GroupSnapshot.Member] {
        snapshot?.groups.first { $0.id == groupID }?.members ?? []
    }

    func setMemberName(_ memberID: String, in groupID: UUID, localName: String?) throws {
        guard let snapshot, memberID != self.localMemberID,
              let index = snapshot.groups.firstIndex(where: { $0.id == groupID }),
              let member = snapshot.groups[index].members.firstIndex(where: { $0.id == memberID }),
              localName.map(IntercomGroup.isValidName) ?? true else { throw GroupStorageError.invalidUpdate }
        if let user = snapshot.users.first(where: { $0.memberIDs.contains(memberID) }) {
            if let localName { try renameUser(user.id, displayName: localName) } else { try resetUserName(user.id) }
            return
        }
        var groups = try snapshot.groups.map { try $0.group() }
        groups[index].members[member].localName = localName
        try update(groups, credential: nil)
    }

    @discardableResult
    func receiveProfile(_ profile: VerifiedPeerProfile, connectedMemberIDs: Set<String> = []) throws -> Bool {
        let name = profile.displayName, memberID = profile.identity.memberID, groupID = profile.groupID
        guard let snapshot else { throw IntercomGroupError.storageUnavailable }
        guard memberID != localMemberID, IntercomGroup.isValidName(name),
              let index = snapshot.groups.firstIndex(where: { $0.id == groupID }) else { return false }
        var groups = try snapshot.groups.map { try $0.group() }
        var users = snapshot.users
        if let user = users.firstIndex(where: { $0.memberIDs.contains(memberID) }) {
            guard users[user].deviceKeys?[memberID] == profile.identity.publicKey,
                  users[user].principal == nil || profile.identity.principal == nil
                    || users[user].principal == profile.identity.principal else { return false }
            users[user].displayName = name
        }
        if groups[index].accountPair != nil {
            guard bindAccountDevice(profile.identity, name: name, to: &groups[index], retaining: connectedMemberIDs) else { return false }
        } else {
            guard let member = groups[index].members.firstIndex(where: { $0.id == memberID }) else { return false }
            groups[index].members[member].displayName = name
        }
        if groups[index] != (try snapshot.groups[index].group()) || users != snapshot.users {
            try update(groups, credential: nil, users: users)
        }
        return true
    }

    /// Existing device keys remain usable offline. Only a current, trusted account
    /// certificate may enroll an unseen device in an account-addressed call.
    private func bindAccountDevice(_ identity: VerifiedDeviceProof, name: String,
                                   to group: inout IntercomGroup, retaining connected: Set<String> = []) -> Bool {
        guard let localMemberID, let local = group.accountDevices[localMemberID]?.principal,
              let remote = group.accountPair?.other(than: local) else { return false }
        let memberID = identity.memberID
        if let known = group.accountDevices[memberID] {
            guard known.principal == remote, known.publicKey == identity.publicKey,
                  identity.principal == nil || identity.principal == remote else { return false }
        } else {
            guard identity.principal == remote else { return false }
        }
        if let index = group.members.firstIndex(where: { $0.id == memberID }) {
            group.members[index].displayName = name
        } else {
            if group.members.count == IntercomGroup.maximumMemberCount {
                guard let index = group.members.firstIndex(where: { $0.id != localMemberID && !connected.contains($0.id) }) else { return false }
                group.accountDevices.removeValue(forKey: group.members.remove(at: index).id)
            }
            group.members.append(.init(id: memberID, displayName: name))
        }
        group.accountDevices[memberID] = .init(principal: remote, publicKey: identity.publicKey)
        return true
    }

    func storedGroup(_ groupID: UUID) -> IntercomGroup? {
        snapshot?.groups.first { $0.id == groupID }.flatMap { try? $0.group() }
    }

    func removeUser(_ id: UUID) throws {
        guard let snapshot, snapshot.users.contains(where: { $0.id == id }) else { throw GroupStorageError.invalidUpdate }
        try update(snapshot.groups.map { try $0.group() }, credential: nil, users: snapshot.users.filter { $0.id != id })
    }

    func acceptInvitation(_ accepted: AcceptedDirectInvitation, inviterName: String) throws {
        guard let snapshot else { throw GroupStorageError.invalidUpdate }
        try update(snapshot.groups.map { try $0.group() }, credential: nil) { next in
            try self.storeAcceptedInvitation(accepted, inviterName: inviterName, in: &next)
        }
    }

    private func storeAcceptedInvitation(_ accepted: AcceptedDirectInvitation, inviterName: String? = nil, in next: inout GroupSnapshot) throws {
        let receipt = accepted.receipt
        guard receipt.isValid, receipt.kind == .accepted, receipt.invitation != nil, receipt.proof != nil,
              receipt.inviteeMemberID == localMemberID,
              let index = next.groups.firstIndex(where: { $0.id == receipt.groupID }),
              next.groups[index].members.contains(where: { $0.id == receipt.inviteeMemberID }) else {
            throw GroupStorageError.invalidUpdate
        }
        let name = inviterName ?? next.groups[index].members.first(where: { $0.id == receipt.inviterMemberID })?.displayName
        guard let name, IntercomGroup.isValidName(name) else { throw GroupStorageError.invalidUpdate }
        if !next.groups[index].receivedInvitationIDs.contains(receipt.id) {
            try Self.remember(.init(id: receipt.inviterMemberID, displayName: name), identity: accepted.inviter, in: &next)
            next.groups[index].receivedInvitationIDs.append(receipt.id)
        }
        if next.groups[index].accountPair != nil {
            var group = try next.groups[index].group()
            guard bindAccountDevice(accepted.inviter, name: name, to: &group, retaining: Set(group.members.map(\.id))) else { throw GroupStorageError.identityConflict }
            next.groups[index].members = GroupSnapshot.Record(group).members
            next.groups[index].accountDevices = group.accountDevices
        }
        next.groups[index].pendingInvitation = receipt
    }

    private static func remember(_ member: GroupMember, identity: VerifiedDeviceProof, in snapshot: inout GroupSnapshot) throws {
        guard identity.memberID == member.id else { throw GroupStorageError.identityConflict }
        let memberIndex = snapshot.users.firstIndex { $0.memberIDs.contains(member.id) }
        let accountIndex = identity.principal.flatMap { principal in snapshot.users.firstIndex { $0.principal == principal } }
        if let memberIndex {
            let existing = snapshot.users[memberIndex]
            guard existing.deviceKeys?[member.id] == identity.publicKey,
                  existing.principal == nil || identity.principal == nil || existing.principal == identity.principal else {
                throw GroupStorageError.identityConflict
            }
        }
        if let memberIndex, let accountIndex, memberIndex != accountIndex {
            let first = min(memberIndex, accountIndex), second = max(memberIndex, accountIndex)
            let other = snapshot.users[second]
            // Preserve local naming choices. Conflicting nicknames require an
            // explicit resolution instead of silently discarding either one.
            guard snapshot.users[first].localName == nil || other.localName == nil
                || snapshot.users[first].localName == other.localName else { throw GroupStorageError.identityConflict }
            snapshot.users[first].localName = snapshot.users[first].localName ?? other.localName
            snapshot.users[first].memberIDs.append(contentsOf: other.memberIDs)
            snapshot.users[first].deviceKeys = (snapshot.users[first].deviceKeys ?? [:]).merging(other.deviceKeys ?? [:]) { old, _ in old }
            snapshot.users[first].principal = identity.principal
            snapshot.users[first].displayName = member.displayName
            snapshot.users.remove(at: second)
        } else if let index = memberIndex ?? accountIndex {
            if !snapshot.users[index].memberIDs.contains(member.id) { snapshot.users[index].memberIDs.append(member.id) }
            var keys = snapshot.users[index].deviceKeys ?? [:]; keys[member.id] = identity.publicKey
            snapshot.users[index].deviceKeys = keys
            snapshot.users[index].principal = identity.principal ?? snapshot.users[index].principal
            snapshot.users[index].displayName = member.displayName
        } else {
            snapshot.users.append(SavedUser(displayName: member.displayName, memberIDs: [member.id],
                deviceKeys: [member.id: identity.publicKey], principal: identity.principal))
        }
    }

    func pendingInvitation(for groupID: UUID) -> DirectInvitationReceipt? {
        snapshot?.groups.first { $0.id == groupID }?.pendingInvitation
    }

    func receiveInvitation(_ verified: VerifiedDirectInvitation) throws {
        let receipt = verified.receipt
        guard receipt.isValid, receipt.kind == .accepted, receipt.inviterMemberID == localMemberID,
              let snapshot, let record = snapshot.groups.first(where: { $0.id == receipt.groupID }) else { throw GroupStorageError.invalidUpdate }
        // Persist receipt IDs even if the contact is later deleted. Retrying an
        // already accepted invitation must not silently recreate that contact.
        guard !record.receivedInvitationIDs.contains(receipt.id) else { return }
        try update(snapshot.groups.map { try $0.group() }, credential: nil) { next in
            guard let index = next.groups.firstIndex(where: { $0.id == receipt.groupID }) else { throw GroupStorageError.invalidUpdate }
            try Self.remember(.init(id: receipt.inviteeMemberID, displayName: receipt.displayName), identity: verified.identity, in: &next)
            next.groups[index].receivedInvitationIDs.append(receipt.id)
        }
    }

    func acknowledgeInvitation(_ receipt: DirectInvitationReceipt) throws {
        guard receipt.kind == .acknowledged, let snapshot,
              let index = snapshot.groups.firstIndex(where: { $0.id == receipt.groupID }),
              let pending = snapshot.groups[index].pendingInvitation,
              pending.id == receipt.id, pending.inviterMemberID == receipt.inviterMemberID,
              pending.inviteeMemberID == receipt.inviteeMemberID,
              pending.invitation == receipt.invitation, pending.proof == receipt.proof,
              let proof = receipt.acknowledgementProof,
              proof.publicKey == pending.invitation?.inviterDeviceKey else { return }
        guard (try? proof.verify(receipt.acknowledgementMessage(), purpose: .acknowledgeInvitation, memberID: receipt.inviterMemberID)) != nil else { return }
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
