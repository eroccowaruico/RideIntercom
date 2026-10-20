# DynamicsProcessor 仕様

DynamicsProcessor は Apple 標準の `AUDynamicsProcessor` Audio Unit を、RideIntercom の音声パイプラインから再利用しやすい Swift Package として切り出したエフェクトライブラリである。

このライブラリはマイク入力、受信音声、ミキサー出力など任意の `AVAudioEngine` ノードチェーンに差し込めるダイナミクス処理エフェクトだけを扱う。音声ルーティング、通信、コーデック、録音、再生デバイス制御は責務に含めない。

## 目的

| 観点 | 仕様 |
|---|---|
| 主目的 | `kAudioUnitSubType_DynamicsProcessor` を `AVAudioUnitEffect` として生成し、任意の `AVAudioEngine` グラフに挿入できるようにする |
| 体験上の目的 | 声の音量差をならし、急な大音量を抑え、通話で聞き取りやすい存在感を作る |
| 利用箇所 | マイク入力後、SoundIsolation後、EQ後、受信音声再生前、マスター出力前など、呼び出し側が選んだ位置 |
| 非目的 | ノイズ除去そのもの、ピークの最終保護、Audio Session 管理、通信経路への組み込み、音声仕様全体の変更 |
| 設計姿勢 | Audio Unit の存在確認、声用途の初期設定、設定値の正規化、パラメータ適用だけを薄く包む |

## パッケージ構成

| 項目 | 内容 |
|---|---|
| パス | `RideIntercom/Effectors/DynamicsProcessor` |
| Package 名 | `DynamicsProcessor` |
| Product | `DynamicsProcessor` library |
| 対応プラットフォーム | iOS 17 以降、macOS 14 以降 |
| 使用フレームワーク | `AVFAudio`, `AudioToolbox` |
| テスト | Swift Testing による SwiftPM テスト |

## 公開API

| API | 種別 | 役割 |
|---|---|---|
| `DynamicsProcessorSupport` | enum | `AUDynamicsProcessor` の `AudioComponentDescription` と利用可否を提供する |
| `DynamicsProcessorSupportSnapshot` | struct | Audio Unit availability を Codable で返す |
| `DynamicsProcessorConfiguration` | struct | ダイナミクス処理の設定値を保持する |
| `DynamicsProcessorRuntimeSnapshot` | struct | 現在の設定、support 情報、runtime state を Codable で返す |
| `DynamicsProcessorRuntimeState` | enum | `active` または `unavailable` の実行状態を表す |
| `DynamicsProcessorEffect` | final class | `AVAudioUnitEffect` を生成し、設定を Audio Unit parameter に適用する |
| `DynamicsProcessorError` | enum | 生成不可、パラメータ欠落などの失敗理由を表す |

## Audio Unit 定義

| Audio Unit 属性 | 値 |
|---|---|
| componentType | `kAudioUnitType_Effect` |
| componentSubType | `kAudioUnitSubType_DynamicsProcessor` |
| componentManufacturer | `kAudioUnitManufacturer_Apple` |
| componentFlags | `0` |
| componentFlagsMask | `0` |

`DynamicsProcessorSupport.isAvailable` は `AudioComponentFindNext` で現在の実行環境に `AUDynamicsProcessor` が存在するか確認する。呼び出し側はこの値を見て、設定UIの有効化やフォールバック経路の選択を行う。

## 設定仕様

| 設定 | 型 | 入力範囲 | Audio Unit へ渡す値 | 既定値 | 備考 |
|---|---|---|---|---|---|
| `threshold` | `Float` | `-60...0` dB | `kDynamicsProcessorParam_Threshold` | `-24` | 圧縮が始まる目安。声用途で強すぎない初期値にする |
| `headRoom` | `Float` | `0...40` dB | `kDynamicsProcessorParam_HeadRoom` | `6` | 小さいほど圧縮が強くなる。初期値は 5 から 8 dB の範囲を採用する |
| `expansionRatio` | `Float` | `1...50` | `kDynamicsProcessorParam_ExpansionRatio` | `1` | 初期値では無効寄り。語尾切れを避ける |
| `expansionThreshold` | `Float` | `-120...0` dB | `kDynamicsProcessorParam_ExpansionThreshold` | `-70` | expansion を使う場合のしきい値 |
| `attackTime` | `Float` | `0.001...0.2` sec | `kDynamicsProcessorParam_AttackTime` | `0.01` | 声の立ち上がりを潰しすぎない速度 |
| `releaseTime` | `Float` | `0.01...3` sec | `kDynamicsProcessorParam_ReleaseTime` | `0.12` | 音量の戻りを自然にする速度 |
| `overallGain` | `Float` | `-40...40` dB | `kDynamicsProcessorParam_OverallGain` | `0` | 圧縮後の補正ゲイン。旧 `MasterGain` は使わない |

範囲外入力は `DynamicsProcessorConfiguration` の初期化時に上表の範囲へ丸める。

