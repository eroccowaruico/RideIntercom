import AuthenticationServices
import Foundation
import CryptoKit
import RTC
import Testing
@testable import RideIntercom

@MainActor
@Suite(.serialized)
struct InternetAccountTests {
    @Test func throttledPreparationDoesNotResendUntilRetryWindowEnds() async throws {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        let authorization = f.authorization
        AccountHTTPStub.respond(status: 429, path: "/api/auth/apple/challenge", retryAfter: "1")
        await authorization.prepare(url: "https://account.test")
        #expect(authorization.message?.contains("Wait 1 second") == true)
        #expect(!authorization.isBusy && !authorization.isReady)
        authorization.cancel()
        await authorization.prepare(url: "https://account.test")
        #expect(AccountHTTPStub.requests.count == 1)
        AccountHTTPStub.respond(status: 200)
        try await Task.sleep(for: .milliseconds(1100))
        await authorization.prepare(url: "https://account.test")
        #expect(AccountHTTPStub.requests.count == 2)
        #expect(authorization.isReady)
    }

    @Test(arguments: ["bad", "-5", "0", "999999999999999999999999999", "3601", ""])
    func untrustedRetryDelayIsBounded(value: String) async {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        let authorization = f.authorization
        AccountHTTPStub.respond(status: 429, path: "/api/auth/apple/challenge", retryAfter: value)
        await authorization.prepare(url: "https://account.test")
        #expect(authorization.message?.contains(value == "3601" ? "Wait 3600 seconds" : "Wait 60 seconds") == true)
        #expect(!authorization.isReady)
    }

    @Test func exchangeThrottlingKeepsCredentialsUnchangedAndRequiresFreshPreparation() async {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        await f.authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.authorization.configure(request)
        AccountHTTPStub.respond(status: 429, path: "/api/auth/apple/session", retryAfter: "60")
        await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(f.saved == nil)
        #expect(!f.authorization.isReady)
        #expect(f.authorization.message?.contains("Wait 60 seconds") == true)
        await f.authorization.prepare(url: "https://account.test")
        #expect(AccountHTTPStub.requests.count == 2)
    }

    @Test func deviceCapacityErrorExplainsHowToFreeARegistration() async {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        await f.authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.authorization.configure(request)
        AccountHTTPStub.respond(status: 409, path: "/api/auth/apple/session", code: "device_limit_reached")
        await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(f.saved == nil)
        #expect(f.authorization.message?.contains("8 registered devices") == true)
        #expect(f.authorization.message?.contains("Sign out") == true)
        #expect(!f.authorization.isReady && !f.authorization.isBusy)
    }

    @Test(arguments: ["deletion_pending", "unknown"])
    func pendingDeletionAndUnknownConflictAreNotDeviceCapacity(code: String) async {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        await f.authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.authorization.configure(request)
        AccountHTTPStub.respond(status: 409, path: "/api/auth/apple/session", code: code)
        await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(f.saved == nil && !f.authorization.isBusy && !f.authorization.isReady)
        #expect(f.authorization.message?.contains("8 registered devices") == false)
        if code == "deletion_pending" {
            #expect(f.authorization.message?.contains("deletion is still pending") == true)
        }
    }

