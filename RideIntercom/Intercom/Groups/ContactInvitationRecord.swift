import Foundation

/// Public pending metadata; complete signed token and secrets live in Keychain.
struct ContactInvitationRecord: Codable, Equatable, Identifiable {
    enum Direction: String, Codable { case outgoing, incoming }
    /// `expired`: a sent invitation nobody accepted in time. Its secret is gone; the record only keeps the
    /// name so the person can send a new invitation (removed when they do, or cancel it).
    enum State: String, Codable { case pending, confirmed, delivered, cancelled, expired }
    let id: UUID
    let direction: Direction
    let expiresAt: TimeInterval
    var state: State = .pending
    var credentialReference: UUID?
    var receiptID: UUID?
    var peerMemberID: String?
    var peerDeviceKey: String?
    /// The inviter's own word for the person, kept on this device only. Becomes the saved user's
    /// local name when the invitation completes; never sent or shown to the other person.
    var nickname: String?
    /// False from creation until a share destination took the link (the share sheet asks for it only then).
    /// Nil on records saved before this was kept: those were treated as sent.
    var sent: Bool?

    var canResume: Bool { (state == .pending || state == .confirmed) && credentialReference != nil }
    var isExpiredTombstone: Bool { state == .expired && direction == .outgoing }
    /// Past its time: a sent invitation still waiting becomes an expired record; anything else goes.
    static func expire(_ records: inout [ContactInvitationRecord], now: TimeInterval) {
        records = records.compactMap { record in
            guard record.expiresAt <= now, record.state != .expired else { return record }
            guard record.direction == .outgoing, record.state == .pending else { return nil }
            var expired = record
            expired.state = .expired; expired.credentialReference = nil
            return expired
        }
    }
    var isValid: Bool {
        guard expiresAt.isFinite, expiresAt >= 0 else { return false }
        guard state != .expired || direction == .outgoing, state != .confirmed || direction == .outgoing,
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
