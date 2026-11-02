# iPhone依存のWatch操作

## 確定した操作範囲

Widgetとの違いは、Watchでは登録済みの通話先を選べることと、iPhone依存の音声入出力・押して話す操作を接続することである。2026-11-01の利用者指定を次の契約として固定する。実装済みの経路と実機受入の結果は下節で区別する。

| 項目 | 契約 |
|---|---|
| 通話先と開始 | iPhoneに保存済みの相手（個人）からWatch上で選択し、Watchの操作から開始する。毎回iPhoneを操作して先に開始することを求めない |
| 管理 | Watchではユーザー追加、グループ作成、メンバー追加を行わない。登録と管理はiPhoneに置く |
| 通話・音声処理 | 通話接続、複数参加者の混合、ミキサー、エフェクト、VADはすべてiPhoneが所有する。Watch独立通話・独自RTC接続・ミキサーを設けない |
| Watchの音声 | マイク音声をiPhoneへ渡し、iPhoneで処理済みの単一音声を受け取って再生する。必要最小限の音声入出力・符号化復号だけを持つ |
| 押して話す操作 | 押下中だけWatchの送話を許可する。解除・取消・中断・切断で閉じ、再接続だけでは開かない。通話と受信は押下ごとに作り直さない |
| 開始条件 | Watchから音声を開始できることが音声機能の採用条件。成立しない場合のリモコンでも、登録済み通話先の選択と開始は残す |

## 所有者と提供範囲

| 項目 | 現在の実装 |
|---|---|
| 通話の所有者 | iPhone本体の`AppCallOwner`と既存`IntercomViewModel`。Watchにアカウント・利用権・RTC・保存ユーザーの別台帳を作らない。製品としての対応範囲もiPhone通話の音声・操作端末に限定し、Watch単体動作・独自の通話処理・直接のRTC接続は提供しない（[製品要求](../../requirements/製品要求.md)） |
| 画面表示 | 通常時はアクセント色、iPhone未接続・音声停止・失敗時は黒のナビゲーション背景に接続先を見出し、状態を記号と文言で示す。通話先の行は電話の記号と名前で示し、種別情報を持たないため人物／グループを推測しない。押下送話は横幅を使った角丸の操作領域に表示する。録音チェックの単一ボタン`watchAudioCheckButton`は準備・実行中に停止、それ以外に開始を表示する |
| Watchの操作 | 保存済みユーザーの開始、現在通話の終了、Watchの押下中送話／通常のマイク切替、現在状態の更新。用途別許可がある保存ユーザーへの明示呼出し通知と、現在の呼出しの取消 |
| 通話先 | 既存`callTargets`を再利用。groupで会っただけの参加者と内部1対1groupを独立した宛先にしない。名前は本人名／端末側の別名をそのまま表示し、翻訳keyにしない |
| 音声 | WatchのSessionManager入出力とAACを、暗号化した端末pairでiPhoneの既存TX／合成済みRXへ接続。iPhoneの入力captureを開始せず、最終機器出力だけを消音する。実Watchの媒体成立は未受入 |
| 到達不能 | 操作をqueueへ積まず、未接続を表示する。接続復帰時に現在状態を取得し、古い開始・マイクONを自動実行しない |
| 着信 | iPhone宛APNsの標準転送を利用する。通知内の「iPhoneで応答」はiPhoneの既存通知検証と通話開始へ渡す。Watch上の通常tapはWatch Appを開くだけで、通知到着では通話を開始しない |

watchOS targetはiPhone依存の単一Appとし、最低OSは27.0。iPhone/iPad・macOSを含む各製品targetも同じ最低OSへ揃える。`WKApplication=true`、`WKCompanionAppBundleIdentifier=com.yowamushi-inc.RideIntercom.RideIntercom`、`WKRunsIndependentlyOfCompanionApp=false`。Watch音声にはマイク・ローカルネットワークの用途説明、`_ride-audio._udp`、標準のaudio background modeを設定する。APNs・CarPlay専用の外部登録は追加しない。