    @Test func lateThrottleCannotRestoreCancelledStateOrBlockAnotherService() async {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        await f.authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.authorization.configure(request)
        AccountHTTPStub.respond(status: 429, path: "/api/auth/apple/session", retryAfter: "60")
        AccountHTTPStub.delayExchange()
        let exchange = Task { await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8)) }
        for _ in 0..<100 {
            if AccountHTTPStub.requests.count == 2 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        f.authorization.cancel()
        await exchange.value
        #expect(f.authorization.message == nil)
        AccountHTTPStub.respond(status: 200)
        await f.authorization.prepare(url: "https://another-account.test")
        #expect(f.authorization.isReady)
        #expect(f.saved == nil)
    }

    @Test func enrollmentUsesServerNonceAndSavesOnlyTheMatchingAccount() async throws {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        await f.authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.authorization.configure(request)
        #expect(request.nonce == String(repeating: "b", count: 64))
        #expect(request.requestedScopes?.isEmpty == true)
        await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("synthetic-proof".utf8))
        #expect(f.saved?.userID == String(repeating: "a", count: 64))
        #expect(f.saved?.deviceID == f.deviceID)
        #expect(f.saved?.accessToken.split(separator: ".")[1] == Substring(String(repeating: "d", count: 64)))
        #expect(f.authorization.message == "Internet calling is connected to your Apple Account.")
        #expect(AccountHTTPStub.requests.map { $0.url!.path } == ["/api/auth/apple/challenge", "/api/auth/apple/session", "/api/auth/identity"])
    }

    @Test(arguments: ["", "invalid", String(repeating: "d", count: 63), String(repeating: "D", count: 64), String(repeating: "d", count: 64) + ".extra"])
    func invalidPrivateLocatorCannotBeSaved(locator: String) async {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        await f.authorization.prepare(url: "https://account.test")
        AccountHTTPStub.setLocator(locator)
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.authorization.configure(request)
        await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(f.saved == nil)
        #expect(f.authorization.message != "Internet calling is connected to your Apple Account.")
    }

    @Test(arguments: ["sub", "deviceID", "memberID", "deviceKey", "iss", "aud"])
    func mismatchedIdentityCannotBeSavedAndNewCredentialIsRevoked(field: String) async {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        await f.authorization.prepare(url: "https://account.test")
        let wrong: [String: String] = ["sub": String(repeating: "b", count: 64), "deviceID": UUID().uuidString.lowercased(),
            "memberID": "another-member", "deviceKey": IdentityEncoding.encode(P256.Signing.PrivateKey().publicKey.x963Representation),
            "iss": "https://another.test", "aud": "another-purpose"]
        AccountHTTPStub.changeIdentity([field: wrong[field]!])
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.authorization.configure(request)
        await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(f.saved == nil && f.savedIdentity == nil)
        #expect(AccountHTTPStub.requests.last?.httpMethod == "DELETE")
    }

    @Test func verifiedIdentityAndPrivateKeySurviveRestartAndAreDisabledOnSignOut() async throws {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        await f.authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.authorization.configure(request)
        await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        let credential = try #require(f.saved), identity = try #require(f.savedIdentity)
        let store = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace)
        try store.save(url: "https://account.test", token: credential.accessToken, identity: identity)
        try f.keychain.saveSecret(credential.deviceID, service: f.namespace + ".InternetConnection", account: "device-id")
        let restarted = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace)
        #expect(try restarted.deletionAccess()?.userID == credential.userID)
        #expect(try restarted.loadIdentity(memberID: "member-fixture")?.userID == credential.userID)
        #expect(try restarted.deviceSigningKey().rawRepresentation == f.signingKey.rawRepresentation)
        #expect(throws: (any Error).self) { try restarted.loadIdentity(memberID: "another-member") }
        _ = try restarted.retireAppleCredential()
        #expect(try restarted.loadIdentity(memberID: "member-fixture") == nil)
        #expect(try restarted.deviceSigningKey().rawRepresentation == f.signingKey.rawRepresentation)
    }

    @Test(arguments: [false, true]) func successfulSignOutKeepsDeletionTargetWithoutRestoringInternetAccess(archiveWriteFails: Bool) async throws {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        await f.authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.authorization.configure(request)
        await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        let credential = try #require(f.saved), identity = try #require(f.savedIdentity)
        let store = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace)
        try f.keychain.saveSecret(credential.deviceID, service: f.namespace + ".InternetConnection", account: "device-id")
        try store.save(url: "https://account.test", token: credential.accessToken, identity: identity)
        var expected = try #require(try store.deletionAccess())
        expected.requiresAppleVerification = true
        let retired = try #require(try store.retireAppleCredential())
        if archiveWriteFails {
            f.keychain.failWrite = true
            #expect(throws: (any Error).self) { try store.finishRevocation(retired) }
            #expect(try store.load() == nil)
            #expect(try store.pendingRevocation() == retired)
            #expect(try store.deletionAccess() == expected)
            f.keychain.failWrite = false
        }
        try store.finishRevocation(retired)
        let restarted = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace,
            developmentDefaults: ["workerURL": "https://fallback.test", "accessToken": "must-not-restore"])
        #expect(try restarted.load() == nil)
        #expect(try restarted.pendingRevocation() == nil)
        #expect(try restarted.loadIdentity(memberID: "member-fixture") == nil)
        #expect(try restarted.deletionAccess() == expected)
        #expect(try restarted.identityTrust()?.issuerKey == identity.envelope.issuerKey)
        let isolated = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace, permitsServiceAccess: false)
        #expect(try isolated.deletionAccess() == nil)
        #expect(try isolated.loadPrincipal(memberID: "member-fixture") == nil)
        #expect(try isolated.identityTrust() == nil)
        let other = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace + ".other")
        #expect(try other.deletionAccess() == nil)
        #expect(try other.loadPrincipal(memberID: "member-fixture") == nil)
        #expect(try other.identityTrust() == nil)
        #expect(throws: (any Error).self) { try restarted.loadPrincipal(memberID: "another-device") }
        try f.keychain.saveSecret("corrupt", service: f.namespace + ".InternetConnection", account: "deletion-account")
        #expect(throws: (any Error).self) { try restarted.deletionAccess() }
        #expect(throws: (any Error).self) { try restarted.loadPrincipal(memberID: "member-fixture") }
        #expect(throws: (any Error).self) { try restarted.identityTrust() }
    }

    @Test(arguments: ["current", "signed-out", "manual"])
    func recreatedAccountKeepsOldDeletionTargetAndCannotRestoreCalls(source: String) throws {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        let store = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace)
        try f.keychain.saveSecret(f.deviceID, service: f.namespace + ".InternetConnection", account: "device-id")
        let oldIdentity = try f.identity()
        try store.save(url: "https://account.test", token: f.credential.accessToken, identity: oldIdentity)
        let configuration = try #require(try store.load())
        var target = try #require(try store.deletionAccess())
        target.requiresAppleVerification = true
        if source == "signed-out" {
            let retired = try #require(try store.retireAppleCredential())
            try store.finishRevocation(retired)
        } else if source == "manual" {
            try store.save(url: "https://account.test", token: "manual-device-token")
            #expect(try store.loadPrincipal(memberID: "member-fixture") == nil)
        }
        let before = f.keychain.values
        let replacement = try f.identity(userID: String(repeating: "b", count: 64))
        #expect(throws: (any Error).self) {
            try store.save(url: "https://account.test", token: "replacement-device-token", identity: replacement)
        }
        #expect(f.keychain.values == before)
        #expect(store.requiresAccountDataReset)
        let restarted = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace,
            developmentDefaults: ["workerURL": "https://fallback.test", "accessToken": "must-not-restore"])
        #expect(restarted.requiresAccountDataReset)
        #expect(!InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace + ".other").requiresAccountDataReset)
        #expect(InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace, permitsServiceAccess: false).requiresAccountDataReset)
        #expect(try restarted.load() == nil)
        #expect(try restarted.loadIdentity(memberID: "member-fixture") == nil)
        #expect(try restarted.loadPrincipal(memberID: "member-fixture") == nil)
        #expect(try restarted.identityTrust() == nil)
        #expect(try restarted.pendingRevocation() == nil)
        #expect(try restarted.deletionAccess() == target)
        #expect(try restarted.deviceSigningKey().rawRepresentation == f.signingKey.rawRepresentation)
        f.keychain.failRead = true
        #expect(restarted.requiresAccountDataReset)
        #expect(try restarted.load() == nil)
        #expect(throws: (any Error).self) { try restarted.deletionAccess() }
        f.keychain.failRead = false
        #expect(throws: (any Error).self) { try restarted.save(url: "https://another.test", token: "manual-bypass") }
        #expect(throws: (any Error).self) {
            try restarted.save(url: "https://account.test", token: f.credential.accessToken, identity: oldIdentity)
        }
        #expect(try restarted.retireAppleCredential() == nil)
        try restarted.finishRevocation(configuration)
        #expect(try restarted.deletionAccess() == target)
        #expect(f.keychain.values == before)
    }

    @Test func manualSettingsPreserveVerifiedDeletionTargetAndArchiveFailurePreservesCurrent() throws {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        let store = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace)
        try f.keychain.saveSecret(f.deviceID, service: f.namespace + ".InternetConnection", account: "device-id")
        try store.save(url: "https://account.test", token: f.credential.accessToken, identity: f.identity())
        var target = try #require(try store.deletionAccess())
        target.requiresAppleVerification = true
        let before = f.keychain.values
        f.keychain.failWriteAccount = "deletion-account"
        #expect(throws: (any Error).self) { try store.save(url: "https://account.test", token: "manual-device-token") }
        #expect(f.keychain.values == before)
        f.keychain.failWriteAccount = nil
        try store.save(url: "https://account.test", token: "manual-device-token")
        #expect(try store.load()?.accessToken == "manual-device-token")
        #expect(try store.loadPrincipal(memberID: "member-fixture") == nil)
        #expect(try store.deletionAccess() == target)
        // Repeated manual saves must not replace the last verified registration.
        try store.save(url: "https://account.test", token: "another-manual-token")
        #expect(try store.deletionAccess() == target)
    }

    @Test func signingOutAManualCredentialDoesNotOverwriteTheVerifiedDeletionTarget() throws {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        let store = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace)
        try f.keychain.saveSecret(f.deviceID, service: f.namespace + ".InternetConnection", account: "device-id")
        try store.save(url: "https://account.test", token: f.credential.accessToken, identity: f.identity())
        var target = try #require(try store.deletionAccess())
        target.requiresAppleVerification = true
        try store.save(url: "https://account.test", token: f.credential.accessToken)
        let pending = try #require(try store.retireAppleCredential())
        try store.finishRevocation(pending)
        #expect(try store.load() == nil)
        #expect(try store.deletionAccess() == target)
    }

    @Test func sameAccountRenewalAndDifferentServiceAreNotAnAccountReplacement() throws {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        let store = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace)
        try store.save(url: "https://account.test", token: f.credential.accessToken, identity: f.identity())
        try store.save(url: "https://account.test", token: "renewed-token", identity: f.identity())
        #expect(try store.load()?.accessToken == "renewed-token")
        try store.save(url: "https://other.test", token: "different-service-token",
            identity: f.identity(userID: String(repeating: "b", count: 64), origin: "https://other.test"))
        #expect(try store.load()?.accessToken == "different-service-token")
        #expect(!store.requiresAccountDataReset)
    }

    @Test func unreadablePreviousRegistrationCannotBeOverwrittenByNewIdentity() throws {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        let store = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace)
        let identity = try f.identity()
        try f.keychain.saveSecret("corrupt", service: f.namespace + ".InternetConnection", account: "current")
        #expect(throws: (any Error).self) {
            try store.save(url: "https://account.test", token: f.credential.accessToken, identity: identity)
        }
        #expect(try f.keychain.secret(service: f.namespace + ".InternetConnection", account: "current") == "corrupt")
    }

    @Test func differentAccountAndReplayedNativeCompletionNeverExchangeProof() async {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        await f.authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.authorization.configure(request)
        await f.authorization.exchange(userID: "another-user", state: request.state, identityToken: Data("proof".utf8))
        await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(f.saved == nil)
        #expect(AccountHTTPStub.requests.count == 1)
    }

    @Test func invalidURLAndAccountChangesCannotStartOrFinishEnrollment() async {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        for url in ["http://account.test", "https://user@account.test", "https://account.test/path", "https://account.test?secret=x"] {
            await f.authorization.prepare(url: url)
        }
        #expect(AccountHTTPStub.requests.isEmpty)
        await f.authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.authorization.configure(request)
        f.currentUser = "changed-user"
        await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(f.saved == nil)
        #expect(AccountHTTPStub.requests.count == 1)
    }

    @Test func failedSaveRevokesNewCredentialAndDoesNotReportSuccess() async {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        f.saveFails = true
        await f.authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.authorization.configure(request)
        await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(f.saved == nil)
        #expect(AccountHTTPStub.requests.last?.httpMethod == "DELETE")
        #expect(f.authorization.message != "Internet calling is connected to your Apple Account.")
    }

    @Test func cancelledExchangeRevokesLateCredentialWithoutSavingIt() async {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        await f.authorization.prepare(url: "https://account.test")
        AccountHTTPStub.delayExchange()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.authorization.configure(request)
        let exchange = Task { await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8)) }
        for _ in 0..<100 {
            if AccountHTTPStub.requests.count >= 2 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        f.authorization.cancel()
        await exchange.value
        #expect(f.saved == nil)
        #expect(AccountHTTPStub.requests.last?.httpMethod == "DELETE")
    }

    @Test func disabledCredentialSurvivesFailedDeletionWithoutBecomingUsable() throws {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        let store = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace)
        #expect(try store.accountDeviceID() == store.accountDeviceID())
        try store.save(url: "https://account.test", token: f.credential.accessToken)
        let retired = try #require(try store.retireAppleCredential())
        #expect(try store.load() == nil)
        f.keychain.failDelete = true
        #expect(throws: (any Error).self) { try store.finishRevocation(retired) }
        let restarted = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace)
        #expect(try restarted.load() == nil)
        #expect(try restarted.pendingRevocation()?.accessToken == retired.accessToken)
        f.keychain.failDelete = false
        try restarted.finishRevocation(retired)
        #expect(try restarted.pendingRevocation() == nil)
    }

    @Test func oldRevocationCannotDeleteNewlySavedCredential() throws {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        let store = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace)
        try store.save(url: "https://account.test", token: f.credential.accessToken)
        let retired = try #require(try store.retireAppleCredential())
        try store.save(url: "https://account.test", token: "new-device-token")
        try store.finishRevocation(retired)
        #expect(try store.load()?.accessToken == "new-device-token")
    }

    @Test func signOutBlocksRestorationEvenWhenKeychainCannotBeRead() throws {
        let f = InternetAccountTestFixture(); defer { f.remove() }
        let store = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace)
        try store.save(url: "https://account.test", token: f.credential.accessToken)
        f.keychain.failRead = true
        #expect(throws: (any Error).self) { try store.retireAppleCredential() }
        f.keychain.failRead = false
        let restarted = InternetConnectionSettingsStore(keychain: f.keychain, namespace: f.namespace)
        #expect(try restarted.load() == nil)
        #expect(try restarted.pendingRevocation() != nil)
    }
}

