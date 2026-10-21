# RideIntercom Settings 画面項目

## 目的

本書は Settings タブの UI 項目を定義する。

Settings は通信経路、Audio Session、入出力、Audio Check、送信 codec、VAD、設定リセットを扱う。設定値の型、既定値、永続化は `docs/spec/App/setting parameters/App/設定値一覧.md` を正とする。

## 親セクション

| 項目名（日本語） | 項目ID | 目的 | 実装 | 発現条件 | 表示仕様 |
|---|---|---|---|---|---|
| 設定画面 | `settingsScrollView` | 通話前後の調整、確認、自己診断を行う | `SettingsView` | 常時 | `Form` |
| 通信設定 | `communicationPanel` | RTC package に渡す有効 route を選択する | `CommunicationPanel` | 常時 | `Communication` section |
| Audio Session設定 | `audioSessionPanel` | SessionManager の mode、speaker、echo cancellation、Duck Other Audio の組み合わせを選択する | `AudioSessionPanel` | 常時 | `Audio Session` section |
| 音声I/O設定 | `audioIOPanel` | 入出力ポートと effect chain の有効/無効を選択する | `AudioIOPanel` | 常時 | `Audio I/O` section |
| オーディオチェック設定 | `audioCheckPanel` | 自己録音/再生で経路確認する | `AudioCheckPanel` | 常時 | `Audio Check` section |
| 送信コーデック設定 | `transmitCodecPanel` | 送信 codec と bitrate を選ぶ | `TransmitCodecPanel` | 常時 | `Transmit Codec` section |
| Voice Activity設定 | `voiceActivityPanel` | 発話検出の感度を調整する | `VoiceActivityPanel` | 常時 | `Voice Activity` section |
| 設定リセット | `resetSettingsPanel` | 調整値だけを既定へ戻す | `ResetSettingsPanel` | 常時 | 最下部 |

## Communication

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 発現条件 | 表示仕様 | 異常系の考え方 |
|---|---|---|---|---|---|---|---|
| Local Network 経路設定 | `communicationPanel` | `localNetworkRouteToggle` | `Local Network` | `enabledRTCTransportRoutes.contains(.multipeer)`。既定 ON | 常時 | Toggle | OFF にすると RTC の `enabledRoutes` から `.multipeer` を外す。最後の有効 route の場合は操作不可。active RTC connection は停止し、次回接続要求は有効 route だけを使う |
| Internet 経路設定 | `communicationPanel` | `internetRouteToggle` | `Internet` | `enabledRTCTransportRoutes.contains(.webRTC)`。既定 ON | 常時 | Toggle | OFF にすると RTC の `enabledRoutes` から `.webRTC` を外す。最後の有効 route の場合は操作不可。WebRTC route の生成と利用可否判定は RTC package を正とする |
| 通信設定補足文 | `communicationPanel` | `communicationPanel` | なし | 固定文言 | 常時 | section footer | route 設定の反映タイミング、最低1 routeを維持すること、route 変更時に active connection を止めることを説明する |

App は route 実体を直接構築しない。Settings の `enabledRTCTransportRoutes` と adapter が持つ codec registry / WebRTC native engine factory を RTC package の `CallSessionFactory` へ渡し、RTC package が `.multipeer` と `.webRTC` の route set を構築する。

## Audio Session

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 発現条件 | 表示仕様 | 異常系の考え方 |
|---|---|---|---|---|---|---|---|
| Session mode選択 | `audioSessionPanel` | `audioSessionProfilePicker` | `Mode` | `.standard` / `.voiceChat`。既定は `Burst mode` | 常時 | `Picker(.menu)`。表示は `Burst mode` / `Stream mode` | `.speakerDefault` は画面選択肢に出さない |
| スピーカー出力設定 | `audioSessionPanel` | `speakerOutputToggle` | `Use Speaker` | `Bool` | 常時 | Toggle | speaker 出力希望は mode と独立して選ぶ。`Stream mode` でも ON にできる |
| Echo Cancellation設定 | `audioSessionPanel` | `echoCancellationToggle` | `Echo Cancellation` | `Bool`。既定 ON | `Mode == Burst mode` | Toggle。`Use Speaker == true` の場合は操作不可にし、実効値は SessionManager report を正とする | `mode = .voiceChat` では session 側 `prefersEchoCancelledInput` を使わない |
| 他音声ダック設定 | `audioSessionPanel` | `duckOthersToggle` | `Duck Other Audio` | `Bool`。既定 ON | `supportsAdvancedMixingOptions == true` | Toggle | Audio Session / input voice processing の組み合わせとして扱う。実効発動は可聴な受信出力の有無から導出 |
| Session mode説明 | `audioSessionPanel` | `audioSessionModeDescription` | なし | 固定文言 | 常時 | section footer の小さな説明文 | `Burst mode` と `Stream mode` の違いだけを説明する。要求状態や適用結果は Settings に出さず Diagnostics を正とする |

