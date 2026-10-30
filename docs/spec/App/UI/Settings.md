# RideIntercom Settings 画面項目

## 目的

本書は Settings タブの UI 項目を定義する。

Settings はアカウントのサインアウト、通信経路、Audio Session、入出力、Audio Check、送信 codec、VAD、設定リセットを扱う。設定値の型、既定値、永続化は `docs/spec/App/Configuration/設定値一覧.md` を正とする。

## 親セクション

| 項目名（日本語） | 項目ID | 目的 | 実装 | 発現条件 | 表示仕様 |
|---|---|---|---|---|---|
| 設定画面 | `settingsScrollView` | 通話前後の調整、確認、自己診断を行う | `SettingsView` | 常時 | `Form` |
| 通信設定 | `communicationPanel` | RTC package に渡す有効 route を選択する | `CommunicationPanel` | 常時 | `Communication` section |
| Internet接続設定 | なし（子IDを使用） | サービスURLと端末資格の保存 | `InternetConnectionPanel` | 常時 | `Internet Connection` section |
| Audio Session設定 | `audioSessionPanel` | SessionManager の mode、speaker、echo cancellation、Duck Other Audio の組み合わせを選択する | `AudioSessionPanel` | 常時 | `Audio Session` section |
| 音声I/O設定 | `audioIOPanel` | 入出力ポートと effect chain の有効/無効を選択する | `AudioIOPanel` | 常時 | `Audio I/O` section |
| オーディオチェック設定 | `audioCheckPanel` | 自己録音/再生で経路確認する | `AudioCheckPanel` | 常時 | `Audio Check` section |
| 送信コーデック設定 | `transmitCodecPanel` | 送信 codec と bitrate を選ぶ | `TransmitCodecPanel` | 常時 | `Transmit Codec` section |
| Voice Activity設定 | `voiceActivityPanel` | 発話検出の感度を調整する | `VoiceActivityPanel` | 常時 | `Voice Activity` section |
| 設定リセット | `resetSettingsPanel` | 調整値だけを既定へ戻す | `ResetSettingsPanel` | 常時 | 最下部 |

## 自分の表示名

| 項目 | ID | 操作 |
|---|---|---|
| Your name | `localDisplayNameField` | 本人が相手へ伝える名前を入力 |
| Save Name | `saveLocalDisplayNameButton` | 前後空白を除き保存。通話を維持して参加者へ更新を送る |
| 保存済み | `localDisplayNameSaved` | 保存成功を表示。再編集すると表示を消す |

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
| チェック実行ボタン | `audioCheckPanel` | `audioCheckButton` | `Record 5s and Play` | Action | 常時 | 録音/再生中は disabled | 二重起動と通話中の競合を防ぐ。録音・再生中はStop Audio Checkを表示 |

## Transmit Codec

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 発現条件 | 表示仕様 | 状態 |
|---|---|---|---|---|---|---|---|
| 送信コーデック選択 | `transmitCodecPanel` | `transmitCodecPicker` | `Codec` | `preferredTransmitCodec`。既定は `AAC-ELD` | 常時 | `Picker(.segmented)`。`PCM 16-bit`、`AAC-ELD`、`Opus` | ユーザーが要求する codec |
| コーデック項目名 | `transmitCodecPanel` | `transmitCodecLabel` | `Codec` | 固定文字列 | 常時 | segmented Pickerの上に明示 | サンプルレート選択と区別する |
| サンプルレート項目名 | `transmitCodecPanel` | `rtcAudioSampleRateLabel` | `Sample Rate` | 固定文字列 | 常時 | segmented Pickerの上に明示 | kHzとkbpsを区別する |
| AAC-ELD bitrate | `transmitCodecPanel` | `aacELDBitRatePicker` | `AAC-ELD Bitrate` | `Int`。sample rate別のOS対応値と品質下限を満たす選択肢。既定48kbps | `preferredTransmitCodec == .mpeg4AACELD` | `Picker(.menu)`、kbps 表示。Section footerにサンプルレートによって候補が変わり、非対応値は最も近い対応値へ補正されることを説明 | codecだけの切替ではAAC候補を変更しない。Sectionはaccessibility containerとし子の識別子を維持 |
| Opus bitrate | `transmitCodecPanel` | `opusBitRateStepper` | `Opus Bitrate` | `Int`。全sample rateで48〜128kbps。既定48kbps | `preferredTransmitCodec == .opus` | `Stepper`、kbps 表示 | Codec package の正規化後の値を表示 |

| RTC Audio選択 | `transmitCodecPanel` | `rtcAudioFormatPicker` | `Sample Rate` | `.mono48k` / `.mono24k` / `.mono16k`、既定48kHz mono | 常時 | segmented Picker | 稼働中は共通音声pipelineを再構築。hardware sample rateとは別 |

