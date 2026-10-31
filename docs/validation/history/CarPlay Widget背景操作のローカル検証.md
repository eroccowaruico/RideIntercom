# CarPlay Widget背景操作のローカル検証

2026-10-31。`2d90250d`とApp統合の保全baselineに対する追加分を、独立worktree `/private/tmp/RideIntercom-carplay-widgets`で検証した。CallKit試作は取り込まず、App/package/serverの工程を混在させていない。機能の現行契約は[システム表示と通話操作](../../spec/App/システム表示と通話操作.md)を参照する。

| 確認 | 範囲と証跡 |
|---|---|
| TDD | 未実装の背景Intent・Widget snapshot読込でREDを確認。日本語タイトル未登録でもRED。さらにApple資格準備が失敗すると終了まで拒否されるREDを確認し、開始・unmuteだけ準備を待つ構成へ修正 |
| Mac局所回帰 | macOS 27.2で32件、失敗・skip・runtime warningなし。背景Intentの8件、宛先投影・既存Surface・App Intent・英日表示を実行。`/private/tmp/carplay-mac-stop-delivery`に結果bundle・summary・入力manifestを保持 |
| build警告の範囲 | Mac最終logにswift-logのLogging targetに対するXcode metadata processorの「AppIntents依存なしの抽出省略」1件を保持。Swift compile・runtime warningは0、generic iOS最終buildのwarningは0。packageの変更やmetadata抽出の無効化で抑止していない |
| OS専用試験 | `BackgroundWidgetTests`はmacOSだけにコンパイルする。OS27を要求し、未対応Macで誤実行した場合は失敗を記録する。通常iOS26.4 unitへnoop、skip、意図的失敗や専用Runner条件を追加しない |
| generic iOS build | 27.2 SDKでdeployment 26.4を維持し、App・Widget・iPhone依存Watchを署名なしでコンパイル。`/private/tmp/carplay-ios-stop-delivery`にbuild logと入力manifestを保持。Simulatorは使用していない |
| Intent metadata | App・Widget両製品のextract.actionsdataに27.0 availability、背景mode、openAppWhenRun=false、同じallowedTargetsが出力されたことを確認。OSによる実配送とは区別する。`/private/tmp/ride-carplay-intent-metadata.json` |
| 認可と停止 | 実App所有者へIntent.perform経由で開始し、別通話への自動切替・古い終了/mute・ログアウト後の開始を拒否。明示muteの重複が反転しない。終了・muteはApple資格準備を呼ばず、開始・unmuteは準備失敗時に実行しない |
| 共有ファイル | 現在の参照・状態・muteと現在も保存されている直近先だけを追加。サインアウト時の消去、削除済み宛先、旧format読込、破損後の再公開を確認。資格やengineは共有しない。iOSファイル保護のロック中成立は実機未受入 |
| 表示幅 | 実Shared定義とWidgetボタンViewをSwiftUI ImageRendererで英日描画。158pt幅・16pt余白で高さ121pt、各操作44pt以上。ボタン文字はiconOnlyとしLabelの読み上げ名を保持。`/private/tmp/ride-carplay-en-large.png`と`/private/tmp/ride-carplay-ja-large.png`。accessibility1環境を指定したMac描画であり、iOSのDynamic Type・CarPlay描画の代替ではない |
| 入力の一致 | Mac unitとgeneric buildの前後で、生成ビルド番号以外の入力fingerprint一致を確認。追加英日キーは`Call controls`の1件だけを別JSONで引き渡す |

iOS 27のOS経由Intent実行、ロック中・初回解除後の実機、CarPlayの実タッチ操作・VoiceOver・Dynamic Type、新規マイク開始、音声停止後のunmute、長時間の背景生存は未受入。Appプロセスへの実行先指定を、録音許可・接続成功・実音声の成立と同一視しない。非タッチ車ではWidgetの操作自体が提供されない。専用CarPlay Appを持たない車載のChoose a callは背景操作ではなく、先にiPhone側でWidgetの通話先を選ぶ。

## 背景ログインと保存の統合

`550825b05d366f59066eb35b5f2ca1bdc46eb7d5`を基準に、WidgetとApp所有者の変更を`/private/tmp/RideIntercom-account-verification`へ統合した。App工程としてpackage・server・検証scriptを変更せず、生成ビルド番号以外の入力を固定して確認する。

