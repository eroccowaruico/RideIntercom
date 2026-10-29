# 音声E2Eテスト

MacとiPhone Simulatorで別々のアプリプロセスを動かし、音声ファイルの発話が通信先の実AVAudioEngineのrender tapまで到達したことを波形で判定する。実装は専用の`RideIntercomAudioE2ETests`ターゲットと`RideIntercomAudioE2E` schemeに置き、通常の単体・結合テストとは独立させる。テストの起動・判定・証跡保存・終了処理にAIや画面操作は必要ない。

## 実行

Xcode、iOS Simulator runtime、プロジェクトの署名環境を[開発環境](開発環境.md)に従って準備する。初回のmacOS側のOS権限承認は開発環境の設定として済ませる。Simulatorのマイク権限は実行スクリプトで設定する。

```sh
python3 scripts/audio_e2e.py
python3 scripts/audio_e2e.py --matrix full
```

通常は両通信経路の`quick`を実行する。`--transport local`はMultipeerによる認証・制御と別のUDP音声経路、`--transport webrtc`はローカルのサーバーモックと実WebRTCに絞る。切り分け用の`--matrix smoke`は既定設定だけを測る。`--codec pcm16` / `--codec opus`と`--isolation off`は診断用の上書きであり、全設定を検証した実績にはしない。`--seconds`は各発話区間の秒数で、既定8秒。無音を測る区間は2秒。

この開発機での両経路の実測は、build cache再利用時のquickが約3分54秒、fullが約17分30秒。初回buildやOS・機材の違いにより所要時間は変わる。測定結果は[検証記録](../validation/history/iOS音声E2Eと通話障害修復.md)を参照する。

| 範囲 | 測定する設定 |
|---|---|
| quick | 実AAC-ELDの符号化・復号、Opus、PCM16、48/24/16kHz、送信・受信master・受信peerのSoundIsolation、DynamicsProcessor、PeakLimiter、VADの3 preset、ducking、音量、出力muteとStream mode + speakerへの復帰 |
| full | quickに加え、3 codec指定×3 rate、AAC/Opusのbit rate下限・上限×3 rate、mode・speaker・明示echo cancellationの6通り、master/peer音量ゼロ、送信muteと復帰 |
| identity | 20秒以上の全文照合。既定設定、PCM16で送信Isolation無効、Opusで送信Isolation無効を比較。英語・日本語・間と相槌を含む会話を別runで実行する |

マトリクスの正本はリポジトリの`scripts/audio_e2e_matrix.py`にある。各runの`scenarios.json`へ全条件を保存する。短い検証では既存のbuild productsを使い、設定区間ごとにアプリを再ビルドしない。

音声sessionはSettingsと同じMode・Use Speaker・Echo Cancellationの操作関数を使う。iOS側でBurst modeはspeakerと明示echo希望の4通り、Stream modeはspeaker ON/OFFの2通りを通す。MacはCoreAudio固有のデバイスIDを持ち、iOSのbuilt-in-speaker指定を持たないため、相手側として実system default出力を使う。表示用の値だけでなく、SessionManagerへ渡されたmode・speaker・echo希望と、OS操作が失敗していないことも検査する。物理機器が必要なBluetooth・有線デバイス選択はSimulatorの設定網羅に含めない。

## 通る経路と判定

合成発話WAV → iOSの実capture clockとhardware format → AudioCore → VADGate → AudioMixerの実AudioUnit chain → Codec → RTC認証・暗号化・UDP datagramまたは再送なしWebRTC DataChannel → 相手のCodec → peer/master/output mixer → SessionManagerの実出力engine → render tapを通す。

iOS側は実`SystemAudioInputStreamBackend`でcaptureを起動し、音声処理・OS形式・callbackの時間間隔を使う。callbackのマイクsampleは直ちに破棄し、同じ形式と長さのfixture発話へ置き換える。Mac側は10msのfixture入力をuserInteractiveのstrict timerで供給する。capture時刻は各区間の開始を表し、区間の全sampleを取得し終えてから渡す。未来のsampleを先送りして遅延を小さく測らないことをMacの事前試験で確認する。人の発話やマイクに入った環境音を保存・送信しない。実機のマイク音響品質、スピーカーの空気振動、Bluetoothや無線干渉の試験は別に必要である。

