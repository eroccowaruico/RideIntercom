import CryptoKit
import Foundation

/// The invitation carries a derived capability, never the author's private key.
/// The context binds it to one group, author, recipient (if specified), and expiry.
struct DirectInvitationContext: Codable, Equatable {
    var id = UUID()
    var groupID: UUID
    var inviterMemberID: String
    var inviterDeviceKey: String?
    var recipientMemberID: String?
    var expiresAt: TimeInterval

    var isValid: Bool {
        inviterDeviceKey.map(DeviceIdentityProof.isValidPublicKey) == true
        && IntercomGroup.isValidMemberID(inviterMemberID)
        && !inviterMemberID.hasPrefix(GroupMember.pendingInvitePrefix)
        && (recipientMemberID.map { IntercomGroup.isValidMemberID($0)
            && !$0.hasPrefix(GroupMember.pendingInvitePrefix) && $0 != inviterMemberID } ?? true)
        && expiresAt.isFinite && expiresAt >= 0
    }
}

struct DirectInvitationGrant: Codable, Equatable {
    let context: DirectInvitationContext
    let secret: String
    var isValid: Bool { context.isValid && DirectInvitationAuthority.key(secret) != nil }
}

struct VerifiedDirectInvitation {
    let receipt: DirectInvitationReceipt
    let identity: VerifiedDeviceProof
    fileprivate init(_ receipt: DirectInvitationReceipt, identity: VerifiedDeviceProof) { self.receipt = receipt; self.identity = identity }
}

final class DirectInvitationAuthority {
    private let keychain: KeychainSecretStoring
    private let service: String
    init(keychain: KeychainSecretStoring, namespace: String) {
        self.keychain = keychain
        service = namespace + ".DirectInvitations"
    }

    func issue(_ context: DirectInvitationContext) throws -> DirectInvitationGrant {
        guard context.isValid else { throw GroupInviteTokenError.invalidTokenEncoding }
        let master: SymmetricKey
        if let stored = try keychain.secret(service: service, account: "author") {
            guard let key = Self.key(stored) else { throw KeychainSecretStoreError.invalidData }
            master = key
        } else {
            let proposed = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
            // Another process may have installed its key since the first read.
            // Adopt that key rather than invalidating its outstanding invitations.
            let retained = try keychain.createSecretIfAbsent(proposed, service: service, account: "author")
            guard let key = Self.key(retained) else { throw KeychainSecretStoreError.invalidData }
            master = key
        }
        return DirectInvitationGrant(context: context, secret: try Self.derive(context, using: master).base64EncodedString())
    }

    func verify(_ receipt: DirectInvitationReceipt, trust: DeviceIdentityTrust? = nil, now: TimeInterval = Date().timeIntervalSince1970) throws -> VerifiedDirectInvitation? {
        guard receipt.isValid, receipt.kind == .accepted, let context = receipt.invitation,
              receipt.id == DirectInvitationReceipt.receiptID(invitationID: context.id, inviteeMemberID: receipt.inviteeMemberID),
              now.isFinite, now < context.expiresAt,
              let code = Data(base64Encoded: receipt.proof ?? ""), code.count == 32,
              let stored = try keychain.secret(service: service, account: "author"),
              let master = Self.key(stored) else { return nil }
        let secret = SymmetricKey(data: try Self.derive(context, using: master))
        guard HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: try receipt.proofMessage(), using: secret) else { return nil }
        guard let proof = receipt.acceptanceProof else { return nil }
        guard let identity = try? proof.verify(receipt.identityMessage(), purpose: .acceptInvitation,
                                               memberID: receipt.inviteeMemberID, trust: trust, now: Date(timeIntervalSince1970: now)) else { return nil }
        return VerifiedDirectInvitation(receipt, identity: identity)
    }

    fileprivate static func key(_ value: String) -> SymmetricKey? {
        guard let bytes = Data(base64Encoded: value), bytes.count == 32 else { return nil }
        return SymmetricKey(data: bytes)
    }
    private static func derive(_ context: DirectInvitationContext, using key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let message = Data("rideintercom.direct-invitation.grant.v1\0".utf8) + (try encoder.encode(context))
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }
}
