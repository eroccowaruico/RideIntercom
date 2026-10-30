import AuthenticationServices
import Foundation
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
        AccountHTTPStub.respond(status: 409, path: "/api/auth/apple/session")
        await f.authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(f.saved == nil)
        #expect(f.authorization.message?.contains("8 registered devices") == true)
        #expect(f.authorization.message?.contains("Sign out") == true)
        #expect(!f.authorization.isReady && !f.authorization.isBusy)
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
        #expect(AccountHTTPStub.requests.map { $0.url!.path } == ["/api/auth/apple/challenge", "/api/auth/apple/session"])
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
    var saveFails = false
    var credential: InternetAccountCredential { .init(userID: String(repeating: "a", count: 64), deviceID: deviceID,
        expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
        accessToken: "ri1.\(String(repeating: "a", count: 64)).\(deviceID).\(String(repeating: "c", count: 64))") }
    lazy var authorization: InternetAccountAuthorization = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountHTTPStub.self]
        AccountHTTPStub.reset(deviceID: deviceID)
        return InternetAccountAuthorization(expectedUserID: "apple-user", deviceID: deviceID,
            client: InternetAccountClient(session: URLSession(configuration: configuration)), currentUser: { [unowned self] in currentUser },
            save: { [unowned self] _, value in if saveFails { throw URLError(.cannotWriteToFile) }; saved = value })
    }()
    func remove() { UserDefaults(suiteName: namespace)?.removePersistentDomain(forName: namespace) }
}

private final class InternetAccountTestKeychain: KeychainSecretStoring {
    var values: [String: String] = [:]
    var failDelete = false
    var failRead = false
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
    func saveSecret(_ secret: String, service: String, account: String) throws { values[service + account] = secret }
    func deleteSecret(service: String, account: String) throws {
        if failDelete { throw KeychainSecretStoreError.invalidData }
        values[service + account] = nil
    }
}

private final class AccountHTTPStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var deviceID = ""
    nonisolated(unsafe) private static var locator = String(repeating: "d", count: 64)
    nonisolated(unsafe) private static var delayed = false
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var responsePath: String?
    nonisolated(unsafe) private static var retryAfter: String?
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(deviceID: String) { lock.withLock {
        recorded = []; Self.deviceID = deviceID; delayed = false; locator = String(repeating: "d", count: 64)
        responseStatus = 200; responsePath = nil; retryAfter = nil
    } }
    static func respond(status: Int, path: String? = nil, retryAfter: String? = nil) { lock.withLock {
        responseStatus = status; responsePath = path; Self.retryAfter = retryAfter
    } }
    static func setLocator(_ value: String) { lock.withLock { locator = value } }
    static func delayExchange() { lock.withLock { delayed = true } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let device = Self.lock.withLock { Self.recorded.append(request); return Self.deviceID }
        let account = String(repeating: "a", count: 64)
        let body: [String: Any]
        if request.url!.path.hasSuffix("/challenge") {
            body = ["challengeID": account, "nonce": String(repeating: "b", count: 64), "deviceID": device,
                    "expiresAt": Date().addingTimeInterval(300).timeIntervalSince1970 * 1000]
        } else if request.httpMethod == "DELETE" { body = [:] }
        else { body = ["userID": account, "deviceID": device, "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
                       "accessToken": "ri1.\(Self.lock.withLock { Self.locator }).\(device).\(String(repeating: "c", count: 64))"] }
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
    override func stopLoading() {}
}
