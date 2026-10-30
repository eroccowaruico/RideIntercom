# Cloudflare試用手順

現行の[Worker仕様](../spec/server/Worker.md)を用いる操作手順。確認結果は[検証](../validation/README.md)へ記録する。

## 管理画面とプレビューの設定

Cloudflareのアカウントを選び、Realtime → Serverless SFUでApp ID / App Secretを取得する。Workers & Pages → Create application → GitHubから本リポジトリを選ぶ場合は、Worker名を`rideintercom`、root directoryを`server`、build commandを空欄にする。Worker名は`server/wrangler.toml`の`name`と揃える。

| 配置先 | 配置方法 | 設定と接続先 |
|---|---|---|
| Production | `npm --prefix server run deploy`。GitHub連携のdeploy commandは`npx wrangler deploy` | 通常のWorker URL。現行の`vars.SERVICE_ENABLED`はfalse |
| 試用プレビュー | `npm --prefix server run preview`。作業branchごとに作成・更新 | Preview URL。`previews.vars`と`previews.durable_objects.bindings`を使用。各プレビューのSQLite DOはProductionと別namespace |

WorkerのSettings → Runtime variables and secretsで **Previews Base** を選び、次を登録する。build variablesではなく、実行時の設定に入れる。

| 名前 | 種類 | 値 |
|---|---|---|
| CLOUDFLARE_SFU_APP_ID | VariableまたはSecret | SFU App ID |
| CLOUDFLARE_SFU_APP_SECRET | Secret | SFU App Secret |
| CLIENT_TOKENS_JSON | Secret | 試用資格の登録用`client-tokens.json`の内容 |

`CLIENT_TOKENS_JSON`は手動発行した利用キーのSHA-256と識別名を対応付ける招待制試用用のregistry。実機の端末IDを事前収集するものではない。下記スクリプトで生成し、JSONを手書きしない。一般公開時の自動登録・資格発行は[未実装課題](../backlog/未実装課題.md)であり、Cloudflareの設定だけでは提供されない。

Baseの値は新しいプレビューへ引き継がれる。既存プレビューのsecretはBaseの後続変更では更新されないため、そのプレビューを選んで更新する。プレビュー側だけに登録した資格はProductionへ反映されない。両端末のAppには同じPreview URLを設定する。`SERVICE_ENABLED = "true"`などの通常変数と2つのDO bindingは`wrangler.toml`の`previews`へ定義済み。SFUの値・資格はファイルやGitへ埋め込まず、Baseから継承する。

Cloudflareプラグインからは、その接続に許可された範囲で設定・メトリクスを確認できる。読取り成功はプレビューの作成権限を保証しない。CLIでプレビューを配置する場合は下記の依存導入と`wrangler login`の後、`npm --prefix server run preview`をリポジトリrootで実行する。固定名で手動試用する場合は`npm --prefix server run preview -- --name trial`と指定できる。

GitHub連携ではSettings → Builds → Branch controlのEnable Preview BuildsをONにし、Preview commandを`npx wrangler preview`にする。作業branchへのpushでそのbranch専用のプレビューへ配置する。Production branchは`main`、既存のdeploy commandは`npx wrangler deploy`のまま維持し、プレビューのために本番の配置経路を置き換えない。root directoryは`server`、build commandは空欄。既存のPreviews Baseの3項目をProductionへコピーする必要はない。

