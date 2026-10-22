# 音声E2Eテスト

MacとiPhone Simulatorで別々のアプリプロセスを動かし、音声ファイルの発話が通信先の実AVAudioEngineのrender tapまで到達したことを波形で判定する。実装は専用の`RideIntercomAudioE2ETests`ターゲットと`RideIntercomAudioE2E` schemeに置き、通常の単体・結合テストとは独立させる。テストの起動・判定・証跡保存・終了処理にAIや画面操作は必要ない。

## 実行

Xcode、iOS Simulator runtime、プロジェクトの署名環境を[開発環境](開発環境.md)に従って準備する。初回のmacOS側のOS権限承認は開発環境の設定として済ませる。Simulatorのマイク権限は実行スクリプトで設定する。

```sh
python3 scripts/audio_e2e.py
python3 scripts/audio_e2e.py --matrix full
```

通常は両通信経路の`quick`を実行する。`--transport local`はMultipeer、`--transport webrtc`はローカルのサーバーモックと実WebRTCに絞る。切り分け用の`--matrix smoke`は既定設定だけを測る。`--codec pcm16` / `--codec opus`と`--isolation off`は診断用の上書きであり、全設定を検証した実績にはしない。`--seconds`は各発話区間の秒数で、既定8秒。無音を測る区間は2秒。

この開発機での両経路の実測は、build cache再利用時のquickが約3分54秒、fullが約17分30秒。初回buildやOS・機材の違いにより所要時間は変わる。測定結果は[検証記録](../validation/history/iOS音声E2Eと通話障害修復.md)を参照する。

| 範囲 | 測定する設定 |
|---|---|
| quick | AAC-ELD v2指定時の実選択、Opus、PCM16、48/24/16kHz、送信・受信master・受信peerのSoundIsolation、DynamicsProcessor、PeakLimiter、VADの3 preset、ducking、音量、出力muteとStream mode + speakerへの復帰 |
| full | quickに加え、3 codec指定×3 rate、AAC/Opusのbit rate下限・上限×3 rate、mode・speaker・明示echo cancellationの6通り、master/peer音量ゼロ、送信muteと復帰 |

マトリクスの正本はリポジトリの`scripts/audio_e2e_matrix.py`にある。各runの`scenarios.json`へ全条件を保存する。短い検証では既存のbuild productsを使い、設定区間ごとにアプリを再ビルドしない。

音声sessionはSettingsと同じMode・Use Speaker・Echo Cancellationの操作関数を使う。iOS側でBurst modeはspeakerと明示echo希望の4通り、Stream modeはspeaker ON/OFFの2通りを通す。MacはCoreAudio固有のデバイスIDを持ち、iOSのbuilt-in-speaker指定を持たないため、相手側として実system default出力を使う。表示用の値だけでなく、SessionManagerへ渡されたmode・speaker・echo希望と、OS操作が失敗していないことも検査する。物理機器が必要なBluetooth・有線デバイス選択はSimulatorの設定網羅に含めない。

## 通る経路と判定

合成発話WAV → iOSの実capture clockとhardware format → AudioCore → VADGate → AudioMixerの実AudioUnit chain → Codec → RTC認証・暗号化・MultipeerConnectivityまたはWebRTC DataChannel → 相手のCodec → peer/master/output mixer → SessionManagerの実出力engine → render tapを通す。

iOS側は実`SystemAudioInputStreamBackend`でcaptureを起動し、音声処理・OS形式・callbackの時間間隔を使う。callbackのマイクsampleは直ちに破棄し、同じ形式と長さのfixture発話へ置き換える。Mac側は20msのfixture入力を使う。人の発話やマイクに入った環境音を保存・送信しない。実機のマイク音響品質、スピーカーの空気振動、Bluetoothや無線干渉の試験は別に必要である。

VoiceProcessingIOについて、このE2Eが保証するのは有効化・無効化・mute・ducking・session profile変更時にOSのI/Oが動き続けること。fixtureはcapture callbackで差し替えるため、ハードウェア側のAECによるエコー低減量やマイク雑音除去の品質は測定しない。AppのAudioMixer上のSoundIsolation / DynamicsProcessor / PeakLimiterにはfixture発話自体を通す。

双方には異なる声・文章を渡す。受信renderの750ms発話断片を異なる3箇所（計2.25秒）で照合する。8kHzへ変換した信号の周波数帯域ごとの時間変化を使い、音量・固定的な音色の変化を除いて相手の発話との相関が0.45を超え、自分の発話より0.10以上強く一致することを要求する。VADが抑止する静かな区間は全区間平均に含めない。これは発話の到達判定であり、自然さ・明瞭度の品質点数ではない。無音・別話者・雑音を拒否し、遅延・音量変化・フィルター・非線形変形を受けた既知発話を識別する事前試験と、実iOS音声session profileの事前試験も毎run実行する。packet数やマイクメーターだけでは合格しない。mute区間は実renderが無音になること、その後は再び発話が届くことを確認する。