@MainActor
private final class InternetAccountTestFixture {
    let namespace = "RideIntercom.Tests.InternetAccount." + UUID().uuidString
    let deviceID = UUID().uuidString.lowercased()
    let keychain = InternetAccountTestKeychain()
    var currentUser = "apple-user"
    var saved: InternetAccountCredential?
    var savedIdentity: VerifiedDeviceIdentity?
    lazy var signingKey = try! InternetConnectionSettingsStore(keychain: keychain, namespace: namespace).deviceSigningKey()
    var saveFails = false
    var credential: InternetAccountCredential { .init(userID: String(repeating: "a", count: 64), deviceID: deviceID,
        expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
        accessToken: "ri1.\(String(repeating: "a", count: 64)).\(deviceID).\(String(repeating: "c", count: 64))") }
    lazy var authorization: InternetAccountAuthorization = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountHTTPStub.self]
        AccountHTTPStub.reset(deviceID: deviceID)
        return InternetAccountAuthorization(expectedUserID: "apple-user", deviceID: deviceID,
            memberID: "member-fixture", deviceKey: IdentityEncoding.encode(signingKey.publicKey.x963Representation),
            client: InternetAccountClient(session: URLSession(configuration: configuration)), currentUser: { [unowned self] in currentUser },
            save: { [unowned self] _, value, identity in if saveFails { throw URLError(.cannotWriteToFile) }; saved = value; savedIdentity = identity })
    }()
    func identity(userID: String = String(repeating: "a", count: 64), origin: String = "https://account.test") throws -> VerifiedDeviceIdentity {
        let certificate = try testIdentityCertificate(userID: userID, deviceID: deviceID,
            deviceKey: IdentityEncoding.encode(signingKey.publicKey.x963Representation), origin: origin)
        return try certificate.verify(origin: URL(string: origin)!, trustedIssuerKey: certificate.issuerKey)
    }
    func remove() { UserDefaults(suiteName: namespace)?.removePersistentDomain(forName: namespace) }
}

