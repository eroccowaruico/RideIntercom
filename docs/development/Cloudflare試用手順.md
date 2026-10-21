# Cloudflare試用手順

現行の[Worker仕様](../spec/server/Worker.md)を用いる操作手順。確認結果は[検証](../validation/README.md)へ記録する。

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
node scripts/Cloudflare/issue-device.mjs https://ride-intercom-server.example.workers.dev my-mac
node scripts/Cloudflare/issue-device.mjs https://ride-intercom-server.example.workers.dev my-phone
cd server
npx wrangler secret put CLIENT_TOKENS_JSON < .trial-credentials/client-tokens.json
```

設定値と既定値は[Worker仕様](../spec/server/Worker.md)を参照する。

```sh
# server/ で設定をレビューした後だけ実行。
npx wrangler deploy
cd ..
node scripts/Cloudflare/check-service.mjs server/.trial-credentials/my-mac.json
```

発行ファイルはdirectory0700/file0600で生成しgitignore対象。端末へ渡すのは各device JSONのWorker URLとaccessTokenだけ。JSONはAppへの自動インポート形式ではなく、Settingsへ手入力するための保存形式。registryにはtokenのSHA-256だけを保存する。revoke時は対象hashをregistryから削除しsecretを再登録。稼働中のWSは既存lease終了まで残り得る。ファイルやsecretをログ・チャット・リポジトリへ貼らない。

`v1` migrationは未デプロイ開発用namespaceを前提にSQLite DOを作る。既に同名Worker/旧KV DOをデプロイしていた場合は、既存migrationを書き換えて適用せず、新しい試用Worker名とnamespaceで開始する。既存データの移行・削除はこの手順に含めない。

## Appでの試用と記録

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
