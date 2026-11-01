# Watch音声のApp接続とデバイス分離

2026-11-01。基準commitは`adea0a73`。Watchの主要課題を優先し、iPhoneの既存通話・VAD・合成済み受信音声へ、Watch側のcapture／rendererとAAC・暗号化媒体pairを接続した。Watchに通話session、ミキサー、VADを追加しない。以下は作業段階ごとの証跡であり、実機での採用条件の達成を意味しない。

## App接続の基準検証

| 範囲 | 確認した結果 | 証跡 |
|---|---|---|
| 出力機器の形式差 | native PCM変換、任意block分割での時計維持、stop／形式変更の履歴破棄、再生予算。SessionManager Swift Testing63件＋XCTest1件成功 | `.validation/watch-output-conversion-20261101/` |
| OS 27音声API | 非同期activation／deactivation、throwするnative接続・再生開始、通知の更新。SessionManager64件＋XCTest1件、Watch／iOS SDK build成功、最終警告0 | `.validation/watch-audio-os27-api-20261101/final/` |
| 端末pairとApp | 実ローカル暗号化UDP＋native AACで、合成入力を既存phone TXへ渡し、合成済みRXを端末側へ返す。関連18件成功、phone input開始0・phone出力schedule0・期限不変を確認 | `.validation/watch-audio-app-pair-20261101/` |
| 全Mac Appの基準 | プラグイン抽出前の534テスト成功。失敗・skip・runtime warning0、検証前後の入力hash一致 | `.validation/watch-audio-baseline-macos-20261101/` |
| Watch App SDK | 初期App接続のgeneric Watch Simulator build成功。OS 27旧API警告は上記の後続package工程で解消 | `.validation/watch-audio-app-watch-sdk-20261101/` |

## 後続工程と受入境界

利用者の追加指示により、媒体・AACをAppから[音声デバイスpackage](../../spec/packages/Audio/AudioDevice.md)へ分離し、既存SessionManagerのbackend契約で差し替えた。package工程は`237de17`でコミットした。押下ごとのiPhoneミュート連動をせず、Watch利用中はiPhoneマイク操作を無効化し、以前のiPhoneミュート値も適用しない。後続Appの関連40テストは成功し、失敗・skip・runtime warningは0。旧phone mute=trueでも双方向音声が成立し、phone capture開始0・元backendへの復帰・通話期限の維持を確認した。証跡は`.validation/watch-audio-device-app-20261101/focused-ready/`。再点検では入力の不連続と状態配送も確認した。

Watch Simulator用の専用iPhone／Watchペアを所有journal `.validation/watch-simulator-pair.json`へ記録した。既存ペアを変更せず、標準CLIで実行・停止する。GUI操作を試験の条件にしない。

実Watchの背景・ロック中の開始、画面消灯、自然な無言区間、無線経路変更、追加遅延、長時間の電池消費は未受入。[TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)ではSimulatorが低レベル通信制限を再現しないため、Simulator成功を実機の成立証明としない。iPhoneで先に操作する条件、CallKit、背景維持用の別音声を採用した結果ではない。


## 再点検で修正した境界

| 巡回 | 確認・改善 |
|---|---|
| 初回 | AudioDeviceを既存capture/render backendへ接続し、Watchに独自の通話・mixerを置かず、iPhoneの音声処理を共用した。保存済みphone mute値とWatchのローカル送話gateを分離した |
| 二巡目 | 入力の途絶・形式変更で旧VAD preroll、DSP効果の履歴、未送出音声を持ち越す問題をREDで再現。AudioMixerの独立工程を`324820f`で凍結した後、AppのVAD・入力表示へ反映した。音量表示による同一Watch snapshotの再送もREDで再現し、日時だけの変化を配送理由にしない比較を追加した。Watch pairがない状態で無効なphone再開操作を表示しない |

## 自動検証の証跡

