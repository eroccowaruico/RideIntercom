# 通知とMacメニューの統合

2026-10-31、`62b93965339588d6749079ef6d1c71c518e7fce1`のAppへ、通常通知と任意のMacメニューバーを統合した。通知の到着では通話を開始せず、利用者の操作後に現在のログイン・直接相手・同意・有効な呼出しを確認し、既存の共通通話操作へ渡す。MenuBarExtraも同じAppCallOwnerの現在通話を使用する。実装契約は[通知](../../spec/App/通知仕様.md)と[システム表示](../../spec/App/システム表示と通話操作.md)を参照する。

## 統合時に確認した境界

| 対象 | 変更と確認内容 |
|---|---|
| 端末の通知OFF | サービス資格が消失しても端末側でOFFにできる。解除待ちを保存し、OS登録取消を呼び、旧通知のtapを拒否する。資格なしでHTTPを送らない |
| 許可の保存容量 | 削除した相手の取消完了行を回収する。発行revisionは既存アカウントDefaultsの単一counterで維持し、未完了取消と保存失敗時の旧行は残す。server台帳や再送queueは増やさない |
| 通知のプライバシー | 個人用の許可は直接相手との内部1対1接続だけで交換する。通常グループの参加者へ配布せず、保存ユーザー外への通知操作を許さない |
| 共通の通話状態 | 通知・Macメニュー・Widget・Watch・App画面が同じ所有者と操作を使う。古い通話・ログインへの終了やmuteを次の通話へ適用しない |
| Macの起動 | メニューバーの追加を理由に通常起動でactivation policyや強制前面化を変更しない。既存のwindow管理を維持する |

## 検証範囲と証跡

最終集約は`.validation/notification-menu-delivery`。各工程の元のxcresultは同ディレクトリの`evidence-locations.json`が指す。外部通信と実音声を使わない既存fixture、専用storage namespace、所有するtest hostとSimulatorを使用する。

| 工程 | 確認する対象 |
|---|---|
| macOS App全体 | 通知36件、Macメニュー6件を含む431件成功。`macos` |
| iOS App全体 | 通知を含む425件成功。`ios-unit` |
| iPhone UI | 英日での回転・sheet・ミュート、保存ユーザー再利用、Standard画面の7件成功。`ios-ui` |
| iPad UI | 英日での縦横・sheet・主要操作2件成功。`ipad` |
| Release生成物 | unsignedのgeneric macOSとiOS Simulatorでbuild成功。AppとWidget、iOS側Watchのbuild番号一致、iPad device family、日英権限説明、APNs production、開発資格の非同梱を確認。`release-macos`・`release-ios` |

最終試験はすべて失敗・skip・runtime warningなし。各工程の386入力は前後一致し、未変更serverも含めた集約409入力を照合した。所有Mac hostを回収し、専用iPhone・iPad SimulatorはShutdownした。iPhone/iPadの日本語横画面のミュートONと状態表示を保存画像でも確認し、native controlの階層も添付した。署名なしRelease buildを実機向け署名・Archive・配布の受入として扱わない。通知serverとpackageはこの工程で変更していない。

## 初回失敗と修正の区別

Macの最初の実行は、先行のcodec評価から証跡へコピーした`Package.swift`をXcodeが二つのtop-level packageとして発見し、依存解決で終了した。製品の依存定義は変更せず、証跡側だけ`Package.swift.evidence`へ改名し、原文hashと再現用の対応表を保持した。失敗ログは`notification-menu-final-macos`に残す。

iPhone UIの初回は日本語横画面でミュート表示が変わらなかった。識別されたSwiftUI行の右端から座標を推測して押していたため、テストを行内のnative Switchに向け、値がONになったことと表示の両方を検査するよう修正した。アプリ本体は変更していない。失敗を含む`notification-menu-final-ios`を保持し、最終UIは`notification-menu-final-ui`へ分ける。Mac単体・iOS単体・Mac Releaseの検証後に変更した入力はこのUIテスト1ファイルだけであり、集約時に本体・設定・artifactの同一性を別途照合する。

## 未確認の境界

実OSの通知許可とAPNs登録、実配送・cold launch、MacメニューとVoiceOverの実操作、Watchの背景連携、署名済みApp Group、Apple portalのprofile更新は[未確認事項](../未確認事項.md)に残す。Mac WebRTCのprivacy manifest配置は独立したpackage/artifact工程で修正する。ローカルfixtureの成功を、これらの受入結果へ置き換えない。
