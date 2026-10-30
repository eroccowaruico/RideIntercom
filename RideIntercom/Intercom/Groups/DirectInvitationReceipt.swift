import CryptoKit
import Foundation

/// Sent only after accepting an invitation, addressed to that invitation's author.
struct DirectInvitationReceipt: Codable, Equatable {
    static let namespace = "rideintercom.direct-invitation.v2"
    enum Kind: String, Codable { case accepted, acknowledged }
    var kind: Kind = .accepted
    var id: UUID = UUID()
    var groupID: UUID
    var inviterMemberID: String
    var inviteeMemberID: String
    var displayName: String
    var invitation: DirectInvitationContext?
    var proof: String?

    static func make(grant: DirectInvitationGrant, inviteeMemberID: String, displayName: String) throws -> Self {
        guard grant.isValid, let bytes = Data(base64Encoded: grant.secret) else { throw GroupInviteTokenError.invalidTokenEncoding }
        var receipt = Self(id: receiptID(invitationID: grant.context.id, inviteeMemberID: inviteeMemberID), groupID: grant.context.groupID, inviterMemberID: grant.context.inviterMemberID,
                           inviteeMemberID: inviteeMemberID, displayName: displayName, invitation: grant.context)
        guard receipt.isValid else { throw GroupInviteTokenError.invalidTokenEncoding }
        receipt.proof = Data(HMAC<SHA256>.authenticationCode(for: try receipt.proofMessage(), using: SymmetricKey(data: bytes))).base64EncodedString()
        return receipt
    }

    static func receiptID(invitationID: UUID, inviteeMemberID: String) -> UUID {
        let input = "rideintercom.invitation-receipt.v2|" + invitationID.uuidString + "|" + inviteeMemberID
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func proofMessage() throws -> Data {
        // A shared name can change independently; it is not an identity or grant.
        struct Fields: Encodable { let receiptID: UUID; let inviteeMemberID: String; let invitation: DirectInvitationContext? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data("rideintercom.direct-invitation.receipt.v2\0".utf8)
            + (try encoder.encode(Fields(receiptID: id, inviteeMemberID: inviteeMemberID, invitation: invitation)))
    }

    var isValid: Bool {
        IntercomGroup.isValidMemberID(inviterMemberID) && IntercomGroup.isValidMemberID(inviteeMemberID)
        && inviterMemberID != inviteeMemberID && IntercomGroup.isValidName(displayName)
        && !inviterMemberID.hasPrefix(GroupMember.pendingInvitePrefix)
        && !inviteeMemberID.hasPrefix(GroupMember.pendingInvitePrefix)
        && (invitation.map { $0.isValid && $0.groupID == groupID && $0.inviterMemberID == inviterMemberID
            && ($0.recipientMemberID == nil || $0.recipientMemberID == inviteeMemberID) } ?? true)
    }
}
