# Apple Watch実機への導入とXcode起動

## 対象と目的

2026-11-01、利用者の「実機Apple Watchで動くように」「Xcodeからも実行できるように」という依頼に対し、Apple Watch Ultra 2（watchOS 27.2）と接続済みiPhoneを使って導入・起動を確認した。Xcodeは27.2（27B52）、Watch OS buildは24S118。通話処理をiPhoneに置く[既存のWatch契約](../../spec/App/Watch操作.md)を変更していない。

基準は`31713383`と着手時の未コミット差分。StoreKit検証構成の整理、Watch翻訳などの既存差分を保持したまま、通常作業フォルダとXcode標準DerivedDataでビルドした。既存差分は今回のコミットへ含めない。バージョンは1.0.0、Buildは315のまま。

## 結果と限界

| 対象 | 観測 |
|---|---|
| 実機検出 | Watch Ultra 2とiPhoneをCoreDeviceがphysical / connectedとして検出。Watch開発者モードは有効、OSは最低27.0を満たす |
| Watch署名 | 共有`RideIntercomWatch` scheme・Debug・実機destination・既存teamの自動署名でbuild成功。Watch用開発profileが取得され、署名とbundle検証が成功 |
| Watch導入・起動 | `devicectl device install app`と`device process launch`が成功。実機スクリーンショットでRideCom画面を確認。初回の画面はiPhone未接続表示であり、通話成立ではない |
| iPhone更新 | 共有`RideIntercom` scheme・Debug・接続済み実機の署名付きbuildと更新installが成功。Watch埋込productの署名検証も成功 |
| iPhone起動の境界 | 更新後の起動要求は`Locked`で拒否された。パスコードを必要とする端末ロックを観測し、解除を利用者へ依頼。認証やロックを回避していない |
| Xcodeからの前回Run | 19:56:30開始のWatch Run記録に「Copying OS library symbols … (0%)」「Waiting for device unavailability condition to be resolved」を確認。実機導入前に端末準備を待った記録であり、build/actionの`status=succeeded`だけを起動成功とは扱わない。19:41作成のDeviceSupportには`.copying_lock`と途中データがあった。コピー待ちが起動しなかった原因として有力だが、GUIでの再現・解消は確認できていない |
| 利用者による再Run | 利用者から「もう一回自分でやる」、続いて「動いたかも」と報告。追加の実機操作は停止した。起動成功の確定、実音声・背景継続の受入には置き換えない |
| GUI操作 | Computer UseでXcode操作が許可されず、GUIのRunボタン操作・実行先選択は未検証。CLIの標準Xcodeビルドと実機起動を、GUI操作の実証とは区別する |

既存の共有`RideIntercomWatch` scheme・通常Debug・自動署名を使用した。[開発手順](../../development/開発環境.md#xcodeだけで実行テスト配布する)に、iPhoneを先に通常Runし、Watch schemeと実機Watchを選ぶ操作、端末準備とロック時の切り分けを追記した。デバッガ無効化、別のビルド構成、専用の実行スクリプトは追加していない。

## 証跡と残る経路

証跡は`.validation/watch-device-20261101/`に保持する。`ride-watch-signed-build.log`、`ride-watch-phone-signed-build.log`は署名付きbuild、`ride-watch-install.json`／`ride-watch-launch.json`と`ride-watch-running.png`はWatch導入・起動、`ride-watch-xcode-logRef.json`は前回のXcode端末準備待ち。標準構成での再buildも成功（`watch-final-build.log`）。既知のAppIntents metadata省略warningを保持する。platform設定のPython 12件、文書リンク・到達性、OS設定検査、`git diff --check`は成功した。これらを実機通話の受入には用いない。

今回アプリ・packageの音声実装は変更していない。iPhoneのロック解除・RideCom起動後、Watchで通話先を表示できること、Watchから開始し、Watchのマイク入力とスピーカー出力、押下解除による実送話停止、終了を確認する経路は未完。CallKitなしの実Watch媒体通信、背景・画面消灯・経路変更・電池・遅延も[未確認事項](../未確認事項.md#iphone依存watchの実機操作と音声)へ残す。実Cloudflare通話や他人への呼出し通知は実行していない。

20:06の最終build後、20:07に別作業の`RideIntercomWatchApp.swift`変更と`WatchRecordingCheck.swift`追加を観測した。これらは編集・再build・実機導入・コミットの対象へ含めない。本記録の起動結果は変更前の生成物に対応し、後から追加された録音確認画面や現在の全ソースの動作確認ではない。
