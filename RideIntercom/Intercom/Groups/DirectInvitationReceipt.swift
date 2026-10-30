import Foundation

/// Sent only after accepting an invitation, addressed to that invitation's author.
struct DirectInvitationReceipt: Codable, Equatable {
    static let namespace = "rideintercom.direct-invitation.v1"
    enum Kind: String, Codable { case accepted, acknowledged }
    var kind: Kind = .accepted
    var id: UUID = UUID()
    var groupID: UUID
    var inviterMemberID: String
    var inviteeMemberID: String
    var displayName: String

    var isValid: Bool {
        IntercomGroup.isValidMemberID(inviterMemberID) && IntercomGroup.isValidMemberID(inviteeMemberID)
        && inviterMemberID != inviteeMemberID && IntercomGroup.isValidName(displayName)
        && !inviterMemberID.hasPrefix(GroupMember.pendingInvitePrefix)
        && !inviteeMemberID.hasPrefix(GroupMember.pendingInvitePrefix)
    }
}
