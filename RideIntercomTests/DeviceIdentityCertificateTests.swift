import CryptoKit
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct DeviceIdentityCertificateTests {
    @Test func acceptsJOSEGeneratedES256Certificate() throws {
        // Produced by server dependency jose using an ephemeral test key; no private key is retained.
        let envelope = DeviceIdentityCertificate(certificate: "eyJhbGciOiJFUzI1NiIsInR5cCI6InJpZGVpbnRlcmNvbS1kZXZpY2Urand0In0.eyJkZXZpY2VJRCI6IjExMTExMTExLTExMTEtNDExMS04MTExLTExMTExMTExMTExMSIsIm1lbWJlcklEIjoibWVtYmVyLWZpeHR1cmUiLCJkZXZpY2VLZXkiOiJCSmkycWtrWmRTZmpHRmw3ZnpYaWNPaURidndkQ01RRk4yNmQ0bTZMVFYxN0pUSFNHdjdtbThGcTYtbHdKU0ZfYmdfN1dCM3NXamxRVjNYMVk0V0pRRGsiLCJpc3MiOiJodHRwczovL2FjY291bnQudGVzdCIsInN1YiI6ImFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJhdWQiOiJyaWRlaW50ZXJjb20tcGVlciIsImlhdCI6MTgwMDAwMDAwMCwiZXhwIjoxODAwMDAwNjAwfQ.HeyA-N8qNv6UOUOSDp72ERzWNi3WtDyC-WOqEzJTEGAD3zmAOrq5GAtx98AqhayOESo8Y5tEmWcv6rhQMLoH6Q",
                                                 issuerKey: "BOMKdoYNh4WGXWi-ElHbqIkWglS5708yWwwsaQdjwRrF9IrTGvsdlOAfstcIv_yVij8CJi82u3MGs_e4wyEH3LI")
        let identity = try envelope.verify(origin: URL(string: "https://account.test")!, trustedIssuerKey: envelope.issuerKey,
                                           now: Date(timeIntervalSince1970: 1_800_000_001))
        #expect(identity.userID == String(repeating: "a", count: 64))
        #expect(identity.memberID == "member-fixture")
    }

    @Test func verifiesIssuerDeviceAndLifetimeWithoutNetwork() throws {
        let signer = P256.Signing.PrivateKey(), device = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let certificate = try testIdentityCertificate(signer: signer, deviceKey: IdentityEncoding.encode(device.publicKey.x963Representation), now: now)
        let verified = try certificate.verify(origin: URL(string: "https://ACCOUNT.test:443/")!, trustedIssuerKey: certificate.issuerKey, now: now)
        #expect(verified.userID == String(repeating: "a", count: 64))
        #expect(verified.memberID == "member-fixture")
        #expect(verified.deviceKey == IdentityEncoding.encode(device.publicKey.x963Representation))
        #expect(throws: (any Error).self) { try certificate.verify(origin: URL(string: "https://another.test")!, trustedIssuerKey: certificate.issuerKey, now: now) }
        #expect(throws: (any Error).self) { try certificate.verify(origin: URL(string: "https://account.test")!, trustedIssuerKey: IdentityEncoding.encode(device.publicKey.x963Representation), now: now) }
        #expect(throws: (any Error).self) { try certificate.verify(origin: URL(string: "https://account.test")!, trustedIssuerKey: certificate.issuerKey, now: now.addingTimeInterval(600)) }
        var parts = certificate.certificate.split(separator: ".").map(String.init)
        parts[2] = IdentityEncoding.encode(Data(repeating: 0, count: 64))
        let tampered = DeviceIdentityCertificate(certificate: parts.joined(separator: "."), issuerKey: certificate.issuerKey)
        #expect(throws: (any Error).self) { try tampered.verify(origin: URL(string: "https://account.test")!, trustedIssuerKey: certificate.issuerKey, now: now) }
    }

    @Test func rejectsMalformedSignedClaims() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), signer = P256.Signing.PrivateKey()
        let deviceKey = IdentityEncoding.encode(P256.Signing.PrivateKey().publicKey.x963Representation)
        let changes: [[String: Any]] = [["aud": "another-purpose"], ["sub": "self-claimed"], ["deviceID": "not-uuid"],
            ["memberID": "invite-pending-someone"], ["memberID": "x".padding(toLength: 64, withPad: "x", startingAt: 0)],
            ["deviceKey": IdentityEncoding.encode(Data(repeating: 0, count: 65))], ["iat": 1_800_000_061],
            ["iat": 1_800_000_000.5], ["exp": 1_800_000_000], ["exp": 1_800_000_000 + 30 * 86400 + 1]]
        for change in changes {
            let certificate = try testIdentityCertificate(signer: signer, deviceKey: deviceKey, now: now, changes: change)
            #expect(throws: (any Error).self) { try certificate.verify(origin: URL(string: "https://account.test")!, trustedIssuerKey: certificate.issuerKey, now: now) }
        }
    }

    @Test func missingOrCorruptPrivateKeyDoesNotGetReplacedByReadingIdentity() throws {
        let namespace = "RideIntercom.Tests.Identity." + UUID().uuidString
        defer { UserDefaults(suiteName: namespace)?.removePersistentDomain(forName: namespace) }
        let keychain = DictionaryKeychain(), store = InternetConnectionSettingsStore(keychain: keychain, namespace: namespace)
        let device = try store.deviceSigningKey()
        let certificate = try testIdentityCertificate(deviceKey: IdentityEncoding.encode(device.publicKey.x963Representation))
        let verified = try certificate.verify(origin: URL(string: "https://account.test")!, trustedIssuerKey: certificate.issuerKey)
        try store.save(url: "https://account.test", token: "test-credential", identity: verified)
        let service = namespace + ".InternetConnection"
        try keychain.deleteSecret(service: service, account: "identity-key")
        #expect(throws: (any Error).self) { try store.loadIdentity(memberID: "member-fixture") }
        #expect(throws: (any Error).self) {
            try store.invitationSigner(memberID: "member-fixture", expectedPublicKey: IdentityEncoding.encode(device.publicKey.x963Representation))
        }
        #expect(try keychain.secret(service: service, account: "identity-key") == nil)
        try keychain.saveSecret("corrupt", service: service, account: "identity-key")
        #expect(throws: (any Error).self) { try store.deviceSigningKey() }
        #expect(try keychain.secret(service: service, account: "identity-key") == "corrupt")
    }
}
