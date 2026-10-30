import CryptoKit
import Foundation

extension IntercomViewModel {
    var regularGroups: [IntercomGroup] { groups.filter { $0.kind == .group } }

    func callTitle(for group: IntercomGroup) -> String {
        guard group.kind == .direct else { return group.name }
        return group.members.first { $0.id != localMemberIdentity.memberID }?.resolvedDisplayName ?? "Call"
    }

    var selectedCallTitle: String { selectedGroup.map(callTitle) ?? "Call" }

    var activeDirectCall: IntercomGroup? {
        groups.first { $0.id == activeGroupID && $0.kind == .direct }
    }

    @discardableResult
    func selectUser(_ userID: UUID) -> Bool {
        groupErrorMessage = nil
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        guard let user = savedRemoteUsers.first(where: { $0.id == userID }) else {
            groupErrorMessage = "This saved user is no longer available for an individual call."
            return false
        }
        let pair: AccountCallPair?
        if let local = localAccountPrincipal, let remote = user.principal { pair = AccountCallPair(local, remote) }
        else { pair = nil }
        guard pair != nil || user.memberIDs.count == 1 else {
            groupErrorMessage = "Verify your account in Internet Connection to call this user."
            return false
        }
        let remoteIDs = user.memberIDs.sorted().prefix(IntercomGroup.maximumMemberCount - 1)
        let members = [GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName)]
            + remoteIDs.map { GroupMember(id: $0, displayName: user.displayName, localName: user.localName) }
        let id = pair?.id ?? IntercomGroup.directCallID(memberIDs: members.map(\.id))
        if let existing = groups.first(where: { $0.id == id }) {
            guard existing.kind == .direct else {
                groupErrorMessage = "The saved call conflicts with another group. Reload your saved groups."
                return false
            }
            selectGroup(existing)
            return true
        }
        do {
            var devices: [String: AccountDeviceBinding] = [:]
            if let pair, let local = localAccountPrincipal, let remote = pair.other(than: local) {
                let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
                devices[signer.memberID] = .init(principal: local, publicKey: signer.publicKey)
                for id in remoteIDs {
                    guard let key = user.deviceKeys?[id] else { throw GroupStorageError.identityConflict }
                    devices[id] = .init(principal: remote, publicKey: key)
                }
            }
            let group = try IntercomGroup(id: id, name: "Direct Call", members: members, kind: .direct,
                                         accountPair: pair, accountDevices: devices)
            let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
            try groupRepository.save([group] + groups, credential: .init(groupID: id, secret: secret))
            refreshGroupStorageStatus()
            groups.insert(group, at: 0)
            selectGroup(group)
            return true
        } catch { reportGroupStorageError(error); return false }
    }

    /// Merge durable membership without resetting live mute, audio or connection state.
    func refreshStoredAccountCall(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }),
              var stored = groupRepository.storedGroup(groupID), stored.accountPair != nil else { return }
        let runtime = Dictionary(uniqueKeysWithValues: groups[index].members.map { ($0.id, $0) })
        stored.members = stored.members.map { member in
            var result = runtime[member.id] ?? member
            result.displayName = member.displayName; result.localName = member.localName
            return result
        }
        groups[index] = stored
        if selectedGroup?.id == groupID { selectedGroup = stored }
    }

    func directCallAccountRecipient(for group: IntercomGroup) -> AccountPrincipal? {
        guard let local = localAccountPrincipal, let remote = group.accountPair?.other(than: local),
              savedRemoteUsers.contains(where: { $0.principal == remote }) else { return nil }
        return remote
    }

    func directCallRecipient(for group: IntercomGroup) -> String? {
        guard group.kind == .direct, group.accountPair == nil,
              let peer = group.members.first(where: { $0.id != localMemberIdentity.memberID }),
              savedRemoteUsers.contains(where: { $0.memberIDs.contains(peer.id) }) else { return nil }
        return peer.id
    }
}
