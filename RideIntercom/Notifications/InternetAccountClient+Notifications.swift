import Foundation

nonisolated struct CallNotificationGrant: Codable, Equatable, Sendable {
    let grantID: UUID
    let capability: String
    var isValid: Bool { !capability.isEmpty && capability.utf8.count <= 4096 }

    /// A rejection filter for an already authenticated contact exchange. Decoding
    /// these claims does not establish issuer trust; the server verifies the JWT.
    func isAddressed(to recipient: AccountPrincipal, from sender: AccountPrincipal) -> Bool {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false)
        guard isValid, parts.count == 3, recipient.issuer == sender.issuer,
              let data = IdentityEncoding.decode(String(parts[1])),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              claims["iss"] as? String == recipient.issuer, claims["aud"] as? String == "rideintercom-call-notification",
              claims["recipient"] as? String == recipient.userID, claims["sub"] as? String == sender.userID,
              let id = claims["jti"] as? String, UUID(uuidString: id) == grantID else { return false }
        return true
    }
}

nonisolated struct CallNotificationReply: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case processing, accepted, noDestinations = "no_destinations", retryLater = "retry_later", rejected, cancelled }
    let requestID: UUID
    let expiresAt: Double // Server milliseconds since 1970, never a new local lifetime.
    let status: Status
    var senderUserID: String?
    func isLive(at now: Date) -> Bool {
        expiresAt.isFinite && expiresAt > now.timeIntervalSince1970 * 1000 && status != .cancelled
    }
}

extension InternetAccountClient {
    nonisolated private struct NotificationAcknowledgement: Decodable, Sendable { var registered: Bool? }

    func registerNotificationDevice(origin: URL, token: String, deviceToken: Data, environment: String, topic: String) async throws {
        try validateNotificationAccess(origin, token: token)
        guard !deviceToken.isEmpty, deviceToken.count <= 2048, ["sandbox", "production"].contains(environment), !topic.isEmpty else { throw Failure.invalidResponse }
        let result: NotificationAcknowledgement = try await send(origin: origin, path: "api/notifications/device", method: "PUT",
            body: ["token": deviceToken.map { String(format: "%02x", $0) }.joined(), "environment": environment, "topic": topic], token: token)
        guard result.registered == true else { throw Failure.invalidResponse }
    }
    func removeNotificationDevice(origin: URL, token: String) async throws {
        try validateNotificationAccess(origin, token: token)
        let _: NotificationAcknowledgement = try await send(origin: origin, path: "api/notifications/device", method: "DELETE", token: token)
    }
    func issueNotificationGrant(origin: URL, token: String, senderUserID: String) async throws -> CallNotificationGrant {
        try validateNotificationAccess(origin, token: token)
        guard Self.notificationUserID(senderUserID) else { throw Failure.invalidResponse }
        let result: CallNotificationGrant = try await send(origin: origin, path: "api/notifications/grants", body: ["senderUserID": senderUserID], token: token)
        guard result.isValid else { throw Failure.invalidResponse }
        return result
    }
    func revokeNotificationGrant(origin: URL, token: String, grantID: UUID? = nil) async throws {
        try validateNotificationAccess(origin, token: token)
        let path = "api/notifications/grants" + (grantID.map { "/" + $0.uuidString.lowercased() } ?? "")
        let _: NotificationAcknowledgement = try await send(origin: origin, path: path, method: "DELETE", token: token)
    }
    func sendCallNotification(origin: URL, token: String, capability: String, requestID: UUID) async throws -> CallNotificationReply {
        try validateNotificationAccess(origin, token: token)
        guard !capability.isEmpty, capability.utf8.count <= 4096 else { throw Failure.invalidResponse }
        let result: CallNotificationReply = try await send(origin: origin, path: "api/notifications/calls",
            body: ["capability": capability, "requestID": requestID.uuidString.lowercased()], token: token)
        guard result.requestID == requestID, result.expiresAt.isFinite, result.expiresAt > 0 else { throw Failure.invalidResponse }
        return result
    }
    func readCallNotification(origin: URL, token: String, recipientUserID: String, requestID: UUID) async throws -> CallNotificationReply {
        try validateNotificationAccess(origin, token: token)
        guard Self.notificationUserID(recipientUserID) else { throw Failure.invalidResponse }
        let result: CallNotificationReply = try await send(origin: origin,
            path: "api/notifications/calls/\(recipientUserID)/\(requestID.uuidString.lowercased())", method: "GET", token: token)
        guard result.requestID == requestID, result.expiresAt.isFinite, result.expiresAt > 0,
              result.senderUserID.map(Self.notificationUserID) == true else { throw Failure.invalidResponse }
        return result
    }
    func cancelCallNotification(origin: URL, token: String, recipientUserID: String, requestID: UUID) async throws {
        try validateNotificationAccess(origin, token: token)
        guard Self.notificationUserID(recipientUserID) else { throw Failure.invalidResponse }
        let _: NotificationAcknowledgement = try await send(origin: origin,
            path: "api/notifications/calls/\(recipientUserID)/\(requestID.uuidString.lowercased())", method: "DELETE", token: token)
    }
    private func validateNotificationAccess(_ origin: URL, token: String) throws {
        _ = try Self.origin(origin.absoluteString)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "ri1", Self.notificationUserID(parts[1]), UUID(uuidString: parts[2]) != nil,
              Self.notificationUserID(parts[3]) else { throw Failure.rejected }
    }
    static func notificationUserID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
