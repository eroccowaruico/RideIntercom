import CryptoKit
import Foundation

/// The envelope is untrusted until verified against a key obtained from our
/// configured service over HTTPS. A peer cannot nominate its own trust key.
nonisolated struct DeviceIdentityCertificate: Codable, Equatable, Sendable {
    let certificate: String
    let issuerKey: String

    func verify(origin: URL, trustedIssuerKey: String, now: Date = Date()) throws -> VerifiedDeviceIdentity {
        guard origin.scheme?.lowercased() == "https", origin.host != nil, origin.user == nil, origin.password == nil,
              certificate.utf8.count <= 4096, issuerKey == trustedIssuerKey else { throw Failure.invalid }
        let parts = certificate.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = IdentityEncoding.decode(parts[0]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: String],
              header == ["alg": "ES256", "typ": "rideintercom-device+jwt"],
              let payload = IdentityEncoding.decode(parts[1]), let signature = IdentityEncoding.decode(parts[2]),
              let issuerBytes = IdentityEncoding.decode(trustedIssuerKey), issuerBytes.count == 65 else { throw Failure.invalid }
        let key = try P256.Signing.PublicKey(x963Representation: issuerBytes)
        guard key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: Data((parts[0] + "." + parts[1]).utf8)) else { throw Failure.invalid }
        let claims = try JSONDecoder().decode(Claims.self, from: payload)
        let instant = now.timeIntervalSince1970
        guard claims.iss == IdentityEncoding.origin(origin), claims.aud == "rideintercom-peer",
              claims.sub.utf8.count == 64, claims.sub.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              UUID(uuidString: claims.deviceID)?.uuidString.lowercased() == claims.deviceID,
              IntercomGroup.isValidMemberID(claims.memberID), !claims.memberID.hasPrefix("invite-pending-"),
              claims.iat.isFinite, claims.exp.isFinite, instant.isFinite,
              claims.iat >= 0, claims.iat.rounded(.down) == claims.iat, claims.exp.rounded(.down) == claims.exp,
              claims.iat <= instant + 60, claims.exp > instant, claims.exp > claims.iat, claims.exp - claims.iat <= 30 * 86400,
              let deviceBytes = IdentityEncoding.decode(claims.deviceKey), deviceBytes.count == 65 else { throw Failure.invalid }
        _ = try P256.Signing.PublicKey(x963Representation: deviceBytes)
        return VerifiedDeviceIdentity(envelope: self, issuer: claims.iss, userID: claims.sub, deviceID: claims.deviceID,
                                      memberID: claims.memberID, deviceKey: claims.deviceKey, expiresAt: claims.exp)
    }
    enum Failure: Error { case invalid }
    private struct Claims: Decodable {
        let iss: String; let sub: String; let aud: String
        let deviceID: String; let memberID: String; let deviceKey: String
        let iat: TimeInterval; let exp: TimeInterval
    }
}

nonisolated struct VerifiedDeviceIdentity: Sendable {
    let envelope: DeviceIdentityCertificate
    let issuer: String
    let userID: String
    let deviceID: String
    let memberID: String
    let deviceKey: String
    let expiresAt: TimeInterval
    fileprivate init(envelope: DeviceIdentityCertificate, issuer: String, userID: String, deviceID: String,
                     memberID: String, deviceKey: String, expiresAt: TimeInterval) {
        self.envelope = envelope; self.issuer = issuer; self.userID = userID; self.deviceID = deviceID
        self.memberID = memberID; self.deviceKey = deviceKey; self.expiresAt = expiresAt
    }
}

nonisolated enum IdentityEncoding {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ text: String) -> Data? {
        guard !text.isEmpty, text.utf8.count <= 8192 else { return nil }
        let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)), encode(data) == text else { return nil }
        return data
    }
    static func origin(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme?.lowercased(); components.host = components.host?.lowercased()
        if components.port == 443 { components.port = nil }
        components.path = ""; components.query = nil; components.fragment = nil
        return components.string!
    }
}
