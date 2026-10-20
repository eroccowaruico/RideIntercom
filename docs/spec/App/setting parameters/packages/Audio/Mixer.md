# AudioMixer package 設定値

## 目的

本書は RideIntercom App が `AudioMixer` package へ渡す設定値を定義する。

画面から直接設定する値は `docs/spec/App/setting parameters/App/設定値一覧.md` を正とし、本書では固定値、導出値、package adapter が決める値だけを扱う。

## Mixer 設定

| package 設定 | App から渡す値 | 種別 |
|---|---|---|
| format | 48kHz mono。TX sinkは選択RTC format、RX sinkはSessionManagerのactualHardwareFormat | adapter 導出 |
| TX bus effect chain | `AudioMixerSnapshot.buses[id == "tx-bus"].effectChain`。現在は空。VADGateはMixer前段で適用し、他のeffect実ノードは未接続 | adapter 導出 |
| RX peer bus effect chain | `AudioMixerSnapshot.buses[id == "rx-peer-{peerID}"].effectChain`。現在は空。`remoteSoundIsolationEnabled` は設定値のみで、実ノードは未接続 | 画面設定から導出 |
| RX master bus effect chain | `AudioMixerSnapshot.buses[id == "rx-master"].effectChain`。現在は空。SoundIsolation / PeakLimiterの実ノードは未接続 | 画面設定 + adapter 固定 |
| master bus volume | `isOutputMuted ? 0 : masterOutputVolume` | 画面設定から導出 |
| peer bus volume | `remoteOutputVolumes[peerID]`。未設定 peer は `1.0` | 画面設定から導出 |

受信側は peer ごとに RX peer bus を作り、全 RX peer bus を receive master bus へ route して mix down する。相手が複数いる場合は peer bus も複数になり、master bus は mix 後の 1 本だけを表す。

TX bus、RX peer bus、RX master bus の effect chain は AudioMixer package の `MixerBusSnapshot.effectChain` を正とする。App の `transmitEffectChainSnapshot`、`receivePeerEffectChainSnapshot(peerID:)`、`receiveMasterEffectChainSnapshot` は `AudioMixerSnapshot` から表示用 stage metadata へ薄く写すだけで、effect の default 値や stage 配列を持たない。

## Snapshot / graph の扱い

| snapshot | App での扱い |
|---|---|
| `AudioMixerSnapshot.busIDs` | TX bus、RX peer bus、RX master bus の存在確認に使う |
| `MixerBusSnapshot.sources` | マイク入力、RTC peer audio source、master 入力数の表示に使う |
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

詳細な bus、format、routing の仕様は `docs/spec/packages/Audio/Mixer.md` を正とする。
