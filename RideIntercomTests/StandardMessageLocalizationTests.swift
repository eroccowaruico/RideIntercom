import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct StandardMessageLocalizationTests {
    @Test(arguments: [1, 60, 3600])
    func retryDelayUsesTheLanguageWithoutChangingItsValue(seconds: Int) throws {
        let path = try #require(Bundle.main.path(forResource: "ja", ofType: "lproj"))
        let japanese = try #require(Bundle(path: path))
        let authorization = InternetAccountAuthorization(expectedUserID: "owner", deviceID: "device", memberID: "member", deviceKey: "unused",
            currentUser: { "owner" }, save: { _, _, _ in })
        let displaySeconds = seconds == 3600 ? "3,600" : String(seconds)
        let japaneseMessage = authorization.retryMessage(seconds: seconds, bundle: japanese, locale: Locale(identifier: "ja_JP"))
        #expect(japaneseMessage == "ログインの試行が多すぎます。\(displaySeconds)秒待ってから「インターネット通話を設定」を選び直してください。")
        let englishPath = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let englishBundle = try #require(Bundle(path: englishPath))
        let english = authorization.retryMessage(seconds: seconds, bundle: englishBundle, locale: Locale(identifier: "en_US"))
        #expect(english == "Too many sign-in attempts. Wait \(displaySeconds) \(seconds == 1 ? "second" : "seconds"), then choose Set Up Internet Calling again.")
    }

    @Test func appGeneratedRecoveryMessagesHaveJapaneseTranslations() throws {
        let path = try #require(Bundle.main.path(forResource: "ja", ofType: "lproj"))
        let japanese = try #require(Bundle(path: path))
        #expect(japanese.localizedString(forKey: "Enter a valid display name.", value: nil, table: nil) == "有効な表示名を入力してください。")
        #expect(japanese.localizedString(forKey: "Internet is unavailable. Retrying automatically; reachable riders stay connected.", value: nil, table: nil)
            == "インターネットに接続できません。自動で再試行します。接続できる相手との通話は続きます。")
    }

    @Test func interpolatedNamesAndCountsRemainLiteralInJapanese() throws {
        let path = try #require(Bundle.main.path(forResource: "ja", ofType: "lproj"))
        let japanese = try #require(Bundle(path: path))
        let name = "Alice 100% %@ あおい"
        #expect(String(localized: "Edit \(name)", bundle: japanese) == "\(name)の名前を編集")
        #expect(String(localized: "Volume for \(name)", bundle: japanese) == "\(name)の音量")
        let count = 8
        #expect(String(localized: "\(count) of 8 members including you", bundle: japanese) == "自分を含めて8人（上限8人）")
    }
}
