import Foundation

/// Public pending metadata; complete signed token and secrets live in Keychain.
struct ContactInvitationRecord: Codable, Equatable, Identifiable {
    enum Direction: String, Codable { case outgoing, incoming }
    enum State: String, Codable { case pending, confirmed, delivered, cancelled }
    let id: UUID
    let direction: Direction
    let expiresAt: TimeInterval
    var state: State = .pending
    var credentialReference: UUID?
    var receiptID: UUID?
    var peerMemberID: String?
    var peerDeviceKey: String?

    var canResume: Bool { (state == .pending || state == .confirmed) && credentialReference != nil }
    var isValid: Bool {
        guard expiresAt.isFinite, expiresAt >= 0 else { return false }
        guard state != .confirmed || direction == .outgoing,
              state != .delivered || direction == .incoming else { return false }
        if direction == .outgoing && state == .pending {
            guard receiptID == nil, peerMemberID == nil, peerDeviceKey == nil else { return false }
        }
        if state == .pending || state == .confirmed {
            guard credentialReference != nil else { return false }
        } else if credentialReference != nil { return false }
        if direction == .incoming || state == .confirmed {
            guard receiptID != nil, let peerMemberID, IntercomGroup.isValidMemberID(peerMemberID),
                  let peerDeviceKey, DeviceIdentityProof.isValidPublicKey(peerDeviceKey) else { return false }
        }
        return true
    }
}

/// GroupCredentialStoring supplies immutable account-scoped Keychain slots.
/// A tagged encoding distinguishes this complete contact checkpoint from a
/// normal group's raw transport key; neither URL nor secret enters the manifest.
struct ContactInvitationPayload: Codable {
    private static let prefix = "RideIntercom.ContactInvitation.v1:"
    let token: GroupInviteToken
    var receipt: DirectInvitationReceipt?

    func encodedSecret() throws -> String {
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= 32_768 else { throw GroupStorageError.invalidUpdate }
        return Self.prefix + bytes.base64EncodedString()
    }

    static func decodeSecret(_ secret: String, record: ContactInvitationRecord) throws -> Self {
        guard secret.hasPrefix(prefix), secret.utf8.count <= 65_536,
              let bytes = Data(base64Encoded: String(secret.dropFirst(prefix.count))) else { throw GroupStorageError.invalidUpdate }
        let payload = try JSONDecoder().decode(Self.self, from: bytes)
        try payload.token.validate(contactBootstrap: true)
        guard payload.token.verifySignature(), let proof = payload.token.identityProof,
              payload.token.directInvitation?.context.id == record.id,
              payload.token.expiresAt == record.expiresAt else { throw GroupStorageError.invalidUpdate }
        _ = try proof.verify(Data(payload.token.signature.utf8), purpose: .issueInvitation, memberID: payload.token.inviterMemberID)
        if let receipt = payload.receipt {
            guard receipt.isValid, receipt.kind == .accepted,
                  receipt.invitation == payload.token.directInvitation?.context,
                  receipt.id == record.receiptID else { throw GroupStorageError.invalidUpdate }
            if record.direction == .outgoing {
                guard receipt.inviteeMemberID == record.peerMemberID,
                      receipt.inviteeDeviceKey == record.peerDeviceKey else { throw GroupStorageError.identityConflict }
            } else {
                guard payload.token.inviterMemberID == record.peerMemberID,
                      payload.token.identityProof?.publicKey == record.peerDeviceKey else { throw GroupStorageError.identityConflict }
            }
        } else if record.direction == .incoming || record.state == .confirmed { throw GroupStorageError.invalidUpdate }
        return payload
    }
}
