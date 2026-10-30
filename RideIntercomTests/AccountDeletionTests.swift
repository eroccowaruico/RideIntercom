import AuthenticationServices
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct AccountDeletionTests {
    @Test(arguments: [true, false]) func newerServerAccountIsPreservedWithoutAdvisingAppleRemoval(withProof: Bool) async throws {
        let f = DeletionFixture(); defer { f.remove() }
        let session = f.session(); f.signIn(session)
        try session.deletion.begin(userID: "owner", access: f.access,
            proof: withProof ? .init(challengeID: "challenge", identityToken: "token", authorizationCode: "code") : nil)
        await session.resumeDeletion(client: f.client(body: ["deleted": true, "appleAuthorizationRevoked": false, "newerAccountPreserved": true]))
        #expect(session.deletion.canFinish)
        #expect(!session.deletion.requiresManualAppleRemoval)
        #expect(session.deletion.record?.serverResult?.newerAccountPreserved == true)
        if withProof { #expect(DeletionHTTPStub.lastBody["expectedUserID"] == f.access.userID) }
    }

    @Test func expiredPendingReceiptRequiresFreshProofAndKeepsLocalErasure() async throws {
        let f = DeletionFixture(); defer { f.remove() }
        let session = f.session(); f.signIn(session)
        try session.deletion.begin(userID: "owner", access: f.access, proof: nil)
        let client = f.client(body: ["deleted": true, "appleAuthorizationRevoked": false, "appleRevocationPending": true])
        await session.resumeDeletion(client: client)
        DeletionHTTPStub.respond(status: 401, body: [:])
        await session.resumeDeletion(client: client)
        #expect(session.deletion.record?.localErased == true)
        #expect(session.deletion.record?.serverResult == nil)
        #expect(!session.deletion.canFinish)
        let proof = InternetAccountDeletionProof(challengeID: "fresh", identityToken: "fresh-token", authorizationCode: "fresh-code")
        try session.deletion.replaceProof(proof)
        DeletionHTTPStub.respond(body: ["deleted": true, "appleAuthorizationRevoked": true])
        await session.resumeDeletion(client: client)
        #expect(session.deletion.canFinish && !session.deletion.requiresManualAppleRemoval)
    }

    @Test(arguments: [false, true]) func mediaCleanupBlocksCompletionAcrossRestart(applePending: Bool) async throws {
        let f = DeletionFixture(); defer { f.remove() }
        let session = f.session(); f.signIn(session)
        try session.deletion.begin(userID: "owner", access: f.access, proof: nil)
        let client = f.client(body: ["deleted": true, "appleAuthorizationRevoked": !applePending,
                                   "appleRevocationPending": applePending, "mediaCleanupPending": true])
        await session.resumeDeletion(client: client)
        #expect(session.deletion.record?.localErased == true)
        #expect(!session.deletion.canFinish)
        #expect(session.deletion.message?.contains("Internet call cleanup") == true)
        #expect(throws: (any Error).self) { try session.deletion.finish() }
        let restarted = f.session()
        #expect(restarted.deletion.blocksSignIn && !restarted.deletion.canFinish)
        DeletionHTTPStub.respond(body: ["deleted": true, "appleAuthorizationRevoked": true, "mediaCleanupPending": true])
        await restarted.resumeDeletion(client: client)
        #expect(!restarted.deletion.canFinish)
        DeletionHTTPStub.respond(body: ["deleted": true, "appleAuthorizationRevoked": true])
        await restarted.resumeDeletion(client: client)
        #expect(restarted.deletion.canFinish)
        #expect(DeletionHTTPStub.requests.count == 3)
        try restarted.deletion.finish()
        #expect(!f.session().deletion.blocksSignIn)
    }

    @Test func failedJournalWriteDoesNotRevokeLogin() throws {
        let f = AccountFixture(); defer { f.remove() }
        f.signIn()
        f.keychain.fails = true
        #expect(throws: (any Error).self) { try f.session.deletion.begin(userID: "apple-user", access: nil, proof: nil) }
        #expect(!f.session.deletion.blocksSignIn && f.session.userID == "apple-user")
    }

    @Test func erasedGenerationRejectsRetainedRepositoryWrites() throws {
        let f = DeletionFixture(); defer { f.remove() }
        let store = FileGroupStore(directory: f.root.appendingPathComponent(f.scoped("owner")).appendingPathComponent("Groups"))
        let repository = GroupRepository(store: store, credentials: KeychainGroupCredentialStore(keychain: f.keychain, namespace: f.scoped("owner")))
        _ = try repository.load(localMemberID: "local")
        try f.eraser.erase(userID: "owner")
        #expect(throws: GroupStorageError.changedByAnotherProcess) { try repository.save([]) }
    }

    @Test func unauthorizedDeletionDoesNotEraseLocalDataOrDropProof() async throws {
        let f = DeletionFixture(); defer { f.remove() }
        let session = f.session(); f.signIn(session)
        let proof = InternetAccountDeletionProof(challengeID: "challenge", identityToken: "token", authorizationCode: "code")
        try session.deletion.begin(userID: "owner", access: f.access, proof: proof)
        let client = f.client(status: 401)
        await session.resumeDeletion(client: client)
        #expect(!session.deletion.canFinish && session.deletion.record?.localErased == false)
        #expect(session.deletion.record?.proof == proof)
        #expect(session.deletion.record?.serverResult == nil)
        #expect(session.userID == nil)
    }

    @Test func acceptedDeletionErasesLocallyWhileAppleRetrySurvivesRestart() async throws {
        let f = DeletionFixture(); defer { f.remove() }
        let session = f.session(); f.signIn(session)
        try session.deletion.begin(userID: "owner", access: f.access,
            proof: .init(challengeID: "challenge", identityToken: "token", authorizationCode: "code"))
        let client = f.client(body: ["deleted": true, "appleAuthorizationRevoked": false, "appleRevocationPending": true])
        await session.resumeDeletion(client: client)
        #expect(session.deletion.record?.localErased == true)
        #expect(session.deletion.record?.proof == nil)
        #expect(!session.deletion.canFinish)
        let restarted = f.session()
        DeletionHTTPStub.respond(body: ["deleted": true, "appleAuthorizationRevoked": true])
        await restarted.resumeDeletion(client: client)
        #expect(restarted.deletion.canFinish && !restarted.deletion.requiresManualAppleRemoval)
        #expect(DeletionHTTPStub.requests.map(\.httpMethod) == ["DELETE", "DELETE"])
        #expect(DeletionHTTPStub.requests.allSatisfy { $0.url?.path == "/api/auth/account" })
        #expect(DeletionHTTPStub.requests.last?.httpBody == nil && DeletionHTTPStub.requests.last?.httpBodyStream == nil)
        try restarted.deletion.finish()
        #expect(!f.session().deletion.blocksSignIn)
    }

    @Test(arguments: [
        ["deleted": false, "appleAuthorizationRevoked": true],
        ["deleted": true, "appleAuthorizationRevoked": true, "appleRevocationPending": true],
        ["deleted": true],
        ["deleted": true, "appleAuthorizationRevoked": true, "newerAccountPreserved": true],
        ["deleted": true, "appleAuthorizationRevoked": false, "newerAccountPreserved": true, "mediaCleanupPending": true]
    ])
    func malformedSuccessCannotEraseLocalData(body: [String: Bool]) async throws {
        let f = DeletionFixture(); defer { f.remove() }
        let session = f.session(); f.signIn(session)
        try session.deletion.begin(userID: "owner", access: f.access, proof: nil)
        await session.resumeDeletion(client: f.client(body: body))
        #expect(session.deletion.record?.serverResult == nil)
        #expect(session.deletion.record?.localErased == false)
        #expect(!session.deletion.canFinish)
    }

    @Test func freshDeletionProofRequiresSameAppleUserStateAndCurrentAccess() async throws {
        let f = DeletionFixture(); defer { f.remove() }
        let client = f.client()
        var current = true
        var accepted: InternetAccountDeletionProof?
        let auth = AccountDeletionAuthorization(userID: "owner", access: f.access, client: client,
            isCurrent: { current }, accept: { accepted = $0 })
        for condition in ["wrongUser", "wrongState", "retired", "valid", "replay"] {
            if condition != "replay" { await auth.prepare() }
            let request = ASAuthorizationAppleIDProvider().createRequest()
            if condition != "replay" { auth.configure(request) }
            #expect(request.requestedScopes?.isEmpty != false)
            if condition == "retired" { current = false }
            auth.submit(userID: condition == "wrongUser" ? "other" : "owner",
                        state: condition == "wrongState" ? "wrong" : request.state, token: Data("identity".utf8), code: Data("code".utf8))
            if condition == "valid" { #expect(accepted?.authorizationCode == "code"); accepted = nil }
            else { #expect(accepted == nil) }
            current = true
        }
    }

    @Test func eraseIsAccountScopedAndInvalidatesOldSnapshotsIncludingCorruptArchives() throws {
        let f = DeletionFixture(); defer { f.remove() }
        let own = f.scoped("owner"), other = f.scoped("other")
        for namespace in [own, other] {
            UserDefaults(suiteName: namespace)!.set("Private name", forKey: "RideIntercom.localDisplayName")
            for suffix in AccountDataEraser.keychainSuffixes {
                try f.keychain.saveSecret("secret", service: namespace + suffix, account: "sample")
            }
            let dir = f.root.appendingPathComponent(namespace).appendingPathComponent("Groups")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("corrupt private data".utf8).write(to: dir.appendingPathComponent("groups.json"))
            try Data("archive".utf8).write(to: dir.appendingPathComponent("groups-corrupt-backup.json"))
        }
        try f.eraser.erase(userID: "owner")
        let store = FileGroupStore(directory: f.root.appendingPathComponent(own).appendingPathComponent("Groups"))
        let snapshot = try #require(try store.read())
        #expect(snapshot.groups.isEmpty && snapshot.users.isEmpty)
        try f.eraser.erase(userID: "owner")
        #expect(try store.read()?.generation != snapshot.generation)
        #expect(UserDefaults(suiteName: own)!.persistentDomain(forName: own)?.isEmpty != false)
        #expect(UserDefaults(suiteName: other)!.string(forKey: "RideIntercom.localDisplayName") == "Private name")
        for suffix in AccountDataEraser.keychainSuffixes {
            #expect(f.keychain.accounts(service: own + suffix).isEmpty)
            #expect(!f.keychain.accounts(service: other + suffix).isEmpty)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path).sorted() == ["groups.json", "groups.lock"])
    }

    @Test func eraseCannotBypassARepositoryLockOrFollowAnotherAccountsDirectory() throws {
        let f = DeletionFixture(); defer { f.remove() }
        let dir = f.root.appendingPathComponent(f.scoped("owner"))
        let store = FileGroupStore(directory: dir.appendingPathComponent("Groups"))
        try store.lock()
        #expect(throws: (any Error).self) { try f.eraser.erase(userID: "owner") }
        store.unlock()
        try FileManager.default.removeItem(at: dir)
        let other = f.root.appendingPathComponent(f.scoped("other"))
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: other.appendingPathComponent("private"))
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: other)
        #expect(throws: (any Error).self) { try f.eraser.erase(userID: "owner") }
        #expect(try String(contentsOf: other.appendingPathComponent("private"), encoding: .utf8) == "keep")
    }

    @Test func pendingDeletionSurvivesRestartAndPreservesProofUntilServerAcknowledges() async throws {
        let f = DeletionFixture(); defer { f.remove() }
        let session = f.session()
        f.signIn(session)
        let access = AccountDeletion.ServiceAccess(workerURL: URL(string: "https://deletion.test")!, accessToken: "ri1.test", deviceID: UUID().uuidString)
        let proof = InternetAccountDeletionProof(challengeID: "challenge", identityToken: "token", authorizationCode: "code")
        try session.deletion.begin(userID: "owner", access: access, proof: proof)
        session.signOut()
        let restarted = f.session()
        #expect(restarted.userID == nil && restarted.deletion.blocksSignIn)
        f.signIn(restarted)
        #expect(restarted.userID == nil)
        #expect(restarted.deletion.record?.proof == proof)
        #expect(restarted.deletion.record?.access == access)
        #expect(!restarted.deletion.canFinish)
        // An unreadable journal must not be treated as an empty account.
        try f.keychain.saveSecret("broken", service: f.name + ".AccountDeletion", account: "pending")
        let unreadable = f.session()
        #expect(unreadable.deletion.blocksSignIn && unreadable.userID == nil)
    }

    @Test func localDeletionEndsAccessAndCanResumeAfterStorageFailure() async throws {
        let f = DeletionFixture(); defer { f.remove() }
        let session = f.session(); f.signIn(session)
        let h = AppTestSupport.makeHarness(accountSession: session)
        let vm = h.viewModel
        let dir = f.root.appendingPathComponent(f.scoped("owner")).appendingPathComponent("Groups")
        let locked = FileGroupStore(directory: dir); try locked.lock()
        try session.deletion.begin(userID: "owner", access: nil, proof: nil)
        await session.resumeDeletion()
        #expect(!vm.canStartCalls && !vm.canEditSavedGroups)
        #expect(session.deletion.blocksSignIn && !session.deletion.canFinish)
        locked.unlock()
        let restarted = f.session()
        await restarted.resumeDeletion()
        #expect(restarted.deletion.canFinish)
        #expect(restarted.deletion.requiresManualAppleRemoval)
        try restarted.deletion.finish()
        #expect(!restarted.deletion.blocksSignIn)
        f.signIn(restarted)
        #expect(restarted.userID == "owner")
        #expect(!vm.canStartCalls)
    }
}

@MainActor private final class DeletionFixture {
    let name = "RideIntercom.DeletionTests." + UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keychain = DictionaryKeychain()
    var access: AccountDeletion.ServiceAccess { .init(workerURL: URL(string: "https://deletion.test")!, accessToken: "ri1.fixture", deviceID: "11111111-1111-1111-1111-111111111111", userID: String(repeating: "a", count: 64)) }
    func client(status: Int = 200, body: [String: Bool] = ["deleted": true, "appleAuthorizationRevoked": true]) -> InternetAccountClient {
        DeletionHTTPStub.reset(status: status, body: body)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeletionHTTPStub.self]
        return .init(session: URLSession(configuration: config))
    }
    var eraser: AccountDataEraser { .init(keychain: keychain, namespace: name, applicationSupport: root) }
    func scoped(_ user: String) -> String { AppleAccountSession.storageNamespace(base: name, userID: user) }
    func session() -> AppleAccountSession {
        AppleAccountSession(keychain: keychain, defaults: UserDefaults(suiteName: name)!, namespace: name,
                            applicationSupport: root, credentialState: { _ in .authorized })
    }
    func signIn(_ session: AppleAccountSession) {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        session.prepare(request)
        _ = session.completeSignIn(userID: "owner", state: request.state)
    }
    func remove() {
        for namespace in [name, scoped("owner"), scoped("other")] { UserDefaults(suiteName: namespace)!.removePersistentDomain(forName: namespace) }
        try? FileManager.default.removeItem(at: root)
    }
}

private final class DeletionHTTPStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body: [String: Bool] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var input: [String: String] = [:]
    static var lastBody: [String: String] { lock.withLock { input } }
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(status: Int, body: [String: Bool]) { lock.withLock { Self.status = status; Self.body = body; recorded = []; input = [:] } }
    static func respond(status: Int = 200, body: [String: Bool]) { lock.withLock { Self.status = status; Self.body = body } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        let (status, body) = Self.lock.withLock {
            Self.recorded.append(request)
            Self.input = (try? JSONDecoder().decode([String: String].self, from: bytes)) ?? [:]
            return (Self.status, Self.body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        var data = try! JSONEncoder().encode(body)
        if request.url!.path.hasSuffix("/challenge") {
            data = try! JSONSerialization.data(withJSONObject: ["challengeID": String(repeating: "a", count: 64), "nonce": String(repeating: "b", count: 64),
                "deviceID": "11111111-1111-1111-1111-111111111111", "expiresAt": Date().addingTimeInterval(300).timeIntervalSince1970 * 1000])
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
