# 配布ビルド採番とOrganizer認証調査

確認日は2026-10-29。利用者の指示は、公開バージョンを勝手に変更せず、App Store Connect／TestFlight用のビルドだけを採番し、内部のRun・Buildでは増やさないこと。手順は[開発環境](../../development/開発環境.md#app-storetestflight用の採番とarchive)、版の判断基準は[開発方針](../../policies/開発方針.md#公開バージョンとビルド番号)を正本とする。

## Organizerの認証エラー

Xcode 27.1（27A9275）の配布ログとmacOSのクラッシュ記録を照合した。

| 観測 | 判断・境界 |
|---|---|
| 19:08:54 JSTの配布失敗 | `IDEDistribution.critical.log`に`NSCocoaErrorDomain Code=4097`、`connection to service named com.apple.dt.Xcode.ITunesSoftwareService`と`account (null)`。同時刻のApple製XPCサービスが`EXC_BAD_ACCESS / SIGBUS`で終了 |
| クラッシュスタック | `CDTransporterDefaults`、`CDAuthContext`、`ContentDelivery`の環境設定参照が再帰。アプリ実行コードのスタックではない |
| 19:13の再試行 | 認証後にアップロード検証へ進み、使用済みビルド4以下として拒否。認証表示だけからログイン期限切れとは判断できない |
| 修正範囲 | 確認した認証失敗はXcode側サービスの異常終了に伴う接続切断。アプリ設定でこのクラッシュが直る根拠はなく、資格情報やXcode設定を削除していない。別問題のビルド番号管理を修正 |

証跡は`~/Library/Logs/DiagnosticReports/com.apple.dt.Xcode.ITunesSoftwareService-2026-10-29-190855.ips`と、一時領域の`RideIntercom_2026-10-29_19-08-52.533.xcdistributionlogs`。認証障害の再発防止は未確認。

## 採番・Archive・書き出し

`b5591e43`の隔離コピーに今回の採番設定とスクリプトを反映し、同時進行中の音声変更を含めずに検証した。元の作業ツリーの配布基準は4に維持。検証コピーはXcodeで開いていないため、実行時だけ`pgrep`を置き換えて「Xcode起動中」のガードを通過させた。採番・ビルド・署名・書き出しには実際のAppleツールを使用した。

| 確認 | 結果 |
|---|---|
| スクリプト回帰 | `python3 -m unittest discover -s scripts/tests -p test_distribution_archive.py -v`の5件成功。採番がArchiveより先に実行されること、採番失敗時の停止、Archive失敗時のlock解除、重複実行・既存Archive・Xcode起動時の拒否、呼出元からの相対パスを検証 |
| 配布Archive 1回目 | `scripts/archive_app_store.sh ios /tmp/RideIntercom-FinalNumber5.xcarchive`で`ARCHIVE SUCCEEDED`。署名済みAppの`CFBundleVersion=5`、`CFBundleShortVersionString=1.0`。Archive側のApplicationPropertiesも一致 |
| 間に挟んだ内部Build | 同じコピーでDebug・generic iOS・`CODE_SIGNING_ALLOWED=NO`の`xcodebuild build`が成功。Appは`1.0 (5)`を維持。projectファイルのSHA-256はBuild前後で一致 |
| 配布Archive 2回目 | 同じ入口で`/tmp/RideIntercom-FinalNumber6.xcarchive`を作成し成功。署名済みAppとArchive情報がともに`1.0 (6)` |
| IPA書き出し | build 5のArchiveに`scripts/ExportOptions.plist`を指定して`xcodebuild -exportArchive`が成功。`/tmp/RideIntercom-FinalNumber5-Export/RideIntercom.ipa`内のAppも`1.0 (5)`を維持 |
| 構造確認 | 開発設定、plist、shell構文、差分検査成功。文書検査は対象変更だけの隔離コピーで成功。元の作業ツリーでは別作業の未追跡バックログ文書「リアルタイム会話の遅延と連続性改善」への入口リンク不足で失敗し、対象外として維持 |
| 残る境界 | AppIntents未使用によるmetadata抽出省略warningあり。macOSの実Archive、OrganizerのGUI設定保持、アップロード、Apple側の受理・TestFlight配信は未検証 |

ログは`/tmp/rideintercom-final-number5.log`、`/tmp/rideintercom-number5-normal.log`、`/tmp/rideintercom-final-number6.log`、`/tmp/rideintercom-final-number5-export.log`。一時領域のため永続保存ではない。検証前の対象project設定のSHA-256は`2ccf2562e192b3a5dd6f704094bcb3ffcaccb35b1a905167573ed446e066fdf8`、採番スクリプトは`fbc0f648ee1fb2d93e11cad187e5ac1c0fd3b5b7ac65daf6742207b6e9323186`。

## 採用しなかった方式

schemeのArchive Pre-actionで`agvtool`を実行すると、project上は新番号でも、そのArchiveには読み込み済みの旧番号が入った。Archiveを開始する前に採番する専用入口を採用した。また、ターゲットごとに番号が異なる状態では`agvtool`が低い番号を基準にしたため、project共通設定を全ターゲットに継承させた。通常Buildでの採番や生成Info.plistの独自前処理は最終変更に含めていない。
