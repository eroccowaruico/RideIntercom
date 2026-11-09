# RideCom Settings 画面項目

## 目的

StandardとAdvancedの設定トップはシステムのgrouped Form背景を使い、内容の幅を最大640ptに保つ。Form自体は描く領域いっぱいに置き（背景とスクロールバーは端まで）、`readableScrollWidth()`で左右の`contentMargins`を足して行を中央に寄せる。iPadの横で浮かぶサイドバーの分も安全領域として足し、見えている領域の中央に置く。モード切替時は新モードの設定トップへ戻り、通話・設定値は共通ViewModelに保持する。

本書は Settings タブの UI 項目を定義する。

## 表示切替と共通設定

App Layout（`interfaceModePicker`）はStandard / Advancedの標準Picker。初期値Standard、アカウント別端末設定として保持する。切替だけでは通話・選択・ミュートを変更しない。Standardはアカウント・本人の表示名・利用権、通話設定、通信経路への入口、音声入出力・VAD・録音再生チェックの順に表示し、リセットを最下部に置く。通信経路はCommunication（`communicationSettingsLink`）に有効な経路を表示し、別画面で設定する。Advanced Settings for Developers（`moreSettingsLink`）には見出し（`advancedSettingsWarningTitle`）と設定変更の注意（`advancedSettingsWarning`）、App Layout、Internet接続、Audio Session、送信codecを置く。Internet接続は自動化が未実装の間もここから設定できる。AdvancedはApp Layoutを先頭、通信経路とInternet接続を主画面に表示し、音声設定をAudio Session・Audio I/O・Voice Activity・Transmit Codec・Audio Checkの順に表示する。録音チェックの接続状態やmeterはAdvancedに限る。

StandardのInternet接続はInternet is set up / Internet is not set upとService Addressを表示し、Appleによる接続操作を案内する。手動のDevice access token入力・保存はAdvancedだけに表示する。AdvancedはWorker URLを含め従来の項目・識別子・保存操作とDiagnosticsを維持する。両表示で同じ設定保存先と音声処理を使う。商品未設定でも配布環境を独立に確認し、テスト配布で利用可能か、判定不能ならCheck Accessを表示する。配布の権利がない場合はNot Available Yetとし、商品未設定のRestore Purchasesは表示しない。


Settings はアカウントのサインアウトと削除、通信経路、Audio Session、入出力、Audio Check、送信 codec、VAD、設定リセットを扱う。設定値の型、既定値、永続化は `docs/spec/App/Configuration/設定値一覧.md` を正とする。

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

## 利用権の状態・購入・復元

| 項目 | ID | 操作・状態 |
|---|---|---|
| Access | `storeAccessSection` | 同じログインモデルの購入・配布由来の利用権を表示。商品未設定でも配布環境を独立に確認する |
| Access Status | `purchaseStatus` | 未取得・有効・期限切れ・取消を区別。購入有効時はAvailable Untilも表示し、期限で端末内評価を更新。testDistributionでは「テスト配布で利用可能」と表示して購入と区別し、架空の期限は付けない |
| Check Access | `checkAccess` | 判定不能時に表示し、商品未設定でも再確認できる。購入復元のsyncは呼ばない。処理中は確認中と表示して無効化 |
| View Purchases | `viewPurchases` | 商品設定済みの場合だけ標準StoreViewの購入画面を開く。設定ID・商品種別を検証してから価格・説明を表示し、不足・取得失敗は再試行を案内。購入の確認・取消はStoreKit標準操作。Doneで閉じる |
| Restore Purchases | `restorePurchases` | 商品設定済みの場合だけ表示。明示操作でApp Storeから復元し、購入または配布の確認中は無効化して重複操作を抑止。購入日の期限は延ばさない |

購入画面の成功通知だけでは利用可能へ変えず、検証済み取引を再取得する。取消・承認待ち・失敗・検証不能を区別し、標準StoreViewの重複する復元ボタンは表示しない。公開商品は未設定のため現時点の本番ではView Purchasesも表示しない。

