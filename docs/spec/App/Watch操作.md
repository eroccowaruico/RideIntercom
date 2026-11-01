# iPhone依存のWatch操作

## 所有者と提供範囲

| 項目 | 現在の実装 |
|---|---|
| 通話の所有者 | iPhone本体の`AppCallOwner`と既存`IntercomViewModel`。Watchにアカウント・利用権・RTC・保存ユーザーの別台帳を作らない。製品としての対応範囲もiPhone通話の音声・操作端末に限定し、Watch単体動作・独自の通話処理・直接のRTC接続は提供しない（[製品要求](../../requirements/製品要求.md)） |
| Watchの操作 | 保存済みユーザーまたは通常groupの開始、現在通話の終了、iPhone側マイクの明示ミュート／解除、現在状態の更新。用途別許可がある保存ユーザーへの明示呼出し通知と、現在の呼出しの取消 |
| 通話先 | 既存`callTargets`を再利用。groupで会っただけの参加者と内部1対1groupを独立した宛先にしない。名前は本人名／端末側の別名をそのまま表示し、翻訳keyにしない |
| 音声 | iPhoneまたはiPhoneへ接続したヘッドホンから入出力する。Watchのマイク・スピーカーでの通話は未実装 |
| 到達不能 | 操作をqueueへ積まず、未接続を表示する。接続復帰時に現在状態を取得し、古い開始・マイクONを自動実行しない |
| 着信 | iPhone宛APNsの標準転送を利用する。通知内の「iPhoneで応答」はiPhoneの既存通知検証と通話開始へ渡す。Watch上の通常tapはWatch Appを開くだけで、通知到着では通話を開始しない |

新しいwatchOS targetはiPhone依存の単一Appとし、最低OSは26.4。iPhone/macOSの最低OSは引き上げない。`WKApplication=true`、`WKCompanionAppBundleIdentifier=com.yowamushi-inc.RideIntercom.RideIntercom`、`WKRunsIndependentlyOfCompanionApp=false`。この制御機能のためにマイク、APNs、CarPlayのentitlementや外部登録を追加しない。

## 音声接続時の要求と現行の境界

音声合成・エフェクト・VADと通話処理はiPhoneが所有する。Watch側でAudioMixer graphを構築せず、複数参加者の音声を個別配送してWatchで合成する経路も設けない。Watchはマイク入力と、iPhoneで合成・処理した単一の受信音声の再生・操作に限定する。媒体接続に必要な入出力・符号化復号・押下解除時の送話停止はこの範囲に含む。

Watchの音声経路は未実装であり、現行の遠隔操作の応答時間をWatch通話の遅延測定として扱わない。[製品要求](../../requirements/製品要求.md)では、iPhone経由の処理・複数段の通信により通常端末に少なくとも約100msを追加する見込みを許容している。通常端末と同じ約125msの総遅延基準は適用しない。100msは実測・固定下限・最大許容値のいずれでもなく、試作後に実際の追加量を測る。

押している間だけ話すモードはこの利用体験に合わせるが、AppleのPush to Talk／CallKitへの統合は行わない。押下解除時にWatchの送話を閉じることと、既に送信済みの音声が通信・再生時間の後に相手へ届くことは区別する。古い解除要求や再接続による録音再開は許さない。codecはApple標準AACの成立性を先に確認し、未測定の電池優位を理由にOpusを既定にしない。

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
| 呼出し先と結果 | `canNotify`は現在の保存ユーザーの用途別許可から投影し、通常groupには付けない。iPhoneで要求時にSavedUserを再解決し、既存`notifications.send`へ渡す。既存outgoingのrequestID・固定status・取消可否だけを表示し、acceptedを配送・応答・通話成立と表示しない。古いrequestIDによる新しい呼出しの取消を拒否する |

通知応答の固定categoryは`RIDEINTERCOM_CALL_REQUEST`、actionは`RIDEINTERCOM_RESPOND_ON_IPHONE`。iOSで`UNNotificationAction`のoptionsを空として登録し、Watchへ転送された通知の背景actionを元の通知先であるiPhoneで処理する。Appの通知bridgeから[共通の通知検証](通知仕様.md)へ渡し、受信ON・recipient・120秒期限・取消・保存関係・ログイン世代・別通話の維持を再利用する。未知action・dismiss・別categoryのactionを通話開始へ渡さない。Watch側に通知資格、APNs token、応答待ちqueue、再送・pollingを追加しない。

この配送先の区別は[Appleのaction規則](https://developer.apple.com/documentation/watchos-apps/adding-actions-to-notifications-on-watchos)による。通常tapがWatch Appを開く動作は[標準通知の表示仕様](https://developer.apple.com/documentation/watchos-apps/presenting-notifications-on-apple-watch)と分ける。「iPhoneで応答」の登録はWatch自身の音声やOS背景起動の実機成立を保証しない。

snapshotの現在通話は閲覧中groupと分ける。表示状態は未ログイン、待機、接続待ち、通話中、音声一時停止、音声利用不能を区別し、現在のiPhone状態から導く。失敗は古い操作・宛先消失・現在アカウントなし・操作不可・到達不能に分け、必要時はiPhoneを開くよう案内する。英語と日本語の標準SwiftUI表示を用意する。

## 検証と未確認

共通操作への接続、宛先削除、ログイン変更、期限切れ、別通話への誤操作、重複タップ、切断後の遅い応答、長時間通話の操作時更新をunitで検証する。generic iOS/watchOS buildはSDKのコンパイル確認であり、Watchとの実配送・背景起動・ペアリング・ロック中の利用可否の証明ではない。WatchConnectivityの実機受入は[未確認事項](../../validation/未確認事項.md)へ残す。

[WCSession](https://developer.apple.com/documentation/watchconnectivity/wcsession)の背景転送は即時ではないため、開始・マイクONを`transferUserInfo`へ退避しない。[sendMessage](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:))によるWatchからiPhoneの背景起動と、マイクの利用・長時間継続は別条件として確認する。

Watch音声の媒体経路と長時間の電池消費は未実装・未受入。SessionManagerのWatch音声session・PCM入出力の共通基盤は追加したが、iPhoneとの媒体配送とWatch Appへの接続はまだない。通話処理をiPhoneに残すため、WebRTC binaryをWatchへ移植する工程は設けない。[TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)が定める音声配信・CallKit通話等の通信条件を確認する。ただし本製品は電話型通話にしないため、CallKitを音声実装の前提にせず、採用しない条件で成立する経路を評価する。WatchConnectivityの操作配送を連続音声の代用にしない。CarPlay専用画面・entitlementも本工程の実装ではない。

## 自動切断

Watchの開始操作は、iPhoneの共通通話処理へWatch利用を伝える。Settingsで通常利用とは別に保持した時間を使い、初期値は5分。13段階の値・期限・再接続の扱いは[自動切断](通信仕様.md#自動切断タイマー)へ従う。既に進行中の同じ通話への重複開始や、後からのミュート操作では期限を更新しない。現在の媒体はiPhoneであり、Watch自身の音声は別途残る。
