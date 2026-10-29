# RTC音声の再送禁止と即時配送

2026-10-30のローカル検証記録。要求の正本は[パッケージ要求](../../requirements/パッケージ要求.md)、配送の仕様は[RTC](../../spec/packages/RTC.md)を参照する。

## 変更と確認

| 対象 | 変更・確認内容 |
|---|---|
| Local音声 | 認証済みGroupRelay envelopeをNetwork.framework UDPで配送。未準備・送信上限では保持や再送を行わず、MCSession音声へのfallbackを禁止 |
| Internet音声 | unordered、maxRetransmits=0に加えてTCP ICE候補とTURN/TCP・TURN/TLSを禁止。既存のreliable channelを音声用に再利用しない |
| 制御との分離 | presence等はreliable。UDP送受信はMainActorを経由しない。MainActorを30ms占有しても音声配送が完了する回帰テストを追加 |
| 受信待ち | 音声専用sequenceを使い、連続packetと途中参加の先頭packetは即時配送。実際の欠番だけ有限の並べ替え猶予を使う |
| 複数経路 | 利用できる各経路へ即時送信し、認証済みの先着だけを採用。接続一覧だけでInternet音声を抑止しない |
| membership | 参加済みの認証済み音声は制御再接続中も活動期限を更新。失効済み資格は音声や遅延application制御で復活させない |

## 結果と証跡

| 実行 | 結果 | ローカル証跡 |
|---|---|---|
| RTC Swift package（WorkerPairを別実行） | 71件とnative WebRTC 4件が成功 | `/tmp/ride-rtc-final-scope.log` |
| WorkerPair | 1件成功。実Swift HTTP/WSとローカルWorker/DO、外部SFUはmock | `/tmp/ride-rtc-worker-pair-final.log` |
| UDPの制御actor待ち | 変更前の失敗を確認し、変更後の全体実行で成功 | `/tmp/ride-udp-control-actor-red.log` |
| 途中参加のsequence | 変更前の失敗を確認し、変更後の全体実行で成功 | `/tmp/ride-stream-join-red.log` |
| 失効済み資格の復活拒否 | 遅延制御による復活を変更前に再現し、修正後の全体実行で成功 | `/tmp/ride-expired-control-red.log` |

package検証とWorkerPairは実機の音声品質の証明ではない。独立音声E2EではAACの一部の欠落と125ms予算超過が残っており、音声全体は未完了。直近の`/tmp/RideIntercomAudioE2E/immediate-join-identity-20261030`ではLocal測定前にSimulatorのAVAudioEngine初期化がRPC timeoutで停止し、WebRTC側でも一方向のAACで欠落を検出した。この失敗を成功扱いしない。

アプリ識別子・署名を変えずに実通信できた先行実行がある。Bonjour拒否の原因を識別子と断定しない。許可対象の追加、TCCのreset、システムdaemonの再起動をテストの前提にしない。物理iPhone、Bluetooth、電波環境と本番Cloudflareの検証は別に残る。
