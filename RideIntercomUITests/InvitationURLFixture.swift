import CryptoKit
import Foundation

/// Synthetic remote signer; the UI tests never call a real account or service.
enum InvitationURLFixture {
    enum Failure: Error { case invalidURL }

    static func make(inviter: String, sharedName: String? = nil, contact: Bool = false,
                     signingKey: P256.Signing.PrivateKey = .init()) throws -> URL {
        let groupID = UUID(), issuedAt = floor(Date().timeIntervalSince1970)
        let expiresAt = issuedAt + 3600
        let secret = "ui-test-invitation-key"
        let groupName = contact ? "Contact Invitation" : "Talk Group"
        let publicKey = base64url(signingKey.publicKey.x963Representation)
        struct Context: Encodable {
            let id: UUID; let groupID: UUID; let inviterMemberID: String
            let inviterDeviceKey: String; let expiresAt: Double; let contactBootstrap: Bool?
        }
        struct Grant: Encodable { let context: Context; let secret: String }
        let grant = Grant(context: .init(id: UUID(), groupID: groupID, inviterMemberID: inviter,
            inviterDeviceKey: publicKey, expiresAt: expiresAt, contactBootstrap: contact ? true : nil),
            secret: Data(repeating: 42, count: 32).base64EncodedString())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let grantData = try encoder.encode(grant)
        let fields = ["6", groupID.uuidString, groupName, secret, inviter, String(format: "%.3f", issuedAt),
            String(format: "%.3f", expiresAt), "", Data((sharedName ?? "").utf8).base64EncodedString(), grantData.base64EncodedString()]
        let signature = HMAC<SHA256>.authenticationCode(for: Data(fields.joined(separator: "|").utf8),
            using: SymmetricKey(data: Data(secret.utf8))).map { String(format: "%02x", $0) }.joined()
        var signed = Data("rideintercom.device-proof.v1\0".utf8)
        for field in [Data("issueInvitation".utf8), Data(inviter.utf8), Data(publicKey.utf8), Data(), Data(), Data(signature.utf8)] {
            var count = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &count) { signed.append(contentsOf: $0) }
            signed.append(field)
        }
        let identityProof = ["publicKey": publicKey, "signature": base64url(try signingKey.signature(for: signed).rawRepresentation)]
        var object: [String: Any] = ["version": 6, "groupID": groupID.uuidString, "groupName": groupName,
            "groupSecret": secret, "inviterMemberID": inviter, "issuedAt": issuedAt, "expiresAt": expiresAt,
            "directInvitation": try JSONSerialization.jsonObject(with: grantData), "signature": signature, "identityProof": identityProof]
        object["inviterDisplayName"] = sharedName
        let encoded = base64url(try JSONSerialization.data(withJSONObject: object))
        guard let url = URL(string: "rideintercom://\(contact ? "contact" : "join")?token=\(encoded)") else { throw Failure.invalidURL }
        return url
    }

    private static func base64url(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
