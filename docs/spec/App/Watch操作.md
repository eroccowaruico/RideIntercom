# iPhone依存のWatch操作

## 所有者と提供範囲

| 項目 | 現在の実装 |
|---|---|
| 通話の所有者 | iPhone本体の`AppCallOwner`と既存`IntercomViewModel`。Watchにアカウント・利用権・RTC・保存ユーザーの別台帳を作らない |
| Watchの操作 | 保存済みユーザーまたは通常groupの開始、現在通話の終了、iPhone側マイクの明示ミュート／解除、現在状態の更新 |
| 通話先 | 既存`callTargets`を再利用。groupで会っただけの参加者と内部1対1groupを独立した宛先にしない。名前は本人名／端末側の別名をそのまま表示し、翻訳keyにしない |
| 音声 | iPhoneまたはiPhoneへ接続したヘッドホンから入出力する。Watchのマイク・スピーカーでの通話は未実装 |
| 到達不能 | 操作をqueueへ積まず、未接続を表示する。接続復帰時に現在状態を取得し、古い開始・マイクONを自動実行しない |
| 着信 | 呼出し通知の送信、Watchでの着信応答、背景からの自動通話開始はこの操作基盤に含まない |

新しいwatchOS targetはiPhone依存の単一Appとし、最低OSは26.4。iPhone/macOSの最低OSは引き上げない。`WKApplication=true`、`WKCompanionAppBundleIdentifier=com.yowamushi-inc.RideIntercom.RideIntercom`、`WKRunsIndependentlyOfCompanionApp=false`。この制御機能のためにマイク、APNs、CarPlayのentitlementや外部登録を追加しない。

## 操作と状態の契約

| 接続点 | 契約 |
|---|---|
| `WatchControlMessage.swift` | FoundationだけのCodable要求／応答／表示snapshot。音声・秘密・本人の認証資格を含めない |
| `AppCallOwner+Watch.swift` | 現在ログインを`callModel()`で確認し、`startCall`・`endCall`・`setCallMuted`へ渡す。開始は別通話への切替を許可しない。開始資格・購入・24時間条件は既存処理の所有 |
| 参照 | 既存のaccountAccessID・connectionGeneration・groupIDから不透明な参照を作る。要求の参照を現在値と比較してから実行。Watch専用epochを増やさない |
| 期限 | iPhoneが発行したsnapshotを120秒有効とする。要求が遅延し期限切れなら実行しない。長時間通話では利用者の操作時だけ1回更新し、通話参照が変わっていなければ明示操作を行う。通話自体を120秒で終了しない |
| 重複 | 開始・終了は既存通話世代、ミュートはtoggleではなく指定したBoolで処理する。同じ指定値は既存処理で冪等。専用requestIDや永続重複台帳を追加しない |
| 削除・切替 | 実行時に保存相手を再解決する。相手削除後の新規開始を拒否し、成立済み通話の終了は許す。別ログイン・別通話・再接続前の要求を拒否する |
| `WatchPhoneBridge` | iPhoneで1つ保持しWCSessionをactivate。Observationで状態変更を検出し、`updateApplicationContext`へ最新snapshotだけ渡す。周期pollingを設けない |
| `WatchConnectivityClient` | activatedかつ到達可能なWCSessionの`sendMessageData`だけで要求する。activation／到達性変更／Watch前面復帰時に更新。接続切断で表示を外し、古い非同期応答を採用しない |
| `WatchControlClient` | 応答待ちに重複タップをqueueへ追加しない。古い応答が新しいcontextを上書きしない。送信受付だけで接続済み・マイクONと表示しない |

snapshotの現在通話は閲覧中groupと分ける。表示状態は未ログイン、待機、接続待ち、通話中、音声一時停止、音声利用不能を区別し、現在のiPhone状態から導く。失敗は古い操作・宛先消失・現在アカウントなし・操作不可・到達不能に分け、必要時はiPhoneを開くよう案内する。英語と日本語の標準SwiftUI表示を用意する。

## 検証と未確認

共通操作への接続、宛先削除、ログイン変更、期限切れ、別通話への誤操作、重複タップ、切断後の遅い応答、長時間通話の操作時更新をunitで検証する。generic iOS/watchOS buildはSDKのコンパイル確認であり、Watchとの実配送・背景起動・ペアリング・ロック中の利用可否の証明ではない。WatchConnectivityの実機受入は[未確認事項](../../validation/未確認事項.md)へ残す。

[WCSession](https://developer.apple.com/documentation/watchconnectivity/wcsession)の背景転送は即時ではないため、開始・マイクONを`transferUserInfo`へ退避しない。[sendMessage](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:))によるWatchからiPhoneの背景起動と、マイクの利用・長時間継続は別条件として確認する。

Watch音声の媒体経路と長時間の電池消費は未実装・未受入。既存WebRTC binaryはwatchOS sliceを持たず、SessionManagerにもwatchOS音声sessionの工程が必要。[TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)が定めるCallKit通話等の通信条件を確認し、WatchConnectivityの操作配送を連続音声の代用にしない。CarPlay専用画面・entitlementも本工程の実装ではない。
