# AudioMixer package 設定値

## 目的

本書は RideIntercom App が `AudioMixer` package へ渡す設定値を定義する。

画面から直接設定する値は `docs/spec/App/Configuration/設定値一覧.md` を正とし、本書では固定値、導出値、package adapter が決める値だけを扱う。

## Mixer 設定

| package 設定 | App から渡す値 | 種別 |
|---|---|---|
| format | 48kHz mono。TX sinkは選択RTC format、RX sinkはSessionManagerのactualHardwareFormat | adapter 導出 |
| `addPCMSource.maximumBufferedDuration` | 通話TXは`0.2`秒、RXは`0.4`秒（再生開始までの待ち時間と単一frame長）、Audio Checkは`nil` | adapter固定 |
| `addPCMSource.captureTimePlayoutDelay` | 通話TXは`0.1`秒、RXは`0.2`秒、Audio Checkは`nil` | adapter固定 |
| TX bus effect chain | `AudioMixerSnapshot.buses[id == "tx-bus"].effectChain`。SoundIsolation → DynamicsProcessor → PeakLimiter。VADGateはMixer前段 | adapter 導出 |
| RX peer bus effect chain | `AudioMixerSnapshot.buses[id == "rx-peer-{peerID}"].effectChain`。SoundIsolationを接続し `remoteSoundIsolationEnabled` でbypassを切替 | 画面設定から導出 |
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

通話の送信・再生sinkは`maximumFrameDuration: 0.02`を指定する。OSがtapへ100 ms以上のbufferを渡しても、通信payloadと再生予約は20 ms以下のPCMを単位に処理する。

通常の100 ms tap配送が未再生tailに重なるため、通話TX sourceは収録時刻に沿って再生し、開始待機100 ms・最大待ち200 msとする。入力の100 ms batchが50 ms遅れても途中で再生を枯らさず、VAD前後で発話の時刻を詰めない。受信sourceは収録時刻の差に沿って再生し、初期の再生待ち200 ms・最大待ち400 msを指定する。実測のpacket到着時刻の幅約172 msを吸収し、無音後の語頭を到着ごとにずらさないための有限設定である。上限を超える停滞・時計不連続はpackageが再基準化する。AppでPCMを加工せず、packageの時刻再生APIへ設定を渡す。

通話の最終hardware出力はSessionManagerの200 ms上限を使用する。これは100 ms以内の配送待ちから2batchがまとまる場合を受け入れる上限であり、固定の待機追加はない。無音のrender frameも順番に出力へ渡し、無音の除去で再生時間を詰めない。通信なし結合試験は従来の100 ms設定・追加待機なしのまま、20 ms / 100 ms配送の連続性を検証する。これらは各境界の上限で、端末間の遅延保証ではない。

Codecとbit rateの変更ではMixerを再構築せず、Appのpacket符号化設定だけを更新する。受信側の予約と時刻の基準は保持する。RTC PCM formatなどgraph形式が変わる場合は再構築する。