VoiceProcessingIOについて、このE2Eが保証するのは有効化・無効化・mute・ducking・session profile変更時にOSのI/Oが動き続けること。fixtureはcapture callbackで差し替えるため、ハードウェア側のAECによるエコー低減量やマイク雑音除去の品質は測定しない。AppのAudioMixer上のSoundIsolation / DynamicsProcessor / PeakLimiterにはfixture発話自体を通す。

双方には異なる声・文章を渡す。従来の到達判定は、受信renderの750ms発話断片を異なる3箇所（計2.25秒）で照合する。8kHzへ変換した信号の周波数帯域ごとの時間変化を使い、音量・固定的な音色の変化を除いて相手の発話との相関が0.45を超え、自分の発話より0.10以上強く一致することを要求する。この判定だけでは良い断片を選べば合格するため、途中の途切れや音声の同一性を保証しない。

非mute区間には、録音全体の時間順を維持する連続性判定も必須とする。network試験では2秒の安定待ち後の録音に対し、繰り返し再生した基準音声との時間位置を全体で一度だけ決定する。区間ごとの遠い位置への再探索や時間伸縮は行わず、欠落・繰り返し・順序入れ替えを隠さない。音量と固定的な音色変化を除いた16帯域の時間変化を比較する。10ms特徴量で選んだ単一の全体offsetを、±15ms内の1ms RMS envelopeで精密化する。native codecの10ms未満の遅延を無音境界の欠落と誤認しないためであり、区間ごとの再整列や閾値の緩和は行わない。

| 指標 | 判定 |
|---|---|
| 全体の相関 | 0.65以上。低い場合は時間整合自体が弱いため、欠落率の厳密な解釈は避ける |
| 発話区間の一致 | 200ms窓を100ms刻みで評価し、相関0.65以上の窓が98%以上。局所の時間ずれ許容は±30ms |
| 発話中の低出力 | 基準の10ms RMSがピークの8%を超える部分を対象とし、推定音量比で補正した基準RMSの10%未満になる比率が0。共通解析器の旧基準1%以下だけでは受け入れず、実通信・単体native経路・codec・送信会話試験で0を追加要求する |
| 連続した低出力 | 上記の低出力が60msを超えて続かない |
| 測定不足 | 有効な発話が2秒未満、評価窓なし、実renderの長さ不足、非有限sampleは合格にしない |

この閾値はリポジトリの回帰検出基準であり、知覚品質の標準スコアや発話内容の文字認識率ではない。元音声の自然な間は低出力比率から除外する。無音・別話者・雑音に加え、100ms周期欠落、途中500msの無音、1秒の繰り返し、順序入れ替えを拒否し、固定遅延・音量変化・フィルター・非線形変形を許容する事前試験を実行する。mute区間は実renderの無音、その後は発話と連続性の復帰を確認する。

1ms RMS区間の境界は実sample rateから毎回求める。44.1kHzを毎区間44sampleへ切り捨てると20秒で約45msの解析時計誤差になるため、44/45sampleの区間で本来の時計を保つ。既知の固定offsetを持つ44.1kHz出力の正例と、欠落・重複の負例を同じ閾値で事前検査する。

双方向試験は最終出力に加え、復号直後と受信Mixer直後の同一性、送受信時刻、出力予約量を記録する。MacとそのSimulatorの共通host clockで相手のcaptureから最終renderまでの遅延を求め、一方が失敗しても他方の測定値を保存する。JSON traceの直列化・相槌解析・WAV保存は通話actor外で行い、証跡保存による音声待ちを作らない。

受信観測は`processReceivedAudio`境界で本番の`AppAudioPipeline.processReceivedAudioPacket`を一度だけ呼び、その戻りPCMを保存する。途中から別decoderを起動して復号を重複実行しない。UIの受信通知・音量表示は通常どおり流し、観測のために音声をMainActorへ戻さない。

連続性不合格でも残りの設定区間を測定してWAVとJSONを保存し、最後にテストを失敗させる。接続喪失や処理不能はその時点で失敗する。保存WAVは判定に使った同じsnapshotから書き出す。

```sh
python3 scripts/audio_e2e.py --matrix identity --speech-pair english
python3 scripts/audio_e2e.py --matrix identity --speech-pair japanese
# iOSの実Mixer→PCM16 encode/decode→実出力を1プロセスで測定する
python3 scripts/audio_e2e.py --pipeline-only
```