## 音声接続時の要求と現行の境界

音声合成・エフェクト・VADと通話処理はiPhoneが所有する。Watch側でAudioMixer graphを構築せず、複数参加者の音声を個別配送してWatchで合成する経路も設けない。Watchはマイク入力と、iPhoneで合成・処理した単一の受信音声の再生・操作に限定する。媒体接続に必要な入出力・符号化復号・押下解除時の送話停止はこの範囲に含む。

Watchの音声経路はAppまで接続済みだが、遠隔操作やローカル自動試験の応答時間を実Watch通話の遅延測定として扱わない。[製品要求](../../requirements/製品要求.md)では、iPhone経由の処理・複数段の通信により通常端末に少なくとも約100msを追加する見込みを許容している。通常端末と同じ約125msの総遅延基準は適用しない。100msは実測・固定下限・最大許容値のいずれでもなく、試作後に実際の追加量を測る。

押している間だけ話す操作はこの利用体験に合わせるが、AppleのPush to Talk／CallKitへの統合は行わない。押下解除時にWatchの送話を閉じることと、既に送信済みの音声が通信・再生時間の後に相手へ届くことは区別する。古い解除要求や再接続による録音再開は許さない。codecはApple標準AACの成立性を先に確認し、未測定の電池優位を理由にOpusを既定にしない。

## 実装済みの媒体接続

Watchの開始操作でマイク許可を確認し、非同期session activationの完了後にcapture／rendererを開始する。送話gateは閉じたまま、一時的なsession ID・256bit鍵・Bonjour endpointを作る。到達可能なWCSessionの明示開始要求にだけofferを載せ、iPhoneは既存のログイン・保存宛先・利用権・通話世代を確認して同じ通話へ結合する。一般表示用のapplication contextへ鍵を含めない。

[AudioDevice](../packages/Audio/AudioDevice.md)の`AudioDeviceConnection`を、既存SessionManagerのcapture／renderer backendへ差し込む。媒体・AACはpackageに置き、Appは準備・購読・終了と操作資格だけを所有する。codecは端末の実入力形式で構築し、非対応をOpus等へ黙って置換しない。endpointの準備と送信資源の待機には各5秒の上限を置く。送信資源のreadyは受信・再生の証明ではなく、Watch UIの通話状態はiPhoneの共通状態から表示する。一時的な通信不可では同じpairを維持し、古い音声を蓄積・再送しない。復旧時はiPhoneの合成済み受信出力だけを再許可し、Watchの送話は新たな押下／切替まで閉じる。fatalな準備・媒体・codec失敗ではpairを破棄し、明示操作から再準備する。

Watch入力も共通の`AudioInputStreamCapture`を通ってiPhoneの既存`AppAudioPipeline.processMicrophoneFrame`に渡り、iPhone側のVAD・音声処理・RTC送信を通る。iPhoneの受信graphにある`rx-output`の合成・処理済みmono PCMを共通rendererからWatchへ送り、`engine-output`だけを消音する。既存engineの時計を使い、追加のmix graph、周期render timer、背景維持専用の無音音声を作らない。

Watchのマイクは押している間だけ送話する（2026-11-01の利用者指示）。通常のマイク切替とモード選択は持たない。閉鎖時はローカル送話gateとnative入力配送を閉じ、部分AACの履歴を捨てる。押下の解除・取消、画面の暗転などinactiveへの移行、背景への移行、音声中断、接続断で閉じ、復帰だけでは再開しない。inactive中の新しい押下は受け付けない。接続済みのWatchで物理音声routeが変わった場合は、形式が固定されたnative入出力を止め、Watchからの再開始を案内する。一時的な媒体pathの復旧とは区別する。押下解除で通話・受信を作り直さない。Watchのnative入出力と遠隔backendは直接接続し、App独自の音声queueやcodecを置かない。端末間の音声callbackはpackageで待機量と100msの配送寿命を制限し、古い発話を追いかけて再生しない。この上限は追加遅延の目標ではない。

