# VADGate 仕様

VADGate は RMS、ノイズフロア推定、ヒステリシス、hangover を使ってリアルタイム音声区間を判定し、必要に応じてサンプルへ gate gain を適用する Swift Package である。

このライブラリは機械学習を使わない軽量な VAD と gate 処理だけを扱う。マイク取得、Audio Session 管理、AVAudioEngine の接続、通信、コーデック、音声デバイス制御は責務に含めない。

## 目的

| 観点 | 仕様 |
|---|---|
| 主目的 | 入力音声の短時間 RMS から speech/silence を判定し、UI 反応、送信制御、簡易 gate に使える状態と gain を返す |
| 体験上の目的 | 文節間や語尾で即 silence にならないよう hangover を持たせ、通話音声のブツ切れを避ける |
| 利用箇所 | マイク入力 tap、送信前の PCM 処理、AudioMixer へ入れる前のサンプル処理、診断UIの発話状態表示 |
| 非目的 | ML VAD、ノイズ除去、通信経路への組み込み |
| 設計姿勢 | App から直接呼びやすい純 Swift DSP として、RMS 入力または `[Float]` サンプル入力を受ける |

## パッケージ構成

| 項目 | 内容 |
|---|---|
| パス | `RideIntercom/Effectors/VADGate` |
| Package 名 | `VADGate` |
| Product | `VADGate` library |
| 対応プラットフォーム | iOS 26.4 以降、macOS 26.4 以降 |
| 使用フレームワーク | `Foundation`、`AVFAudio`、`AudioUnit` |
| テスト | Swift Testing による SwiftPM テスト |

## 公開API

| API | 種別 | 役割 |
|---|---|---|
| `VADGate` | final class | RMS 計算、状態遷移、ノイズフロア更新、gate gain 更新、サンプルへの gain 適用を行う |
| `VADGateEffect` | struct | `AUAudioUnit` を内包し `AVAudioNode` として AudioMixer へ挿入できる AVAudioEngine 対応ラッパー |
| `VADGateConfiguration` | struct | attack/release、しきい値offset、ノイズフロア、gain ramp などを保持する |
| `VADGateAnalysis` | struct | 1回の処理結果として状態、RMS、ノイズフロア、しきい値、gain を返す |
| `VADGateRuntimeSnapshot` | struct | 現在の設定、状態、ノイズフロア、gain、最後の解析結果を Codable で返す |
| `VADGateState` | enum | `silence` と `speech` の状態を表す |
| `VADGateError` | enum | `unsupported` — Audio Unit の生成に失敗したときに `VADGateEffect.make()` が投げるエラー |

## 判定仕様

| 状態 | 条件 | 遷移 |
|---|---|---|
| `silence` | `rmsDBFS > noiseFloorDBFS + speechThresholdOffsetDB` が `attackDuration` 以上続く | `speech` へ遷移する |
| `silence` | speech 条件を満たさない | attack 累積をリセットし、ノイズフロアを更新する |
| `speech` | `rmsDBFS < noiseFloorDBFS + silenceThresholdOffsetDB` が `releaseDuration` 以上続く | `silence` へ遷移する |
| `speech` | silence 条件を満たさない | release 累積をリセットする |

`speechThresholdOffsetDB` と `silenceThresholdOffsetDB` を分けることでヒステリシスを作る。`releaseDuration` は hangover として働き、発話中の短い無音で gate が閉じることを避ける。

## 設定仕様

| 設定 | 型 | 入力範囲 | 既定値 | 備考 |
|---|---|---|---|---|
| `attackDuration` | `Double` | `0.01...1.0` sec | `0.08` | speech へ入るまでに必要な継続時間 |
| `releaseDuration` | `Double` | `0.05...2.0` sec | `0.5` | silence へ戻るまでの hangover 時間 |
| `updateInterval` | `Double` | `0.005...0.1` sec | `0.02` | `duration` 未指定時の1フレーム時間 |
| `speechThresholdOffsetDB` | `Float` | `1...40` dB | `12` | ノイズフロアから speech 判定しきい値までの差分 |
| `silenceThresholdOffsetDB` | `Float` | `0...speechThresholdOffsetDB` dB | `8` | ノイズフロアから silence 判定しきい値までの差分。ヒステリシスが逆転しないよう speech 側以下へ丸める |
| `initialNoiseFloorDBFS` | `Float` | `minimumNoiseFloorDBFS...maximumNoiseFloorDBFS` | `-60` | 初期ノイズフロア |
| `minimumNoiseFloorDBFS` | `Float` | 任意 | `-90` | ノイズフロア下限 |
| `maximumNoiseFloorDBFS` | `Float` | 任意 | `-20` | ノイズフロア上限 |
| `noiseFloorAdaptation` | `Float` | `0...1` | `0.05` | silence 中のノイズフロア追従係数 |
| `speechGain` | `Float` | `0...1` | `1` | speech 中の目標 gain |
| `silenceGain` | `Float` | `0...1` | `0` | silence 中の目標 gain |
| `gainAttackDuration` | `Double` | `0.001...1.0` sec | `0.03` | speech gain へ近づく速さ |
| `gainReleaseDuration` | `Double` | `0.001...2.0` sec | `0.12` | silence gain へ近づく速さ |

範囲外入力は `VADGateConfiguration` の初期化時に上表の範囲へ丸める。

## 処理仕様