private final class InternetAccountTestKeychain: KeychainSecretStoring {
    var values: [String: String] = [:]
    var failDelete = false
    var failRead = false
    var failWrite = false
    var failWriteAccount: String?
    func accounts(service: String) throws -> [String] { Array(values.keys) }
    func secret(service: String, account: String) throws -> String? {
        if failRead { throw KeychainSecretStoreError.invalidData }
        return values[service + account]
    }
    func createSecretIfAbsent(_ value: String, service: String, account: String) throws -> String {
        if let retained = try secret(service: service, account: account) { return retained }
        try saveSecret(value, service: service, account: account)
        return value
    }
    func saveSecret(_ secret: String, service: String, account: String) throws {
        if failWrite || failWriteAccount == account { throw KeychainSecretStoreError.invalidData }
        values[service + account] = secret
    }
    func deleteSecret(service: String, account: String) throws {
        if failDelete { throw KeychainSecretStoreError.invalidData }
        values[service + account] = nil
    }
}

private final class AccountHTTPStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var deviceID = ""
    nonisolated(unsafe) private static var identityChanges: [String: String] = [:]
    nonisolated(unsafe) private static var locator = String(repeating: "d", count: 64)
    nonisolated(unsafe) private static var delayed = false
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var responsePath: String?
    nonisolated(unsafe) private static var responseCode: String?
    nonisolated(unsafe) private static var retryAfter: String?
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(deviceID: String) { lock.withLock {
        recorded = []; Self.deviceID = deviceID; delayed = false; locator = String(repeating: "d", count: 64)
        responseStatus = 200; responsePath = nil; retryAfter = nil; responseCode = nil; identityChanges = [:]
    } }
    static func respond(status: Int, path: String? = nil, retryAfter: String? = nil, code: String? = nil) { lock.withLock {
        responseStatus = status; responsePath = path; Self.retryAfter = retryAfter; responseCode = code
    } }
    static func changeIdentity(_ changes: [String: String]) { lock.withLock { identityChanges = changes } }
    static func setLocator(_ value: String) { lock.withLock { locator = value } }
    static func delayExchange() { lock.withLock { delayed = true } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let device = Self.lock.withLock { Self.recorded.append(request); return Self.deviceID }
        let account = String(repeating: "a", count: 64)
        var body: [String: Any]
        if request.url!.path.hasSuffix("/challenge") {
            body = ["challengeID": account, "nonce": String(repeating: "b", count: 64), "deviceID": device,
                    "expiresAt": Date().addingTimeInterval(300).timeIntervalSince1970 * 1000]
        } else if request.url!.path.hasSuffix("/identity") {
            let input = Self.body(request)
            let changes = Self.lock.withLock { Self.identityChanges }
            let proof = try! testIdentityCertificate(deviceID: device, memberID: input["memberID"] as? String ?? "missing",
                deviceKey: input["deviceKey"] as? String ?? "missing", origin: IdentityEncoding.origin(request.url!), changes: changes)
            body = ["certificate": proof.certificate, "issuerKey": proof.issuerKey]
        } else if request.httpMethod == "DELETE" { body = [:] }
        else { body = ["userID": account, "deviceID": device, "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
                       "accessToken": "ri1.\(Self.lock.withLock { Self.locator }).\(device).\(String(repeating: "c", count: 64))"] }
        if let code = Self.lock.withLock({ Self.responseCode }), Self.lock.withLock({ Self.responsePath }) == request.url?.path { body = ["code": code] }
        let data = try! JSONSerialization.data(withJSONObject: body)
        let (status, retryAfter) = Self.lock.withLock {
            (Self.responsePath == nil || Self.responsePath == request.url?.path ? Self.responseStatus : 200, Self.retryAfter)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                      headerFields: retryAfter.map { ["Retry-After": $0] })!
        let deliver: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if request.url!.path == "/api/auth/apple/session", Self.lock.withLock({ Self.delayed }) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2, execute: deliver)
        } else { deliver() }
    }
    private static func body(_ request: URLRequest) -> [String: Any] {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
    }
    override func stopLoading() {}
}
