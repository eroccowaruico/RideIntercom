# AudioDevice 仕様

`AudioDevice`は、暗号化された一時的な端末ペアをSessionManagerの入力・出力backendとして使うpackageである。通話の参加者、認証、利用権、mix、エフェクト、VAD、UIは所有しない。Watchへの適用は[Watch操作](../../App/Watch操作.md)で定める。

| 項目 | 契約 |
|---|---|
| Product / 場所 | `AudioDevice` / `RideIntercom/packages/Audio/AudioDevice` |
| 依存 | AudioCore、Codec、RTC、SessionManager |
| 対象 | iOS・macOS・watchOS 27以降 |
| 差し替え境界 | `AudioDeviceConnection`が既存の`AudioInputStreamBackend`と`AudioOutputStreamBackend`へ直接適合する。別のadapter・registryは設けない |
| 準備 | `prepare()`でendpointを取得し、認証された操作経路で交換後に`connect(to:)`する。準備待ちは5秒以内。同期のcapture／render開始に非同期通信の準備を隠さない |
| 時計 | engineを開始・停止せず、周期render timerも作らない。呼出し側の既存`renderingEngine`を共有できるが、`rendersToHardware`はfalseでありローカル再生を意味しない |
| 入力 | 受信PCMの元の形式をcaptureへ渡す。固定の周波数・channel countへ暗黙変換しない |
| 出力 | 呼出し側が指定した形式でAAC-ELDを構築する。必要なPCM形式変換はSessionManagerのrendererが担当する。非対応の形式・bitrateは開始失敗とし、別codecへ自動置換しない |
| 符号化設定 | 既存Codecの`AACELDv2Options`を受け取る。48kHz stereoでは48kbpsを受理しないnative条件を確認しており、stereoの検証では64kbpsを指定する。monoへの強制変換や電池消費の優位を意味しない |
| 送話gate | 明示許可、準備済み、送信可能、render開始済みの条件で開く。閉じる際は部分AACの履歴を捨てる。通信復旧だけで自動的に開かない |
| 無音 | 既存Codecのゼロ無音抑止を使う。独自VADを追加しない |
| 準異常系 | 一時的な通信不可は既存pairを保持し、古い音声を蓄積しない。fatalな符号化復号・媒体準備失敗はpairを停止して所有者へ返す |
| 終了 | 入出力購読・codec履歴・endpoint待ち・一時媒体資格を破棄する。再利用する通話とはlifecycleを分ける |

codecと状態を扱うlockの外でtransport操作・利用者callbackを行い、相互のlock待ちを作らない。出力の配送寿命は100ms以内とし、古いframeを追いかけて送らない。これはWatchの追加遅延の目標や実測値ではない。

ローカルの暗号化音声往復、形式保持、gateと停止を自動試験で検証する。端末pairの準備や送信可能通知は相手での再生成功を証明しない。Watchの背景・低レベル通信制限・電池消費・実無線の受入は別に確認する。
