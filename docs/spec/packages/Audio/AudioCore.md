# AudioCore 仕様

`AudioCore` は音声 package 間の共通語彙だけを持つ。音を変える処理、OS処理、codec処理、通信処理は持たない。

## Package Profile

| 項目 | 仕様 |
|---|---|
| パス | `RideIntercom/packages/Audio/AudioCore` |
| Product | `AudioCore` library |
| 依存 | なし |
| 対応プラットフォーム | iOS `26.4` 以降、macOS `26.4` 以降 |
| Swift | Swift `6` |
| テスト | Swift Testing の SwiftPM テスト |

## Boundary

| 持つ | 持たない |
|---|---|
| PCM format | resample |
| PCM frame | channel mix |
| encoded audio metadata | gain / volume |
| signal measurement | limiter / VAD判断 / noise reduction |
| processing report / failure | hardware / codec / transport |

```text
SessionManager -> PCMFrame -> AudioMixer -> PCMFrame -> Codec -> RTC
                         ^                    ^
                         |                    |
                    AudioCore vocabulary only
```

## Public Contract

| 型 | 契約 |
|---|---|
| `AudioFormat` | sample rate と channel count を表す。値は package 境界で扱える範囲に丸める |
| `PCMFrame` | sequence、format、capturedAt、interleaved Float samples を持つ |
| `AudioSignalMeter` | `PCMFrame` を読んで RMS / peak / clipping を返す。samples は変更しない |
| `EncodedAudioMetadata` | encoded payload の codec、format、timestamp、sample count、bit rate を保持する |
| `AudioProcessingReport` | package内処理の source/target format、sample count、結果を表す |
| `AudioProcessingFailure` | 継続可能な処理失敗を Codable な診断として表す |

## External Specification

| 外部入力 | 正常出力 | エラー出力 | 保証 |
|---|---|---|---|
| `AudioFormat(sampleRate:channelCount:)` | 正規化済み `AudioFormat` | なし | sample rate / channel count が許容範囲に入る |
| `PCMFrame.validated()` | 同じ `PCMFrame` | `AudioProcessingFailure(operation: .validateFrame)` | samples と channel count の整合を確認する |
| `AudioSignalMeter.measure(frame)` | `AudioSignalMeasurement` | frame validation failure | frameを変更せず RMS / peak / clipping を返す |
| `EncodedAudioMetadata(...)` | 正規化済み metadata | なし | sample count / bit rate が負値にならない |
| `AudioProcessingReport(...)` | Codable report | なし | source/target format と処理結果を package 間で共有できる |

```text
caller input
  -> AudioCore type initializer / validator / meter
  -> normalized value or reportable failure
```

## External Guarantees

| 項目 | 保証 |
|---|---|
| ABI姿勢 | package固有PCM型の重複を増やさず、共通型をここへ集約する |
| Codable | runtime report、diagnostics、transport metadata に載せられる |
| Sendable | Swift Concurrency 境界で値として渡せる |
| 副作用 | `AudioSignalMeter` と value initializer は audio graph / hardware / network に触れない |
| 変換 | PCMの内容、channel構成、sample rate を変更しない |

## PCM Invariants

| 項目 | 仕様 |
|---|---|
| sample rate | `8_000...96_000` |
| channel count | `1...2` |
| samples | interleaved Float PCM |
| frame count | `samples.count / channelCount` |
| validation | `samples.count` が `channelCount` で割り切れない frame を拒否する |
| frame state | level、gain、volume、conversion state を持たない |

## Signal Measurement

| 項目 | 仕様 |
|---|---|
| API | `AudioSignalMeter.measure(_:)` |
| 入力 | `PCMFrame` |
| 出力 | `AudioSignalMeasurement(rms, peak, isClipped)` |
| 副作用 | なし |
| 利用先 | Diagnostics、meter表示、VAD入力、runtime report |

`AudioSignalMeter` は測定器であり effect ではない。測定結果を frame に保存しない。

## Error I/O

| エラー出力 | 発生条件 | 呼び出し側の扱い |
|---|---|---|
| `AudioProcessingFailure(operation: .validateFrame)` | samples数がchannel countで割り切れない | frame生成元を修正する。音声処理packageは継続可能失敗としてreportできる |
| `AudioProcessingResult.failed` | AudioMixerなど別packageが処理失敗をreportする | Appはpackage名、operation、source/target formatをDiagnosticsに表示できる |

`AudioCore` のエラーは音声処理の停止命令ではない。停止するか、frame単位で捨てるか、診断だけに残すかは失敗を発生させたpackageが決める。

## Report Ownership

| operation | 実装するpackage |
|---|---|
| `validateFrame` | `AudioCore` |
| `measureSignal` | `AudioCore` |
| `normalizeSource` | `AudioMixer` |
| `normalizeSink` | `AudioMixer` |

`AudioCore` は `normalizeSource` / `normalizeSink` の report 型を提供するだけで、正規化処理は実装しない。

## Compatibility Surface

| 外部package | 使う型 | 使い方 |
|---|---|---|
| `SessionManager` | `AudioFormat`, `PCMFrame`, `AudioProcessingReport` | hardware format の frame と schedule report |
| `AudioMixer` | `AudioFormat`, `PCMFrame`, `AudioProcessingReport` | source ingress / sink egress 正規化と graph診断 |
| `Codec` | `AudioFormat`, `PCMFrame`, `EncodedAudioMetadata` | encode / decode 境界 |
| Effectors | `PCMFrame`, `AudioSignalMeter` | 測定入力または effect前後の診断 |

## Test Matrix

| 観点 | 確認 |
|---|---|
| format | sample rate / channel count が範囲内へ丸められる |
| frame | sample count と channel count の不整合を拒否する |
| meter | RMS / peak / clipping を計算し、frame を変更しない |
| metadata | sample count / bit rate を安全な値に丸める |

## 外部入力の検証

`PCMFrame.validated()`は公開可変プロパティやDecodable経由の値も再検証する。sample rateは有限の8–96 kHz、channelは1–2、timestampと全sampleは有限値でなければ拒否する。ゼロchannelのframeCountは0を返して除算例外を避ける。RMSはDoubleで累積し、有限の大きなFloat入力で中間値がoverflowしない。

## Render配送と不連続の処理

| 型 | 契約 |
|---|---|
| AudioRenderCapture | 単一producer（render）/単一consumerの32slot ring。最大4096frame/slotを事前確保。renderはcopy・atomic公開・signalのみを行い、PCM配列とcallbackは非render threadで生成する。overflowはdroppedFrameCountへ計上 |
| PCMStreamTransition | 同じ直列ownerでbegin/process/resetする。通常streamはbit exact。明示的不連続だけ最後のsampleから2msで無音へ移り、指定settlingの後に新しい音へ2msで戻す。sample数・capture時刻を変更せず、貯留・時間伸縮をしない |

settlingDurationは有限の2ms〜1秒へ制限する。長い会話休止の後はresetで過去sampleを復活させない。音声内容を通常ログへ記録しない。

`AudioRenderCapture`の時刻は最初のhost timeをdevice sample timeへ対応付け、その後はsample clock差から求める。host timestampの観測上の揺れだけで連続PCMを切らない。sample timeの前方gapは保持し、sample clockが巻き戻る再起動は新しいhost anchorに切り替える。ringの破棄counterと欠落は隠さない。

`finish()`は新しい入力と未配信のringを破棄し、実行中のcallbackを待たずに返る。既に実行中のcallbackだけは完了し得るため、その呼出先も通話の世代を確認する。停止後の意図した破棄はcapture overflowに数えない。入力backendの停止とrender observerの破棄で必ず呼ぶ。