購入履歴の正本・失敗時の扱い・ユーザー切替は[利用権仕様](../利用権仕様.md)を参照する。ログイン画面からの復元や、独自サーバーの購入登録待ちは設けない。

## 通話の通知

| 項目 | ID | 操作・状態 |
|---|---|---|
| Receive Call Requests | `receiveCallNotificationsToggle` | 端末の受信希望を切り替える。ONは明示的にOS許可を要求して登録し、OFFは即時に受信を止め取消を試みる。資格未設定かつOFFでは無効。すでにONのまま資格を失った場合はOFFにできる |
| 状態 | `callNotificationsStatus` | 設定を開いたときと前景復帰に状態を確認する。許可シートは自動で出さない。OS拒否は設定画面への入口、登録失敗は再試行を示す |

Standard/Advancedで同じモデルを使用する。SavedUserの編集には相手ごとのAllow Call Requests、Send Call Request、Cancel Call Requestを置く。許可は相手と1対1で接続すると共有する。group内だけの相手や自分の別端末を候補へ昇格させず、通知の受付を通話成立と表示しない。詳細は[通知仕様](../通知仕様.md)を参照する。

## 自動切断

| 項目 | ID | 操作・状態 |
|---|---|---|
| Automatic Disconnection | `callDisconnectTimerSection` | Standard／Advancedの共通Section。次の開始から適用し、相手待ちと再接続の時間も含むことを説明 |
| Regular Calls | `callDisconnectIntervalPicker` | 通常利用の時間。初期値3時間 |
| Calls Started from Watch | `watchCallDisconnectIntervalPicker` | Watchから開始した通話の時間。初期値5分。Watch自身の音声の提供状況は変更しない |

どちらも標準menu Pickerで1・3・5・10・15・30分、1・2・3・6・8・12・24時間を選ぶ。無制限はなく、アカウント別の端末内設定として個別に保持する。現在の通話の期限は変更せず、期限で終話した後も利用者の操作で再開始できる。

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
| 通話状態表示 | `audioCheckPanel` | `liveAudioStateLabel` | `Call` | `connectionLabel` | Advanced | 右寄せ表示 | RTCの実状態を表示。準備済みだけでLiveとしない |
| チェック状態表示 | `audioCheckPanel` | `audioCheckPhaseLabel` | `Audio Check` | `audioCheckPhase` | Advanced | 右寄せの文字と状態色の記号 | idle / recording / playing / completed / failed。文字は標準の前景色 |
| マイク入力確認 | `audioCheckPanel` | `audioCheckInputMeter` | `Microphone Input` | `diagnosticsInputLevel`, `diagnosticsInputPeakLevel` | Advanced | 入力メーター | 権限未許可時は上がらない |
| スピーカー出力確認 | `audioCheckPanel` | `audioCheckOutputMeter` | `Speaker Output` | `diagnosticsOutputLevel`, `diagnosticsOutputPeakLevel` | Advanced | 出力メーター | 最終出力へ回した音声を示す |
| チェック状態メッセージ | `audioCheckPanel` | `audioCheckStatusLabel` | 状態文言 | `String` | 常時 | footnote | 実行中、完了、失敗 |
| 録音入力元 | `audioCheckPanel` | `audioCheckInputSource` | `Recording Input` | `isUsingWatchAudio`, `audioCheckInputPortName` | 常時 | `LabeledContent` | Watch音声使用中は`Watch Microphone`、それ以外は`This Device: ポート名`。録音・再生中はAudio Sessionの実入力ポート、それ以外は選択済み入力ポートを表示 |
| 再生出力先 | `audioCheckPanel` | `audioCheckOutputDestination` | `Playback Output` | `isUsingWatchAudio`, `audioCheckOutputPortName` | 常時 | `LabeledContent` | Watch音声使用中は`Watch Speaker`、それ以外は`This Device: ポート名`。録音・再生中はAudio Sessionの実出力ポート、それ以外は選択済み出力ポートを表示 |
| マイクミュート状態 | `audioCheckPanel` | `audioCheckMuteState` | `Microphone mute: On` / `Off` | `isMuted` | `isUsingWatchAudio == false` | 状態テキスト | 現在のマイクミュート状態を表示。Watch音声使用中は、Watch音声を停止してからこの端末のチェックを開始する案内を表示 |
| チェック実行・停止ボタン | `audioCheckPanel` | `audioCheckButton` | `Record 5s and Play` / `Stop Audio Check` | Action | 常時 | 同じボタンで開始と停止を切り替える。進行中以外は開始不可条件で disabled | 二重起動と通話中の競合を防ぐ。準備・録音・再生中は停止可能 |

