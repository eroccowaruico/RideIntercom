# VADGate package 設定値

## 目的

本書は RideIntercom App が `VADGate` package へ渡す設定値を定義する。

画面から直接設定する値は `docs/spec/App/Configuration/設定値一覧.md` を正とし、本書では固定値、導出値、package adapter が決める値だけを扱う。

## VADGateConfiguration

| package 設定 | App から渡す値 | 種別 |
|---|---|---|
| `VADGateConfiguration` | `vadSensitivity` から導出した App preset | 画面設定から導出 |
| attack / release | VoiceActivitySensitivity.configurationのpreset。Standardはpackage default | 画面設定から導出 |
| noise floor | package default | 固定 |
| gate gain / ramp | package default | 固定 |
| runtime snapshot | `VADGateRuntimeSnapshot` を `RTCRuntimePackageReport(kind: runtimeSnapshot)` として送信し、AppのvadGateRuntimeSnapshotへ保持する | runtime report |

`vadSensitivity` は App 画面から選ぶが、package の細かい VAD parameter を画面へ直接出さない。

## App preset

| `vadSensitivity` | 導出方針 | 用途 |
|---|---|---|
| `.lowNoise` | package default より小さい threshold offset と短め attack | 静かな環境で小さい声を拾う |
| `.standard` | package default | 通常環境 |
| `.noisy` | package default より大きい threshold offset と長め attack | 走行音や風切り音がある環境 |

具体的な dB 値、attack/release、noise floor の範囲は `docs/spec/packages/Audio/Effectors/VADGate.md` を正とする。Settings は preset 選択だけを扱い、直近 `VADGateAnalysis` はruntime reportとAppの診断モデルに保持する。現行Diagnosticsにnoise floor等の専用詳細行はなく、TX effect chainにも含めない。

## App 画面に出さない値

| 値 | 扱い |
|---|---|
| attack duration | App presetにより0.04 / package default / 0.12秒 |
| release duration / hangover | App presetにより0.45 / package default / 0.65秒 |
| noise floor adaptation | package default |
| speech / silence gain | package default |
| gain ramp | package default |

詳細な VAD / gate の仕様は `docs/spec/packages/Audio/Effectors/VADGate.md` を正とする。