コーデックの要求と実選択は別に記録する。AAC-ELD v2はOSの変換器を作れても実変換に失敗する場合がある。実encode/decode能力判定で非対応なら既存仕様のPCM fallbackを試験し、AAC成功とは報告しない。

## 再利用と後片付け

通常実行では管理情報に記録した専用Simulatorを1台だけ再利用する。終了時に停止し、毎回端末を増やさない。build cacheも既定の`/tmp/RideIntercom-AudioE2E-Build`に再利用する。`--build-root`で場所を変えられるが、Xcodeの同期folderが生成物を取り込まないようリポジトリ外を指定する。

成功・失敗・timeout・SIGINT・SIGTERMでは、起動したコマンドのprocess groupと、記録した実行ファイルの完全なパスに一致するMac test hostを終了し、専用Simulatorを停止する。名前だけの`pkill`や`simctl shutdown all`は使用しない。二重実行はlockで拒否する。SIGKILLや電源断で終了処理自体が実行できなかった場合も、次回起動でjournalに記録した資源だけを回収する。

```sh
# CI等で今回作った端末を終了時に削除する
python3 scripts/audio_e2e.py --matrix quick --ephemeral
# 管理対象のアプリを終了し、再利用端末も削除する
python3 scripts/audio_e2e.py --cleanup-only
```

再利用用と一時実行用の所有情報は`/tmp/RideIntercom-AudioE2E-<uid>/`に置く。`--cleanup-only`はbuild cacheと検証証跡を消さない。

## 証跡

標準出力の`Evidence:`が保存先を示す。`--output`で新しい空の保存先を指定できる。同じrunを上書きしない。

| ファイル | 内容 |
|---|---|
| results.json / results.tsv | build、実行、受入判定、後片付けの成否と秒数 |
| measurements.json | 全通信経路・全端末・全設定の発話照合、packet数、render数、peak、要求／実選択codec。各設定の実測が揃わない場合も失敗扱い |
| configuration.json / scenarios.json | run識別子、入力境界、通信経路、設定区間 |
| source-manifest.json | HEAD、Swift・テスト・スクリプト・project・発話fixtureのSHA-256。buildから受入までにsourceが変わると失敗扱い |
| local-mac.xcresult / local-ios.xcresult / webrtc-mac.xcresult / webrtc-ios.xcresult | 通信経路・端末別の独立したXCTest結果 |
| attachments-<通信経路>-<端末> | 設定区間ごとのJSON測定値、実render WAV、終了時の状態 |
| simulator-id.txt | 実行に使用した端末の識別子 |

成功判定には両側で専用E2Eが実際に1件ずつ完了し、失敗・skipがないことを要求する。後片付け失敗も終了コードを非ゼロにする。実行結果・未確認範囲は[検証状況](../validation/README.md)へ記録する。

## Fixture

同梱WAVはmacOSの音声合成で生成した48kHz・mono・PCM16の英語発話である。`speech.wav`はSamantha、`reply.wav`はDanielを使い、別の文章を発話する。実行のたびに音声合成や外部サービスを呼ばず、同じWAVを繰り返す。

## サーバーモックの範囲

Mac側のテストターゲットが`127.0.0.1`だけでWorker API / WebSocket membership / SFUを起動し、終了時に全connectionを閉じる。資格はrun固有のfixture値であり、実Cloudflare資格・外部サービスは使わない。

| 境界 | 実際に通るもの |
|---|---|
| アプリ | App-owned adapter、RTC RouteManager、CloudflareRealtimeSignalingClient、URLSession HTTP / WebSocket、WebRTCNativeEngine |
| 媒体 | 両端末と模擬SFUの間の実ICE / DTLS / SCTP。信頼性あり制御channelと信頼性なし音声channel |
| 模擬SFU | 同梱WebRTCエンジンで受信した暗号化済みgroup envelopeを相手の接続へ転送。発話の生成・復号・decodeをしない |
| 模擬Worker | join / publish / pull / renew / deleteとmembership通知。実Cloudflareの運用認証・quota・TURN・請求の検証は含めない |
| 起動制約 | localhostへのHTTPだけを使い、既存のRTC clientのlocalhost許可範囲を利用。製品のHTTPS設定UIは変更しない |

WebSocketのhandshake / framingは[RFC 6455](https://www.rfc-editor.org/rfc/rfc6455)に従う。テストサービスは2参加者のmembership通知に必要な範囲だけを実装し、汎用WebSocketサーバーとして公開しない。

物理iPhoneのマイク・Bluetooth・ロック中の動作と、実Cloudflareの運用結果は、このSimulatorとサーバーモックの結果で代用しない。
