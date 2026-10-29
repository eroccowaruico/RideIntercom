# AudioMixer package 設定値

## 目的

本書は RideIntercom App が `AudioMixer` package へ渡す設定値を定義する。

画面から直接設定する値は `docs/spec/App/Configuration/設定値一覧.md` を正とし、本書では固定値、導出値、package adapter が決める値だけを扱う。

## Mixer 設定

| package 設定 | App から渡す値 | 種別 |
|---|---|---|
| format | 48kHz mono。TX sinkは選択RTC format、RX sinkはSessionManagerのactualHardwareFormat | adapter 導出 |
| `addPCMSource.maximumBufferedDuration` | TXは同期AudioFrameProcessorで再生queueを持たない。RXは`0.12`秒（再生開始までの待ちと単一frame長）、Audio Checkは`nil` | adapter固定 |
| `addPCMSource.captureTimePlayoutDelay` | TXは待機なし。RXは描画済みブロックの終端から`0.002`秒を下限に`adaptivePlayout`を有効化、Audio Checkは`nil` | adapter固定 |
| TX bus effect chain | `AudioMixerSnapshot.buses[id == "tx-bus"].effectChain`。SoundIsolation → DynamicsProcessor → PeakLimiter。VADGateはMixer前段 | adapter 導出 |
| RX peer bus effect chain | `AudioMixerSnapshot.buses[id == "rx-peer-{peerID}"].effectChain`。SoundIsolationを接続し `remoteSoundIsolationEnabled` で実接続を切替（無効nodeはlatency補償の対象からも外す） | 画面設定から導出 |
| RX master bus effect chain | `AudioMixerSnapshot.buses[id == "rx-master"].effectChain`。SoundIsolation。master faderの後に `rx-output` busをrouteしPeakLimiterを適用 | 画面設定 + adapter 固定 |
| master bus volume | `isOutputMuted ? 0 : masterOutputVolume` | 画面設定から導出 |
| peer source volume | `remoteOutputVolumes[peerID]`。未設定 peer は `1.0` | 画面設定から導出 |

受信側は peer ごとに RX peer bus を作り、全 RX peer bus を receive master bus へ route して mix down する。相手が複数いる場合は peer bus も複数になり、master bus は mix 後の 1 本だけを表す。

TX bus、RX peer bus、RX master bus の effect chain は AudioMixer package の `MixerBusSnapshot.effectChain` を正とする。App の `transmitEffectChainSnapshot`、`receivePeerEffectChainSnapshot(peerID:)`、`receiveMasterEffectChainSnapshot` は `AudioMixerSnapshot` から表示用 stage metadata へ薄く写すだけで、effect の default 値や stage 配列を持たない。

RX masterの表示用effect chainは、実snapshotの `rx-master.effectChain` と `rx-output.effectChain` を信号順に結合する。speaker-output sinkはrx-outputに置き、最終Limiterの後段に追加gainを置かない。

## Snapshot / graph の扱い

| snapshot | App での扱い |
|---|---|
| `AudioMixerSnapshot.busIDs` | TX bus、RX peer bus、RX master bus の存在確認に使う |
| `MixerBusSnapshot.sources` | マイク入力、RTC peer audio source、予約時間・リセット回数を確認する |
| `MixerBusSnapshot.effectChain` | Diagnostics の effect chip の順序、状態、詳細に使う |
| `AudioMixerSnapshot.routes` | RX peer bus から `rx-master` への mix down 表示に使う |
| `AudioMixerSnapshot.outputBusID` | 最終出力へ接続された bus の確認に使う |
| `MixerGraphSnapshot.nodes` / `edges` | グラフ描画が必要な UI では node / edge をそのまま使う。App 固有の推測で経路を補完しない |

## App 画面に出さない値

| 値 | 扱い |
|---|---|
| default format | package 仕様を正とする |
| bus ID / routing | App adapter の固定構成として扱う |
| effect chain 再構築 | package adapter が扱い、画面設定にしない |
| effect index | package adapter が扱い、画面設定にしない |
| soft clip / limiter の内部値 | Effectors 側の設定に寄せる |

詳細な bus、format、routing の仕様は `docs/spec/packages/Audio/AudioMixer.md` を正とする。

通話TXはAudioFrameProcessorの同期manual renderingで、native effectを通したPCMを10ms単位に符号化する。受信のrender通知は実Audio Unit quantumで受け、再生sinkは20msを上限に分割する。100ms tap待機、送信用player、二つ目の送信hardware clockは使わない。

RXは相手ごとのcapture clockをplayer clockへ対応付ける。連続sampleは隙間・重複なく予約し、到着が遅れた場合だけ必要な分を遅らせる。既に出力済みの発話を切り詰めず、無音中に増えた待ちを短縮する。時計の大きなジャンプや120msを超える停滞は再基準化する。

通話の最終hardware出力はSessionManagerの200ms上限を使用する。これは過負荷時の鮮度制限であり、固定の待機追加はない。無音frameも渡してcodecと再生の時計を維持する。各境界の上限は端末間遅延の保証ではない。

Codec、bit rate、RTC PCM formatの変更では受信Mixerと相手decoderを保持し、送信encoderとsink target formatだけを更新する。effect有効状態を変えた場合は、packageが報告する処理遅延の間だけPCMStreamTransitionの2msフェード付き無音を入れ、古い音を貯めて後から流さない。通常の連続PCMは加工しない。
