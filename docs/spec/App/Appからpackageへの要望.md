# App から package への要望と現状の回避

本ドキュメントは解決済みの内容を残さないこと。
パッケージ更新時はこのドキュメントを参照して、App 側で回避している内容が解消されているか確認すること。
パッケージ更新時は本ドキュメントを編集や更新を一切しないこと。

## 目的

本書は、App 側で見つかった package の不足責務だけを記録する。

App を作り直す前提では、App 側の暫定実装や既存コードの棚卸しは本書に残さない。`docs/spec/packages` の仕様で吸収すべき不足が見つかった場合だけ、package 要求として追記する。

## 現在の package 要求

| package | 不足している責務 | App に暫定実装しない理由 | App から消す条件 |
|---|---|---|---|
| Audio/SessionManager | ハードウェア入出力の実 format と App が要求する stream format を分離して扱う。ハードウェア側はデバイス要求を尊重しつつ既定 48kHz / mono を優先し、実 format が requested stream format と異なる場合は package 内で PCM を変換してから `AudioStreamFrame` と output renderer へ渡す。input/output snapshot と operation report には requested stream format、実 hardware format、変換有無、変換失敗時の continuable な report を含める | hardware format は iOS / macOS、Audio Session mode、入力デバイス、出力デバイスで変わる OS 依存点であり、App が AVAudioEngine / AVAudioConverter / CoreAudio 差分を持つと package 独立性と同一呼び出し方が崩れるため | `AudioInputStreamCapture` と `AudioOutputStreamRenderer` が requested stream format と actual hardware format の不一致を package 内で吸収し、App は同じ `AudioInputStreamConfiguration` / `AudioOutputStreamConfiguration` を渡すだけで 48kHz 基準の入出力または必要な変換済み frame を受け取れる |
| RTC | RTC packet audio の target format を route / session 設定として切り替え可能にし、送信 frame、codec、packet envelope、jitter buffer、受信 frame の sampleRate / channelCount を常に target format と一致させる。入力 frame format が target format と異なる場合は RTC package 内で PCM 変換してから codec encode へ渡す。WebRTC route-managed media では App managed sample を使わず、WebRTC 側の media format / codec negotiation 状態を runtime report に出す | packet audio format、codec format、route-managed media format は通信方式差分であり、App が route ごとの resample や codec 前後の format 整合を持つと transport abstraction が崩れるため | `CallStartRequest.audioFormat` または後継設定で target sampleRate / channelCount を指定でき、`CallSession.sendAudioFrame(_:)` は source format の違いを RTC 内で吸収する。RTC runtime status / metrics が target format、source format、変換有無、変換失敗 drop を報告する |

## 追記ルール

| 記録する項目 | 内容 |
|---|---|
| package | 変更対象 package |
| 不足している責務 | App ではなく package が持つべき責務 |
| App に暫定実装しない理由 | package 独立性、OS差分吸収、準異常系処理、runtime 情報通知、設定受け取りのどれに関わるか |
| App から消す条件 | どの package API / runtime event / report があれば App が同一呼び出しで使えるか |

## App 作り直し時の扱い

| 項目 | 方針 |
|---|---|
| App 側暫定実装 | 作り直し前の都合として扱い、本書には残さない |
| package に既にある責務 | `docs/spec/packages` と `docs/spec/App/setting parameters/packages` を参照し、App 仕様へ重複定義しない |
| 新しい不足の判断 | App が OS 差分、継続可能な準異常系、runtime report/event、設定受け取りを自前で補う必要が出た場合だけ追記する |
