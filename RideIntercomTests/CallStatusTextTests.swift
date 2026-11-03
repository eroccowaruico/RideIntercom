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
        #expect(ja("Voice Isolation") == "声を分離")
        #expect(ja("No Groups Yet") == "まだグループがありません")
        #expect(ja("Invite Someone") == "新しい相手を追加")
        #expect(ja("Create and Connect") == "作成して接続")
    }
}
