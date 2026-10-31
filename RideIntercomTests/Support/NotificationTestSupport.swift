import CryptoKit
import Foundation
@testable import RideIntercom

/// Same JWT shape and ES256 encoding as the local Worker contract, with an
/// ephemeral fixture issuer. The App's rejection filter does not trust this key.
nonisolated func testCallNotificationGrant(owner: AccountPrincipal, allowedSender: AccountPrincipal,
                                           grantID: UUID = UUID()) throws -> CallNotificationGrant {
    let key = P256.Signing.PrivateKey()
    let header = IdentityEncoding.encode(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "rideintercom-notification+jwt"], options: [.sortedKeys]))
    let payload = IdentityEncoding.encode(try JSONSerialization.data(withJSONObject: ["iss": owner.issuer, "aud": "rideintercom-call-notification",
        "sub": allowedSender.userID, "recipient": owner.userID, "jti": grantID.uuidString.lowercased(), "iat": floor(Date().timeIntervalSince1970)], options: [.sortedKeys]))
    let message = header + "." + payload
    let signature = IdentityEncoding.encode(try key.signature(for: Data(message.utf8)).rawRepresentation)
    return .init(grantID: grantID, capability: message + "." + signature)
}
