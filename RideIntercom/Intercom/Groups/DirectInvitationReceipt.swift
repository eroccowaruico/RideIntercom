import CryptoKit
import Foundation

/// Sent only after accepting an invitation, addressed to that invitation's author.
struct DirectInvitationReceipt: Codable, Equatable {
    static let namespace = "rideintercom.direct-invitation.v3"
    enum Kind: String, Codable { case accepted, acknowledged }
    var kind: Kind = .accepted
    var id: UUID = UUID()
    var groupID: UUID
    var inviterMemberID: String
    var inviteeMemberID: String
    var inviteeDeviceKey: String?
    var displayName: String
    var invitation: DirectInvitationContext?
    var proof: String?
    var acceptanceProof: DeviceIdentityProof?
    var acknowledgementProof: DeviceIdentityProof?

    static func make(grant: DirectInvitationGrant, signer: DeviceIdentitySigner, inviteeMemberID: String, displayName: String) throws -> Self {
        guard signer.memberID == inviteeMemberID, grant.isValid, let bytes = Data(base64Encoded: grant.secret) else { throw GroupInviteTokenError.invalidTokenEncoding }
        guard grant.context.recipientAccount == nil || grant.context.recipientAccount == signer.principal else { throw GroupInviteTokenError.wrongRecipient }
        var receipt = Self(id: receiptID(invitationID: grant.context.id, inviteeMemberID: inviteeMemberID), groupID: grant.context.groupID, inviterMemberID: grant.context.inviterMemberID,
                           inviteeMemberID: inviteeMemberID, inviteeDeviceKey: signer.publicKey, displayName: displayName, invitation: grant.context)
        guard receipt.isValid else { throw GroupInviteTokenError.invalidTokenEncoding }
        receipt.proof = Data(HMAC<SHA256>.authenticationCode(for: try receipt.proofMessage(), using: SymmetricKey(data: bytes))).base64EncodedString()
        receipt.acceptanceProof = try signer.sign(receipt.identityMessage(), purpose: .acceptInvitation)
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
        struct Fields: Encodable { let receiptID: UUID; let inviteeMemberID: String; let inviteeDeviceKey: String?; let invitation: DirectInvitationContext? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data("rideintercom.direct-invitation.receipt.v2\0".utf8)
            + (try encoder.encode(Fields(receiptID: id, inviteeMemberID: inviteeMemberID, inviteeDeviceKey: inviteeDeviceKey, invitation: invitation)))
    }

    func identityMessage() throws -> Data {
        struct Fields: Encodable {
            let id: UUID; let groupID: UUID; let inviterMemberID: String; let inviteeMemberID: String
            let displayName: String; let inviteeDeviceKey: String?; let invitation: DirectInvitationContext?; let proof: String?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Fields(id: id, groupID: groupID, inviterMemberID: inviterMemberID,
            inviteeMemberID: inviteeMemberID, displayName: displayName, inviteeDeviceKey: inviteeDeviceKey, invitation: invitation, proof: proof))
    }
    func acknowledgementMessage() throws -> Data {
        var copy = self; copy.kind = .acknowledged; copy.acknowledgementProof = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(copy)
    }
    func acknowledged(by signer: DeviceIdentitySigner) throws -> Self {
        guard signer.memberID == inviterMemberID, signer.publicKey == invitation?.inviterDeviceKey else { throw DeviceIdentityProof.Failure.invalid }
        var copy = self; copy.kind = .acknowledged
        copy.acknowledgementProof = try signer.sign(copy.acknowledgementMessage(), purpose: .acknowledgeInvitation)
        return copy
    }

    var isValid: Bool {
        IntercomGroup.isValidMemberID(inviterMemberID) && IntercomGroup.isValidMemberID(inviteeMemberID)
        && inviteeDeviceKey.map(DeviceIdentityProof.isValidPublicKey) == true
        && (acceptanceProof.map { $0.publicKey == inviteeDeviceKey } ?? true)
        && inviterMemberID != inviteeMemberID && IntercomGroup.isValidName(displayName)
        && !inviterMemberID.hasPrefix(GroupMember.pendingInvitePrefix)
        && !inviteeMemberID.hasPrefix(GroupMember.pendingInvitePrefix)
        && (invitation.map { $0.isValid && $0.groupID == groupID && $0.inviterMemberID == inviterMemberID
            && ($0.recipientMemberID == nil || $0.recipientMemberID == inviteeMemberID) } ?? true)
    }
}