`--pipeline-only`はRTC・VAD・送信Isolationを通さず、日本語発話を20ms / 100ms周期でAppAudioPipelineへ渡す。各条件で2秒の安定待ちと20秒の測定を行い、同じ連続性判定、実出力WAV、処理エラー、再生予約リセット回数を残す。通信を外しても欠落するかを切り分ける試験であり、ネットワーク試験の代用ではない。

コーデックの要求と実選択は別に記録する。現行AACはnative AAC-ELD monoであり、AAC条件では実選択がAAC-ELDかつfallback=falseを要求する。旧AAC-ELD v2の非対応時にPCMへ代替した結果はAAC成功として数えない。

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
| pipeline-measurements.json | `--pipeline-only`の20ms / 100ms入力周期別の連続性、再生予約リセット、処理失敗 |
| configuration.json / scenarios.json | run識別子、入力境界、通信経路、設定区間 |
| source-manifest.json | HEAD、Swift・テスト・スクリプト・project・発話fixtureのSHA-256。buildから受入までにsourceが変わると失敗扱い |
| local-mac.xcresult / local-ios.xcresult / webrtc-mac.xcresult / webrtc-ios.xcresult | 通信経路・端末別の独立したXCTest結果 |
| attachments-<通信経路>-<端末> | 設定区間ごとのJSON測定値、実render WAV、終了時の状態 |
| simulator-id.txt | 実行に使用した端末の識別子 |

成功判定には両側で専用E2Eが実際に1件ずつ完了し、失敗・skipがないことを要求する。後片付け失敗も終了コードを非ゼロにする。実行結果・未確認範囲は[検証状況](../validation/README.md)へ記録する。

## Fixture

同梱WAVはmacOSの音声合成で生成した48kHz・mono・PCM16の発話である。実行のたびに音声合成や外部サービスを呼ばず、同じWAVを繰り返す。実際の利用者の会話は含まない。

| ファイル | 声・生成条件 | 長さ |
|---|---|---|
| speech.wav | Samantha、英語 | 約4.48秒 |
| reply.wav | Daniel、別の英語文 | 約3.57秒 |
| speech-ja.wav | Kyoko、日本語、`say -r 180` | 約13.70秒 |
| reply-ja.wav | Reed（日本語）、別の日本語文、`say -r 210` | 約13.90秒 |

日本語入力は2026-10-29に`/usr/bin/say -v <voice> -r <rate> -o <file.aiff> <text>`で生成し、`afconvert -f WAVE -d LEI16@48000 -c 1`で変換した。原文は以下の通り。

> 次の信号を右に曲がってください。橋を渡ったら、広い駐車場で待ち合わせましょう。後ろの二人も聞こえていますか。ゆっくり進むので、安全なところで返事をしてください。

> こちらは全員そろっています。少し風が強くなりました。トンネルを抜けてから、青い看板の手前で止まります。三人目は赤い自転車です。到着したら、もう一度連絡します。

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

## 低遅延・微小不連続・会話の自動検証

```sh
# 実iOS capture → VAD → TX isolation → codec → RX → hardware output、3音声×3codec
python3 scripts/audio_e2e.py --realtime-only
# native codecの全提供bitrateと、VAD/DSPを含む送信結合
python3 scripts/audio_e2e.py --codec-only
# 8人の実RouteManager / codec、仮想の複数配送経路、実hardware mix
python3 scripts/audio_e2e.py --group-only
# 再生を続けながらcodec / rate / isolationを切り替える
python3 scripts/audio_e2e.py --switches-only
# 1〜3秒の間と短い相槌を両端末で照合する（20秒以上）
python3 scripts/audio_e2e.py --matrix identity --speech-pair conversation --seconds 20
```

