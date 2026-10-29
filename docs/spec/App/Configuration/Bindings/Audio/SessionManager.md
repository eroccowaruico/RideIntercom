# SessionManager package 設定値

## 目的

本書は、現行のRideIntercom App が `SessionManager` package へ渡す固定値、導出値、runtime report の扱いを定義する。

画面から直接設定する値は `docs/spec/App/Configuration/設定値一覧.md` を正とし、`SessionManager` の型、既定値、OS差分、operation report、runtime event は `docs/spec/packages/Audio/SessionManager.md` を正とする。

## AudioSessionConfiguration

| package 設定 | App から渡す値 | 種別 | Diagnostics で確認する値 |
|---|---|---|---|
| `mode` | Settings の `Mode` から導出。`Burst mode` は `.default`、`Stream mode` は `.voiceChat` | 画面設定から導出 | resolved mode |
| `defaultToSpeaker` | `Use Speaker == true` または `selectedOutputDevice == .builtInSpeaker` | 画面設定から導出 | requested / resolved output |
| `prefersEchoCancelledInput` | `mode == .default && Echo Cancellation == true`。`Use Speaker` からは App で派生させない | 画面設定から導出 | requested / resolved echo cancellation |
| `preferredInput` | `selectedInputDevice` | 画面設定 | requested / current input |
| `preferredOutput` | `selectedOutputDevice` | 画面設定 | requested / current output |

既定は `Burst mode` + `Use Speaker = false` + `Echo Cancellation = true` とし、Duck Other Audio も opt-in ON から開始する。`voiceChat + prefersEchoCancelledInput` は不正な組み合わせのため UI に出さない。`defaultToSpeaker = true` は speaker 出力希望としてだけ App から渡し、`mode == .default` で speaker 向け echo cancellation を有効化するかは `SessionManager` の resolved configuration / report を正とする。`mode == .voiceChat` では明示的な `prefersEchoCancelledInput` を使わない。

| UI 状態 | `mode` | App が渡す `defaultToSpeaker` | App が渡す `prefersEchoCancelledInput` | SessionManager resolved |
|---|---|---:|---:|---|
| `Burst mode` + `Use Speaker = false` + `Echo Cancellation = false` | `.default` | `false` | `false` | echo cancellation は要求しない |
| `Burst mode` + `Use Speaker = false` + `Echo Cancellation = true` | `.default` | `false` | `true` | echo cancellation を要求する |
| `Burst mode` + `Use Speaker = true` + 明示 Echo Cancellation 希望なし | `.default` | `true` | `false` | speaker 出力として echo cancellation を package 側で解決する |
| `Burst mode` + `Use Speaker = true` + 明示 Echo Cancellation 希望あり | `.default` | `true` | `true` | echo cancellation を要求し、speaker 出力としても同じ resolved 値になる |
| `Stream mode` + `Use Speaker = false` | `.voiceChat` | `false` | `false` | voiceChat mode の route/processing に任せる |
| `Stream mode` + `Use Speaker = true` | `.voiceChat` | `true` | `false` | voiceChat mode のまま speaker 出力を要求する |

## AudioInputStreamConfiguration

| package 設定 | App から渡す値 | 種別 | Diagnostics で確認する値 |
|---|---|---|---|
| `preferredFormat.sampleRate` | `48_000` | 希望値。実値はsnapshot | input stream actualHardwareFormat |
| `preferredFormat.channelCount` | `1` | 固定 | input stream snapshot format |
| `bufferFrameCount` | `128` | 固定 | start operation report |
| `voiceProcessing` | `AudioInputVoiceProcessingConfiguration` の導出値 | 画面設定と再生状態から導出 | input stream snapshot `inputVoiceProcessing` |

入力 stream の初期適用、未開始時更新、実行中更新はすべて `AudioInputStreamCapture.updateVoiceProcessing(_:)` と `start()` の report/event で確認する。App は `AudioInputVoiceProcessingManager` や `AVAudioInputNode` を保持しない。

## AudioInputVoiceProcessingConfiguration

| package 設定 | App から渡す値 | 種別 | Diagnostics で確認する値 |
|---|---|---|---|
| `soundIsolationEnabled` | `false` | 固定 | requested / applied / ignored |
| `otherAudioDuckingEnabled` | `isDuckOthersEnabled` | 画面設定。発話の有無ではI/O modeを変えない | requested / effective |
| `duckingLevel` | `isOtherAudioDuckingActive ? .medium : .minimum` | 導出 | requested level |
| `inputMuted` | `isMuted` | 画面設定から導出 | requested mute |