音声チェックの実行・停止と状態文はSectionの先頭に置き、その後に機器・ミュートの情報を示す。操作は標準Formのボタン行とし、使用不可の理由やWatch所有中の案内を残す。

## Transmit Codec

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 発現条件 | 表示仕様 | 状態 |
|---|---|---|---|---|---|---|---|
| 送信コーデック選択 | `transmitCodecPanel` | `transmitCodecPicker` | `Codec` | `preferredTransmitCodec`。既定は `AAC-ELD` | 常時 | `Picker(.segmented)`。`PCM 16-bit`、`AAC-ELD`、`Opus` | ユーザーが要求する codec |
| コーデック項目名 | `transmitCodecPanel` | `transmitCodecLabel` | `Codec` | 固定文字列 | 常時 | segmented Pickerの上に明示 | サンプルレート選択と区別する |
| サンプルレート項目名 | `transmitCodecPanel` | `rtcAudioSampleRateLabel` | `Sample Rate` | 固定文字列 | 常時 | segmented Pickerの上に明示 | kHzとkbpsを区別する |
| AAC-ELD bitrate | `transmitCodecPanel` | `aacELDBitRatePicker` | `AAC-ELD Bitrate` | `Int`。sample rate別のOS対応値。従来の品質範囲と、48kHz・32kbps／24kHz・16kbpsの手動低帯域候補。既定48kbps | `preferredTransmitCodec == .mpeg4AACELD` | `Picker(.menu)`、kbps表示。該当候補だけ`Lower Quality`／`音質低下`を付ける。footerで周波数依存と、非対応値は従来の品質範囲から最も近い値へ補正することを説明 | codecだけの切替ではAAC候補を変更しない。Sectionはaccessibility containerとし子の識別子を維持 |
| 低帯域候補の説明 | `transmitCodecPanel` | `aacLowBandwidthExplanation` | 英日説明文 | 48kHz・32kbps／24kHz・16kbpsは音質低下を伴い、既定を変更しない。符号化bitrateと総通信量は別 | AAC選択中で、現在の周波数にnative対応の低帯域候補がある | 標準Section footer内のText | 品質推奨・実通信量や電池の効果を確定した表示にしない |
| Opus bitrate | `transmitCodecPanel` | `opusBitRateStepper` | `Opus Bitrate` | `Int`。OS対応の24／32kbpsと従来48〜128kbps。既定48kbps | `preferredTransmitCodec == .opus` | `Stepper`、24／32には`Lower Quality`／`音質低下`を付け、48以上は2kbps刻み | Appの手動候補選択後の値を表示 |
| Opus低帯域候補の説明 | `transmitCodecPanel` | `opusLowBandwidthExplanation` | 英日説明文 | 24／32kbpsは音質低下を伴う選択肢。既定48を維持し符号化量と全通信量を区別 | `preferredTransmitCodec == .opus` | Section footer | 推奨下限の変更ではない |

