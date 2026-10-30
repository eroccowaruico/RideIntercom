# Cloudflare 試用準備の検証記録

> この記録は記載時点の実装・コマンド・結果。現在の受け入れ状況は[検証一覧](../README.md)を参照し、当時の成功件数を現行HEADの再実行結果と読み替えない。

> この文書は初回Cloudflare試用基盤の履歴。現行のDataChannel中継・機器停止・費用見直しの結果は [混在通話検証](混在通話検証.md) が正本。旧native RTP / mid再利用の説明を現行媒体へ適用しない。


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

2026-10-21の追加点検で、購読midの再利用、Swift clientとWorkerのペア検証、native SDPの自動検証を追加した。上記の未確認事項のうち「peer入替時のSDP再利用」はローカル自動検証済みとなった。実Cloudflare媒体の確認は引き続き必要。最新の結果は [品質点検](品質点検.md) を参照する。

## プラグインによる実設定とプレビュー準備の確認

2026-10-30。Cloudflareプラグインで実Workerの設定・メトリクスを読取り、他作業と分離したworktreeでプレビュー設定を追加した。Workerの媒体処理、App、RTC packageは変更していない。

| 対象 | 結果と条件 |
|---|---|
| 実Worker | `rideintercom`。通常URLは`https://rideintercom.analog.workers.dev`。Productionに2つのSQLite DO bindingがあり、SERVICE_ENABLEDはfalse、SFU値・端末registryは未登録 |
| 実メトリクス | 2026-10-30 19:22 JST取得。直前24時間のWorkers集計はrequests=3、errors=0、subrequests=0。errorsは実行時例外等の指標でありHTTP 401/503やSFU音声の成否とは別 |
| Previews Base | 初回読取時、SFU App ID、SFU App Secret、CLIENT_TOKENS_JSONの3項目が存在。secretの内容は取得・出力していない。実プレビューは0件 |
| 設定の修正 | Worker名を実設定と同期。`previews.vars`へ有効化と利用枠、`previews.durable_objects.bindings`へ2つの独立bindingを定義。`npm run preview`を追加しbranch単位で配置 |
| ローカル検証 | Wrangler 4.151.3による設定読込み・bundle dry-run、TypeScript型検査、Worker 20 tests、Cloudflareスクリプト4 tests、文書検査、diff checkが成功 |
| 外部配置の制約 | プラグインのPreview作成APIはHTTP 403。ローカルWranglerは未ログイン。既存main用CIをPreview向けに置換する操作は、自動承認レビューが本番配置への影響を理由に拒否し、変更されていない |
| 採用した配置経路 | mainのProduction用CIを保持し、利用者がGitHub連携のPreview buildsと`npx wrangler preview`を設定。修正を含む専用branchをpushして配置する |
| 配置前の未確認 | 実Preview URLでの資格照合・DO動作、実SFUの接続・双方向音声、利用枠更新、TURN、請求。ローカルの20 testsは外部SFUを代替しており、これらを証明しない |

同日19:33 JST、`codex/cloudflare-preview-setup`の`2a50b5cba134ff0ae755fecb087dfe53f3883023`をpushし、GitHub連携のプレビュービルドが成功した。以降の記録更新では、同じbranchのソースへ変更を加えていない。

| 実プレビューの確認 | 結果 |
|---|---|
| Preview URL | `https://codex-cloudflare-preview-setup-rideintercom.analog.workers.dev` |
| 配置 | build `a565635f-440d-42d4-9bed-c0b8a8e8e30d`がsuccess。deployment `dc340055-0e85-41cd-85db-669d3b8100f8`、migration v1 |
| 実行時設定 | Baseの3項目と、ファイルで定義した有効化・利用枠・2つのDO bindingを確認。SERVICE_ENABLED=true、TURN_ENABLED=false |
| 独立性 | SIGNALING_ROOM / USAGE_GUARDのnamespace IDが両方ともProductionと異なる。Productionのdeployment `9cdf421f-c93e-4130-94f2-c8d9abd7ad68`が変更されていないことをAPIで照合 |
| GET /health | 200、service=`RideIntercom SFU`、protocol=1 |
| GET /api/status、資格なし | 401 |
| GET /api/status、Mac / iPhoneの個別資格 | 両方200。2026-10月、予約参加者秒0、月上限1,000,000、active sessions 0。資格の値は出力していない |
| 残る確認 | 実SFUの接続・双方向音声、通話中の更新・回収、TURN・制限回線、実請求。healthとstatusの成功はSFU App Secretの有効性や音声品質の証明ではない |

現行の設定手順は[Cloudflare試用手順](../../development/Cloudflare試用手順.md)を参照する。