2026-11-01の追加指示として、Watchの押下／マイク切替をiPhoneのミュート状態へ連動させない。押下ごとにWCSessionの制御要求・応答待ちを発生させず、Watch内のマイク入力配送と送話だけを切り替える。iPhoneの既存VAD・通話・受信回路を継続し、少量の残る通信をなくすために操作遅延や制御処理を増やさない。

Watch利用中はiPhoneのマイクミュート操作を無効にし、Widget・Siri等の共通操作入口でも拒否する。以前のiPhoneミュート値をWatch入力へ適用しない。iPhone側は「Watchでマイクを操作」と表示し、Watchの送話状態を知っているかのようにON/OFFを表示しない。端末経路の切替時に必要な実効入力設定だけを適用し、押下ごとの状態同期・別のミュート台帳を作らない。

終了・ログアウト・別通話でpairと古い音声配送を破棄し、次の通常通話／Audio Checkに備えて元のnative backendへ戻す。Watch経路の失敗でiPhoneマイクへ自動移行せず、同じ通話を維持してWatchから再操作できる状態を返す。

Watchの録音確認では、録音中のフレーム数や有音サンプル数を進捗ごとにWatchへ公開せず、状態とsessionの変更を通知する。録音終了後に確定したフレーム数・有音サンプル数を公開する。録音中は未確定の数値や無音判定をWatchに表示せず、iPhone内の実カウンタと入力メーターは維持する。

## 画面構成