| RTC Audio選択 | `transmitCodecPanel` | `rtcAudioFormatPicker` | `Sample Rate` | `.mono48k` / `.mono24k` / `.mono16k`、既定48kHz mono | 常時 | segmented Picker | 稼働中は共通音声pipelineを再構築。hardware sample rateとは別 |

## Voice Activity

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 発現条件 | 表示仕様 | 状態 |
|---|---|---|---|---|---|---|---|
| VAD感度選択 | `voiceActivityPanel` | `vadSensitivityPicker` | `VAD Sensitivity` | `.lowNoise` / `.standard` / `.noisy` | 常時 | `Picker(.segmented)` | `VADGate` へ渡す preset |

## Reset Settings

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 発現条件 | 表示仕様 | 異常系の考え方 |
|---|---|---|---|---|---|---|---|
| 設定リセットボタン | `resetSettingsPanel` | `resetAllSettingsButton` | `Reset All Settings` | Action | 常時 | destructive button。標準alertで確認 | グループ、参加者、Internet資格、入力muteは維持。routeが既定へ変わる場合は切断する |
| リセットの確認 | `resetSettingsPanel` | `confirmResetAllSettingsButton` / `cancelResetAllSettingsButton` | `Reset All Settings` / `Cancel` | Action | 確認中 | 標準alert | 確定時のみリセット。キャンセル時は変更しない |
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
| Audio Check | 通話接続中・接続開始中は開始不可。準備・録音・再生中は `audioCheckButton` で停止可能。Settingsからの開始はこの端末の入力・出力を使用し、選択した機器とミュート設定を尊重する。Watch所有中は通常開始を拒否する |
| 通話への移行 | Connect開始時にAudio Checkを停止。古い完了処理は通話を停止しない |
| 資格保存 | ViewModelが入力検証・Keychain保存・切断・RTC設定適用を担当。Viewは入力と表示だけ |
| 資格保存失敗 | 現在の通話・保存済み設定を維持 |
| 設定確認 | `internetConfigurationStatus` は保存の有無。認証成功とは区別し、DiagnosticsのCheck Internet Serviceへ誘導 |


Audio Checkは録音入力元・再生先・ミュート設定を常時表示する。準備前は選択値、録音・再生中はAudio Sessionが確定した実機器名を表示し、実行中の入力・出力選択は変更できない。Watchが音声を所有する場合はWatchマイク・Watchスピーカーと明示し、Stop後の明示的な開始を案内する。

開始時のcategory/route確定と録音中の実機器切替を区別する。準備完了時の実snapshotを基準とし、古い遅着snapshotで次のチェックを中断しない。録音・再生中の実機器切替・切断・割り込み・Media Services resetは停止し、再実行を案内する。録音再生sourceのqueueは録音長に応じて最大5秒に限定し、通常通話のlive queueは変更しない。

## Account

| 項目 | 項目ID | 意味・挙動 |
|---|---|---|
| ログイン状態 | なし | Signed in with Apple。生のApple識別子・本名・メールを表示しない。資格確認エラー時は保存ログインを使用している説明を表示 |
| サインアウト | `signOutButton` | Sign Out。標準確認dialogで通話終了とデータ保持を説明 |
| 実行確認 | `confirmSignOutButton` | Sign Outで通話を停止しログイン画面へ。Cancelなら変更しない。アカウント削除や購入解約とは異なる |


## アカウント削除