| UI 状態 | App が SessionManager へ渡す値 | 実効値の読み方 |
|---|---|---|
| `Burst mode`、`Use Speaker = false`、`Echo Cancellation = false` | `mode = .default`、`defaultToSpeaker = false`、`prefersEchoCancelledInput = false` | echo cancellation を要求しない |
| `Burst mode`、`Use Speaker = false`、`Echo Cancellation = true` | `mode = .default`、`defaultToSpeaker = false`、`prefersEchoCancelledInput = true` | default mode のまま echo cancellation を要求する |
| `Burst mode`、`Use Speaker = true` | `mode = .default`、`defaultToSpeaker = true`、`prefersEchoCancelledInput` は明示 Echo Cancellation 希望だけを渡す | speaker 出力時の echo cancellation 実効値は `AudioSessionConfigurationReport.resolvedConfiguration` を正とする |
| `Stream mode`、`Use Speaker = false` | `mode = .voiceChat`、`defaultToSpeaker = false`、`prefersEchoCancelledInput = false` | 電話に近い会話体験やレシーバー利用を優先する |
| `Stream mode`、`Use Speaker = true` | `mode = .voiceChat`、`defaultToSpeaker = true`、`prefersEchoCancelledInput = false` | Stream mode のままスピーカー出力を要求する。明示的な `prefersEchoCancelledInput` は使わない |

## Audio I/O

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 発現条件 | 表示仕様 | 異常系の考え方 |
|---|---|---|---|---|---|---|---|
| 出力デバイス選択 | `audioIOPanel` | `audioCheckOutputPicker` | `Output` | `AudioPortInfo` | `availableOutputPorts.count > 1` | `Picker(.menu)` | 切替失敗は Call の音声エラーと Diagnostics に反映 |
| 入力デバイス選択 | `audioIOPanel` | `audioCheckInputPicker` | `Input` | `AudioPortInfo` | `availableInputPorts.count > 1` | `Picker(.menu)` | 切替失敗は音声デバイス問題として扱う |
| 送信 Voice Isolation Effect設定 | `audioIOPanel` | `soundIsolationToggle` | `Transmit Voice Isolation Effect` | `Bool` | `supportsSoundIsolation == true` | Toggle | 非対応 platform では非表示。SessionManager の voice processing 設定ではなく送信用 SoundIsolation effect chain の有効/無効として扱う。受信 peer bus / master bus は Call 画面で設定する |

## Audio Check

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 発現条件 | 表示仕様 | 状態 |
|---|---|---|---|---|---|---|---|
| 通話状態表示 | `audioCheckPanel` | `liveAudioStateLabel` | `Call` | `connectionLabel` | 常時 | 右寄せ表示 | RTCの実状態を表示。準備済みだけでLiveとしない |
| チェック状態表示 | `audioCheckPanel` | `audioCheckPhaseLabel` | `Audio Check` | `audioCheckPhase` | 常時 | 右寄せ表示 | idle / recording / playing / completed / failed |
| マイク入力確認 | `audioCheckPanel` | `audioCheckInputMeter` | `Microphone Input` | `diagnosticsInputLevel`, `diagnosticsInputPeakLevel` | 常時 | 入力メーター | 権限未許可時は上がらない |
| スピーカー出力確認 | `audioCheckPanel` | `audioCheckOutputMeter` | `Speaker Output` | `diagnosticsOutputLevel`, `diagnosticsOutputPeakLevel` | 常時 | 出力メーター | 最終出力へ回した音声を示す |
| チェック状態メッセージ | `audioCheckPanel` | `audioCheckStatusLabel` | 状態文言 | `String` | 常時 | footnote | 実行中、完了、失敗 |
| チェック実行ボタン | `audioCheckPanel` | `audioCheckButton` | `Record 5s and Play` | Action | 常時 | 録音/再生中は disabled | 二重起動を防ぐ |