[デザイン](../../design/一般向け/画面構成とレイアウト.md#watch)に従い、`NavigationStack`の2階層とする。通話がある間は通話画面を前面に固定し、終了で一覧へ戻る。

| 画面 | 識別子 | 表示と操作 |
|---|---|---|
| 接続先一覧 | `watchDestinationList` | 「iPhoneに接続済み」、保存済みの相手（`watchTarget-{id}`、`person.fill`）。行タップで開始。呼出しの送信・取消は行のスワイプ操作（watchOSで長押しメニューの`contextMenu`が非推奨のため、デザインの長押しから置き換え）。footerに音声の注意書きを1回、末尾に更新。背景はaccentのグラデーション |
| 通話画面 | `watchActiveCall` | 戻るを隠し、左上（`topBarLeading`）に切断（`watchEndCallButton`）。押すと確認（「切断しますか？」とdestructiveの「通話を終了」）。中央に相手名と状態（`watchCallStatus`）。下半分いっぱいに送話パネル。音声停止・利用不能では背景を黒にする |
| 送話パネル | `watchHoldToTalk` | 角丸（`ConcentricRectangle`）の横長パネル。待機は「押して話す」（`mic`、淡いaccent）、押下中は「話しています」（`waveform`、voiceで塗る）、準備中は進行表示、音声停止は無効。押下の開始・解除で触覚。視差効果を減らす設定では記号の動きを止める |
| iPhone未接続／サインアウト | `watchMessage` | 黒背景に記号と案内。未接続は「もう一度試す」で更新 |

Digital Crownと`handGestureShortcut`には送話を割り当てない。文言はWatch専用のString Catalog（`RideIntercomWatch/Localizable.xcstrings`）で英語・日本語を切り替え、使われなくなったキーは削除する。検証ビルドのSimulatorでは`RIDEINTERCOM_WATCH_UI_FIXTURE`（`list`・`connecting`・`in-call`・`paused`・`signed-out`・`unreachable`）で各画面を表示し、iPhoneへは送信しない。

## 操作と状態の契約

| 接続点 | 契約 |
|---|---|
| `WatchControlMessage.swift` | Codableの操作要求／応答／表示snapshot。表示snapshotには音声・秘密・本人の認証資格を含めない。明示開始のofferだけが一時pair資格を持つ |
| `AppCallOwner+Watch.swift` | 現在ログインを`callModel()`で確認し、`startCall`・`endCall`・`setCallMuted`へ渡す。Watch音声選択中のphone mute要求は共通入口が拒否する。開始は別通話への切替を許可しない。開始資格・購入・24時間条件は既存処理の所有 |
| 参照 | 既存のaccountAccessID・connectionGeneration・groupIDから不透明な参照を作る。要求の参照を現在値と比較してから実行。Watch専用epochを増やさない |
| 期限 | iPhoneが発行したsnapshotを120秒有効とする。要求が遅延し期限切れなら実行しない。長時間通話では利用者の操作時だけ1回更新し、通話参照が変わっていなければ明示操作を行う。通話自体を120秒で終了しない |
| 重複 | 開始・終了は既存通話世代、ミュートはtoggleではなく指定したBoolで処理する。同じ指定値は既存処理で冪等。専用requestIDや永続重複台帳を追加しない |
| 削除・切替 | 実行時に保存相手を再解決する。相手削除後の新規開始を拒否し、成立済み通話の終了は許す。別ログイン・別通話・再接続前の要求を拒否する |
| `WatchPhoneBridge` | iPhoneで1つ保持しWCSessionをactivate。Observationで状態変更を検出し、通話参照・通話先・表示内容が変わった場合だけ`updateApplicationContext`へ最新snapshotを渡す。音量meter等からの再評価で発行日時だけが変わっても送信しない。activation・Watch切替時は再発行し、送信失敗値は送信済みにしない。明示操作の応答は有効期限を更新する。周期pollingを設けない |
| `WatchConnectivityClient` | activatedかつ到達可能なWCSessionの`sendMessageData`だけで要求する。activation／到達性変更／Watch前面復帰時に更新。接続切断で表示を外し、古い非同期応答を採用しない |
| `WatchControlClient` | 応答待ちに重複タップをqueueへ追加しない。古い応答が新しいcontextを上書きしない。送信受付だけで接続済み・マイクONと表示しない |
| 呼出し先と結果 | `canNotify`は現在の保存ユーザーの用途別許可から投影し、通常groupには付けない。iPhoneで要求時にSavedUserを再解決し、既存`notifications.send`へ渡す。既存outgoingのrequestID・固定status・取消可否だけを表示し、acceptedを配送・応答・通話成立と表示しない。古いrequestIDによる新しい呼出しの取消を拒否する |

通知応答の固定categoryは`RIDEINTERCOM_CALL_REQUEST`、actionは`RIDEINTERCOM_RESPOND_ON_IPHONE`。iOSで`UNNotificationAction`のoptionsを空として登録し、Watchへ転送された通知の背景actionを元の通知先であるiPhoneで処理する。Appの通知bridgeから[共通の通知検証](通知仕様.md)へ渡し、受信ON・recipient・120秒期限・取消・保存関係・ログイン世代・別通話の維持を再利用する。未知action・dismiss・別categoryのactionを通話開始へ渡さない。Watch側に通知資格、APNs token、応答待ちqueue、再送・pollingを追加しない。

この配送先の区別は[Appleのaction規則](https://developer.apple.com/documentation/watchos-apps/adding-actions-to-notifications-on-watchos)による。通常tapがWatch Appを開く動作は[標準通知の表示仕様](https://developer.apple.com/documentation/watchos-apps/presenting-notifications-on-apple-watch)と分ける。「iPhoneで応答」の登録はWatch自身の音声やOS背景起動の実機成立を保証しない。

snapshotの現在通話は閲覧中groupと分ける。表示状態は未ログイン、待機、接続待ち、通話中、音声一時停止、音声利用不能を区別し、現在のiPhone状態から導く。失敗は古い操作・宛先消失・現在アカウントなし・操作不可・到達不能に分け、必要時はiPhoneを開くよう案内する。英語と日本語の標準SwiftUI表示を用意する。

## 接続境界と実機受入の条件

2026-11-01の再確認。通話処理はiPhoneだけが持ち、Watchはそのマイク・スピーカーと操作端末として接続する。この所有関係と経路は当初からの要求であり、選択候補ではない。Watch単体動作・Watch独自の通話処理・グループ参加・直接のRTC接続は開発対象にしない。以下の境界をApp接続へ適用した。ローカル音声往復と実Watchの受入を区別する。

| 境界 | 実装・受入の条件 |
|---|---|
| 通話の所有 | iPhoneの既存RTC接続・認証・利用権・通話世代を使う。Watchを別の参加者やWebRTC接続として追加しない。Watchから開始した音声は明示終了または自動切断期限まで入出力ともWatchに固定し、iPhoneのマイク・スピーカーへ暗黙に切り替えない。音声機器の切替・復旧で24時間の起算点や自動切断期限を更新しない |
| 起動中の継続 | Watch Appを開いたまま手首を下げ画面が暗くなっても音声と受話を継続し、送話は暗転で閉じる。押下のrelease・操作取消はWatchローカルの送話gateだけを閉じ、受話と通話を維持する。腕下げによる暗転と別画面へ移った背景状態を区別する |
| 通信とnative経路 | 相手の無音・packet欠落・省電力のための音声通信停止を、Watchのnative入出力経路の破棄と結び付けない。無音を出せる再生状態を維持し、次の受話で再初期化を要求しない。この条件と暗転中の受話継続、押下解除中の受話継続を回帰・実機受入で確認する |
| 音声session | Watchでは[非同期activation](https://developer.apple.com/documentation/avfaudio/avaudiosession/activate(options:completionhandler:))の実完了を待つ。途中の終了・中断・新開始に古い完了を適用せず、設定変更のたびのactivationや周期的な再activationを設けない。指定できない周波数・バッファ長・出力先等は要求値と実適用を区別する |
| 媒体と秘密 | WatchConnectivityは操作と接続準備に限定する。既存のNetwork UDP配送・音声packetを再利用し、認証・暗号化・鮮度破棄をpackageに閉じる。グループ鍵やアカウント資格は渡さず、現在のペアと通話だけに使う一時的な媒体資格を別の明示契約で扱う。一般の表示snapshotに秘密を追加しない |
| 既存packageとの差 | 再利用対象はiPhone–Watch間のNetwork配送・PCM入出力であり、WatchへNative WebRTCやグループ通話を移植しない。既存moduleのMultipeer専用CFNetwork/socket処理と、Watch非対応のAudio Toolbox・Audio Unit処理を分離し、必要な処理だけをWatchで使える境界を確認する |
| 入出力と時計 | SessionManagerのcapture/render backend境界を使う。mix・エフェクト・VADはiPhoneに置き、Watch側にはAudioMixer graphを作らない。iPhoneで合成済みの単一音声をWatchへ送り、Watchは最小限の入出力・媒体codec・押下送話gateを持つ。iPhone側のmix時計とWatch側の再生時計の差・二重bufferを接続境界で検証し、出力callbackを転送できるだけで完了にしない |
| Watchの遅延受入 | 通常端末に対して少なくとも約100ms追加する設計上の見込みを許容し、通常の約125ms総遅延ゲートを適用しない。iPhone経由・各通信段・codec・再生待ちの実測を分け、押して話すUIで許可状態と発話・受信の時間差が理解できることを確認する。固定100ms待ちを追加する実装にはしない |
| codecと電池 | Apple標準AACを優先候補として公開APIによるdecodeを検証する。特定形式解析APIの不在とAAC全体の利用可否を区別する。Opusへの変更は十分な電池消費上の利点を比較して判断し、実機未測定の優位を採用根拠にしない |
| ミュート | Watch選択中はiPhoneマイクを同時送信しない。押下の解除・取消・中断・媒体断はWatch内の送話gateを閉じ、iPhoneの応答待ちを必要としない。受信と通話は維持し、遅れた要求・復旧だけではgateを開かない |
| 実機の境界 | [TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)の制限はSimulatorで再現されない。CallKitなしの双方向音声、無音待機、画面消灯、iPhone不在・再到達、経路変更、電池消費を実Watchで確認する。activation成功・コンパイル成功をこの受入の代わりにしない |

#### 背景継続の成立条件と確認待ち

iPhoneのローカルマイクを使わないことと、既存音声エンジンの時計を使わないことを混同しない。manual renderingを必須とした先行判断は撤回する。実装は、既存AppAudioReceiverの実通話音声の合成・処理結果を最終端末出力前のPCM sinkからWatchへ渡し、iPhoneの最終出力だけを消音する構成。追加のミキサー・周期timer・無関係な無音音声による延命を設けない。このApp接続は背景継続の実証ではない。

| 項目 | 現在の判断 |
|---|---|
| 維持する要求 | Watchから通話先を選んで開始し、iPhoneが通話・合成・DSPを所有する。WatchにMixerを追加しない。Widgetは配置時に指定した通話先だけのリモコンとする。両方でユーザーやグループの追加管理を行わない |
| 開始の入口 | [WCSession.sendMessage](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:))によるiPhoneの背景起動と、その後の音声activation・継続実行は別の条件として扱う |
| 開始の確定条件 | iPhoneでの事前開始は認めない。Watch自身から開始できなければWatch音声は採用せず、iPhone通話のリモコンに限定する。その場合も選択・開始は必須。iPhone前面開始やOS進捗表示を必要とするBGContinuedProcessingTask方式は採用しない |
| 次の成立確認 | 既存native音声経路を使うローカルの往復を検証済み。背景・ロック中の開始、自然な無言区間、画面消灯後の継続と復旧は実機の受入へ残す。消音だけを根拠に背景実行可能／不可能のいずれとも断定しない |

package単独の検証後にAppへ接続した。旧通話／アカウントのpacket、重複・順序逆転・過大payload・暗号化失敗を自動試験で拒否する。音声の再送やTCP／WebSocketへのfallbackを追加して遅延を隠す構成にはしない。

## 検証と未確認

共通操作への接続、宛先削除、ログイン変更、期限切れ、別通話への誤操作、重複タップ、切断後の遅い応答、長時間通話の操作時更新をunitで検証する。generic iOS/watchOS buildはSDKのコンパイル確認であり、Watchとの実配送・背景起動・ペアリング・ロック中の利用可否の証明ではない。WatchConnectivityの実機受入は[未確認事項](../../validation/未確認事項.md)へ残す。

[WCSession](https://developer.apple.com/documentation/watchconnectivity/wcsession)の背景転送は即時ではないため、開始・マイクONを`transferUserInfo`へ退避しない。[sendMessage](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:))によるWatchからiPhoneの背景起動と、マイクの利用・長時間継続は別条件として確認する。

Watch AppからiPhoneへの媒体配送と音声入出力は実装した。長時間の電池消費と実機の媒体成立は未受入。SessionManagerのWatch音声session・PCM入出力を使い、出力機器との形式差は同packageのnative変換で吸収する。通話処理をiPhoneに残すため、WebRTC binaryをWatchへ移植する工程は設けない。[TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)が定める音声配信・CallKit通話等の通信条件を確認する。ただし本製品は電話型通話にしないため、CallKitを音声実装の前提にせず、採用しない条件で成立する経路を評価する。WatchConnectivityの操作配送を連続音声の代用にしない。CarPlay専用画面・entitlementも本工程の実装ではない。

## 自動切断

Watchの開始操作は、iPhoneの共通通話処理へWatch利用を伝える。Settingsで通常利用とは別に保持した時間を使い、初期値は5分。13段階の値・期限・再接続の扱いは[自動切断](通信仕様.md#自動切断タイマー)へ従う。既に進行中の同じ通話への重複開始や、後からのミュート操作では期限を更新しない。媒体pairの再準備・入出力の切替だけではこの期限を更新しない。
