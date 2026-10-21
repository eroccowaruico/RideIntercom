# 検証状況と証跡

## 結果を読む基準

| 区分 | 意味 |
|---|---|
| 実装済み | sourceと現行仕様に存在する。成功・実機確認を意味しない |
| 自動検証済み | 指定された版・条件・コマンドで成功。現行HEADでの再実行と過去記録を区別 |
| 実サービス未確認 | 実Cloudflare SFU / TURN / 請求をローカルfixtureで保証しない |
| 実機未確認 | Mac/iPhoneの音響、無線、10分、ロック、Bluetooth/有線は別途 |
| 未対応 | 必要なAPI・UI・運用がまだない。マニュアルに操作可能と書かない |

## 現在の確認と記録

[未確認事項](未確認事項.md)に確認待ちと条件、[自動検証範囲](自動検証範囲.md)にテストの担当範囲をまとめる。未実装作業は[課題](../backlog/README.md)へ分ける。

| 領域 | 記録 |
|---|---|
| 全体監査・ローカル基盤 | [全体敵対的レビュー・修正・残存リスク](history/全体敵対的レビュー.md)、[全ファイルの調査台帳](history/全体監査ファイル台帳.json) |
| 責務分解・保存復旧・待機制御 | [変更・検証・残存リスク](history/責務分解と保存復旧.md)、[既存テストの移動対応](history/責務分解テスト対応.json) |
| 不要コードと全回帰 | [整理・不具合修正・要求とのテスト対応](history/不要コード整理と回帰検証.md) |
| RTC / native / App / TURN | [通信診断とTURN](history/通信診断とTURN資格検証.md)、[混在通話](history/混在通話検証.md) |
| Worker / Swiftペア / 費用 | [Cloudflare](history/Cloudflare検証.md)、[品質点検](history/品質点検.md)、[費用試算](../development/Cloudflare費用試算.md) |
| 音声・UI | [音声エフェクト](history/音声エフェクト接続検証.md)、[混在通話](history/混在通話検証.md) |
| 開発環境 | [構造検査の記録](history/文書役割分離記録.md) |
| 文書・ログ整合 | [文書整理](文書整理記録.md)、[要求構造整理](history/要求構造整理記録.md)、[役割分離](history/文書役割分離記録.md) |

## 再実行

[自動検証](../development/自動検証.md)を入口とする。`scripts/validate.sh`は実行ごとのenvironment / logs / results.tsv / xcresultを保持し、一部の失敗を全体成功にしない。`/private/tmp`内の過去証跡は永続保存ではない。

## Xcode参照修復の確認（2026-10-21）

対象は`2b55397`上の未コミット作業ツリー。既存のproject設定・Info.plist変更を保持し、Repositoryのコンテナ判定と自己project参照を修正した。

| 確認 | 結果・境界 |
|---|---|
| 修正前の切り分け | `xcodebuild -list`で9 local packageを解決。CLIのmacOS buildも成功しており、利用者のXcode画面のエラーはCLIでは再現しなかった |
| 自己参照 | Xcode起動中に除去した自己参照が再生成された。利用者がXcodeを終了後、`explicitFileTypes`のfolder指定を保持して残った自己参照を除去 |
| 回帰 | `python3 -m unittest scripts.tests.test_development_setup`の6件成功。開発設定・文書検査も成功 |
| 最終build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project RideIntercom.xcodeproj -scheme RideIntercom -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/RideIntercom-XcodeRepair CODE_SIGNING_ALLOWED=NO`成功。ログは`/tmp/rideintercom-xcode-build-final.log`。error / warning / package読み込みエラーなし。実行前後のprojectファイルSHA-1は`ab96e3e1f1a10e977c9fe8fc77cd42d892fd6462`で一致 |
| 残る確認 | Xcode再起動後のエラー消失・自己参照非再生成・navigator表示は画面操作権限がなく未確認。署名・アプリ起動・iOS buildは今回未実行 |

### 再起動後の検査修正と推奨設定反映（同日）

上記の修復後、Xcodeは`explicitFileType = folder`の参照も`projectReferences`へ再登録した。最初の検査は種別を区別せず拒否していたため、利用者のbuildを`PhaseScriptExecution`で停止させた。folder種別は許容し、projectとして解釈される自己参照だけを拒否するよう修正した。自己参照レコードの非再生成を完了条件とした上記の判断は訂正する。

| 確認 | 結果・境界 |
|---|---|
| 再発回帰 | Xcode保存後のfolder参照と、明示種別が推定種別より優先されるケースを追加。設定検査の7件成功 |
| 推奨設定 | 利用者の画像の提案に従い、projectと3 targetのDebug・Releaseで`DEAD_CODE_STRIPPING = YES`、projectで`STRING_CATALOG_GENERATE_SYMBOLS = YES`を反映。Xcode 27.1で確認し`LastUpgradeCheck = 2710`へ更新 |
| Appテストの追随 | 既存のInfo.plist編集で説明文がビルド設定から生成される構成になっていた。`appInfoPlistEnablesBackgroundAudioMode`が元ファイルの説明文を要求して失敗したため、生成済みApp bundleの値を検証するよう修正。Info.plistの既存編集は維持 |
| 最終検証 | 上記buildコマンドを`test -only-testing:RideIntercomTests`として実行し`TEST SUCCEEDED`。ログは`/tmp/rideintercom-xcode-settings-final-test.log`、xcresultは`/tmp/RideIntercom-XcodeRepair/Logs/Test/Test-RideIntercom-2026.10.21_21-57-19-+0900.xcresult`。文書検査も成功 |
| 境界 | AppIntents依存がないためmetadata抽出を省略するXcode toolのwarningは残る。Xcode画面の推奨通知の消失・iOS build・署名は未確認 |
