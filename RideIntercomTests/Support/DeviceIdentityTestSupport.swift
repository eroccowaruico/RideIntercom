import CryptoKit
import Foundation
@testable import RideIntercom

nonisolated func testIdentityCertificate(signer: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
    userID: String = String(repeating: "a", count: 64), deviceID: String = "11111111-1111-4111-8111-111111111111",
    memberID: String = "member-fixture", deviceKey: String,
    origin: String = "https://account.test", now: Date = Date(), changes: [String: Any] = [:]) throws -> DeviceIdentityCertificate {
    var claims: [String: Any] = ["iss": origin, "sub": userID, "aud": "rideintercom-peer", "deviceID": deviceID,
        "memberID": memberID, "deviceKey": deviceKey, "iat": floor(now.timeIntervalSince1970), "exp": floor(now.timeIntervalSince1970) + 600]
    claims.merge(changes) { _, new in new }
    let header = IdentityEncoding.encode(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "rideintercom-device+jwt"]))
    let payload = IdentityEncoding.encode(try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
    let signed = header + "." + payload
    let signature = try signer.signature(for: Data(signed.utf8))
    return .init(certificate: signed + "." + IdentityEncoding.encode(signature.rawRepresentation),
                 issuerKey: IdentityEncoding.encode(signer.publicKey.x963Representation))
}
