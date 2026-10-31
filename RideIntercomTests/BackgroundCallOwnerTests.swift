import AuthenticationServices
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct BackgroundCallOwnerTests {
    @Test func signedOutAccountRecoversFromUnavailableStorageWithoutLosingSignInEntry() async throws {
        let f = AccountFixture(); defer { f.remove() }; f.signIn(); f.session.signOut()
        f.keychain.fails = true
        let account = f.restart { _ in .authorized }
        #expect(account.storageUnavailable && account.userID == nil)
        f.keychain.fails = false
        await account.reload()
        #expect(!account.storageUnavailable && account.userID == nil)
        let request = ASAuthorizationAppleIDProvider().createRequest(); account.prepare(request)
        #expect(account.isSigningIn)
        #expect(account.completeSignIn(userID: "apple-user", state: request.state))
    }

    @Test func endingCallDuringBackgroundPreparationDoesNotAllowDelayedStart() async throws {
        let f = AccountFixture(); defer { f.remove() }; f.signIn()
        var pending: CheckedContinuation<AppleCredentialState, Never>?
        let account = f.restart { _ in await withCheckedContinuation { pending = $0 } }
        let h = AppTestSupport.makeHarness(accountSession: account)
        let vm = h.viewModel
        let owner = AppCallOwner(account: account, viewModel: vm)
        let group = try #require(vm.groups.first)
        #expect(vm.startCall(to: .group(group.id), accountAccessID: account.accessID))
        let reference = vm.currentCallReference
        let preparation = Task { try await owner.prepareForBackgroundCallAction() }
        await AppTestSupport.waitUntil { pending != nil }
        #expect(vm.endCall(reference))
        pending?.resume(returning: .authorized)
        await #expect(throws: CallIntentError.self) { try await preparation.value }
        #expect(vm.activeGroupID == nil)
    }

    @Test func ownerReplacesRetiredModelWithoutAViewAndDoesNotReconnect() async throws {
        let f = AccountFixture(); defer { f.remove() }; f.signIn()
        let first = AppTestSupport.makeHarness(accountSession: f.session)
        var made = 0
        let owner = AppCallOwner(account: f.session, viewModel: first.viewModel, makeViewModel: { account in
            made += 1
            return AppTestSupport.makeHarness(accountSession: account).viewModel
        })
        first.viewModel.selectGroup(try #require(first.viewModel.groups.first))
        f.session.signOut()
        #expect(first.viewModel.activeGroupID == nil)
        f.signIn("replacement")
        await AppTestSupport.waitUntil { owner.viewModel?.accountUserID == "replacement" }
        #expect(made == 1)
        #expect(owner.viewModel !== first.viewModel)
        #expect(owner.viewModel?.activeGroupID == nil)
        #expect(!first.viewModel.canStartCalls)
    }

    @Test func unavailableSavedLoginDoesNotCreateModelOrOverwriteAndRecoversOnRetry() async throws {
        let f = AccountFixture(); defer { f.remove() }; f.signIn()
        f.keychain.fails = true
        let account = f.restart { _ in .authorized }
        var made = 0
        let owner = AppCallOwner(account: account, viewModel: nil, makeViewModel: { account in
            made += 1; return AppTestSupport.makeHarness(accountSession: account).viewModel
        })
        await #expect(throws: CallIntentError.self) { try await owner.prepareForBackgroundCallAction() }
        #expect(made == 0 && f.keychain.value == "apple-user")
        f.keychain.fails = false
        try await owner.prepareForBackgroundCallAction()
        #expect(made == 1 && owner.viewModel?.canStartCalls == true)
        let model = owner.viewModel
        try await owner.prepareForBackgroundCallAction()
        #expect(owner.viewModel === model && made == 1)
    }

    @Test(arguments: ["apple-user", "another-user"])
    func refreshCannotPassOldActionToANewLogin(nextUser: String) async throws {
        let f = AccountFixture(); defer { f.remove() }; f.signIn()
        var pending: CheckedContinuation<AppleCredentialState, Never>?
        let account = f.restart { _ in await withCheckedContinuation { pending = $0 } }
        let h = AppTestSupport.makeHarness(accountSession: account)
        let owner = AppCallOwner(account: account, viewModel: h.viewModel, makeViewModel: { account in
            AppTestSupport.makeHarness(accountSession: account).viewModel
        })
        let preparation = Task { try await owner.prepareForBackgroundCallAction() }
        await AppTestSupport.waitUntil { pending != nil }
        account.signOut()
        let request = ASAuthorizationAppleIDProvider().createRequest(); account.prepare(request)
        #expect(account.completeSignIn(userID: nextUser, state: request.state))
        pending?.resume(returning: .authorized)
        await #expect(throws: CallIntentError.self) { try await preparation.value }
        #expect(h.viewModel.activeGroupID == nil)
    }

    @Test func concurrentPreparationWaitsForTheSameCredentialCheck() async throws {
        let f = AccountFixture(); defer { f.remove() }; f.signIn()
        var pending: CheckedContinuation<AppleCredentialState, Never>?
        var checks = 0
        let account = f.restart { _ in checks += 1; return await withCheckedContinuation { pending = $0 } }
        let h = AppTestSupport.makeHarness(accountSession: account)
        let owner = AppCallOwner(account: account, viewModel: h.viewModel)
        let first = Task { try await owner.prepareForBackgroundCallAction() }
        await AppTestSupport.waitUntil { pending != nil }
        var secondFinished = false
        let second = Task { defer { secondFinished = true }; try await owner.prepareForBackgroundCallAction() }
        for _ in 0..<10 { await Task.yield() }
        #expect(!secondFinished && checks == 1)
        pending?.resume(returning: .revoked)
        await #expect(throws: CallIntentError.self) { try await first.value }
        await #expect(throws: CallIntentError.self) { try await second.value }
        #expect(account.userID == nil && h.viewModel.activeGroupID == nil)
    }

    @Test func anotherSessionSignOutInvalidatesCachedAccessBeforeBackgroundPreparation() async throws {
        let f = AccountFixture(); defer { f.remove() }; f.signIn()
        let account = f.restart { _ in .authorized }
        let h = AppTestSupport.makeHarness(accountSession: account)
        let owner = AppCallOwner(account: account, viewModel: h.viewModel)
        h.viewModel.selectGroup(try #require(h.viewModel.groups.first))
        let oldAccess = account.accessID
        f.session.signOut()
        await #expect(throws: CallIntentError.self) { try await owner.prepareForBackgroundCallAction() }
        #expect(account.userID == nil && account.accessID != oldAccess)
        #expect(h.viewModel.activeGroupID == nil && !h.viewModel.canStartCalls)
        await account.reload()
        #expect(account.userID == nil)
    }

    @Test func anotherSessionPendingDeletionBlocksBackgroundPreparation() async throws {
        let f = AccountFixture(); defer { f.remove() }; f.signIn()
        let account = f.restart { _ in .authorized }
        let h = AppTestSupport.makeHarness(accountSession: account)
        let owner = AppCallOwner(account: account, viewModel: h.viewModel)
        try f.session.deletion.begin(userID: "apple-user", access: nil, proof: nil)
        await #expect(throws: CallIntentError.self) { try await owner.prepareForBackgroundCallAction() }
        #expect(account.userID == nil && account.deletion.blocksSignIn)
        #expect(!h.viewModel.canStartCalls)
    }

    @Test(arguments: [false, true])
    func persistedDenialDuringNativeCheckCannotBeUndone(deleting: Bool) async throws {
        let f = AccountFixture(); defer { f.remove() }; f.signIn()
        var pending: CheckedContinuation<AppleCredentialState, Never>?
        let account = f.restart { _ in await withCheckedContinuation { pending = $0 } }
        let h = AppTestSupport.makeHarness(accountSession: account)
        let owner = AppCallOwner(account: account, viewModel: h.viewModel)
        let preparation = Task { try await owner.prepareForBackgroundCallAction() }
        await AppTestSupport.waitUntil { pending != nil }
        if deleting { try f.session.deletion.begin(userID: "apple-user", access: nil, proof: nil) }
        else { f.session.signOut() }
        pending?.resume(returning: .authorized)
        await #expect(throws: CallIntentError.self) { try await preparation.value }
        #expect(account.userID == nil && !h.viewModel.canStartCalls)
    }

    @Test func transientGroupReadFailureRetriesWithoutResettingTheSnapshot() async throws {
        let h = AppTestSupport.makeHarness()
        let vm = h.viewModel
        let saved = h.groupStore.snapshot
        vm.groupStorageIssue = .unavailable
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        try await owner.prepareForBackgroundCallAction()
        #expect(vm.groupStorageIssue == nil && h.groupStore.snapshot == saved)
        #expect(!owner.callTargets.isEmpty)
    }
}
