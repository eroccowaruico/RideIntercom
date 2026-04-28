# EffectSoundIsolation 仕様

EffectSoundIsolation は Apple 標準の `AUSoundIsolation` Audio Unit を、RideIntercom の音声パイプラインから再利用しやすい Swift Package として切り出したエフェクトライブラリである。

このライブラリはマイク入力、受信音声、ミキサー出力など任意の `AVAudioEngine` ノードチェーンに差し込める音声分離エフェクトだけを扱う。音声ルーティング、通信、コーデック、録音、再生デバイス制御は責務に含めない。

## 目的

| 観点 | 仕様 |
|---|---|
| 主目的 | `kAudioUnitSubType_AUSoundIsolation` を `AVAudioUnitEffect` として生成し、任意の `AVAudioEngine` グラフに挿入できるようにする |
| 利用箇所 | マイク入力後、受信音声再生前、個別チャンネル、マスター出力前など、呼び出し側が選んだ位置 |
| 非目的 | VoiceProcessingIO への固定、マイク権限管理、Audio Session 管理、通信経路への組み込み、音声仕様全体の変更 |
| 設計姿勢 | Audio Unit の存在確認、設定値の正規化、パラメータ適用だけを薄く包む |

## パッケージ構成

| 項目 | 内容 |
|---|---|
| パス | `RideIntercom/EffectSoundIsolation` |
| Package 名 | `EffectSoundIsolation` |
| Product | `EffectSoundIsolation` library |
| 対応プラットフォーム | iOS 17 以降、macOS 14 以降 |
| 使用フレームワーク | `AVFAudio`, `AudioToolbox` |
| テスト | Swift Testing による SwiftPM テスト |

## 公開API

| API | 種別 | 役割 |
|---|---|---|
| `VoiceIsolationSupport` | enum | `AUSoundIsolation` の `AudioComponentDescription` と利用可否を提供する |
| `VoiceIsolationConfiguration` | struct | 分離対象と Wet/Dry Mix を保持する |
| `VoiceIsolationSoundType` | enum | `voice` と `highQualityVoice` の選択肢を表す |
| `VoiceIsolationEffect` | final class | `AVAudioUnitEffect` を生成し、設定を Audio Unit parameter に適用する |
| `VoiceIsolationError` | enum | 生成不可、未対応設定、パラメータ欠落などの失敗理由を表す |

## Audio Unit 定義

| Audio Unit 属性 | 値 |
|---|---|
| componentType | `kAudioUnitType_Effect` |
| componentSubType | `kAudioUnitSubType_AUSoundIsolation` |
| componentManufacturer | `kAudioUnitManufacturer_Apple` |
| componentFlags | `0` |
| componentFlagsMask | `0` |

`VoiceIsolationSupport.isAvailable` は `AudioComponentFindNext` で現在の実行環境に `AUSoundIsolation` が存在するか確認する。呼び出し側はこの値を見て、設定UIの有効化やフォールバック経路の選択を行う。

## 設定仕様

| 設定 | 型 | 入力範囲 | Audio Unit へ渡す値 | 既定値 | 備考 |
|---|---|---|---|---|---|
| `soundType` | `VoiceIsolationSoundType` | `voice`, `highQualityVoice` | `kAUSoundIsolationParam_SoundToIsolate` | `voice` | `highQualityVoice` は iOS 18 以降、macOS 15 以降でのみ使用する |
| `mix` | `Float` | `0.0...1.0` | `kAUSoundIsolationParam_WetDryMixPercent` に `0...100` として渡す | `1.0` | 範囲外入力は初期化時に `0.0...1.0` へ丸める |

| `VoiceIsolationSoundType` | Audio Unit 値 | OS availability |
|---|---|---|
| `voice` | `kAUSoundIsolationSoundType_Voice` | iOS 16 以降、macOS 13 以降 |
| `highQualityVoice` | `kAUSoundIsolationSoundType_HighQualityVoice` | iOS 18 以降、macOS 15 以降 |

`VoiceIsolationSoundType.highQualityVoice` はライブラリの対応OS下限より新しい定数を使うため、未対応OSでは `parameterValue` を持たない。未対応OSで `VoiceIsolationEffect.apply` に渡した場合は `VoiceIsolationError.unsupportedSoundType` を返す。

