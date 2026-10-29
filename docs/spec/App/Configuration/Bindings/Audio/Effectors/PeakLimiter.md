# PeakLimiter package 設定値

## 目的

本書は RideIntercom App が `PeakLimiter` package へ渡す設定値を定義する。

画面から直接設定する値は `docs/spec/App/Configuration/設定値一覧.md` を正とし、本書では固定値、導出値、package adapter が決める値だけを扱う。

## PeakLimiterConfiguration

| package 設定 | App から渡す値 | 種別 |
|---|---|---|
| `PeakLimiterConfiguration` | attack 0.001秒、decay / pre-gainはpackage default | 固定 |
| TX effect chain 挿入 | App adapter の固定構成で決める | adapter 導出 |
| RX master effect chain 挿入 | RX masterのfader後にrouteするrx-output busへ必ず挿入する | adapter 固定 |
| runtime snapshot | `PeakLimiterRuntimeSnapshot` を `RTCRuntimePackageReport(kind: transmitRuntimeSnapshot / receiveMasterRuntimeSnapshot)` に載せる | runtime report |

PeakLimiter の attack、decay、pre-gain などは画面設定として提供しない。

RX master 側の PeakLimiter はユーザー設定を持たない安全弁として扱う。peer bus、master volume、master effect chain の処理後、出力 stream へ渡す直前の最終段に置く。

## App 画面に出さない値

| 値 | 扱い |
|---|---|
| attack time | 0.001秒。送受信の先読み待ちを最小化する |
| decay time | package default |
| pre-gain | package default |
| Audio Unit parameter | package 仕様を正とする |

詳細な PeakLimiter の仕様は `docs/spec/packages/Audio/Effectors/PeakLimiter.md` を正とする。