## Runtime snapshot 仕様

| 項目 | 型 | 意味 |
|---|---|---|
| `configuration` | `DynamicsProcessorConfiguration` | 現在適用されている dynamics 設定 |
| `support.isAvailable` | `Bool` | 現在の実行環境で `AUDynamicsProcessor` Audio Unit が見つかるか |
| `state` | `DynamicsProcessorRuntimeState` | support から見た実行状態 |

`DynamicsProcessorSupport.snapshot` は effect を生成できない環境でも support 情報を返す。`DynamicsProcessorEffect.runtimeSnapshot` は生成済み effect の設定と現在環境の support を返す。DynamicsProcessor package は AudioMixer や RTC の型へ依存しない。

## 生成と適用

| 処理 | 仕様 |
|---|---|
| 生成 | `DynamicsProcessorEffect.make(configuration:)` が `AUDynamicsProcessor` の存在確認後に `AVAudioUnitEffect(audioComponentDescription:)` で生成する |
| ノード取得 | `DynamicsProcessorEffect.node` で `AVAudioNode` として取得する |
| 詳細アクセス | `DynamicsProcessorEffect.avAudioUnitEffect` で `AVAudioUnitEffect` として取得する |
| 設定適用 | `DynamicsProcessorEffect.apply(_:)` が Audio Unit parameter tree に各設定値を設定する |
| runtime snapshot | `DynamicsProcessorEffect.runtimeSnapshot` が設定、support、state を返す |
| 設定保持 | 適用成功時のみ `configuration` を更新する |
| 失敗時 | Audio Unit がない、生成に失敗した、必要な parameter がない場合に throw する |

## 接続例

| ユースケース | ノード接続 |
|---|---|
| マイク音声の聞き取りやすさ調整 | `Input Source -> DynamicsProcessorEffect.node -> Encoder or Mixer` |
| SoundIsolation後の音量差補正 | `SoundIsolationEffect.node -> DynamicsProcessorEffect.node -> Mixer` |
| 受信音声の音量差補正 | `PlayerNode -> DynamicsProcessorEffect.node -> Mixer` |
| 出力前の軽い整音 | `Mixer -> DynamicsProcessorEffect.node -> PeakLimiterEffect.node -> OutputNode` |

```swift
import AVFAudio
import DynamicsProcessor

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let dynamics = try DynamicsProcessorEffect.make(
    configuration: DynamicsProcessorConfiguration()
)

engine.attach(player)
engine.attach(dynamics.avAudioUnitEffect)
engine.connect(player, to: dynamics.node, format: format)
engine.connect(dynamics.node, to: engine.mainMixerNode, format: format)
```

## エラー仕様

| Error | 発生条件 | 呼び出し側の扱い |
|---|---|---|
| `audioUnitUnavailable` | `AudioComponentFindNext` で `AUDynamicsProcessor` が見つからない | エフェクトなしの経路へフォールバックする |
| `missingParameter` | Audio Unit parameter tree に必要な parameter が存在しない | Audio Unit の互換性問題として扱い、エフェクトなしの経路へフォールバックする |

## 制約と注意点

| 観点 | 内容 |
|---|---|
| かけすぎ | 圧縮を強くしすぎると息継ぎ、環境音、ノイズも持ち上がるため、初期値は控えめにする |
| expansion | ノイズゲート的に使えるが、声用途で強くすると語尾が切れやすいため初期値は無効寄りにする |
| リミッターとの関係 | クリップ最終保護は PeakLimiter の責務とし、DynamicsProcessor は聞き取りやすさの調整を主目的にする |
| ライブラリ責務 | フォールバック音声経路の構築、UI表示、診断ログ、音声品質評価は呼び出し側で行う |

## テスト仕様

| テスト観点 | 確認内容 |
|---|---|
| Audio Unit descriptor | Apple の `AUDynamicsProcessor` effect を指す定数になっている |
| 既定値 | RideIntercom の声用途初期設定になっている |
| 値の正規化 | 各設定値が定義範囲に丸められる |
| runtime snapshot | 設定、support、state を Codable として roundtrip できる |

実 Audio Unit の存在や音質は実行環境に依存するため、単体テストでは設定値と descriptor の正しさを検証する。実機やOS差を含む音声品質評価は、このライブラリを呼び出す統合経路側で扱う。

## 固定Apple Audio Unitの生成

| 項目 | 契約 |
|---|---|
| `make(configuration:) throws` | 組込みApple Audio Unitを存在確認後に同期生成し、設定を適用して返す。audio render callbackからは呼ばない |
| グラフ構成 | node生成・設定・busへの挿入を同じ構成工程で完了できる。生成待ちの古いcallbackが新しいgraphへ混入しない |
| 検証 | 実Audio Unitの生成、parameterの再適用、runtime snapshot一致を実行する |

任意の外部AU extensionの非同期ロードは対象外。旧async factoryは残さず、Apple SDKのEffect initializerを使用する。
