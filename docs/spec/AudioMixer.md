# AudioMixer 仕様

AudioMixer は `AVAudioEngine` と `AVAudioMixerNode` を使い、RideIntercom のアプリ内音声を Bus 単位でまとめる Swift Package である。

このライブラリはミキサーグラフの作成、Bus 作成、Source 追加、Bus 単位の Effect chain、Bus 間 routing、最終 output への接続だけを扱う。マイク取得、スピーカー出力制御、通信、コーデック、エフェクト生成、Audio Session 管理は責務に含めない。

## 目的

| 観点 | 仕様 |
|---|---|
| 主目的 | インカム用途のローカル音声、リモート音声、監視音声などを Bus として扱い、同じ API でサブミックスと最終出力へ routing できるようにする |
| 利用箇所 | 通話画面または音声処理経路で、入力済みの `AVAudioNode` や Effectors の `AVAudioNode` を接続する場所 |
| 非目的 | BGM/SFX ミキサー、音楽制作用ミキサー、複数 send/aux、parallel effect chain、AUv3 外部公開 |
| 設計姿勢 | 通常チャンネル、グループ、マスターをすべて `MixerBus` として扱い、API を増やさない |

## パッケージ構成

| 項目 | 内容 |
|---|---|
| パス | `RideIntercom/AudioMixer` |
| Package 名 | `AudioMixer` |
| Product | `AudioMixer` library |
| 対応プラットフォーム | iOS 17 以降、macOS 14 以降 |
| 使用フレームワーク | `AVFAudio` |
| テスト | Swift Testing による SwiftPM テスト |

## 公開API

| API | 種別 | 役割 |
|---|---|---|
| `AudioMixer` | final class | `AVAudioEngine` を保持し、Bus 作成、routing、output 接続、start/stop を行う |
| `MixerBus` | final class | Bus 内の input mixer、effect chain、fader mixer、source/effect 追加を扱う |
| `AudioMixerError` | enum | Bus ID 不正、未知 Bus、routing 不正、循環 routing、effect index 不正などの失敗理由を表す |

## 基本グラフ

| 要素 | 内部ノード | 役割 |
|---|---|---|
| Source | 呼び出し側が渡す `AVAudioNode` | マイク入力後のノード、リモート受信再生ノード、検証用プレイヤーなど |
| `MixerBus.inputMixer` | `AVAudioMixerNode` | Source または子 Bus からの複数入力をまとめる |
| Effect chain | `[AVAudioNode]` | SoundIsolation、DynamicsProcessor、PeakLimiter などを順番に挿入する |
| `MixerBus.faderMixer` | `AVAudioMixerNode` | Bus 全体の volume を調整する |
| Output | `AVAudioEngine.mainMixerNode` | 最終 Bus からシステム出力へ渡す |

Bus 内部の接続は次の形に固定する。

```text
sources or child buses
  -> inputMixer
  -> effect1
  -> effect2
  -> effect3
  -> faderMixer
  -> parent bus or engine.mainMixerNode
```

## フォーマット仕様

| 設定 | 値 |
|---|---|
| commonFormat | `.pcmFormatFloat32` |
| sampleRate | `48_000` |
| channels | `2` |
| interleaved | `false` |

`AudioMixer.defaultFormat` は上表の固定フォーマットを返す。`AudioMixer.init(engine:format:)` で別 format を渡せるが、RideIntercom の初期利用では stereo / Float32 / 48kHz を基本とする。

## `AudioMixer` 仕様

| 処理 | 仕様 |
|---|---|
| 初期化 | `AVAudioEngine` と `AVAudioFormat` を保持する。既定では新規 `AVAudioEngine` と `defaultFormat` を使う |
| `createBus(_:)` | 空でない ID の Bus を作成し、`inputMixer` と `faderMixer` を attach して直結する。同じ ID がある場合は既存 Bus を返す |
| `bus(_:)` | 作成済み Bus を ID で取得する |
| `busIDs` | 作成済み Bus ID を昇順で返す |
| `route(_:to:)` | 子 Bus の `outputNode` を親 Bus の `inputMixer.nextAvailableInputBus` へ接続する |
| `routeToOutput(_:)` | Bus の `outputNode` を `engine.mainMixerNode` へ接続する |
| `start()` | `engine.prepare()` 後に `engine.start()` を呼ぶ |
| `stop()` | `engine.stop()` を呼ぶ |

## `MixerBus` 仕様

| 処理 | 仕様 |
|---|---|
| `volume` | `faderMixer.outputVolume` を読み書きする |
| `outputNode` | 親 Bus または output へ接続するため `faderMixer` を返す |
| `addSource(_:)` | Source node を engine に attach し、`inputMixer.nextAvailableInputBus` へ接続する |
| `addEffect(_:)` | Effect node を engine に attach して末尾に追加し、Bus 内 chain を再構築する |
| `removeEffect(at:)` | 指定 index の Effect node を chain から外し、engine から detach して chain を再構築する |
| `effects` | 現在の Effect chain を順序付きで保持する |

