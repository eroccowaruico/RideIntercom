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