## 生成と適用

| 処理 | 仕様 |
|---|---|
| 生成 | `VoiceIsolationEffect.make(configuration:)` が `AUSoundIsolation` の存在確認後に `AVAudioUnitEffect.instantiate` で生成する |
| ノード取得 | `VoiceIsolationEffect.node` で `AVAudioNode` として取得する |
| 詳細アクセス | `VoiceIsolationEffect.avAudioUnitEffect` で `AVAudioUnitEffect` として取得する |
| 設定適用 | `VoiceIsolationEffect.apply(_:)` が Audio Unit parameter tree に Wet/Dry Mix と Sound Type を設定する |
| 設定保持 | 適用成功時のみ `configuration` を更新する |
| 失敗時 | Audio Unit がない、生成に失敗した、必要な parameter がない、未対応 Sound Type が指定された場合に throw する |

## 接続例

| ユースケース | ノード接続 |
|---|---|
| 受信音声のノイズ除去 | `PlayerNode -> VoiceIsolationEffect.node -> Mixer` |
| マスター出力のクリーンアップ | `Mixer -> VoiceIsolationEffect.node -> OutputNode` |
| 個別チャンネル処理 | `PlayerNode -> VoiceIsolationEffect.node -> SubMixer` |
| マイク取得後のノイズ除去 | `InputNode/Tap Source -> VoiceIsolationEffect.node -> Encoder or Mixer` |

```swift
import AVFAudio
import EffectSoundIsolation

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let isolation = try await VoiceIsolationEffect.make(
    configuration: VoiceIsolationConfiguration(soundType: .voice, mix: 1.0)
)

engine.attach(player)
engine.attach(isolation.avAudioUnitEffect)
engine.connect(player, to: isolation.node, format: format)
engine.connect(isolation.node, to: engine.mainMixerNode, format: format)
```

## エラー仕様

| Error | 発生条件 | 呼び出し側の扱い |
|---|---|---|
| `audioUnitUnavailable` | `AudioComponentFindNext` で `AUSoundIsolation` が見つからない | エフェクトなしの経路へフォールバックする |
| `instantiationFailed` | `AVAudioUnitEffect.instantiate` が Audio Unit を返さない | ログへ失敗理由を残し、エフェクトなしの経路へフォールバックする |
| `unsupportedSoundType` | 現在OSで使えない `VoiceIsolationSoundType` が指定された | `.voice` へ戻す、または設定UIで選択不可にする |
| `missingParameter` | Audio Unit parameter tree に必要な parameter が存在しない | Audio Unit の互換性問題として扱い、エフェクトなしの経路へフォールバックする |

## 制約と注意点

| 観点 | 内容 |
|---|---|
| レイテンシ | ML ベースの処理で遅延が増えるため、リアルタイム通話では実測で確認する |
| チャンネル | 音声分離は主に音声信号を想定する。ステレオや多チャンネル信号へ適用する場合は呼び出し側で検証する |
| 実行環境差 | OSが対応していても環境によって Audio Unit が利用できない可能性があるため、必ず `isAvailable` または `make` の失敗を扱う |
| ライブラリ責務 | フォールバック音声経路の構築、UI表示、診断ログ、音声品質評価は呼び出し側で行う |

## テスト仕様

| テスト観点 | 確認内容 |
|---|---|
| Audio Unit descriptor | Apple の `AUSoundIsolation` effect を指す定数になっている |
| Mix 正規化 | `mix` が `0.0...1.0` に丸められる |
| Wet/Dry 変換 | `mix` が `0...100` の `kAUSoundIsolationParam_WetDryMixPercent` 値へ変換される |
| Sound Type | `.voice` が安定して `kAUSoundIsolationSoundType_Voice` へ変換される |
| High Quality availability | `.highQualityVoice` が iOS 18 / macOS 15 未満では使用不可として扱われる |

実 Audio Unit の存在や音質は実行環境に依存するため、単体テストでは設定値と descriptor の正しさを検証する。実機やOS差を含む音声品質評価は、このライブラリを呼び出す統合経路側で扱う。