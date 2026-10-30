import CryptoKit
import Foundation

struct GroupInviteToken: Codable, Equatable {
    static let currentVersion = 3

    let version: Int
    let groupID: UUID
    let groupName: String
    let groupSecret: String
    let inviterMemberID: String
    let inviterDisplayName: String?
    let recipientMemberID: String?
    let issuedAt: TimeInterval
    let expiresAt: TimeInterval?
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
        signature: String
    ) throws {
        guard (1...3).contains(version) else {
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
        self.signature = signature
    }

    static func make(
        groupID: UUID,
        groupName: String,
        groupSecret: String,
        inviterMemberID: String,
        inviterDisplayName: String? = nil,
        recipientMemberID: String? = nil,
        issuedAt: TimeInterval = Date().timeIntervalSince1970,
        expiresAt: TimeInterval? = nil
    ) throws -> GroupInviteToken {
        let version = inviterDisplayName == nil ? (recipientMemberID == nil ? 1 : 2) : currentVersion
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
            signature: makeSignature(
                version: version,
                groupID: groupID,
                groupName: groupName,
                groupSecret: groupSecret,
                inviterMemberID: inviterMemberID,
                inviterDisplayName: inviterDisplayName,
                recipientMemberID: recipientMemberID,
                issuedAt: issuedAt,
                expiresAt: expiresAt
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
            expiresAt: expiresAt
        )
    }

    func validate() throws {
        guard (1...3).contains(version) else { throw GroupInviteTokenError.unsupportedVersion }
        if version == 3 {
            guard let inviterDisplayName, IntercomGroup.isValidName(inviterDisplayName) else { throw GroupInviteTokenError.invalidTokenEncoding }
        } else if inviterDisplayName != nil { throw GroupInviteTokenError.invalidTokenEncoding }
        if version == 1 || (version == 3 && recipientMemberID == nil) {
            guard recipientMemberID == nil else { throw GroupInviteTokenError.invalidTokenEncoding }
        } else {
            guard let recipientMemberID, IntercomGroup.isValidMemberID(recipientMemberID),
                  recipientMemberID != inviterMemberID,
                  !recipientMemberID.hasPrefix(GroupMember.pendingInvitePrefix),
                  !inviterMemberID.hasPrefix(GroupMember.pendingInvitePrefix),
                  groupID == IntercomGroup.directCallID(memberIDs: [inviterMemberID, recipientMemberID])
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
        expiresAt: TimeInterval?
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
        if version >= 2 { fields.append(recipientMemberID ?? "") }
        // Base64 keeps arbitrary user-chosen separators out of the signed field framing.
        if version == 3 { fields.append(Data((inviterDisplayName ?? "").utf8).base64EncodedString()) }
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