| 範囲 | 結果・境界 | 証跡 |
|---|---|---|
| 音声デバイスpackage | SessionManager 66件＋XCTest1件、AudioDevice Mac9件、Watch Simulator9件（引数別13実行）、iOS/Watch SDK成功。対象ソースのhashは一致。別作業のcommitによりHEADが変わったため全入力一致stageの失敗は保持し、対象一致の記録と分ける | `.validation/audio-device-package-20261101/final/` |
| DSP入力の不連続 | AudioMixer 63件＋XCTest7件、iOS SDK成功、警告0、対象hash一致。旧tail・端数の破棄と次発話のfresh効果との一致を検査 | `.validation/audio-mixer-discontinuity-20261101/review-final/` |
| App全体の中間確認 | Mac 533件成功、skip・runtime warning0、入力hash一致。以下の入力途絶修正より前の結果 | `.validation/watch-audio-device-app-20261101/macos-final/` |
| 検証スクリプト | Python125件とCloudflareスクリプト試験成功、入力hash一致。外部サービスへは接続しない | `.validation/watch-audio-device-app-20261101/scripts-final/` |
| Watch App起動 | Debug-Validationを標準DerivedDataでbuildし、専用Watch Simulatorへinstall・launch。5秒のログと同一process生存を確認後、Appと所有ペアを停止。compiler警告・検出runtime問題0。AppIntentsメタデータ対象なしのtool警告1件を区別する。ValidationはWCSessionを無効化するため、この結果は実操作配送・Watchからの音声開始の成功ではない | `.validation/watch-audio-device-app-watch-launch-20261101/` |
| 追加回帰のRED | 入力gap・format変更で旧preroll／音声／VADと入力表示が残る8assert、日時・meter変更による不要なWatch配送20assertを確認。初回import不足のcompile失敗とは分ける | `.validation/watch-input-gap-app-20261101/behavior-red/` |
| App追加回帰 | 54件成功、skip・runtime warning0、入力hash一致。実入力gapとPCM形式変更、入力途絶の表示失効、停止時の即時消去、Watch状態差分を検査 | `.validation/watch-input-gap-app-20261101/focused/` |
| Mac App最終 | 536件成功、skip・runtime warning0。製品入力は一致。実行中に外部のefficient-workスキル参照3文書だけが更新され、全入力一致stageは失敗のまま保持し、`input-boundary.json`で区別した。sandbox内の初回はprocess管理権限で未実行 | `.validation/watch-audio-app-final-20261101/macos-verified/` |
| iPhone Simulator App最終 | 522件成功、skip・runtime warning0、全入力hash一致。所有Simulatorを停止・回収。UI操作試験や実機背景開始の結果ではない | `.validation/watch-audio-device-app-20261101/ios-final/` |

Release音声E2Eの初回buildでは、別schemeの測定用targetに旧`rendersToHardware`引数の追従漏れとOS 27の旧tap API警告があった。測定前のbuild失敗として`.validation/watch-audio-app-final-20261101/realtime/`に保持し、音声の合格や実測失敗とは扱わない。API追従後の検証は別の実行先へ記録する。


API追従後のRelease再実行は`.validation/watch-audio-app-final-20261101/realtime-verified/`。Mac/iOS buildと事前検査7件は成功したが、本体は1件失敗、音声測定は0/9件。AURemoteIOが入力形式を2ch・0Hzとして開始に失敗し、`SystemAudioInputStreamBackend`が`invalidFrame`を返した。非同期activationの完了待ち・teardownのdeactivation待ちは実装済みで、未待機を原因とする証拠はなかった。遅延・音質は未測定として保持し、成功したApp単体522/536件とは分ける。対象ソースhashは一致、HEADのみ外部スキルcommitで変わった。所有SimulatorのShutdown・検証プロセス終了・共有lock解放を`cleanup-review.json`で確認した。


同じ所有Simulatorの限定診断では、音声処理を無効・有効にしたfresh sessionの各1回とも、native nodeが設定前から0Hzだった。非同期activation/deactivationは成功し、session自体は入力あり・48kHz。Macにも有効な入力機器が存在する。VP単独原因やactivationの待機漏れは裏付けられず、原因未確定としてこの診断で終了した。権限付与は自動承認審査で拒否されたため実行せず、既に許可済みのE2E hostを使いOS設定を変えなかった。診断用の仮テストを証跡へ保全してsourceから撤去し、productionは変更していない。証跡は`.validation/session-input-format-diagnostic-20261101/`。


