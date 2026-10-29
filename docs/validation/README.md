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
| 音声の途切れ・同一性 | [修復前の再現](history/音声同一性と途切れの再現.md)、[原因・修復・再検証](history/音声の連続性修復.md) |
| iOS音声E2E・切断／無音 | [実発話・全設定・サーバーモックと修復の検証](history/iOS音声E2Eと通話障害修復.md) |
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

## iOS配布のiCloud署名修復（2026-10-21）

対象は`50243f5`上の作業ツリー。利用者によるproject形式・対応platform等の変更を保持して検証した。

| 確認 | 結果・境界 |
|---|---|
| 元の失敗 | 利用者の22:21:49のxcdistributionlogsでApp Store Connectエラー90046を確認。iCloud環境の値が空と判定され、Productionが必要とされた。元のArchiveと配布ログには空のコンテナ一覧とCloudKit権限があった |
| 原因と修正 | App・packageのSwiftコードにCloudKit利用がなく、保存先は端末内ファイルとKeychain。未使用の`com.apple.developer.icloud-container-identifiers`と`com.apple.developer.icloud-services`をentitlementsから除去。APNs・マイク権限は保持 |
| 回帰 | `appDoesNotRequestUnusedICloudServices`が修正前に失敗し、修正後のAppテスト全体で`TEST SUCCEEDED`。ログは`/tmp/rideintercom-icloud-before-test.log`と`/tmp/rideintercom-icloud-after-test.log`。最初の個別filter実行は対象を選択できず、検証実績に含めない |
| iOS Archive | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild archive -project RideIntercom.xcodeproj -scheme RideIntercom -destination 'generic/platform=iOS' -archivePath /tmp/RideIntercom-DistributionRepair.xcarchive -derivedDataPath /tmp/RideIntercom-DistributionRepair`で`ARCHIVE SUCCEEDED`。署名済みAppにiCloud権限がないことを確認 |
| 配布書き出し | `xcodebuild -exportArchive`を`method=app-store-connect`、`destination=export`、`signingStyle=automatic`、`manageAppVersionAndBuildNumber=false`、`uploadSymbols=false`で実行し`EXPORT SUCCEEDED`。IPAは`/tmp/RideIntercom-DistributionExport/RideIntercom.ipa`。展開したAppでiCloud権限なし・APNs productionを確認し、`codesign --verify --deep --strict`成功 |
| 証跡 | Archiveログは`/tmp/rideintercom-distribution-archive.log`、exportログは`/tmp/rideintercom-distribution-export.log`。開発設定・文書・plist・差分検査成功。AppIntents未使用によるmetadata抽出省略warningは残る |
| 未確認 | App Store Connectへの再アップロード・サーバー側検証は未実行。ローカル書き出し成功はApple側の受理を保証しない。旧Archiveは変更されないため、新Archiveを使って再送する |

## iOS配布のアイコン・WebRTCシンボル修復（2026-10-21）

同じ`50243f5`上の作業ツリーで、利用者の選択に従いRideIntercomの仮アイコンを新規生成した。AppIconには画像が未登録で、WebRTCは`enable_dsyms=false`だった。

| 確認 | 結果・境界 |
|---|---|
| アイコン | 紺・白・ターコイズで道路と音声波形を表した仮素材を登録。iOS用1024pxとmacOS用16〜1024px。生成条件は[開発環境](../development/開発環境.md)に記録 |
| WebRTC再ビルド | 同じsource revision `2a990ce0cc`のiOS arm64を`enable_dsyms=true`で再ビルド。Simulator・macOS binaryは既存出力を維持。`DebugSymbolsPath`付きでiOS実機dSYMを同梱 |
| 継続防止 | build scriptでiOS実機dSYM生成を有効化。検証スクリプトで宣言・DWARF欠落・binaryとのUUID不一致を拒否。欠落を拒否するテストが修正前に失敗し、修正後に成功 |
| 成果物採用 | `ASSEMBLE_ONLY=true WEBRTC_BRANCH=branch-heads/8078 scripts/BuildWebRTC/update-webrtc-binary.sh`成功。隔離したRTCNativeWebRTC build、RTC test run 51件とnative test run 2件成功後に取り込み。zipは97,147,343 bytes。SHA-256は隣接metadataが正本 |
| 回帰テスト | `python3 -m unittest discover -s scripts/tests -v`の36件成功。Appは`xcodebuild test -only-testing:RideIntercomTests`で`TEST SUCCEEDED`。開発設定・文書・差分検査も成功 |
| Archive | `/tmp/RideIntercom-DistributionReady.xcarchive`で`ARCHIVE SUCCEEDED`。`CFBundleIcons`と`CFBundleIcons~ipad`のprimary icon名が`AppIcon`。`AppIcon60x60@2x.png`が120×120、`AppIcon76x76@2x~ipad.png`が152×152 |
| シンボル | Archive内WebRTC.frameworkと`dSYMs/WebRTC.framework.dSYM`のarm64 UUIDが`4C4C4470-5555-3144-A11C-BA59995DD9EB`で一致。旧ArchiveのUUIDとは異なるため旧Archiveへの流用不可 |
| 配布書き出し | `method=app-store-connect`、`destination=export`、`uploadSymbols=true`で`EXPORT SUCCEEDED`。IPAは`/tmp/RideIntercom-DistributionReadyExport/RideIntercom.ipa`。IPA内のアイコン名・サイズ、iCloud権限なし・APNs production、`codesign --verify --deep --strict`成功を確認 |
| 証跡 | `/tmp/rideintercom-distribution-ready-archive.log`、`/tmp/rideintercom-distribution-ready-export.log`、`/tmp/rideintercom-distribution-ready-app-tests.log`、`/tmp/rideintercom-distribution-script-tests.log`、`/tmp/rideintercom-webrtc-symbol-update.log`。一時領域のため永続保存ではない |
| 残るwarning | WebRTC vendor sourceの`tracksWithMediaType:`非推奨、AppIntents未使用によるXcode metadata抽出省略。今回の配布エラーとは別に残る |
| 未確認 | App Store ConnectへのアップロードとApple側の受理は未実行。macOS/SimulatorのdSYM同梱は今回のiOS配布修復対象外。旧Archiveを再送せず、上記の新Archiveまたは修正後に作成したArchiveを使う |

## カメラ不要の配布バイナリ修復（2026-10-22）

対象は`d201c80`上の作業ツリー。App Store ConnectからVersion 1.0 / Build 1に`ITMS-90683`が通知された。利用者の「カメラは不要」という指示に従い、利用していないカメラの目的文字列を追加せず、WebRTCのカメラAPIを除去した。

| 確認 | 結果・境界 |
|---|---|
| 原因の証拠 | 旧Archive内WebRTCに`AVCaptureSession`、`AVCaptureDeviceDiscoverySession`、`AVCaptureVideoDataOutput`、`AVCaptureVideoPreviewLayer`等の参照が存在。Appにカメラ機能はなく、SDK内の未使用実装が検出要因と考えられる |
| 修正 | 同じWebRTC revision `2a990ce0cc`の全5構成を再ビルド。撮影・プレビュー・撮影位置helperをGN入力から除去し、成果物検証でカメラAPI・headerの混入を拒否。上流checkoutの変更は終了時に復元。package検証・取り込み後にAppのbuild番号のみ2へ更新 |
| 回帰 | 全sliceのカメラAPI不在テストは修正前に失敗、修正後に成功。scripts全38件成功。隔離RTCテスト51件と実WebRTCによるSDP・双方向packet転送2件成功 |
| Appテスト | macOSの`RideIntercomTests`全109件成功（パラメータ展開後112件）。失敗・skip 0件。専用storage namespace `CameraFreeValidation`を使用 |
| ArchiveとIPA | Version 1.0 / Build 2でArchive・App Store向けIPA書き出し成功。アプリ本体とWebRTCの外部シンボルに`AVCapture`・`RTCCamera`なし。`NSCameraUsageDescription`なし。IPAの`codesign --verify --deep --strict`成功 |
| dSYM | Archive内WebRTCとdSYMのarm64 UUIDが`4C4C445B-5555-3144-A1A3-0ADBD6A1CAA0`で一致 |
| 成果物 | `/tmp/RideIntercom-CameraFree-Build2.xcarchive`、`/tmp/RideIntercom-CameraFree-Build2-Export/RideIntercom.ipa`。採用zipのSHA-256は隣接metadataが正本 |
| 証跡 | `/tmp/rideintercom-camera-red.log`、`/tmp/rideintercom-camera-free-rebuild.log`、`/tmp/rideintercom-camera-free-import.log`、`/tmp/rideintercom-camera-script-tests.log`、`/tmp/rideintercom-camera-free-app-tests.log`、`/tmp/rideintercom-camera-free-archive.log`、`/tmp/rideintercom-camera-free-export.log`、`/tmp/rideintercom-camera-free-upload.log`。一時領域のため永続保存ではない |
| 検証境界 | 最初のsandbox内実行はXcode cacheへの書き込み・既存テストのprocess確認が拒否され、必要なアクセスを許可して再実行。AppIntents未使用によるmetadata抽出省略warningは残る。実機通話品質・Apple側の処理完了はローカル成功から判断しない |
| App Store Connect | 2026-10-22 00:04 JSTに`Upload succeeded`・`EXPORT SUCCEEDED`を確認。Version 1.0 / Build 2は`Uploaded package is processing`。アップロード成功であり、Apple側の処理完了・審査承認を意味しない |
