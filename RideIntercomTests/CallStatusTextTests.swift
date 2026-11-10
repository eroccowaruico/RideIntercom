import Foundation
import Testing
@testable import RideIntercom

/// The state reads on one short line; any reason goes on the next line, never after a dash.
struct CallStatusTextTests {
    @Test(arguments: [StandardCallStatus.ready, .connecting, .inCall, .audioPaused, .audioUnavailable])
    func titleIsTheStateAloneAndDetailIsTheReason(status: StandardCallStatus) {
        #expect(!status.title.contains("—"))
        #expect(status.detail.map { !$0.contains("—") } ?? true)
        #expect((status.detail == nil) == [.ready, .inCall].contains(status))
    }

    @Test func japaneseUsesTheDesignTerms() throws {
        let bundle = try #require(Bundle.main.path(forResource: "ja", ofType: "lproj").flatMap(Bundle.init(path:)))
        let ja = { (key: String) in bundle.localizedString(forKey: key, value: nil, table: nil) }
        #expect(ja(StandardCallStatus.inCall.title) == "会話中")
        #expect(ja(StandardCallStatus.ready.title) == "未接続")
        #expect(ja(StandardCallStatus.connecting.detail ?? "") == "相手の参加を待っています")
        #expect(ja("End Call") == "切断")
        #expect(ja("Recent Call") == "前回の接続先")
        // The glossary: say which voice isolation works on, invite (never add), and the words below.
        #expect(ja("Voice Isolation") == "受信する声を分離")
        #expect(ja("Transmit Voice Isolation Effect") == "送信する声を分離")
        #expect(ja("Unmuted") == "オフ")
        #expect(ja("Allow Call Requests") == "この相手からの呼び出しを受け取る")
        #expect(ja("Cancel Call Request") == "呼び出しを取り消す")
        #expect(ja("Share Call Invite") == "招待を共有")
        #expect(ja("Name shared by this person") == "本人の名前")
        #expect(ja("Switch to This Call") == "接続を切り替える")
        #expect(ja("Contact Invitation") == "招待")
        #expect(ja("No Groups Yet") == "まだグループがありません")
        #expect(ja("Invite Someone") == "新しい相手を招待")
        #expect(ja("Create and Connect") == "作成して接続")
    }
}
