import AppIntents
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct CallIntentLocalizationTests {
    @Test func actionTitlesAndDescriptionUseJapaneseResources() throws {
        #expect(try render(StartSavedCallIntent.title, language: "ja") == "通話を開始")
        #expect(try render(StartRecentCallIntent.title, language: "ja") == "最近の通話を再開")
        #expect(try render(EndCurrentCallIntent.title, language: "ja") == "現在の通話を終了")
        #expect(try render(StartSavedCallIntent.description.descriptionText, language: "ja")
            == "RideIntercomに保存したユーザーやグループへ接続します。")
        #expect(try render(StartSavedCallIntent.title, language: "en") == "Start a call")
    }

    @Test(arguments: ["Call", "User", "Group", "100% %@ あおい"])
    func entityKindIsTranslatedAndPersonalNamesAreNot(name: String) throws {
        let user = CallTargetEntity(id: "fixture-user", name: name, kind: "User")
        let group = CallTargetEntity(id: "fixture-group", name: name, kind: "Group")
        for language in ["en", "ja"] {
            #expect(try render(user.displayRepresentation.title, language: language) == name)
            #expect(try render(group.displayRepresentation.title, language: language) == name)
        }
        let userKind = try #require(user.displayRepresentation.subtitle)
        let groupKind = try #require(group.displayRepresentation.subtitle)
        #expect(try render(userKind, language: "ja") == "ユーザー")
        #expect(try render(groupKind, language: "ja") == "グループ")
    }

    @Test func intentErrorsExposeLocalizableResourcesIncludingSharedFailures() throws {
        let errors: [(any Error, String)] = [
            (CallIntentError.unavailable("No recent call is available. Choose a saved user or group in RideIntercom."),
             "最近の通話はありません。RideIntercomで保存済みのユーザーかグループを選んでください。"),
            (CallIntentError.unavailable("End the current call before starting a different call."),
             "別の通話を始める前に、現在の通話を終了してください。"),
            (CallIntentError.unavailable("Remove the previous account data on this device to set up your account again."),
             "この端末の以前のアカウントデータを削除して、アカウントを設定し直してください。")
        ]
        for (error, expected) in errors {
            let localizable = try #require(error as? any CustomLocalizedStringResourceConvertible)
            #expect(try render(localizable.localizedStringResource, language: "ja") == expected)
        }
        let unknown = CallIntentError.unavailable("External message: 100% %@ あおい")
        for language in ["en", "ja"] {
            #expect(try render(unknown.localizedStringResource, language: language) == "External message: 100% %@ あおい")
        }
        let english = CallIntentError.unavailable("The call could not be started.")
        #expect(try render(english.localizedStringResource, language: "en") == "The call could not be started.")
    }

    @Test func shortcutPhrasesHaveJapaneseWithoutReplacingTheApplicationPlaceholder() throws {
        let japanese = try languageBundle("ja")
        #expect(japanese.localizedString(forKey: "Start a call with ${applicationName}", value: nil, table: "AppShortcuts")
            == "${applicationName}で通話を開始")
        #expect(japanese.localizedString(forKey: "Resume my call in ${applicationName}", value: nil, table: "AppShortcuts")
            == "${applicationName}で最近の通話を再開")
        #expect(japanese.localizedString(forKey: "End my call in ${applicationName}", value: nil, table: "AppShortcuts")
            == "${applicationName}で通話を終了")
    }

    private func render(_ resource: LocalizedStringResource, language: String) throws -> String {
        String(localized: resource.defaultValue, table: resource.table,
               bundle: try languageBundle(language), locale: Locale(identifier: language))
    }
    private func languageBundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }
}