## Transmit Codec

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 発現条件 | 表示仕様 | 状態 |
|---|---|---|---|---|---|---|---|
| 送信コーデック選択 | `transmitCodecPanel` | `transmitCodecPicker` | `Codec` | `preferredTransmitCodec`。既定は `AAC-ELD v2` | 常時 | `Picker(.segmented)`。`PCM 16-bit`、`AAC-ELD v2`、`Opus` | ユーザーが要求する codec |
| AAC-ELD v2 bitrate | `transmitCodecPanel` | `aacELDv2BitRateStepper` | `AAC-ELD v2 Bitrate` | `Int`, `12_000...128_000`。既定 32 kbps | `preferredTransmitCodec == .mpeg4AACELDv2` | `Stepper`、kbps 表示 | Codec package の正規化後の値を表示 |
| Opus bitrate | `transmitCodecPanel` | `opusBitRateStepper` | `Opus Bitrate` | `Int`, `6_000...128_000`。既定 32 kbps | `preferredTransmitCodec == .opus` | `Stepper`、kbps 表示 | Codec package の正規化後の値を表示 |

## Voice Activity

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 発現条件 | 表示仕様 | 状態 |
|---|---|---|---|---|---|---|---|
| VAD感度選択 | `voiceActivityPanel` | `vadSensitivityPicker` | `VAD Sensitivity` | `.lowNoise` / `.standard` / `.noisy` | 常時 | `Picker(.segmented)` | `VADGate` へ渡す preset |

## Reset Settings

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 発現条件 | 表示仕様 | 異常系の考え方 |
|---|---|---|---|---|---|---|---|
| 設定リセットボタン | `resetSettingsPanel` | `resetAllSettingsButton` | `Reset All Settings` | Action | 常時 | destructive button | グループ、参加者、credential は変更しない |
| 設定リセット補足文 | `resetSettingsPanel` | `resetSettingsPanel` | 補足文 | 固定文字列 | 常時 | footer | データ削除と混同させない |

## Voice Isolationの現在の提供状態

SoundIsolation対応環境では、送信・peer・masterのVoice Isolation操作を表示する。通話開始時に実Mixerへノードを接続し、設定変更は実Audio Unitのbypassへ反映する。停止中は要求設定だけ保持し、稼働中とは表示しない。非対応環境では操作を表示せずsupport reportで区別する。

## Internet Connection

`Configure Internet Connection` (`configureInternetConnection`) から標準sheetを開く。presenterはSettings画面のFormに置き、入力欄を通話設定一覧から分離する。`Close` (`closeInternetConnection`) で入力状態を解放して一覧へ戻る。Macでは内容を操作できる最小サイズを持つsheet、iOSではNavigationStack付きsheetを使用する。

| 項目 | ID | 入力と動作 |
|---|---|---|
| Worker URL | `internetWorkerURL` | HTTPS origin のみ。path・query・fragment・URL内資格を拒否 |
| 端末資格 | `internetDeviceToken` | SecureField。保存先 Keychain。招待 URL / UserDefaults / ログへ含めない |
| 保存 | `saveInternetConnection` | 入力検証後に保存、通話終了、RTC configuration 更新。保存失敗は画面内テキストで表示 |

保存済み資格は入力欄へ再表示しない。試用時は同一 Worker の個別端末資格を入力し、Local Network を OFF にして Internet のみで接続を確認できる。

## 音声経路による操作範囲

| 状態 | 操作 / 表示 |
|---|---|
| Local / 停止中 | packageのcodec、VAD、effect、volumeを設定可能 |
| Internet / 混在 | Localと同じCodec / VAD / effects / device設定を使う。Internet OFFでも近くの参加者が中継できることと電池・通信量を説明 |
| Audio Check | 通話接続中・接続開始中は開始不可。録音/再生中は `stopAudioCheckButton` で停止可能 |
| 通話への移行 | Connect開始時にAudio Checkを停止。古い完了処理は通話を停止しない |
| 資格保存 | ViewModelが入力検証・Keychain保存・切断・RTC設定適用を担当。Viewは入力と表示だけ |
| 資格保存失敗 | 現在の通話・保存済み設定を維持 |
| 設定確認 | `internetConfigurationStatus` は保存の有無。認証成功とは区別し、DiagnosticsのCheck Internet Serviceへ誘導 |
