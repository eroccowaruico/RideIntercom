import CryptoKit
import Foundation

extension IntercomViewModel {
    var regularGroups: [IntercomGroup] { groups.filter { $0.kind == .group } }

    func callTitle(for group: IntercomGroup) -> String {
        guard group.kind == .direct else { return group.name }
        return group.members.first { $0.id != localMemberIdentity.memberID }?.displayName ?? "Call"
    }

    var selectedCallTitle: String { selectedGroup.map(callTitle) ?? "Call" }

    var activeDirectCall: IntercomGroup? {
        groups.first { $0.id == activeGroupID && $0.kind == .direct }
    }

    @discardableResult
    func selectUser(_ userID: UUID) -> Bool {
        groupErrorMessage = nil
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        guard let user = savedRemoteUsers.first(where: { $0.id == userID }), user.memberIDs.count == 1 else {
            groupErrorMessage = "This saved user is no longer available for an individual call."
            return false
        }
        let members = [GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName),
                       GroupMember(id: user.memberIDs[0], displayName: user.displayName)]
        let id = IntercomGroup.directCallID(memberIDs: members.map(\.id))
        if let existing = groups.first(where: { $0.id == id }) {
            guard existing.kind == .direct else {
                groupErrorMessage = "The saved call conflicts with another group. Reload your saved groups."
                return false
            }
            selectGroup(existing)
            return true
        }
        do {
            let group = try IntercomGroup(id: id, name: "Direct Call", members: members, kind: .direct)
            let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
            try groupRepository.save([group] + groups, credential: .init(groupID: id, secret: secret))
            refreshGroupStorageStatus()
            groups.insert(group, at: 0)
            selectGroup(group)
            return true
        } catch { reportGroupStorageError(error); return false }
    }

    func directCallRecipient(for group: IntercomGroup) -> String? {
        guard group.kind == .direct,
              let peer = group.members.first(where: { $0.id != localMemberIdentity.memberID }),
              savedRemoteUsers.contains(where: { $0.memberIDs.contains(peer.id) }) else { return nil }
        return peer.id
    }
}