| 処理 | 仕様 |
|---|---|
| `process(rmsDBFS:duration:)` | dBFS 値を直接受け取り、状態遷移、ノイズフロア更新、gain 更新を行って `VADGateAnalysis` を返す |
| `process(samples:duration:)` | `[Float]` PCM サンプルから RMS dBFS を計算し、`process(rmsDBFS:duration:)` と同じ処理を行う |
| `applyGate(to:duration:)` | `[Float]` PCM サンプルを解析し、更新後の gain をサンプルへ乗算して `VADGateAnalysis` を返す |
| `apply(configuration:)` | 設定を更新する。状態は維持したまま次フレームから新しい設定で動作する |
| `reset(noiseFloorDBFS:)` | 状態、attack/release 累積、gain、ノイズフロアを初期化する |
| `runtimeSnapshot` | `VADGateRuntimeSnapshot` を返す。`VADGateEffect.runtimeSnapshot` からも同じ情報を取得できる |
| `rms(samples:)` | サンプル列の短時間 RMS を返す |
| `rmsDBFS(samples:)` | サンプル列の短時間 RMS を dBFS で返す |

入力サンプルは `Float` PCM を想定する。チャンネル分離、AudioBufferList、`AVAudioPCMBuffer` からの取り出しは呼び出し側で行う。

## Runtime snapshot 仕様

| 項目 | 型 | 意味 |
|---|---|---|
| `configuration` | `VADGateConfiguration` | 現在適用されている VAD/gate 設定 |
| `state` | `VADGateState` | 現在の speech/silence 判定 |
| `noiseFloorDBFS` | `Float` | 現在推定しているノイズフロア |
| `gain` | `Float` | 現在適用する gate gain |
| `lastAnalysis` | `VADGateAnalysis?` | 最後に処理した frame の解析結果。`reset` 直後は `nil` |

`VADGateConfiguration`、`VADGateAnalysis`、`VADGateRuntimeSnapshot`、`VADGateState` は `Codable` とし、RTC などの外部 transport へ載せる場合も VADGate package は transport 実装へ依存しない。

## 接続例

| ユースケース | 呼び出し方 |
|---|---|
| AudioMixer へ挿入 | `VADGateEffect.make()` → `.node` を `addEffect()` へ渡す |
| UI の発話インジケータ | `process(samples:)` の `state` と `rmsDBFS` を表示に使う |
| 送信前 gate | `applyGate(to:)` で PCM サンプルへ gain を適用してからエンコードへ渡す |
| VAD だけ利用 | `process(rmsDBFS:)` を使い、gate gain は使わない |
| ノイズ環境変化への追従 | silence 中の `noiseFloorDBFS` 更新結果を診断値として確認する |

```swift
// AudioMixer のエフェクターチェーンへ挿入する場合
import VADGate

let effect = try await VADGateEffect.make()
try mixerBus.addEffect(effect.node)

// 発話状態を外から読む場合
let state = effect.vadGate.state
```

```swift
// PCM tap で直接使う場合
import VADGate

let gate = VADGate()

var frame: [Float] = capturedPCMFrame
let analysis = gate.applyGate(to: &frame, duration: 0.02)

if analysis.state == .speech {
    // frame を送信処理へ渡す
}
```

## AudioMixer との関係

| 観点 | 仕様 |
|---|---|
| AVAudioNode | `VADGateEffect.node` が `AVAudioNode` を公開する。`AudioMixer.MixerBus.addEffect()` に直接渡せる |
| AudioMixer へ挿入する方法 | `VADGateEffect.make()` で生成し、`.node` を `addEffect()` へ渡す |
| PCM tap での利用 | `VADGate` を直接使い、`process(samples:)` または `applyGate(to:)` をフレームごとに呼ぶ（エフェクターチェーン外で使いたい場合） |
| Effectors との共通点 | SoundIsolation、DynamicsProcessor、PeakLimiter と同様に `make() async throws` で生成する |
| Effectors との違い | VADGate は純 Swift DSP クラスとして単体でも使える。他の Effectors は Audio Unit のみ |
| レンダーブロック | `VADGateAudioUnit` の `internalRenderBlock` が全チャンネルの RMS を合算して VAD を1回処理し、得た gain を全チャンネルへ適用する |

## 制約と注意点

| 観点 | 内容 |
|---|---|
| ML 非使用 | 機械学習VADではないため、騒音環境では誤検出が起きる可能性がある |
| hangover | `releaseDuration` を短くしすぎると語尾や文節間で gate が閉じやすい |
| ノイズフロア | ノイズフロアは silence 中のみ追従するため、長時間 speech 状態が続く環境では更新が遅れる |
| gate gain | 完全 mute が不自然な場合は `silenceGain` を `0.1` などに上げる |
| リアルタイム処理 | 高頻度コールを想定し、Audio Session や engine 操作は行わない |

試験範囲は[自動検証範囲](../../../../validation/自動検証範囲.md)を参照する。

## 設定と並行実行の境界

init・applyで可変または復号済み設定を再正規化する。非有限設定値は安全な下限値へ、noise floorは−120…0 dBFSへ制限する。processの非有限RMSは−120 dBFS、無効durationは設定間隔として扱う。非有限sampleはgate出力で0にする。apply・reset・process・snapshotを同じlockで保護し、設定変更と音声処理が重なっても内部状態を競合させない。
