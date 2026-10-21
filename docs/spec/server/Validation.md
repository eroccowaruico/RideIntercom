# Cloudflare 試用準備の検証記録

> この文書は初回Cloudflare試用基盤の履歴。現行のDataChannel中継・機器停止・費用見直しの結果は [混在通話検証](../scripts/混在通話検証.md) が正本。旧native RTP / mid再利用の説明を現行媒体へ適用しない。


## 背景と範囲

2026-10-21。dev基準の復旧済み作業ブランチ `codex/restore-dev-calls` で、SFU接続・利用枠・端末資格・費用試算を実装。実機と外部デプロイを待たず、自動検証を進める指示に従う。実Cloudflareアカウントの請求・音声は未検証。

## 環境と証跡

| 項目 | 値 |
|---|---|
| workspace | `/Users/naohito/.codex/worktrees/restore-dev-calls/RideIntercom` |
| 証跡directory | `/private/tmp/rideintercom-cloudflare-validation`。一時領域なので必要なら利用者側で保管する |
| Apple toolchain | Xcode27.1 / Swift6.4。各コマンドに `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` |
| macOS | 27.0.1、arm64 |
| iOS | 専用 iPhone17 Pro Simulator、iOS26.4.1、`5DDF37BD-AAC5-4930-AB0D-FA16412C9E18` |
| サーバー | Node26.12.0。依存版はWorker.md |
| 既存作業 | 元の `codex/restore-local-calls` の未コミット変更を保持。main `295f54b` / dev `efb50cf` は更新しない |

## 自動検証と限界

| 対象 | 結果 / 証跡 |
|---|---|
| Worker | 型検査・8 tests成功。`server-final-types.log` / `server-final-tests.log` |
| 費用・端末資格 | 3 tests成功。`cloudflare-scripts.log` / `cost-scenarios.tsv` |
| macOS App | 49 tests成功。`macos-accepted.xcresult` (最終RTC・資格編集sheet組込み) |
| iOS App単体 | 49 tests成功。`ios-accepted.xcresult`内のRideIntercomTests。UIのhit testing失敗を含むため、このbundle全体を成功と扱わない |
| RTC | 31 tests成功。`rtc-final3.log`。一時更新失敗・遅延DELETEのredは `rtc-renew-red3.log` |
| native WebRTC | `swift build --package-path RideIntercom/packages/RTC --target RTCNativeWebRTC` 成功。`native-final2.log` |
| 初回red | `app-red.xcresult` / `app-red2.xcresult`。新設定APIと音声所有権eventが存在しない状態で失敗を確認 |
| 途中のテスト不備 | `app-green2` は非同期イベント待ち不足。`ios1` は追加セクションのスクロール前提、`ios-ui3` は表示範囲/キーボード、`ios-final` は浮動タブのhit pointで失敗。さらに前回失敗のroute設定残留と初回タブ識別子差を修正して再実行 |
| iOS UI最終 | `ui-accepted.xcresult` の3 tests成功（主要操作、資格入力後の復帰/スイッチ、起動）。最終Appコードは`ios-accepted`の単体49件と同じ。UIテスト修正とソースのインデント整理だけを後から反映 |
| 資格編集の回帰 | `ui-focus-red` / `ui-focus2` で入力後のタブ復帰失敗を再現。Settings画面をpresenterとする標準sheetへ分離し、`ui-sheet2` の専用回帰1件成功。さらにスイッチの値変化を検査した `ui-switch` も成功 |
| 空の実行 | `ios-ui2.xcresult` は指定誤りで実行0件。成功件数に含めない |
| SDK通知 | AppIntents未使用targetのmetadata extraction skipped、XcodeのSDK build文字列診断、失敗時のsimctl診断収集警告が残る。テスト対象Swiftコードのwarningを隠す設定変更は行わない |
| Simulator codec | AAC ELDv2 unavailableを検出してfallbackするログあり。実機のcodec availabilityと同一とは扱わない |

## 再実行入口

```sh
scripts/validate.sh packages
scripts/validate.sh worker
scripts/validate.sh scripts
scripts/validate.sh macos
scripts/validate.sh ios
```

`ios` は新しい専用Simulatorを作り、終了時にshutdownする。利用者のSimulatorをeraseしない。失敗段階は `results.tsv` と終了コードへ反映する。

今回のApp単体は以下の形式で実行し、証跡名を変えて失敗と修正後を分けた。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project RideIntercom.xcodeproj -scheme RideIntercom \
  -destination 'platform=macOS,arch=arm64' -only-testing:RideIntercomTests \
  -derivedDataPath /private/tmp/rideintercom-dev-validation/automation-macos/DerivedData-macOS \
  -resultBundlePath /private/tmp/rideintercom-cloudflare-validation/macos-final.xcresult
```

既存xcresultへ上書きしないため、再実行時は新しいresultBundlePathを選ぶ。実アカウント試用の手順は `Worker.md`、費用再計算は `Cost.md` を参照。

## 後続の受け入れ

| 残件 | 確認内容 |
|---|---|
| Cloudflare実サービス | アカウント/秘密設定、2端末publish/subscribe、実媒体、20分以上のlease跨ぎ、請求meterを確認 |
| 実機 | Mac/iPhoneの双方向音声、画面ロック、Bluetooth/有線切替、一時ネットワーク断の復帰 |
| 公開前 | identity自動発行/失効、edge abuse制限、TURN、peer入替時のSDP再利用、実料金監視と停止運用 |

自動テスト成功を「実機通話復旧完了」「公開準備完了」「月額上限保証」と記載しない。

最終UI実行コマンド（既存専用Simulatorを再利用、データeraseなし）:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project RideIntercom.xcodeproj -scheme RideIntercom \
  -destination 'platform=iOS Simulator,id=5DDF37BD-AAC5-4930-AB0D-FA16412C9E18' \
  -only-testing:RideIntercomUITests -parallel-testing-enabled NO \
  -derivedDataPath /private/tmp/rideintercom-dev-validation/automation-ios/DerivedData-iOS \
  -resultBundlePath /private/tmp/rideintercom-cloudflare-validation/ui-accepted.xcresult
```

## コミットの区分

| コミット | 内容 |
|---|---|
| `89b7abe` | RTCの実SFU publish/subscribe・lease契約 |
| `71314a9` | Worker認証・利用枠・費用試算・試用スクリプト |
| `5e9ff9a` | Appの資格保存・音声所有権切替 |
| `c1f8646` | RTCの一時更新失敗と遅延切断応答の回帰修復 |
| 本記録を含む最終コミット | 資格編集sheet、UI回帰、要求・仕様・検証記録 |

main/devへのマージ、push、Cloudflareデプロイは行っていない。

## 後続の品質点検

2026-10-21の追加点検で、購読midの再利用、Swift clientとWorkerのペア検証、native SDPの自動検証を追加した。上記の未確認事項のうち「peer入替時のSDP再利用」はローカル自動検証済みとなった。実Cloudflare媒体の確認は引き続き必要。最新の結果は [品質点検](../scripts/品質点検.md) を参照する。
