# DynamicsProcessor package 設定値

## 目的

本書は RideIntercom App が `DynamicsProcessor` package へ渡す設定値を定義する。

画面から直接設定する値は `docs/spec/App/Configuration/設定値一覧.md` を正とし、本書では固定値、導出値、package adapter が決める値だけを扱う。

## DynamicsProcessorConfiguration

| package 設定 | App から渡す値 | 種別 |
|---|---|---|
| `DynamicsProcessorConfiguration` | package default | 固定 |
| effect chain 挿入 | App adapter の固定構成で決める | adapter 導出 |
| runtime snapshot | `DynamicsProcessorRuntimeSnapshot` を `RTCRuntimePackageReport(kind: transmitRuntimeSnapshot)` に載せる | runtime report |

DynamicsProcessor の threshold、head room、attack、release などは画面設定として提供しない。

## App 画面に出さない値

| 値 | 扱い |
|---|---|
| threshold / head room | package default |
| attack / release | package default |
| master gain | package default |
| Audio Unit parameter | package 仕様を正とする |

詳細な DynamicsProcessor の仕様は `docs/spec/packages/Audio/Effectors/DynamicsProcessor.md` を正とする。