| 項目名（日本語） | 項目ID | 操作・表示 |
|---|---|---|
| 削除入口 | `deleteAccountButton` | Account sectionのDelete Account。確認sheetへ進み、この時点では通話・保存内容を変更しない |
| 削除確認 | `accountDeletionConfirmation` | 自分の端末内ユーザー・グループ・設定・鍵、接続済みInternetサービスの全端末登録という削除範囲を説明。別端末・他人への共有済み情報と購入解約は別扱い。Cancelで戻る |
| Apple再認証 | `verifyAppleDeletionButton` | Prepare Apple Verificationでserver nonceを取得後、標準Continue with Appleを表示。同じ本人・request state・有効期限・現在のログイン世代を確認し、identity tokenとauthorization codeを削除要求へ渡す。メール・本名を要求しない |
| Apple確認なしの削除 | `deleteWithoutAppleButton` | 別の破壊的確認を経て実行。Apple側で手動解除が必要なことを明示する。現在資格・削除復旧用の退避の両方にInternet登録がなければ、この端末のデータ削除だけを提示し、他端末のInternet登録は消せないと説明する |
| 削除中と再開 | `accountDeletionProgress` | 確定後は通話を停止し、通常画面とログインを閉じる。保存失敗・HTTP拒否・Apple取消待ち・Internet通話回収待ちを完了と扱わず、Retry Deletionを表示する。server受理前はAppleの再確認、または明示的な確認なし削除へ変更できる |
| 削除の終了 | `finishAccountDeletionButton` | 端末内消去と必要なserver受理が済み、Apple取消待ち・Internet通話回収待ちがない場合だけReturn to Sign Inを表示。Apple取消が未実施ならApple Accountへのリンクと手動解除手順を示す。押すと削除記録を除去してログインへ戻る |

サインアウト済みの登録が残る場合は、その登録の削除にAppleでの再確認が必要と説明し、確認なしの削除を提示しない。退避読取失敗では端末だけの削除へ進めない。

削除処理はsheetの寿命に依存しない。再起動しても削除記録を先に読み、未完了なら同じ再開画面へ戻る。削除記録・保存資格を読み出せない場合、空のアカウントとして削除を進めない。資格の期限切れ・失効、または取消待ちの受領記録失効でserverが401を返すと、保存済みの公開IDを対象としてApple再認証へ戻る。再認証は新しいInternet登録を作らない。元のアカウントが既に削除され、新しい公開IDで登録されている場合は、元の端末内データだけを消し、新しい登録とApple認可は維持したと表示する。この場合はAppleの手動解除を案内しない。公開IDを確認できない手入力資格は削除開始前に拒否し、SettingsからAppleでInternet接続を再確認するよう案内する。

## 利用者向け案内の言語

Internetログインの再試行案内は、待ち時間を数値のままString Catalogへ補間し、英語の1 second / 複数secondsと日本語の秒表示を切り替える。1・60・3,600秒でも同じ待機値を保持し、翻訳のために再試行制限やアカウント状態を変えない。招待、名前入力、音声復旧のApp定型メッセージも日本語を用意する。ユーザー名・グループ名は補間時に保持し、OSや接続先が返した任意の自由文は独自翻訳しない。Advancedの診断文言の全訳は対象外。

## 通話状態の表示

| 項目 | ID | 操作・表示 |
|---|---|---|
| Call status display | なし | Standard/Advanced共通section。iOSは名前なしのロック画面・Dynamic Island表示、macOSはこのMacのメニューバー表示を説明 |
| Show call status outside the app | `liveActivityToggle` | 初期OFF。ON/OFFを即時保存。OFF・表示消去は通話を終了しない |
| Show call status in the menu bar | `menuBarToggle` | macOSのみ。初期OFF。ON/OFFを即時保存。OFFで通話を終了しない |
| 表示失敗 | なし | iOSのLive Activity要求失敗時、通話継続とOFF→ONによる再試行を案内 |

表示と対象照合は[システム表示と通話操作](../システム表示と通話操作.md)を正とする。各OSで利用できる表示用の1スイッチだけを示す。

## モードごとの画面構成と共通部品

`UI/Settings`内の`StandardSettingsView`と`AdvancedSettingsView`が各モードのSection構成と順序を持つ。`SettingsView`は共通のFormとInternet設定sheetの状態を所有し、`SettingsPanels`は両画面で意味の同じ設定部品を提供する。設定値と実処理は既存のIntercomViewModelへ集約し、モードごとに複製しない。アクセシビリティIDと設定の保存・反映・リセットの契約は共通で維持する。