[公式プレビュー設定](https://developers.cloudflare.com/workers/previews/configuration/)と[GitHub連携](https://developers.cloudflare.com/workers/ci-cd/builds/)を参照する。

## Apple登録入口の保護

`APPLE_AUTH_ENABLED`はProduction/Previewとも既定でfalseのままにする。AppのInternet登録は端末証明の発行も必要なため、有効化する際は環境専用のP-256 private JWKをsecret `DEVICE_IDENTITY_SIGNING_KEY`へ登録する。未設定では証明発行が503となり、Appは新資格を回収して登録を完了させない。既存のLocal通話はこの設定を待たない。秘密鍵を通常変数・Git・ログへ入れない。証明の契約と鍵変更時の再取得は[Worker仕様](../spec/server/Worker.md#ユーザーと端末の署名付き証明)を参照する。合わせて`APPLE_CLIENT_ID`と、`APPLE_ENROLLMENT_IP_LIMIT`・`APPLE_ENROLLMENT_GLOBAL_LIMIT`の両bindingを配置する。`wrangler.toml`は送信元別30回/60秒、全体300回/60秒を指定し、Productionのnamespace 1001/1002とPreviewの1003/1004を分ける。同じCloudflareアカウントの別Workerでこのnamespaceを共用しない。

登録制限の429には60秒待って新たに認証を準備する。409 / `device_limit_reached`は登録8端末の上限であり、単なる待機では解除されない。利用できる他端末でInternet資格をサインアウト・失効するか、その資格の期限を待つ。既存端末の再認証は上限でも可能。`/api/auth/session`のGET/DELETEは登録頻度制限から独立している。保存済み資格の値やApple tokenを診断へ貼らない。

制限はlocation単位の近似値であり、費用上限ではない。[APIと保持範囲](../spec/server/Worker.md#apple認証と端末資格)と[実配置の確認待ち](../validation/未確認事項.md#appleログインの実受入)を参照する。

## 初期設定と試用

リポジトリrootで実行する。操作を実際に行うのは利用者がアカウントを用意した後。実施の有無と結果は検証記録へ保存する。

```sh
npm --prefix server ci
npm --prefix server run type-check
npm --prefix server test
node --test scripts/Cloudflare/*.test.mjs
cd server
npx wrangler login
```

Cloudflare RealtimeでSFU Appを作り、App ID / App Secretを取得する。SDK付きRealtimeKitの会議作成と混同しない。[公式SFU API](https://developers.cloudflare.com/realtime/sfu/api/)が接続先の正本。

```sh
# server/ で実行。対話入力へ値を入れ、コマンド引数やgitへ秘密を残さない。
npx wrangler secret put CLOUDFLARE_SFU_APP_ID
npx wrangler secret put CLOUDFLARE_SFU_APP_SECRET
cd ..
# Worker名/アカウントに対応する実際のHTTPS originへ置換。
node scripts/Cloudflare/issue-device.mjs https://rideintercom.example.workers.dev my-mac
node scripts/Cloudflare/issue-device.mjs https://rideintercom.example.workers.dev my-phone
cd server
npx wrangler secret put CLIENT_TOKENS_JSON < .trial-credentials/client-tokens.json
```

設定値と既定値は[Worker仕様](../spec/server/Worker.md)を参照する。

以下はProductionへの配置手順。資格登録後に`wrangler.toml`の`vars.SERVICE_ENABLED`をtrueへ変更する。管理画面で通常変数だけを変更しても次の配置でファイルの値へ戻るため、設定ファイルを同期させる。プレビューで試す場合は上記のPreviews Baseへ資格を登録し、Productionへの配置の代わりに`npm --prefix server run preview`を使う。

```sh
# server/ で設定をレビューした後だけ実行。
npx wrangler deploy
cd ..
node scripts/Cloudflare/check-service.mjs server/.trial-credentials/my-mac.json
```

発行ファイルはdirectory0700/file0600で生成しgitignore対象。端末へ渡すのは各device JSONのWorker URLとaccessTokenだけ。JSONはAppへの自動インポート形式ではなく、Settingsへ手入力するための保存形式。registryにはtokenのSHA-256だけを保存する。revoke時は対象hashをregistryから削除しsecretを再登録。稼働中のWSは既存lease終了まで残り得る。ファイルやsecretをログ・チャット・リポジトリへ貼らない。

`v1` migrationは未デプロイ開発用namespaceを前提にSQLite DOを作る。既に同名Worker/旧KV DOをデプロイしていた場合は、既存migrationを書き換えて適用せず、新しい試用Worker名とnamespaceで開始する。既存データの移行・削除はこの手順に含めない。

## Appでの試用と記録

実サービスを使う前に、[開発方針](../policies/開発方針.md#実サービスを使う検証の費用制約)に従い、単体・結合を含むローカル検証をすべて成功させる。以降の手順は明示的な実サービス確認用であり、通常テストや設定マトリクスから大量実行しない。目的・人数・時間・回数を先に決め、短い疎通から進める。

Debugで手動試用する場合は、前述の端末JSONから、このcheckoutの[Configuration](../../Configuration/README.md)の`Debug.local.xcconfig`へ接続先hostとplatform別tokenを用意する。通常のXcode Run・Buildが対象端末の値を生成Info.plistへ取り込み、AppはKeychain未設定時の既定値として読む。Settingsへの手入力や保存は不要。既定値はKeychainへ自動保存せず、保存済み設定を優先する。Release・Archive・隔離された検証buildへは含めない。秘密ファイルはgitignore対象で、GitHub経由では配布されない。

unit / UI / 音声E2Eのcurrent-process compositionは、XCTestの環境変数または`RIDEINTERCOM_LOCAL_TESTING=1`でInternet資格を無効にする。UI testはこのflagをlaunch environmentへ渡す。ローカルfixtureを使うテストはstoreを明示注入する。外部費用のない自動試験と、Debugの手動試用を混同しない。

| 操作 | 確認すること |
|---|---|
| Settings → Internet Connection → Configure | 同じWorker origin、端末ごとのaccess tokenを保存 |
| Settings → Local Network OFF | Internetを明示選択。近距離経路の成功をSFU成功と誤認しない |
| groupを作成し既存招待URLを共有 | 両端末が同じgroup secretを持つ |
| Connect、双方向発話、mute | SFU APIの成功だけで音声成功と判定しない |
| 20分以上継続 | leaseを跨いでsessionIdが変わらず手動再接続不要かを確認 |
| 一時的WS切断、端末終了 | media継続/WS再接続と、期限切れのchannel閉鎖を別々に確認 |
| 料金計測 | Cloudflare実egress / requests / duration / CPUと [費用試算](Cloudflare費用試算.md) の仮定を比較 |

## TURN有効化

アカウント用意後、Cloudflare RealtimeでTURN keyを作り、serverディレクトリで次を対話入力する。`TURN_ENABLED = "true"`へ変更して設定をレビュー後にdeployする。実行結果は検証記録へ保存する。

```sh
npx wrangler secret put CLOUDFLARE_TURN_KEY_ID
npx wrangler secret put CLOUDFLARE_TURN_API_TOKEN
```

## 検証環境の間接依存

| 依存 | 採用 / 理由 |
|---|---|
| Miniflare | 安定版4.20260730.0を維持。npm latestはこの版、5系列はbeta |
| undici | Miniflare 4配下を7.30.1へoverride。7系列の修正版。HTTP/WSのaudit指摘を解消 |
| sharp | Miniflare 4配下を0.35.5へoverride。libheif/librsvgのaudit指摘を解消 |
| 根拠 / 検証 | 2026-10-21 npm registryの版・依存、npm audit。lockfile同期、ci、型検査、Worker9件、Swiftペア成功 |
| override除去条件 | 安定版Miniflareが修正版を宣言したら通常依存へ戻し、同じWorker/ペア試験を通す |

例: [undici advisory](https://github.com/advisories/GHSA-w293-vg96-wgc3)、[sharp advisory](https://github.com/advisories/GHSA-wq5f-xc86-pv6w)。これらはローカル開発・検証ツールの依存であり、Worker bundleへそのまま配布するものではない。
