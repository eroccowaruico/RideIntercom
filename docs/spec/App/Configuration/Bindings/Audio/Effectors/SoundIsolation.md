# SoundIsolation package 設定値

## 目的

本書は RideIntercom App が `SoundIsolation` package へ渡す設定値を定義する。

画面から直接設定する値は `docs/spec/App/Configuration/設定値一覧.md` を正とし、本書では固定値、導出値、package adapter が決める値だけを扱う。

## VoiceIsolationConfiguration

| package 設定 | App から渡す値 | 種別 |
|---|---|---|
| `VoiceIsolationConfiguration` | package default | 固定 |
| TX effect chain 挿入 | 対応時はnodeを保持、`isSoundIsolationEnabled` でbypassを切替 | Settings の送信設定と runtime support から導出 |
| RX peer bus effect chain 挿入 | 対応時はnodeを保持、`remoteSoundIsolationEnabled[peerID, default: false]` でbypassを切替 | Call の参加者設定と runtime support から導出 |
| RX master bus effect chain 挿入 | 対応時はnodeを保持、`receiveMasterSoundIsolationEnabled` でbypassを切替 | Call の master 出力設定と runtime support から導出 |
| runtime snapshot | `VoiceIsolationRuntimeSnapshot` を chain ごとに `RTCRuntimePackageReport` と AudioMixer effect metadata に載せる | runtime report |

Settings の `Voice Isolation Effect` は送信用 `SoundIsolation` package の effect-level 設定として扱う。Call の参加者行と master 出力行は受信側 peer bus / RX master bus の effect-level 設定として扱う。SessionManager の `AudioInputVoiceProcessingConfiguration.soundIsolationEnabled` へは渡さない。mix などの Audio Unit parameter は画面設定にしない。

| 状態 | App の扱い |
|---|---|
| chain ごとの有効設定が `true` かつ `VoiceIsolationSupport.isAvailable == true` | 該当 bus の effect chain に `VoiceIsolationEffect` を挿入する |
| chain ごとの有効設定が `true` かつ `VoiceIsolationSupport.isAvailable == false` | Toggle を非表示にし、support reportで非対応とする。存在しないnodeをchainへ捏造しない |
| chain ごとの有効設定が `false` | 実Audio Unitのbypassを有効にし、runtime chain snapshot では bypassed stage として返し、Diagnostics はその snapshot を表示する。実音声処理では no-op / bypass として扱い、App 側で別の表示用 stage を作らない |

## App 画面に出さない値

| 値 | 扱い |
|---|---|
| wet / dry mix | package default |
| Audio Unit parameter | package 仕様を正とする |
| support check / fallback の詳細 | package adapter で扱う |

詳細な SoundIsolation の仕様は `docs/spec/packages/Audio/Effectors/SoundIsolation.md` を正とする。

## 通話の音声保持

音声分離を有効にしたbusは処理音50%・原音50%のmixを指定する。送信・相手別・全体を重ねた場合も、各分類器が落とす弱い音節を残すため、既知の発話で全文を比較して設定する。無効busはmix 100%のままbypassする。package既定値のmix 100%は変更しない。原音を残す分、背景音の抑制は弱くなるため、走行音・Bluetoothを含む実機評価で確認する。