| 試験 | 追加した厳密な条件 |
|---|---|
| realtime-only | 3音声×PCM16/Opus/AAC。共通host clockと単一offsetでcapture→最終renderを測り、10msの計測余裕を加えて125ms以下。capture・actor配送・renderの破棄0、処理失敗0、全文同一性、会話の相槌一致 |
| codec-only / native | 4音声×22 codec/rate/bitrate条件。既存の全文判定に加えmissingActiveRatio=0、会話は各相槌も一致。fallbackを認めない |
| codec-only / transmit | 2声×入力quantum 256/960sample×isolation ON/OFF×3codecの24条件。実App送信VAD/DSP/codecを通して2周再生し、欠落0と相槌を検査 |
| group-only | 8人の独立時計、PCM/Opus/AACと異なるbitrate/rate、Localのみ・Internetのみ・両方の参加者。仮想経路の遅延・jitter・複製を実認証/暗号化/中継へ与え、全話者の順序・欠落・重複・codec境界と7話者同時mixを検査。1/2/3秒後の100ms相槌も残ること |
| switches-only | 12区間で送受信isolationとPCM/Opus/AAC・16/24/48kHzを変更。通常区間は微小不連続oracle、切替区間はsample段差0.04未満・無音120ms以下、内部破棄0・エラー0。全体を実render WAVで保存。別テストで共有I/Oを4回切替し、各操作500ms未満・復帰後の定常toneを検証 |
| 微小不連続の負例 | 全体の0.1%に当たる1ms欠落・1ms重複、単発clickを必ず拒否。単一正弦波fit後の最大2ms残差RMS≤0.006・sample段差≤0.10。平均誤差で薄めない |
| 相槌の負例 | 「うん」「ふん」を個別に消した音声を拒否。whole recordingで決めた同じoffsetの位置で相関≥0.65を要求し、別の良い断片へ探し直さない |

8人試験の配送は決定的な仮想経路であり、8台の物理無線機器・実Cloudflare SFUの測定ではない。ネットワーク2端末試験とは独立して必要とする。realtime-onlyも空気伝搬・Bluetooth・物理iPhoneの口から耳を測った結果ではない。native SoundIsolationのalgorithmic latencyは有効な段数に応じて加算されるため、任意に重ねた設定や全ネットワークで125msを保証するものではない。

測定JSONは各専用modeでもpipeline-measurements.jsonに集約する。codec-onlyは2件、他の単独modeは1件の専用XCTest完了と全scenarioの測定存在を必須にする。preflightはiOSの従来の負例・micro gap・相槌負例・native sessionの計5件と、Macのfixture時刻検査2件を必須にし、skipは認めない。packet到着・capture・OS制御の時刻traceはE2E専用attachmentへ保存し、本番のframeごとのログには追加しない。

conversation-ja.wav（Kyoko、約16.38秒）とconversation-reply-ja.wav（Reed、約14.89秒）は1/2/3秒の休止と「うん」「ふん」を含む。原文・各発話の正確な開始終了はFixtures/conversation-manifest.json、再生成はscripts/build_conversation_fixtures.pyが正本。毎回のテストでは同梱WAVを使う。

## ビルド成果物の再作成

既存のbuild productsに問題がある場合は`--clean-build`を指定し、同じDerivedData内でcleanしてから再構築する。別のcacheを使う場合も`--build-root`だけを変更する。bundle identifierや署名方式を実行ごとに変更せず、OSの許可リストを増やす方法を復旧策にしない。local networkの拒否とbuild／hostの不整合は結果を分けて記録し、確認していない原因を権限不足と決めつけない。

録音probeのsample領域は開始前に確保・初期化し、音声callback内で配列の拡張やcopy-on-writeの大きなコピーを行わない。snapshotは記録済みprefixをrender用lockの外で複製し、設定区間の境界はsample数だけを読む。snapshotとresetは同じ試験ownerが順に行い、解析中の領域を書き換えない。iOS captureの時刻不連続も測定JSONへ残し、内部ringのdrop counterとは別に検出する。

fixtureの再生位置は最初のcapture時刻と現在のcapture時刻の差から求める。native I/Oが中断した場合、その区間のsource sampleを省略し、その後の発話全部を後ろへずらさない。10msの欠落で正確に10ms分のsource sampleを省略し、以後の時計を保つ正例を事前検査する。欠落・繰り返しの拒否閾値は変更しない。

性能測定では`--configuration Release`を明示し、配布構成と同じ最適化を使用できる。既定のDebug構成も保持する。`configuration.json`へ構成名を記録し、音声同一性・欠落ゼロ・125msの判定は構成によらず同じものを適用する。Releaseの成功で既存のDebug失敗を成功へ書き換えない。テストから内部APIを参照するため`ENABLE_TESTABILITY=YES`のみ明示し、音声経路やbundle identifierを変更しない。

MacとSimulatorは同じMacのCoreAudio serviceを共有する。二つのhostのnative graph初期化を同時に開始せず、最初のhostが初期化完了を通知してから次を起動する。初期化は30秒を上限とし、失敗時は後続hostを起動せず所有processを回収する。通話開始後の双方向送受信・capture/render時計・判定閾値は変えない。