`addEffect(_:)` と `removeEffect(at:)` は `inputMixer -> effects -> faderMixer` を再接続する。再生中の頻繁な追加削除はグリッチ原因になるため、基本は start 前に構成を作る。再生中の調整は volume や Effectors 側の parameter 変更を使う。

## Routing 制約

| 制約 | 仕様 |
|---|---|
| Bus 管理 | `route` と `routeToOutput` は同じ `AudioMixer` が作成した Bus のみ受け付ける |
| 親数 | 1つの Bus は親 Bus または output のどちらか1つだけへ送れる |
| 循環 | `A -> B -> C -> A` になる routing は禁止する |
| 出力 | v1 では `routeToOutput` できる最終 Bus は1つだけとする |
| 複数 send | 1つの Bus を複数 Bus へ同時に送る send/aux は扱わない |

## インカム用途の接続例

| Bus | 役割 | 例 |
|---|---|---|
| `localVoice` | ローカルマイク処理後の音声 | VAD 後や送信前モニター用の source を追加する |
| `remotePeer` | 受信した相手音声 | 受信再生用 player node を追加する |
| `voiceMaster` | 通話音声のサブミックス | local/remote の音量差をまとめて調整する |
| `finalMaster` | 最終出力 | PeakLimiter などの安全弁を最後に置く |

```swift
import AVFAudio
import AudioMixer

let mixer = AudioMixer()

let localVoice = try mixer.createBus("localVoice")
let remotePeer = try mixer.createBus("remotePeer")
let voiceMaster = try mixer.createBus("voiceMaster")
let finalMaster = try mixer.createBus("finalMaster")

try localVoice.addSource(localMonitorNode)
try remotePeer.addSource(remotePlayerNode)

try localVoice.addEffect(localVoiceLimiterNode)
try remotePeer.addEffect(remoteDynamicsNode)
try voiceMaster.addEffect(masterLimiterNode)

localVoice.volume = 0.8
remotePeer.volume = 1.0
voiceMaster.volume = 1.0
finalMaster.volume = 1.0

try mixer.route(localVoice, to: voiceMaster)
try mixer.route(remotePeer, to: voiceMaster)
try mixer.route(voiceMaster, to: finalMaster)
try mixer.routeToOutput(finalMaster)

try mixer.start()
```

上記はインカム用途の利用イメージである。BGM/SFX や音楽制作向けのチャンネル設計はこの仕様の対象外とする。

## Effectors との関係

| ライブラリ | AudioMixer からの扱い |
|---|---|
| SoundIsolation | `VoiceIsolationEffect.node` または `avAudioUnitEffect` を `addEffect(_:)` に渡す |
| DynamicsProcessor | `DynamicsProcessorEffect.node` または `avAudioUnitEffect` を `addEffect(_:)` に渡す |
| PeakLimiter | `PeakLimiterEffect.node` または `avAudioUnitEffect` を `addEffect(_:)` に渡す |

AudioMixer は Effect node の生成や parameter 設定を行わない。Effectors 側で生成済みの `AVAudioNode` を受け取り、Bus 内の順序付き chain に接続する。

## エラー仕様

| Error | 発生条件 | 呼び出し側の扱い |
|---|---|---|
| `emptyBusID` | `createBus("")` が呼ばれた | 呼び出し側の ID 定義を修正する |
| `unknownBus` | 別 mixer の Bus または未管理 Bus を routing した | 同じ `AudioMixer` が作成した Bus を使う |
| `invalidRoute` | 自分自身への route、source/effect の重複追加など不正な操作 | グラフ定義を修正する |
| `busAlreadyRouted` | Bus がすでに親 Bus または output に接続済み | v1 では複数 send を使わない構成へ直す |
| `cycleDetected` | 循環 routing になる | Bus 階層を木構造またはDAGとして見直す |
| `invalidEffectIndex` | 存在しない effect index を削除しようとした | `effects` の範囲内 index を指定する |

## v1 対応範囲

| 機能 | 対応 |
|---|---|
| Bus 作成 | 対応 |
| Source 追加 | 対応 |
| Bus ごとの複数 Effect | 対応 |
| Bus ごとの volume | 対応 |
| Bus から Bus への routing | 対応 |
| 最終 output への接続 | 対応 |
| Effect 追加後の chain 再構築 | 対応 |
| Effect 削除後の chain 再構築 | 対応 |
| 複数 send/aux | 非対応 |
| parallel effect chain | 非対応 |
| surround / ambisonics | 非対応 |
| AUv3 外部公開 | 非対応 |

## テスト仕様

| テスト観点 | 確認内容 |
|---|---|
| default format | stereo / Float32 / 48kHz / non-interleaved になっている |
| Bus 作成 | 同じ ID では既存 Bus を返し、空 ID は拒否する |
| volume | `MixerBus.volume` が `faderMixer.outputVolume` に反映される |
| Effect chain | 複数 Effect を追加でき、指定 index の Effect を削除できる |
| routing 制約 | 循環 routing と複数親 routing を拒否する |

実音声の音質や実デバイス出力は実行環境に依存するため、単体テストではグラフ定義、設定値、routing 制約を検証する。実マイク・実スピーカーを含む音声品質評価は、このライブラリを呼び出す統合経路側で扱う。
