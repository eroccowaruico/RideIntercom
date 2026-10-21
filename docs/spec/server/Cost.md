# Cloudflare 音声通話の費用試算

## 指示・背景

少人数の試用から公開へ進める際、頻繁な手動再接続を要求せず、従量課金の増大を抑える。通信量だけでなく、参加時間課金、Workers、Durable Objects (DO) を比較する。2026-10-21 に公式料金を確認。USD、税・為替・独自ドメイン・運用人件費は含めない。

## 課金の区別と履歴

| 対象 | 課金 | 根拠 |
|---|---|---|
| Realtime SFU / TURN | egress $0.05/GB、合計1,000GB/月無料。ingress無料。SFUを通るTURNは二重計上しない | [SFU pricing](https://developers.cloudflare.com/realtime/sfu/platform/pricing/) |
| RealtimeKit 音声 | $0.0005/参加者分。通話時間ではなく各参加者の接続時間の合計 | [RealtimeKit pricing](https://developers.cloudflare.com/realtime/realtimekit/platform/pricing/) |
| Calls の履歴 | 2024-04-04の告知で、2024-05-15以降1TB無料・超過$0.05/GBと発表 | [Cloudflare Calls 発表](https://blog.cloudflare.com/cloudflare-calls-anycast-webrtc/) |
| 旧リポジトリ記載 | `3227bb6` の Worker.md にあった「1000 participant-minutes/month」は今回の Calls / SFU API の料金として裏付けられないため削除 | 製品を混同しない。最近時間課金から容量課金に変わった、という説明はしない |

RealtimeKit は完成した会議機能を含む別製品であり、SFUを自作制御する場合と開発・運用負担は同一ではない。RealtimeKit の比較は音声参加料だけで、独自バックエンド等は加算していない。[Realtime サイト](https://realtime.cloudflare.com/) の無料10,000分表示にはbeta/GA予定の記載もあり、公式料金文書との整合とアカウント適用条件が未確認のため、既定試算は無料分0とする。10,000分が適用される場合の差は最大$5/月。

## 制御サーバーの料金

| 項目 | Free | Paid の含有量 / 超過単価 |
|---|---|---|
| Workers | 100,000 requests/日、CPU 10ms/呼出 | $5/月。10M requests/月 + $0.30/M、CPU 30M ms/月 + $0.02/M ms |
| DO requests | 100,000/日 | 1M/月 + $0.15/M。WebSocket受信20メッセージを1 request換算、送信無料 |
| DO duration | 13,000 GB-s/日 | 400,000 GB-s/月 + $12.50/M GB-s。128MB = 0.128GB |
| SQLite reads | 5M rows/日 | 25B rows/月 + $0.001/M rows |
| SQLite writes | 100,000 rows/日 | 50M rows/月 + $1/M rows |
| SQLite保存 | 5GB | 5GB + $0.20/GB月 |

[Workers 料金](https://developers.cloudflare.com/workers/platform/pricing/)・[DO 料金](https://developers.cloudflare.com/durable-objects/platform/pricing/)を使用。DOの超過は課金単位へ切り上げる。Workersには待機時間のwall clock課金はない。DOはHibernation APIを使用し、WebSocket接続中ずっと常駐する時間課金を避ける。ただしイベント処理・HTTP待ち等のactive durationは残る。Free超過は失敗となり、通話継続を保証しない。無料枠はこのアプリ専用ではなくアカウントの他利用と共有される。

## 計算条件

| 変数 | 既定値 / 意味 |
|---|---|
| 月の参加時間 | 利用者数 × 20時間 × 60分。1回の参加時間は1時間を仮定 |
| 同じ部屋の人数 | 2 / 4 / 8人。全員が全員の音声を購読 |
| 音声通信量 | 1話者あたり64kbps。native送信Opus上限32kbpsにRTP/UDP/IP/暗号化等の余裕を見た仮定。実測値・料金上限ではない |
| 無音削減 | 0%。全員が全時間送信する保守的条件。DTX/VADの節約を未確認のまま計上しない |
| WebSocket | 各参加者4 messages/秒。App report最大2回/秒、RTC periodic 5秒、metadata等と操作余裕を含む。料金計算上の仮定でrate limitではない |
| HTTP | 5分ごとのlease更新 + 参加1回につき6リクエスト。DO間呼出も別途計上 |
| CPU / duration | Worker CPU 2ms/HTTP、DO active 200ms/HTTP、5ms/WS message。実測前の仮定。同じ部屋で重なるactive時間は部屋の占有時間で上限を設け、global guardを別加算 |
| 保存量 | 0.1GB。小さな参加者・leaseレコードを想定。read/write行数もスクリプトに明示 |
| 異常時 | 大量再試行・攻撃・ログ保存・長いupstream待ち・TURN独立利用は既定試算外 |

`egress GB = 参加者分 × 60 × wire kbps × 1000 / 8 × (部屋人数−1) / 10^9`

参加者の送信音声は他の全員へ配信される。同じ1時間でも、2人と8人で1人当たりの受信量が7倍違う。無料枠は部屋ごとに繰り返し引かない。

## 月額比較

| 利用者数 | 部屋人数 | SFU egress GB | SFU + Workers + DO | RealtimeKit音声参加料 |
|---:|---:|---:|---:|---:|
| 4 | 4 | 6.91 | $0.00 (Free) | $2.40 |
| 100 | 4 | 172.80 | $5.15 (Paid) | $60.00 |
| 1,000 | 2 | 576.00 | $7.25 | $600.00 |
| 1,000 | 4 | 1,728.00 | $43.65 | $600.00 |
| 1,000 | 8 | 4,032.00 | $158.85 | $600.00 |
| 10,000 | 2 | 5,760.00 | $290.50 | $6,000.00 |
| 10,000 | 4 | 17,280.00 | $866.50 | $6,000.00 |
| 10,000 | 8 | 40,320.00 | $2,018.50 | $6,000.00 |

この表は需要に対する容量計画であり、既定の月1,000,000秒・同時32セッションで全シナリオを受け入れる意味ではない。現在の月上限設定のhard maximumは100,000,000秒であり、10,000人規模は認証・上限・監視を拡張した後の参考値。

1,000人・4人通話の内訳は SFU $36.40、Workers基本料 $5、DO requests $2.25、その他は含有量内。実際の請求確定値ではない。Freeの平均日量が収まっても、日別集中・CPU上限・アカウントの他サービスで失敗し得る。公開時にFreeのみで継続保証する計画にはしない。

## 条件を変えた試算と判断

| 1,000人・月20時間・4人通話 | egress | SFU + 制御 |
|---|---:|---:|
| 32kbps | 864GB | $7.25 |
| 64kbps | 1,728GB | $43.65 |
| 128kbps | 3,456GB | $130.05 |
| 64kbps、送信時間30% | 518.4GB | $7.25 (無音削減が実測で成立する場合のみ) |

無料枠・制御費を除く限界単価の交点は64kbpsで約22人、128kbpsで約12人。人数を無制限に増やす設計ではSFU容量課金が必ず安いとは言えない。現在の部屋上限8人・音声のみなら、上の条件では容量課金が有利。DOの1メッセージactive時間が5msから1秒になる条件では、部屋が常時activeになる上限まで見て合計約$68.65/月となる（1,000人・4人）。同じ部屋の同時イベントの時間を何重にも加算しない。Hibernationを外す変更や音声をWorker経由で中継する変更は、この表をそのまま流用しない。

## 費用制御と限界

| 実装した制御 | 効果 / 限界 |
|---|---|
| 端末資格を必須化 | 未認証者からSFU作成を許可しない。Worker入口への不正HTTP自体の負荷は残る |
| 最大8人/部屋、同時32セッション | 音声fanoutと同時利用を制限 |
| 月1,000,000参加者秒を前払い予約 | 64kbps・8人なら最大約56GB相当の利用枠。失敗・早期切断時も予約を返金せず、超過後の新規/更新を拒否 |
| 600秒lease、自動更新 | 手動でつなぎ直さず継続。更新拒否時は停止し、無応答端末はalarmで閉じる |
| 起動回数100回/owner/UTC日 | 接続し直しによる無制限なSFU作成を抑止 |
| WS受信上限600/分、32KiB | 異常送信の接続を終了。正常想定の4回/秒には余裕を持つ |
| SERVICE_ENABLED=false | 新規HTTP操作を停止。既存媒体は次のlease alarmまで残り得る |

参加者秒は実GB計測でもCloudflareアカウントの金額ハードキャップでもない。改変クライアントのRTP帯域、再送、他アプリによる無料枠消費、upstream障害で閉鎖が遅れる場合を完全には制限できない。公開前に端末認証/失効、edge rate limit、実egress計測、請求通知、障害時停止運用の検証が必要。予算到達後も無制限に通話を続けることと厳密な上限は両立しないため、通常は自動更新、利用枠を使い切った場合のみ停止する。

## 再計算

リポジトリrootで実行する。

```sh
node scripts/Cloudflare/estimate-cost.mjs
node scripts/Cloudflare/estimate-cost.mjs '{"users":1000,"hours":20,"roomSize":4,"wireKbps":128}'
node scripts/Cloudflare/estimate-cost.mjs '{"users":1000,"activeMsPerEvent":1000}'
node scripts/Cloudflare/estimate-cost.mjs '{"users":1000,"kitFreeMinutes":10000}'
node --test scripts/Cloudflare/*.test.mjs
```

実請求の評価は、少人数で計測した音声bytes・WS頻度・DO duration・HTTP CPUをこれらの入力へ置き換えてから行う。自動テストの合成データを実料金測定と呼ばない。