## Voice Activity

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 発現条件 | 表示仕様 | 状態 |
|---|---|---|---|---|---|---|---|
| VAD感度選択 | `voiceActivityPanel` | `vadSensitivityPicker` | `VAD Sensitivity` | `.lowNoise` / `.standard` / `.noisy` | 常時 | `Picker(.segmented)` | `VADGate` へ渡す preset |

## Reset Settings

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 発現条件 | 表示仕様 | 異常系の考え方 |
|---|---|---|---|---|---|---|---|
| 設定リセットボタン | `resetSettingsPanel` | `resetAllSettingsButton` | `Reset All Settings` | Action | 常時 | destructive button | グループ、参加者、Internet資格、入力muteは維持。routeが既定へ変わる場合は切断する |
| 設定リセット補足文 | `resetSettingsPanel` | `resetSettingsPanel` | 補足文 | 固定文字列 | 常時 | footer | データ削除と混同させない |

## Voice Isolationの現在の提供状態

SoundIsolation対応環境では、送信・peer・masterのVoice Isolation操作を表示する。通話開始時に実Mixerへノードを接続し、設定変更は実Audio Unitのbypassへ反映する。停止中は要求設定だけ保持し、稼働中とは表示しない。非対応環境では操作を表示せずsupport reportで区別する。

## Internet Connection

`Configure Internet Connection` (`configureInternetConnection`) から標準sheetを開く。presenterはSettings画面のFormに置き、入力欄を通話設定一覧から分離する。`Close` (`closeInternetConnection`) で入力状態を解放して一覧へ戻る。Macでは内容を操作できる最小サイズを持つsheet、iOSではNavigationStack付きsheetを使用する。

| 項目 | ID | 入力と動作 |
|---|---|---|
| Worker URL | `internetWorkerURL` | HTTPS origin のみ。path・query・fragment・URL内資格を拒否 |
| Set Up Internet Calling | `prepareInternetAppleSignIn` | serverの使い捨てnonceを取得し、Apple認証を準備。失敗しても現在のLocalログインと通話を維持。同じsheetで再操作しても認証modelを作り直さず、429の待機期限までは再送しない |
| Continue with Apple | `internetAppleSignInButton` | 準備後に有効。現在のAppleアカウントと一致する認証だけをserverへ送り、端末資格をKeychainに保存して通話を終了・RTC configurationを更新 |
| Apple認証の状態 | `internetAppleSignInStatus` | 準備・認証・保存の失敗、保存成功を表示。token・メール・本名は表示しない |
| 端末資格 | `internetDeviceToken` | SecureField。保存先 Keychain。招待 URL / UserDefaults / ログへ含めない |
| 保存 | `saveInternetConnection` | 入力検証後に保存、通話終了、RTC configuration 更新。保存失敗は画面内テキストで表示 |

資格は入力欄へ再表示しない。設定済みの場合の状態表示は`Device token configured`。Debugの手動試用ではローカル資格を[開発用の既定値](../Configuration/設定値一覧.md#開発用の既定接続値)として自動適用でき、手入力と保存は不要。明示保存した設定はKeychainへ保存し優先する。実サービスでの試用時は同一Workerを使い、Local NetworkをOFFにしてInternetのみで接続を確認できる。自動テストはローカル代替環境を使用する。

429では`internetAppleSignInStatus`に待機秒数とSet Up Internet Callingでの再試行を表示し、Apple認証は準備ができるまで無効。409では登録端末が8台あることと、別端末でのサインアウトを案内する。エラーは標準Textで表示し、色だけで区別しない。

Apple認証の登録入口はserver側で有効化されている必要があり、現在の配置設定では無効が既定である。手入力欄は`Manual Access Token`へ分け、試用資格を引き続き入力できる。通信不可・Keychain失敗時は既存設定を空に変えない。サインアウト時は端末側のInternet資格を使用禁止にしてserver失効を試み、失敗時は次にこのsheetを開いた際に再試行する。禁止フラグはKeychain読出・削除より先に保存するため、失敗後の再起動でも古い資格を復帰しない。

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

## Account

| 項目 | 項目ID | 意味・挙動 |
|---|---|---|
| ログイン状態 | なし | Signed in with Apple。生のApple識別子・本名・メールを表示しない。資格確認エラー時は保存ログインを使用している説明を表示 |
| サインアウト | `signOutButton` | Sign Out。標準確認dialogで通話終了とデータ保持を説明 |
| 実行確認 | `confirmSignOutButton` | Sign Outで通話を停止しログイン画面へ。Cancelなら変更しない。アカウント削除や購入解約とは異なる |
