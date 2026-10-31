import AppIntents
import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct SiriMuteIntentTests {
    @Test func explicitValuesAreIdempotentAndKeepTheCurrentConnection() async throws {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel; defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        vm.selectGroup(vm.groups[0])
        let reference = vm.currentCallReference, starts = h.inputBackend.startCount
        let mute = SetCallMutedIntent(muted: true); mute.owner = owner
        _ = try await mute.perform(); _ = try await mute.perform()
        #expect(vm.isMuted)
        let unmute = SetCallMutedIntent(muted: false); unmute.owner = owner
        _ = try await unmute.perform(); _ = try await unmute.perform()
        #expect(!vm.isMuted)
        #expect(vm.currentCallReference == reference)
        #expect(h.inputBackend.startCount == starts)
    }

    @Test(arguments: [true, false])
    func idleMuteUsesTheCommonContractWithoutStartingAudio(muted: Bool) async throws {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel; defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let intent = SetCallMutedIntent(muted: muted); intent.owner = owner
        _ = try await intent.perform()
        #expect(vm.isMuted == muted)
        #expect(vm.activeGroupID == nil)
        #expect(h.inputBackend.startCount == 0 && h.outputBackend.startCount == 0)
    }

    @Test func resolvesTheCurrentReferenceAtExecutionAndOldReferenceCannotControlIt() async throws {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel; defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        vm.selectGroup(vm.groups[0]); let stale = vm.currentCallReference
        let intent = SetCallMutedIntent(muted: true); intent.owner = owner
        #expect(vm.startCall(to: .group(vm.groups[1].id), accountAccessID: vm.accountAccessID))
        let current = vm.currentCallReference
        #expect(!vm.setCallMuted(true, for: stale))
        _ = try await intent.perform()
        #expect(vm.isMuted && vm.currentCallReference == current)
    }

    @Test func oldLoginAndDeniedCommonOperationCannotChangeMute() async throws {
        let account = AccountFixture(); defer { account.remove() }; account.signIn()
        let h = AppTestSupport.makeHarness(accountSession: account.session), vm = h.viewModel; defer { vm.disconnect() }
        let owner = AppCallOwner(account: account.session, viewModel: vm)
        let before = vm.isMuted
        let intent = SetCallMutedIntent(muted: !before); intent.owner = owner
        vm.requiresAccountDataReset = true
        await #expect(throws: CallIntentError.self) { _ = try await intent.perform() }
        #expect(vm.isMuted == before)
        vm.requiresAccountDataReset = false
        account.session.signOut()
        await #expect(throws: CallIntentError.self) { _ = try await intent.perform() }
        account.signIn()
        await #expect(throws: CallIntentError.self) { _ = try await intent.perform() }
        #expect(vm.isMuted == before)
    }

    @Test func usesExistingForegroundAndAuthenticationPolicy() {
        #expect(SetCallMutedIntent.supportedModes == .foreground(.immediate))
        #expect(SetCallMutedIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
    }

    @Test func titlePromptResponseAndSiriPhraseAreLocalized() throws {
        #expect(try localized(SetCallMutedIntent.title, language: "en") == "Set microphone mute")
        #expect(try localized(SetCallMutedIntent.title, language: "ja") == "マイクのミュートを設定")
        let expected = [
            "Should the microphone be muted?": "マイクをミュートしますか？",
            "Microphone muted.": "マイクをミュートしました。",
            "Microphone unmuted.": "マイクのミュートを解除しました。",
            "The microphone could not be changed. Open RideIntercom and try again.": "マイクの状態を変更できませんでした。RideIntercomを開いて、もう一度お試しください。"
        ]
        for (key, value) in expected {
            #expect(try localized(.init(stringLiteral: key), language: "ja") == value)
            #expect(try localized(.init(stringLiteral: key), language: "en") == key)
        }
        let japanese = try bundle("ja")
        #expect(japanese.localizedString(forKey: "Set microphone mute in ${applicationName}", value: nil, table: "AppShortcuts")
            == "${applicationName}でマイクのミュートを設定")
    }

    private func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }
    private func localized(_ resource: LocalizedStringResource, language: String) throws -> String {
        String(localized: resource.defaultValue, table: resource.table,
               bundle: try bundle(language), locale: Locale(identifier: language))
    }
}
