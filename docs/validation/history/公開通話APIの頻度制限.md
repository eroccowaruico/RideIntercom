# 公開通話APIの頻度制限の検証

2026-10-31、`89cbcb40cff3411d6a8b2aa1c6399013a1f91802`から隔離したserver工程で、rooms/statusの認証後に標準Rate Limiting bindingを追加した。通常8人の利用と復旧操作に余裕を持たせ、独自の回数台帳・新しいDO・定期照会を増やさない。[現行契約](../../spec/server/Worker.md#通話apiの頻度制限)を正本とする。

| 確認 | 結果 |
|---|---|
| TDDの赤 | 制限実装前に、同一ownerの超過・binding欠落・同一Apple accountの別端末共有の3件が、期待した429/503でなく200を返して失敗。`red.log`と`red-build.log`を保持 |
| 対象の緑 | 上記3件と8人分の余裕を確認する1件が成功。全体回帰では同じaccountの通知宛先／許可取消・サインアウト・削除と別account保持の確認も追加 |
| 認証とcleanup | 無効資格401、別ownerのsession DELETE403を維持。枠を使い切っても自分のsession DELETEとICE取消が通る。`signal`へのDELETEをcleanup例外にできず、制限後の新しいprovider呼出しは増えない |
| 通常要求 | 同一試用ownerへ8人分のICE・join・publish、7相手ずつのpull、renew、status 120回を集めた160要求と、その後の全session終了が成功。実端末の通信量やユーザー体験を測った試験ではない |
| 全Worker回帰 | `npm --prefix server test`の78件成功、失敗・取消・skipなし。Miniflare内のApple／SFU／TURN／APNs mockを使用し、実サービスへ送信しない |
| Swift–Worker結合 | `npm --prefix server run test:pair`の1件成功、PAIR PASS。専用scratch/cache、mock provider、同じ448入力の前後一致。compiler／stale-path warningなし |
| 型・bundle | `npm --prefix server run type-check`とWrangler dry-runが成功。生成した`WorkerBindings`に600回/60秒のbindingを含む。warning/errorなし。Wranglerの更新通知は依存更新として扱わず、lockfileを維持 |
| 入力同一性 | 文書を除く448 source/configuration入力が試験前後で一致。うちApp・package・Xcode・App testsの350入力は基準commitと一致 |
| 証跡 | 隔離worktree `/private/tmp/RideIntercom-api-abuse/.validation/api-abuse` の`full-worker.log`、`type-check.log`、`source-before.json`、`source-after.json`、`summary.json`。mainへ同じserver入力を照合して`.validation/api-abuse-delivery`へ集約。いずれもGit管理外のローカル証跡 |

追加したbindingはCloudflare location単位の近似制限であり、分散した全世界の要求数や請求金額を厳密に止める仕組みではない。実配置、分散locationでの効果、実egress、請求通知、障害時停止運用は未確認・未実装として維持する。RTC側の429に対する自動待機は追加していない。App／package・既存認証方式・同時参加枠・音声経路を変更せず、Simulatorや実機も使用していない。

統合レビューでは公開最新版workers-types `5.20261031.1`のRateLimit形状と公式APIを確認し、lockfile版`5.20261019.1`と今回利用する契約が一致することを照合した。リポジトリの依存更新はしていない。
