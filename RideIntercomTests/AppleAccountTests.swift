import AuthenticationServices
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct AppleAccountTests {
    @Test func allRoutesRequireLoginAndSignOutStopsActiveCall() throws {
        let f = AccountFixture(); defer { f.remove() }
        let denied = AppTestSupport.makeHarness(accountSession: f.session)
        denied.viewModel.selectGroup(try #require(denied.viewModel.groups.first))
        #expect(denied.callSession.connectedGroup == nil)
        #expect(!denied.viewModel.startAudioPipelineIfNeeded())
        f.signIn()
        let allowed = AppTestSupport.makeHarness(accountSession: f.session)
        defer { allowed.viewModel.disconnect() }
        // This verifies authorization and media shutdown; native ML effect
        // initialization is exercised by the dedicated audio tests.
        allowed.viewModel.setSoundIsolationEnabled(false)
        allowed.viewModel.selectGroup(try #require(allowed.viewModel.groups.first))
        #expect(allowed.callSession.connectedGroup != nil)
        allowed.callSession.authenticate(try #require(allowed.viewModel.selectedGroup).members.dropFirst().map(\.id))
        #expect(allowed.viewModel.isAudioReady)
        let savedGroups = allowed.viewModel.groups
        f.session.signOut()
        #expect(allowed.viewModel.activeGroupID == nil)
        #expect(!allowed.viewModel.isAudioReady)
        #expect(allowed.viewModel.groups.map(\.id) == savedGroups.map(\.id))
        let count = allowed.callSession.startMediaCallCount
        allowed.viewModel.connectLocal()
        #expect(allowed.callSession.connectedGroup == nil && allowed.callSession.startMediaCallCount == count)
        f.signIn("other-account")
        allowed.viewModel.connectLocal()
        #expect(allowed.callSession.connectedGroup == nil && allowed.callSession.startMediaCallCount == count)
    }
    @Test(arguments: ["apple-user", "other-account"])
    func retiredModelCannotRegainAccessAfterAnotherLogin(nextUser: String) throws {
        let f = AccountFixture(); defer { f.remove() }
        f.signIn()
        let old = AppTestSupport.makeHarness(accountSession: f.session)
        defer { old.viewModel.disconnect() }
        let group = try #require(old.viewModel.groups.first)
        old.viewModel.selectGroup(group)
        f.session.signOut()
        f.signIn(nextUser)
        #expect(!old.viewModel.canStartCalls)
        #expect(!old.viewModel.canEditSavedGroups)
        #expect(!old.viewModel.canStartAudioCheck)
        old.viewModel.connectLocal()
        #expect(old.callSession.connectedGroup == nil)
        #expect(old.viewModel.makeSelectedGroupInviteURL() == nil)
        #expect(!old.viewModel.setLocalDisplayName("Stale name"))
        let fresh = AppTestSupport.makeHarness(accountSession: f.session)
        defer { fresh.viewModel.disconnect() }
        #expect(fresh.viewModel.canStartCalls)
        #expect(fresh.viewModel.canEditSavedGroups)
    }

    @Test func signedOutOperationsCannotChangeSavedDataOrCredentials() throws {
        let f = AccountFixture(); defer { f.remove() }
        f.signIn()
        let settings = InMemoryAppSettingsStore()
        let internet = InternetConnectionSettingsStore(keychain: InternetTestKeychain(), namespace: "retired-model")
        let h = AppTestSupport.makeHarness(accountSession: f.session, appSettingsStore: settings, internetSettingsStore: internet)
        let vm = h.viewModel
        defer { vm.disconnect() }
        let group = try #require(vm.groups.first)
        vm.selectGroup(group)
        let invite = try #require(vm.makeSelectedGroupInviteURL())
        let before = h.groupStore.snapshot
        let previousSettings = settings.load()
        f.session.signOut()
        #expect(!vm.createTalkGroup(name: "Stale operation"))
        #expect(!vm.commitGroups([]))
        vm.deleteGroup(group.id)
        vm.resetSavedGroups()
        #expect(throws: (any Error).self) { try vm.acceptInviteURL(invite) }
        #expect(throws: (any Error).self) { try vm.credential(for: group) }
        #expect(throws: (any Error).self) { try vm.saveInternetConnection(url: "https://account.test", token: "stale-token") }
        vm.setOpusBitRate(16_000)
        #expect(h.groupStore.snapshot == before)
        #expect(settings.load() == previousSettings)
        #expect(try internet.load() == nil)
    }

    @Test func accountReplacementRevokesOldAccessBeforeShutdownCallback() {
        let f = AccountFixture(); defer { f.remove() }
        f.signIn()
        let h = AppTestSupport.makeHarness(accountSession: f.session)
        var accessDuringShutdown: Bool?
        f.session.onAccessRevoked = { accessDuringShutdown = h.viewModel.canStartCalls }
        f.signIn("other-account")
        #expect(accessDuringShutdown == false)
        f.signIn()
        #expect(!h.viewModel.canStartCalls)
    }

    @Test func loginRequiresMatchingRequestAndPersistsOnlyIdentifier() throws {
        let f = AccountFixture(); defer { f.remove() }
        #expect(f.session.userID == nil)
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.session.prepare(request)
        #expect(request.requestedScopes?.isEmpty == true)
        #expect(request.state != nil)
        #expect(!f.session.completeSignIn(userID: "apple-user", state: "wrong"))
        #expect(f.keychain.value == nil)
        f.session.prepare(request)
        #expect(f.session.completeSignIn(userID: "apple-user", state: request.state))
        #expect(f.session.userID == "apple-user")
        #expect(f.keychain.value == "apple-user")
        #expect(!f.session.completeSignIn(userID: "other-user", state: request.state))
        #expect(f.session.userID == "apple-user")
    }

    @Test func restoreAndTemporaryFailureRetainCachedLogin() async {
        let f = AccountFixture(); defer { f.remove() }
        f.signIn()
        let restored = f.restart { _ in .authorized }
        #expect(restored.userID == "apple-user") // Local calls never wait for an online refresh.
        await restored.refresh()
        #expect(restored.userID == "apple-user")
        let offline = f.restart { _ in throw URLError(.notConnectedToInternet) }
        await offline.refresh()
        #expect(offline.userID == "apple-user")
        #expect(offline.message != nil)
    }

    @Test(arguments: [AppleCredentialState.revoked, .notFound, .transferred])
    func invalidCredentialStopsAccessAndDoesNotReturnAfterRestart(state: AppleCredentialState) async {
        let f = AccountFixture(); defer { f.remove() }
        f.signIn()
        let restored = f.restart { _ in state }
        var stopped = false
        restored.onAccessRevoked = { stopped = true }
        await restored.refresh()
        #expect(restored.userID == nil)
        #expect(stopped)
        #expect(f.keychain.value == nil)
        let again = f.restart { _ in throw URLError(.notConnectedToInternet) }
        await again.refresh()
        #expect(again.userID == nil)
    }

    @Test func failedKeychainWriteNeverSignsIn() {
        let f = AccountFixture(); defer { f.remove() }
        f.keychain.fails = true
        f.signIn()
        #expect(f.session.userID == nil)
        #expect(f.session.message != nil)
    }

    @Test func cancelledNativeLoginCanBeRetried() {
        let f = AccountFixture(); defer { f.remove() }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        f.session.prepare(request)
        f.session.complete(.failure(ASAuthorizationError(.canceled)))
        #expect(f.session.userID == nil)
        #expect(f.session.message == nil)
        #expect(!f.session.isSigningIn)
        #expect(!f.session.completeSignIn(userID: "apple-user", state: request.state))
        f.signIn()
        #expect(f.session.userID == "apple-user")
    }

    @Test func failedSignOutDeletionCanBeRetriedWithoutSigningIn() async {
        let f = AccountFixture(); defer { f.remove() }
        f.signIn()
        f.keychain.fails = true
        f.session.signOut()
        #expect(f.session.storageUnavailable)
        f.keychain.fails = false
        await f.session.reload()
        #expect(f.keychain.value == nil)
        #expect(f.session.userID == nil)
        #expect(!f.session.storageUnavailable)
    }

    @Test func signOutFailureStillBlocksOfflineRestoration() async {
        let f = AccountFixture(); defer { f.remove() }
        f.signIn()
        f.keychain.fails = true
        f.session.signOut()
        #expect(f.session.userID == nil)
        #expect(f.session.message != nil)
        f.keychain.fails = false
        #expect(f.keychain.value != nil) // Failed deletion preserves the original.
        let restored = f.restart { _ in throw URLError(.notConnectedToInternet) }
        await restored.refresh()
        #expect(restored.userID == nil)
    }

    @Test func unreadableKeychainIsPreservedAndNotOverwritten() {
        let f = AccountFixture(); defer { f.remove() }
        f.signIn()
        f.keychain.fails = true
        let restored = f.restart { _ in .authorized }
        f.keychain.fails = false
        let request = ASAuthorizationAppleIDProvider().createRequest()
        restored.prepare(request)
        #expect(!restored.completeSignIn(userID: "other", state: request.state))
        #expect(f.keychain.value == "apple-user")
        #expect(restored.userID == nil)
    }

    @Test func pendingRefreshCannotUndoSignOut() async {
        let f = AccountFixture(); defer { f.remove() }
        f.signIn()
        var continuation: CheckedContinuation<AppleCredentialState, Never>?
        let restored = f.restart { _ in await withCheckedContinuation { continuation = $0 } }
        let task = Task { await restored.refresh() }
        await AppTestSupport.waitUntil { continuation != nil }
        restored.signOut()
        continuation?.resume(returning: .authorized)
        await task.value
        #expect(restored.userID == nil)
    }

    @Test func keychainRecoveryPublishesANewAccessForTheSignedInScreen() async {
        let f = AccountFixture(); defer { f.remove() }
        f.signIn()
        f.keychain.fails = true
        let recovered = f.restart { _ in .authorized }
        let unavailableAccess = recovered.accessID
        #expect(recovered.userID == nil && recovered.storageUnavailable)
        f.keychain.fails = false
        await recovered.reload()
        #expect(recovered.userID == "apple-user")
        #expect(recovered.accessID != unavailableAccess)
        let validAccess = recovered.accessID
        await recovered.refresh()
        await recovered.reload()
        #expect(recovered.accessID == validAccess) // Refresh must not replace a live call owner.
    }

    @Test func accountNamespaceIsStableAndIsolated() {
        #expect(AppleAccountSession.storageNamespace(base: "Test", userID: "one") == AppleAccountSession.storageNamespace(base: "Test", userID: "one"))
        #expect(AppleAccountSession.storageNamespace(base: "Test", userID: "one") != AppleAccountSession.storageNamespace(base: "Test", userID: "two"))
        #expect(!AppleAccountSession.storageNamespace(base: "Test", userID: "private-apple-id").contains("private-apple-id"))
    }
}

@MainActor
final class AccountFixture {
    let keychain = AccountTestKeychain()
    let name = "RideIntercom.AccountTests." + UUID().uuidString
    let defaults: UserDefaults
    lazy var session = restart { _ in .authorized }
    init() { defaults = UserDefaults(suiteName: name)! }
    func remove() { defaults.removePersistentDomain(forName: name) }
    func restart(_ check: @escaping @MainActor (String) async throws -> AppleCredentialState) -> AppleAccountSession {
        AppleAccountSession(keychain: keychain, defaults: defaults, namespace: name, credentialState: check)
    }
    func signIn(_ userID: String = "apple-user") {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        session.prepare(request)
        _ = session.completeSignIn(userID: userID, state: request.state)
    }
}

final class AccountTestKeychain: KeychainSecretStoring {
    var value: String?
    var fails = false
    func accounts(service: String) throws -> [String] { [] }
    func secret(service: String, account: String) throws -> String? {
        if fails { throw KeychainSecretStoreError.invalidData }; return value
    }
    func createSecretIfAbsent(_ value: String, service: String, account: String) throws -> String {
        if let retained = try secret(service: service, account: account) { return retained }
        try saveSecret(value, service: service, account: account)
        return value
    }
    func saveSecret(_ secret: String, service: String, account: String) throws {
        if fails { throw KeychainSecretStoreError.invalidData }; value = secret
    }
    func deleteSecret(service: String, account: String) throws {
        if fails { throw KeychainSecretStoreError.invalidData }; value = nil
    }
}
