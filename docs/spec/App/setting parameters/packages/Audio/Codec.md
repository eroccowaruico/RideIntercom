# Codec package 設定値

## 目的

本書は、作り直す RideIntercom App が `Codec` package へ渡す画面設定値、導出値、fallback の扱いを定義する。

画面から直接設定する値は `docs/spec/App/setting parameters/App/設定値一覧.md` を正とし、本書ではそれを `CodecEncodingConfiguration` と `RTCAudioPolicy` へ渡す方法を扱う。

## CodecEncodingConfiguration

| package 設定 | App から渡す値 | 種別 | Diagnostics で確認する値 |
|---|---|---|---|
| `codec` | `preferredTransmitCodec` を要求値として `CodecRuntimeReport.resolving` に渡す。利用不可または route 未対応なら `pcm16` へ fallback | 画面設定から導出 | requested / selected / fallback |
| `format.sampleRate` | `rtcAudioFormatPreset.audioFormat.sampleRate`。既定は `48_000`、候補は `48_000` / `24_000` / `16_000` | 画面設定から導出 | encoded / decoded frame format |
| `format.channelCount` | `rtcAudioFormatPreset.audioFormat.channelCount`。候補は常に mono | 画面設定から導出 | encoded / decoded frame format |
| `aacELDv2Options.bitRate` | `aacELDv2BitRate` | 画面設定 | codec option summary |
| `opusOptions.bitRate` | `opusBitRate` | 画面設定 | codec option summary |

Codec は App の送信設定として選ぶ。Codec package の availability により要求 codec が使えない場合、App composition は `CodecRuntimeReport.resolving` の結果を Diagnostics に残し、通話継続可能なら `pcm16` へ fallback する。

## Codec UI 設定

| App 設定 | UI | package 反映 | 表示条件 |
|---|---|---|---|
| `preferredTransmitCodec` | segmented picker。既定 `.mpeg4AACELDv2` | `CodecEncodingConfiguration.codec` と `RTCAudioPolicy.preferredCodecs` の先頭 | 常時 |
| `rtcAudioFormatPreset` | segmented picker。既定 `48 kHz` | `CodecEncodingConfiguration.format`、`RTCAudioPolicy.preferredSendFormat`、TX `MixerPCMSink.targetFormat` | 常時 |
| `aacELDv2BitRate` | stepper または menu。既定 `32_000` | `CodecEncodingConfiguration.aacELDv2Options.bitRate` | `preferredTransmitCodec == .mpeg4AACELDv2` |
| `opusBitRate` | stepper または menu。既定 `32_000` | `CodecEncodingConfiguration.opusOptions.bitRate` | `preferredTransmitCodec == .opus` |
| selected / fallback codec | Diagnostics の Codec 行 | `CodecRuntimeReport` と `RTCAudioPolicy.preferredCodecs` の結果 | 常時 |

Diagnostics は codec の希望値と実際に選ばれた codec を分けて表示する。要求 codec が使えない状態は設定ミスではなく、環境差異または route capability 差異として扱う。

## RTC との bridge

| 境界 | App composition の処理 | 完了条件 |
|---|---|---|
| TX PCM frame | AudioMixer TX sink から `AudioCore.PCMFrame` を受け取る | frame format が `rtcAudioFormatPreset.audioFormat` と一致する |
| encode | `CodecEncoder.encode(_:)` を呼び、`EncodedCodecFrame` を `RTCAudioPacket` へ詰める | codec、format、sample count、payload を保持する |
| decode | `ReceivedAudioPacket.packet` を `EncodedCodecFrame` へ変換し `CodecDecoder.decode(_:)` を呼ぶ | payload envelope を App が解釈しない |
| format policy | `CodecEncodingConfiguration.format`、`RTCAudioPolicy.preferredSendFormat`、TX `MixerPCMSink.targetFormat` を同じ `AudioFormat` にする | 送信 packet、codec runtime report、RTC policy の sample rate / channel count が一致する |

## Runtime report / event の App 側処理

| 事象 | App の扱い | UI 反映 | ログ |
|---|---|---|---|
| requested codec unavailable | `pcm16` fallback が可能なら継続 | Diagnostics の Codec 行 | `audio.codec.fallback` |
| decode failure | 対象 frame を破棄し、受信 drop として扱う | Diagnostics の Reception / Codec 行 | `audio.codec.decode_failed` |
| malformed payload | 対象 frame を破棄する | Diagnostics に直近エラー | warning |
| invalid sample count | adapter 実装不備として扱う | Diagnostics に failed | error |

## App 画面に出さない値

| 値 | 扱い |
|---|---|
| payload envelope 詳細 | package 仕様を正とする |
| AudioConverter availability の詳細 | Diagnostics とログへ要約だけを出す |

詳細な codec、payload、availability の仕様は `docs/spec/packages/Audio/Codec.md` を正とする。