## コアストーリーを通した区切り

利用者から、部品単位の改善が続き各機能のコアストーリーが優先されていないとの指摘を受け、既存の`WatchAudioIntegrationTests`一件を一連の操作へ強化した。`WatchControlClient`で保存先を取得・選択し、`startAudio`を共通所有者へ渡す。実ローカル暗号化AAC pairで既存phone TX/RXへ音声を渡し、Watch送話gateを閉じても受話・同一通話・期限が維持され、閉じた期間のPCMが送信されないことを確認する。再押下で送話を再開し、同じclientの`end`でpair停止・元backendへの復帰・遅い音声の遮断まで検査した。保存済みphone mute=trueの保持と、押下ごとの制御要求なしも確認した。

Mac・iPhone Simulatorで各1回成功し、失敗・skip・runtime warning0、HEADと全入力hash一致、所有Simulator停止を確認した。証跡は`.validation/watch-core-story-20261101/`。全体536/522件の確認後に変更したのはこの試験だけで、productionは同一である。

この区切りは合成Watch入力・offline phone graphを用いるアプリの操作／媒体契約の検証である。実Watch UI、実WatchConnectivity配送、native Watchマイク・スピーカー、背景開始・継続を通した利用体験の受入ではない。通常iOSマイクの0Hz問題も未解決として別に残す。Watch機能全体を完了にはせず、[現行の実行順](../../backlog/未実装課題.md#依存関係と取り組む順序)に沿って次の利用体験へ進める。

`efficient-work`を適用し、継続中のSol／medium担当を再利用して局所実装・診断・このstory試験を担当させた。主担当が要求と受入境界、差分、コミットを確認した。新しい管理役や重複レビュー役は追加せず、全体テストの再実行はproduction変更がないため行っていない。料金・削減率の推計はしていない。


## 通話から独立したWatchの録音確認

Watch Simulatorの実Appで、標準`AVAudioRecorder`による録音→`AVAudioFile`での読取→`AVAudioPlayer`での再生を確認した。`.playAndRecord`・`.default`・optionsなし、非同期activation完了後の録音で、48kHz mono・2秒・96,000 frames・非zero 92,119 samplesを取得し、再生完了delegateまで到達した。録音内容は証跡へ保存せず、測定後に一時CAFを削除した。証跡は`.validation/watch-native-recording-check-20261101/`。

同じcontrollerを使うDebug専用の入口を残した。Xcodeの通常DebugでWatch Appを起動し、`Recording Check`→`Record 5s`→`Stop`／`Play`で、形式・秒数・frames・信号取得有無・エラーを確認できる。ログイン・通話・音声packageを起動せず、CLI入口は隔離Validation build・明示fixture・Simulatorの全条件を要求する。Releaseでは録音controllerと画面をコンパイルしない。実機の操作・録音と、実際に聞こえたことは未確認であり、native再生APIの完了と区別する。

終了取消・停止後再生・次録音・ファイル削除を二巡目に点検した。最初のawaitより前に取消tokenを固定し、古いrecorderのdelegateと所有参照を停止時に外す。途中停止の12,024 framesとその再生、次の96,000 framesの録音／再生、遅い許可応答後の開始抑止、残CAF 0を確認した。6項目成功、対象source一致。証跡は`.validation/watch-recording-check-lifecycle-20261101/`。

削除失敗後に新しい録音が既存file参照・エラーを上書きしないguardも追加した。所有する合成ファイルのdirectoryを一時的に書込不可として実削除失敗を起こし、guardなしではエラー保持・許可要求抑止の2項目が失敗、修正後は6項目成功した。権限復元後の削除とdirectory回収も確認し、この試験ではマイク録音を開始していない。最終buildには既知のAppIntentsメタデータ対象なしwarningが1件あり、警告ゼロとは扱わない。成功時はcleanupでfileがnilになるため従来の録音経路を変えない。証跡は`.validation/watch-recording-cleanup-failure-20261101/`。

Recorder成功からWatchのnative入力一般が利用不能とはいえない。先のEngine試験はsession optionsも異なっていたため、APIだけの比較ではなかった。同じcategory・mode・optionsなし・deactivate→activate完了に揃えた直接Engine＋Sinkでも入力0Hz・0 frames・開始エラー-10851、標準input tapでは-10868となった。optionsだけの原因説とSinkだけの原因説は裏付けられず、AVAudioEngine入力の未成立を残す。証跡は`.validation/watch-native-engine-empty-options-20261101/`と`.validation/watch-native-input-tap-20261101/`。診断コードはsourceから撤去した。この区切り後、利用者から「Watchで録音したファイルを送るのではなく、iPhoneで録音する」と訂正された。次の必須項目はWatchマイクのlive音声を既存AudioDeviceでiPhone設定のAudioCheckへ届け、iPhone側で処理・録音し、Watchで再生すること。録音ファイル配送案は撤回し、その仮実装と専用REDテストを本体から除いた。Watch単体録音を通話streamやWatch会話E2Eの完了とは扱わない。

## iPhone設定の5秒録音と有限配送

2026-11-02、設定画面のAudio Checkを所有iPhone Simulatorで2回続けて実行した。両回ともnative入力は48kHz mono・240,000 framesの正確な5秒で、入力の配送dropと時刻gapは0、終了時にnative入出力の停止を確認した。有限録音ではsample予算で末尾をtrimし、通常通話に使う32 frame／100msの鮮度制限を適用しない。通常通話の既定配送条件は維持する。5秒ぶんの入力が得られない場合は、壁時計だけで短い録音を成功扱いせず、猶予後に失敗を表示する。

証跡は`.validation/phone-audio-check-route-20261101/finite-main-native-two-cycles/`。この実行はUIの録音→再生→完了と再開始に成功したが、native出力のMainActor観測配送で7,680／5,760 framesのdropを検出した。hardware実再生の欠落とは区別し、全量再生の波形受入は未完とした。2回目はnative出力のchannel数の違いも測定不能の原因だった。録音の5秒入力成立を、送信エフェクト・codec適用や5秒全量再生の成立へ読み替えない。

有限再生の観測はstartup／drainを含む最大6秒のsample予算で保持し、同一sample rateのstereo hardware出力はmonoへ平均して入力と比較する修正を追加した。`.validation/phone-audio-check-route-20261101/finite-output-green/`では、有限配送2件・ViewModelの5秒録音と再開始・stereo比較・故障注入後のgraph再構築の計5件が成功し、runtime warnings／skipは0。native再測定の`.validation/phone-audio-check-route-20261101/finite-output-native-two-cycles/`では、2回目の出力が242,880 frames／5.06秒、drop／gap 0で、先頭・中央・末尾の3窓の相関はすべて1.0、全量coverageが成立した。1回目は出力callbackの波形観測が0のため未測定であり、UI2回成功や入力両回5秒をもってnative再生両回の受入完了とはしない。録音前の送信pipeline構築と、録音から再生へのshared engine lifecycleを続く送信エフェクト工程で確認する。

Simulatorのnative入力確認では、Macの既定入力が48kHz、既定出力が別形式の場合の0callbackを再現した。同じ所有Simulatorだけのinput／outputを既存48kHz機器へ固定するとnative入力testは成功した。Macの既定設定は変更せず、Simulatorのinput／output／volumeを実行前の値へ戻し、所有Simulatorを停止した。証跡は`finite-main-pinned/pinned-audio-state.json`と`finite-output-green/pinned-audio-state.json`。pinしたsuite全体の故障注入testでAppleのAudio Unit parameter更新threadのSIGTRAPを1回検出した。同じtestの同pin条件単独実行は成功したが、再現条件や原因を未確定のまま保持する。


## 送信処理を使う録音と共有engineの開始順序

2026-11-02、Watchの未統合差分を保全して外し、通常のmain作業場所・標準DerivedDataでAppの録音修正を単独検証した。録音は現在の送信エフェクト・VAD・codecを通したpacketの復号結果を保存し、DSP／codecの末尾を回収する。VADで送らない区間は5秒の同じ時間位置に残す。送信処理の失敗を無音の成功にせず、明示ミュートによる正常な無音とは区別する。通常通話と録音で共有engineのgraph構築をnative入力開始より先にし、入力開始後にgraph再構築で入力callbackが止まる問題を修正した。

単独候補の影響回帰は65件中64件が成功し、残る1件は旧raw録音用のテストが実入力通知・送信処理を迂回していた。入力backendから実処理へ送るよう修正して限定再実行し、先頭・中央・末尾のtoneと有限再生の保持を確認した。製品コードはこの再実行前後で変更していない。証跡は`.validation/phone-audio-check-route-20261101/app-standalone-regression/`と`app-standalone-playback-regression/`。同回帰にはnative録音・再生の2回実行、通常通話のnative入力継続・再開始、送信失敗後のミュート録音再開始を含む。通話の認証・transportはfixtureであり、相手端末との会話成立を示すものではない。

設定画面の最終実行は`.validation/phone-audio-check-route-20261101/app-standalone-settings-final/`。両回とも処理後録音240,000 frames／5秒、native出力242,880 frames／5.06秒、入力・出力観測のdropとgapは0で、録音→再生→完了→再開始と終了時の入出力停止を確認した。ただし、この実行の処理後録音と出力はともに全て無音だった。非無音区間を基準にした5秒全体の波形照合は測定不能で、波形受入判定は不合格のまま保存する。UI成功やframe数を有音の全量再生の成立へ読み替えない。条件を固定した有音検証、Mac／iPad／Watchの各経路、実機の聴感・Bluetoothは引き続き未確認である。

診断用の独立したfresh AVAudioEngineマイク調査コードは、App本体のnative入力・再開始の回帰へ役割を移して撤去する。過去の失敗・成功証跡は維持し、専用Simulatorの音声設定復元・停止とsource対応を各runに記録する。


## 固定音声によるiPhoneの5秒全量再生

2026-11-02、既存の`SpeechFileInput`と`RideIntercomAudioE2E` schemeで、native入力の時計・routeを動かしながらマイクPCMの内容だけを既存の日本語音声fixtureへ置き換えた。Appの同じAudio Check・選択済みの標準送信設定・codecを通し、実TXを復号した5秒分の録音とnative出力を比較した。製品コード・fixture機構は追加せず、テスト1件で録音→再生→停止→再開始を2回実行した。

証跡は`.validation/phone-audio-check-route-20261101/audio-check-known-speech-final/`。両回とも処理後録音240,000 frames、有音232,992 samples。native出力は241,920／242,880 framesで、有音数は各回の録音と一致し、5秒全体のcoverage、相関1.0、正規化誤差0、無音区間残差0を確認した。実測した入力・出力観測のdropと時刻gapは0、共有engineの停止と2回目の再開始が成功した。波形の位置合わせ値約30／32msは、この比較のoffsetであり通話遅延の測定値ではない。

テスト1件成功、skip・runtime warnings 0、実行前後の362ファイルの指紋一致、Simulatorの入出力・音量の復元と停止を確認した。追加テストはコミット済みのApp APIだけを参照し、保全中Watch差分の新API・fieldに依存しない。Watchのoffer・linkを作らないため、Watch専用の分岐は通らない。GUIからの録音・再生操作は前節の設定画面テストで確認した。

成立した範囲は、制御した入力内容とnative時計の下での実TX5秒timeline→録音→native再生・再開始である。比較基準は送信処理後の復号音であり、元fixtureからTXまでの音質全体をこの比較だけで保証しない。実マイクの内容は置換しているため、実機マイクの音質・音響・Bluetoothは未確認である。Mac／iPad／Watchの各経路も別に確認を続ける。前節の環境マイクが全無音だった測定不能の結果は保持し、この成功へ書き換えない。


## Watch Simulatorの入出力固定と残るclock開始

2026-11-02、所有するWatch／iPhone Simulatorペアの停止状態を確認し、Watchの入出力を互換48kHz機器へ固定して一回検証した。既存CLIの一時的なnative入力専用分岐で、通話と同じSessionManagerのcapture／rendererと共有AVAudioEngineを使った。Phoneへの到達待ちを外し、AVAudioRecorderによる事前録音は使っていない。この試験の問いはnative入力の開始可否であり、5秒録音やWatch会話の受入ではない。

権限・session構成・活性化は成功し、実input hardware／client formatは以前の0Hzから48kHz monoへ変わった。capture開始は`applied`だったが、共有engineは停止状態、output hardware formatは0Hz／2chのままだった。renderer開始は`-10867`で失敗し、callback／frameは0で、native入力の成立判定は不合格である。packageの開始報告だけを入力取得の成功として扱わない。

証跡は`.validation/watch-native-input-pin-20261102/`の`observations.json`・`acceptance.json`・`source-correspondence.json`・`audio-pin-state.json`。診断sourceは`99111066`と同所の`diagnostic-source.patch`で再構成でき、`diagnostic-source-basis.json`に対応を残した。実行前後の362ファイルの指紋一致、入出力・音量の復元、Macの既定機器が不変であること、所有ペアの停止を確認した。入力形式の0Hz問題は固定条件で変化したが、出力とclockの開始原因は未確定であり、Simulator固有の不可能性やAPI変更の必要性を断定しない。

次の切り分けでは、稼働中のgraphへ出力nodeを初めて取得する影響と、再生データがない状態を区別する。インストール済みWatchSimulator SDKの`AVAudioEngine.h`は、出力nodeを初アクセス時に生成することと、watchOSではidle時のhardware自動停止が常に有効であることを説明している。今回のprobeは出力PCMを予約していないため、engine停止だけをnative入力APIの利用不能の証拠にしない。必要な比較を限定し、一時probeは役目を終えた時点で撤去する。


## Watch共有engineの入出力を開始前に準備する比較

2026-11-02、同じ所有Simulator・48kHz機器固定・session設定・AVAudioRecorder事前録音なしで、共有engineの開始条件を比較した。先の入力先行では後から取得した出力が0Hzだった。出力先行に変えた比較では出力48kHz／2chとengine開始は成立したが、後から開始する入力が0Hz／2chとなりcallbackは0だった。証跡は`.validation/watch-native-output-first-executed-20261102/`。起動順の単純な反転では解消しない。

出力node・player graph・2秒の有限無音bufferを入力開始前に用意した比較では、入力190 callbacks・97,280 frames、出力48kHz／2chが成立した（`.validation/watch-native-output-demand-corrected-20261102/`）。ただし、この組合せだけでは無音bufferの必要性を判断できない。先行したbuild失敗は`.validation/watch-native-output-demand-20261102/`に保持し、native実行の結果に含めない。

最後の比較では手動graphとPCM予約を除き、session活性化後・engine開始前に出力nodeと入力nodeの両方を取得してから、元のcapture→renderer順で開始した。入力48kHz mono・出力48kHz stereo、190 callbacks・97,280 frames・非zero 96,183 samples、入力時刻の幅2.016秒を確認した。engineとplayerの時計も動作し、両stream・engine・sessionの停止に成功した。この条件では事前録音・無音buffer・手動player接続は不要だった。native両I/Oを開始前に準備する条件を製品側へ適用する。

最終比較の証跡は`.validation/watch-native-both-nodes-prepared-20261102/`。各比較にsource差分と基準commitを保存し、実行前後362ファイルの一致、Simulatorの入出力・音量の完全復元、Macの既定機器不変、所有ペアの停止を確認した。成立したのはWatchのnative入力と出力時計の開始であり、出力波形・iPhoneでの5秒録音・Watchへの全量再生・会話成立は引き続き別に検証する。

SessionManagerに明示的な`AudioDuplexIO.prepare(engine:)`を追加した。停止中の両node準備だけを行い、単方向backendの生成・開始は変更しない。空実装でnode取得の期待が失敗するREDを確認後、既存を含む68テストが成功した。証跡は`.validation/session-duplex-prepare-20261102/`。このpackage単位はApp差分から独立しており、Watch Appへの接続は次の工程で行う。


## Watch Appへの接続と次の媒体開始境界

2026-11-02、Watchの実controllerでsession活性化後・capture開始前に`AudioDuplexIO.prepare`を呼ぶよう接続した。診断専用のnative入力分岐とAVAudioRecorder事前録音を撤去し、Debugの録音確認はWatch入力→iPhone処理・録音→Watch再生の既存App経路へ揃えた。操作状態は同一sessionで共有し、終了・取消・失敗では元のPhone backendへ戻す。Watchにファイル録音やMixerを置かない。

標準DerivedDataでiPhone／Watchをbuildし、所有Simulatorペアで実行した。最初の起動はログイン済みfixture設定の不足でPhoneが終了し、次は自動起動済みWatchへの検証設定が適用されずCLI未到達だった。これらは検証器の起動条件の不備として、それぞれ`.validation/watch-app-core-prepared-20261102/`と`watch-app-core-prepared-account-20261102/`に保持する。設定を補い、同じbinaryをWatch processの明示終了後に起動した実行は`.validation/watch-app-core-prepared-explicit-launch-20261102/`。

この実行ではnative capture／rendererが`applied`、入力48kHz mono・出力48kHz stereo・engine稼働を確認した。次のAudioDevice媒体endpoint取得で約5秒待った後`stopped`となり、iPhoneの録音要求には到達していない。入力配送handlerの設置前でマイクgateも閉じているため、このApp実行のinputFrames 0をDのnative入力成功へ混ぜない。native mixerの220,500 framesは全て無音であり、相手音声・録音内容の再生成功ではない。失敗表示とWatch終了状態、source 362ファイル一致、入出力・音量復元、所有ペア停止を確認した。媒体開始と5秒全量往復は未完として継続する。

部分App単位の回帰では、Watch連携4テスト（引数別5ケース）と通常Phoneの有限5秒録音・再開始1テストが成功した。旧Watchテストの直接録音処理呼出しでは期待が失敗するREDを保持し、合成入力を実device renderer→暗号化媒体・AAC→Phoneの送信処理へ通すfixtureに修正した。成功・失敗・遅いactivationの取消、二重再生拒否、停止後のPhone録音・再生復帰とミュート設定の保持を確認する。短い合成入力の契約試験であり、Watch実Appの5秒全量往復の代替ではない。証跡は`.validation/watch-app-contract-green-20261102/`と`watch-app-phone-finite-final-20261102/`。Phone単独テストの最初のfilterが選択0件だった結果を保持し、正しいfilterの1件成功と区別する。失敗・skip・検出runtime warnings 0、362ファイル一致、最終production Swiftがnative実行時と同一であること、所有Simulator停止、一時runner5本回収を確認した。


## Watch媒体endpointの登録通知待ち

2026-11-02、公開APIを増やさずRTCとAudioDeviceのprivate分岐に一時DEBUGログを置き、実Watch AppのPIDを絞って観測した。listenerは`ready`となり、登録`add`／`remove`・`waiting`／`failed`はなく、約5秒後に`prepare timeout`→`endpointUnavailable`→停止となった。明示取消が先行した失敗ではない。source 362ファイル一致・条件復元を確認し、一時ログは撤去した。証跡は`.validation/watch-endpoint-private-log-20261102/`。

| 比較 | 観測結果 | 証跡 |
|---|---|---|
| 同じ診断binaryを標準dns-sdから観測 | 別名positive controlの追加・削除を各4件（interface別）観測し、観測器の動作を確認。baselineのdevice広告0、新規device候補0。Watchは同じready→5秒timeout。binary UUID／hashを照合し、保存した診断patchとの対応を記録 | `.validation/watch-endpoint-browser-20261102/` |
| 登録domainだけを明示`local.`へ変更 | 現sourceで両Appをbuild。control追加・削除各4、新規device候補0、登録addなし、ready→timeoutのまま。改善の証拠がなく、domain指定と一時ログを撤去 | `.validation/watch-endpoint-explicit-domain-20261102/` |

広告名・IP・鍵・PCMは比較結果へ保存せず、役割に合う広告の件数と時刻で観測する。登録通知を受けず、同時にhost browserでも広告を見なかったことまでは確定するが、OS内部の登録状態や実Watch固有の制限を断定しない。Phone録音要求前の停止であり、音声往復は未成立である。両比較で所有processの終了、Simulatorの音声設定・音量の復元と停止、一時runner回収を確認した。次は同App内の最小NWListener単独対照で、独自wrapper／parameter条件の外側でも同症状かを確認する。


## 同じWatch App内のNWListener単独対照

2026-11-02、音声session・Phone App・RTC／AudioDeviceを起動せず、同じWatch Appの一時Validation入口からNWListenerを動かした。Aは現行と同じP2P許可・cellular禁止、Bは標準UDP条件とし、短い検証専用名・既定domainで各約8.5秒保持した。両方ともready・portあり、登録add/remove 0、外部browserの該当広告0で、cancelled通知と段階ごとの停止を確認した。browserの別名positive controlは追加・削除各4件である。wrapperや既存parameterだけを原因とする根拠は得られなかった。

証跡は`.validation/watch-listener-standalone-20261102/`。source362ファイル一致、一時sourceのHEAD完全復元、所有process・Simulator停止、runner・自前cache回収を確認した。音声設定は変更していない。[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)はwatchOSとSimulatorがローカルネットワークのprivacy機構をサポートしないと説明し、[TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)はSimulatorの低レベル通信を許可している。今回を許可拒否や実Watchの背景制限として扱う根拠はなく、確認した公式資料に今回の既知問題や登録成功期限も見つからない。Watch広告の永続的な非対応は断定しない。

現在の両端広告は、送信専用outgoing接続と受信専用listener接続を分けた実装の条件であり、製品要求ではない。次の採否判断は、実Phone Appに待受を置き、実Watch Appから同一UDP接続で有限データを双方向に往復できるかの最小技術実証とする。Watchのマイク・スピーカー、iPhoneでの通話・音声処理という要求は維持し、成立するまでは製品transportを変更しない。


## Phone側待受とWatch単一接続の双方向対照

2026-11-02、実Phone AppのNWListenerへ実Watch Appが接続し、同じUDP flowで32byteの検証値を2回echoする一時対照を行った。PhoneのBonjour登録とport取得は成功した。初回はWatchの自動refreshと検証要求が競合して要求未送信だったため、媒体不成立とは扱わず`.validation/watch-single-flow-20261102/`へ保持する。既存の到達性・待機状態が整ってから要求する補正後は、実WCでservice endpointを受け取ったが、WatchのNWConnectionはpreparingのまま期限に達し、送信・受信0だった。証跡は`.validation/watch-single-flow-ready-20261102/`。実際のcancelledと停止後250msの件数不変を両端で確認した。

続く対照では、Phone実processの利用中Wi-Fi／Ethernet pathと実interfaceを照合して得た非loopback IPv4候補1件・listener実portを、検証専用の有界・version付きWC返信で渡した。固定IPやlocalhostは使わず、service endpointの型をhost／portへ読み替えていない。今回の候補はwiredEthernet 1件である。WatchのhostPort接続はreadyとなり、Phone受信・echo各2、Watch送信・echo受信・全32byte一致各2を確認した。実際のlistener／connection取消と停止後250msの件数不変も成立した。これは停止後の観測であり、意図的な遅延packet注入試験ではない。

証跡は`.validation/watch-hostport-flow-20261102/`。source362ファイル一致、IP値を観測JSON・Appログへ保存していないこと、一時2sourceのHEAD完全復元、runner回収、両App終了・所有Simulator停止を確認した。音声設定は変更していない。同条件でUDP通信自体は成立し、Bonjour指定の接続準備停止とは差が出たが、根本原因を特定したものではない。LAN対照はAPなし近距離・製品fallback・暗号化音声・録音会話の成立を示さない。

実証した単一flowの双方向配送を、既存の認証・暗号化・replay防止と配送上限を保つ音声device packageへ接続する。製品のBonjour既定・APなし近距離要求は維持し、IP交換を製品fallbackとして採用する判断とは分ける。App追従とnative5秒録音・全量再生は引き続き未完である。