Voice Isolation Effect の画面設定は `SoundIsolation` effect の有効/無効であり、SessionManager の `AudioInputVoiceProcessingConfiguration.soundIsolationEnabled` へは渡さない。SessionManager の voice processing は Duck Other Audio とローカルマイクミュートの適用先として使う。

`isOtherAudioDuckingActive` は次をすべて満たす場合だけ `true` とする。

| 条件 |
|---|
| `isDuckOthersEnabled == true` |
| Audio Check 中ではない |
| 直近に可聴な受信音声を最終出力へ渡している |
| `isOutputMuted == false` |
| `masterOutputVolume > 0` |
| 該当 peer の出力音量が 0 ではない |

## AudioOutputStreamConfiguration

| package 設定 | App から渡す値 | 種別 | Diagnostics で確認する値 |
|---|---|---|---|
| `preferredFormat.sampleRate` | `48_000` | 希望値。実値はsnapshot | output stream actualHardwareFormat |
| `preferredFormat.channelCount` | `1` | 固定 | output stream snapshot format |
| `maximumBufferedDuration` | 通話 `0.2`秒、Audio Check `0.1`秒 | hardware出力で、新frameの再生開始までの待ち時間上限・単一frame長上限 | bufferedOutputDuration / playbackResetCount |

出力 renderer の `start()`、`schedule(_:)`、`stop()` は `AudioStreamOperationReport` と `AudioStreamRuntimeEvent` を Diagnostics に集約する。

## Runtime report / event の App 側処理

| Event / report | App の扱い | UI 反映 | ログ |
|---|---|---|---|
| `AudioSessionConfigurationReport` | 直近の session 設定結果として保持 | Diagnostics の Session 行 | `audio.session.configured` |
| `AudioSessionOperationReport.result.applied` | 成功として記録 | 通常状態 | 必要に応じて debug |
| `AudioSessionOperationReport.result.ignored` | 継続可能な環境差異として記録 | Diagnostics に `Ignored` と理由を表示 | debug または notice |
| `AudioSessionOperationReport.result.failed` | media 開始可否へ反映 | Call の音声エラー、Diagnostics に失敗理由 | warning または error |
| `AudioStreamOperationReport` | 入力/出力 stream の直近操作として保持 | Diagnostics の Stream 行 | `audio.stream.operation` |
| `AudioStreamRuntimeEvent.inputFrame` | 入力 level と VAD へ渡す | Call / Settings の入力メーター | 高頻度通常ログは禁止 |
| `AudioStreamRuntimeEvent.outputFrameScheduled` | 最終出力 level と schedule count へ渡す | Call / Settings / Diagnostics の出力メーター | 高頻度通常ログは禁止 |
| `AudioSessionSnapshotChange` | device list / current route を更新 | Settings の picker、Diagnostics の Route 行 | `audio.session.route_changed` |

## App 画面に出さない値

| 値 | 扱い |
|---|---|
| iOS category / mode / options | package 仕様を正とし、App 画面では個別設定しない |
| CoreAudio device 切替の詳細 | `AudioSessionDeviceSelection` と report だけを扱う |
| advanced ducking の OS API 詳細 | `AudioInputVoiceProcessingConfiguration` と stream report だけを扱う |
| voice processing bypass | `soundIsolationEnabled = false` と `otherAudioDuckingEnabled` から package が導出する |
| `AudioInputVoiceProcessingManager` | App は直接保持しない |

詳細な OS 差分と内部既定値は `docs/spec/packages/Audio/SessionManager.md` を正とする。

入力・出力の希望formatと実hardware formatは同一と仮定しない。Mixerのsource/sink境界で明示的に変換する。Audio Checkの5秒録音はMixer sourceで保持し、hardware出力にはengineの進行に合わせて渡す。

受話の有無ではvoice processingのI/Oモードを変えず、Duck Other AudioがONの間は入力開始前から有効にする。受話時はducking levelだけをmediumへ、無受話時はminimumへ切り替える。機能のON/OFFでI/Oモードが変わる場合の安全な停止・再開はSessionManagerが担当する。

通話の最終出力は`intercomCall`の200 ms上限を開始時に明示する。100 msのtapがactorへの配送でまとまる場合も、期限内の2batchを途中で破棄しない。固定の待機を追加する設定ではない。Audio Checkは`intercom`の100 msへ戻し、直接結合試験も100 msのまま使う。