| 確認 | 範囲と証跡 |
|---|---|
| App所有者の局所検証 | `/private/tmp/RideIntercom-background-owner/.validation/background-owner/summary.json`。同じ保存領域の別sessionによるサインアウト・削除、Apple確認の重複抑止、既存秘密を交換しないKeychain保護属性の移行、group保存の保護を確認。専用namespaceでMac全462件成功、344入力不変 |
| 独立レビューでの追加修正 | `/private/tmp/RideIntercom-background-owner-review/.validation/background-owner-review/summary.json`。Apple確認待ち中に通話を終了・切替した後で古い開始が実行されることと、未ログインの保存読込失敗から復旧してもログイン操作が戻らないことをREDで再現。2テスト・4issueの失敗を保存し、修正後に関連31件成功、393入力不変 |
| 統合Mac全体 | `.validation/carplay-final-macos`。474件成功、失敗・skip・runtime warningなし。OS27専用背景Intent 8件を含む。396入力の前後一致、所有host回収、生成Infoの専用namespaceとbuild 253を確認 |
| 統合iPhone全体 | `.validation/carplay-final-ios`。App単体460件と通常UI20件の計480件成功。prepared corruptRecovery 1件と復旧fixtureの事後検査も成功。失敗・skip・runtime warningなし。396入力の前後一致、build 254の専用namespace、所有Simulatorのshutdownとlease解放を確認 |
| iPad画面 | `.validation/carplay-final-ipad`。英日2件で縦横・主要tab・sheet・通話を確認。失敗・skip・build/runtime warningなし。396入力の前後一致、build 255の専用namespace、所有Simulatorのshutdownとlease解放を確認。XCTestが無視したAX階層取得の非失敗診断98行はlogに保持 |
| Release製品 | `.validation/carplay-release-macos`と`carplay-release-ios`。署名なしのMac App／Widgetはbuild 256、iOS Simulator向けApp／Widget／Watchは257で一致。APNs production、開発資格の除外、英日権限文言、iPhone／iPad／Watchの端末familyを確認。Mac WebRTCの標準Resources manifestとbinaryのSHA-256も先行修正から不変 |
| ReleaseのIntent metadata | AppとWidget双方で背景実行、Appプロセス指定、前面起動なし、OS27 availabilityが一致。`background-intents.json`へ保持。metadata一致はOSの実配送・背景マイク開始の受入ではない |

App所有者の初期unit実行ではhostのStorageNamespace指定が漏れた。fixtureは代替実装を使うが、host起動まで隔離できた証跡にはならないため、その実行を受入から除外し、所有hostを停止して同じソースを`RideIntercom.Validation.BackgroundOwner`で再実行した。実ユーザーデータへの無影響は未確認であり、結果の成功から推定しない。統合工程は`RideIntercom.Validation.carplay-final-macos.macos-tests`を生成Infoでも照合した。

統合Macのbuild logには、RideIntercomUITests targetに対する既知のmetadata抽出省略warningが1件ある。Swift compile・runtime warningは0。Mac unitは署名entitlementとApp Sandboxを外した隔離fixtureであり、配布署名・実Keychain entitlement・ロック中アクセスの受入ではない。

iPhone通常UIは約22分で終了した。復旧をまとめた`testRecoveryWorkflowInOneLaunch`は設定の探索を含め333.345秒を要したが、介入・再試行なしで成功した。待ち時間を試験失敗や修正成功へ読み替えず、元logを保持する。iPhoneはiOS 26.4.1の専用Simulatorであり、OS27専用背景IntentのOS配送を実行した結果ではない。

最終の読取inventory確認は初回に`DEVELOPER_DIR`を指定し忘れ、`simctl`を取得できなかった。Xcodeの環境を明示して一覧だけを再取得し、両専用SimulatorのShutdown・common leaseの再取得と解放・専用DerivedDataに属するprocess残存0を確認した。テスト自体は再試行していない。集約は`.validation/carplay-final-ios/ios-ipad-handoff.json`に保持する。

mainの`.validation/carplay-delivery`に統合Mac／iPhone／iPadの結果bundle・log・入力manifestとRelease確認を保持する。署名済みArchive、実機、CarPlay、Watch自身の音声、Apple側の処理、実サービスへの配送はこの工程の完了範囲に含めない。
