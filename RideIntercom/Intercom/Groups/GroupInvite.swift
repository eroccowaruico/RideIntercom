import CryptoKit
import Foundation

struct GroupInviteToken: Codable, Equatable {
    static let currentVersion = 4

    let version: Int
    let groupID: UUID
    let groupName: String
    let groupSecret: String
    let inviterMemberID: String
    let inviterDisplayName: String?
    let recipientMemberID: String?
    let issuedAt: TimeInterval
    let expiresAt: TimeInterval?
    let directInvitation: DirectInvitationGrant?
    let signature: String

    init(
        version: Int = GroupInviteToken.currentVersion,
        groupID: UUID,
        groupName: String,
        groupSecret: String,
        inviterMemberID: String,
        inviterDisplayName: String? = nil,
        recipientMemberID: String? = nil,
        issuedAt: TimeInterval,
        expiresAt: TimeInterval?,
        directInvitation: DirectInvitationGrant? = nil,
        signature: String
    ) throws {
        guard version == Self.currentVersion else {
            throw GroupInviteTokenError.unsupportedVersion
        }

        self.version = version
        self.groupID = groupID
        self.groupName = groupName
        self.groupSecret = groupSecret
        self.inviterMemberID = inviterMemberID
        self.inviterDisplayName = inviterDisplayName
        self.recipientMemberID = recipientMemberID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.directInvitation = directInvitation
        self.signature = signature
    }

    static func make(
        authority: DirectInvitationAuthority,
        groupID: UUID,
        groupName: String,
        groupSecret: String,
        inviterMemberID: String,
        inviterDisplayName: String? = nil,
        recipientMemberID: String? = nil,
        issuedAt: TimeInterval = Date().timeIntervalSince1970,
        expiresAt: TimeInterval? = nil
    ) throws -> GroupInviteToken {
        let version = currentVersion
        let expiresAt = expiresAt ?? issuedAt + 7 * 24 * 60 * 60
        let grant = try authority.issue(.init(groupID: groupID, inviterMemberID: inviterMemberID,
                                             recipientMemberID: recipientMemberID, expiresAt: expiresAt))
        return try GroupInviteToken(
            version: version,
            groupID: groupID,
            groupName: groupName,
            groupSecret: groupSecret,
            inviterMemberID: inviterMemberID,
            inviterDisplayName: inviterDisplayName,
            recipientMemberID: recipientMemberID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            directInvitation: grant,
            signature: makeSignature(
                version: version,
                groupID: groupID,
                groupName: groupName,
                groupSecret: groupSecret,
                inviterMemberID: inviterMemberID,
                inviterDisplayName: inviterDisplayName,
                recipientMemberID: recipientMemberID,
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                directInvitation: grant
            )
        )
    }

    func verifySignature() -> Bool {
        signature == Self.makeSignature(
            version: version,
            groupID: groupID,
            groupName: groupName,
            groupSecret: groupSecret,
            inviterMemberID: inviterMemberID,
            inviterDisplayName: inviterDisplayName,
            recipientMemberID: recipientMemberID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            directInvitation: directInvitation
        )
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw GroupInviteTokenError.unsupportedVersion }
        guard let directInvitation, directInvitation.isValid,
              directInvitation.context.groupID == groupID,
              directInvitation.context.inviterMemberID == inviterMemberID,
              directInvitation.context.recipientMemberID == recipientMemberID,
              directInvitation.context.expiresAt == expiresAt,
              inviterDisplayName.map(IntercomGroup.isValidName) ?? true else { throw GroupInviteTokenError.invalidTokenEncoding }
        if let recipientMemberID {
            guard groupID == IntercomGroup.directCallID(memberIDs: [inviterMemberID, recipientMemberID])
            else { throw GroupInviteTokenError.invalidTokenEncoding }
        }
        guard IntercomGroup.isValidName(groupName), !groupName.contains("|"),
              IntercomGroup.isValidMemberID(inviterMemberID),
              !groupSecret.isEmpty, groupSecret.utf8.count <= 256, !groupSecret.contains("|"),
              issuedAt.isFinite, issuedAt >= 0,
              expiresAt.map({ $0.isFinite && $0 >= issuedAt }) ?? true else {
            throw GroupInviteTokenError.invalidTokenEncoding
        }
    }

    func isExpired(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    private static func makeSignature(
        version: Int,
        groupID: UUID,
        groupName: String,
        groupSecret: String,
        inviterMemberID: String,
        inviterDisplayName: String?,
        recipientMemberID: String?,
        issuedAt: TimeInterval,
        expiresAt: TimeInterval?,
        directInvitation: DirectInvitationGrant?
    ) -> String {
        var fields = [
            "\(version)",
            groupID.uuidString,
            groupName,
            groupSecret,
            inviterMemberID,
            String(format: "%.3f", issuedAt),
            expiresAt.map { String(format: "%.3f", $0) } ?? ""
        ]
        fields.append(recipientMemberID ?? "")
        // Base64 keeps arbitrary user-chosen separators out of the signed field framing.
        fields.append(Data((inviterDisplayName ?? "").utf8).base64EncodedString())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        fields.append((try? encoder.encode(directInvitation))?.base64EncodedString() ?? "")
        let message = fields.joined(separator: "|")
        let key = SymmetricKey(data: Data(groupSecret.utf8))
        return HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum GroupInviteTokenError: Error, Equatable {
    case unsupportedVersion
    case invalidURL
    case invalidTokenEncoding
    case invalidSignature
    case expired
    case credentialStorageFailed
    case activeGroupKeyChanged
    case wrongRecipient
    case incompatibleCall
}

enum GroupInviteTokenCodec {
    static func joinURL(for token: GroupInviteToken) throws -> URL {
        let data = try JSONEncoder().encode(token)
        let encodedToken = data.base64URLEncodedString()
        guard let url = URL(string: "rideintercom://join?token=\(encodedToken)") else {
            throw GroupInviteTokenError.invalidURL
        }
        return url
    }

    static func decodeJoinURL(_ url: URL) throws -> GroupInviteToken {
        guard url.absoluteString.utf8.count <= 8192, url.scheme == "rideintercom",
              url.host == "join",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil, url.path.isEmpty,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count == 1,
              let encodedToken = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "token" })?
                .value,
              let data = Data(base64URLEncoded: encodedToken) else {
            throw GroupInviteTokenError.invalidURL
        }

        let token = try JSONDecoder().decode(GroupInviteToken.self, from: data)
        try token.validate()
        guard token.verifySignature() else {
            throw GroupInviteTokenError.invalidSignature
        }
        return token
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        self.init(base64Encoded: base64)
    }
}
