# RideIntercom Call 画面項目

## 目的

本書は Call タブの UI 項目を定義する。

Call は通話開始、接続維持、参加者確認、入出力の最小操作を行う主画面である。

## グループ選択画面

### 親セクション

| 項目名（日本語） | 項目ID | 目的 | 実装 | 発現条件 | 表示仕様 |
|---|---|---|---|---|---|
| グループ選択画面 | `groupSelectionList` | 接続対象グループを選ぶ起点を提供する | `GroupSelectionView` | `selectedGroup == nil` | `navigationTitle("Groups")` |
| 最近のグループ一覧 | `groupSelectionList` | 過去に保持したグループを一覧表示する | `List > Section("Recent Groups")` | `selectedGroup == nil` | グループ一覧の親コンテナ |
| グループ選択ツールバー | `call-groups-toolbar` | 新しいグループを作成する | `ToolbarItem(placement: .primaryAction)` | `selectedGroup == nil` | 右上に新規作成ボタン |

### 子項目

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 異常系の考え方 |
|---|---|---|---|---|---|---|
| 空状態メッセージ | `groupSelectionList` | なし | `Create a group to start a call.` | 固定文字列 | カード風表示 | データ不足をエラー扱いしない |
| グループ行 | `groupSelectionList` | `groupRow-{group.name}` | グループ名 | `IntercomGroup` | 行全体タップで選択 | 選択だけでは既存接続を奪わない |
| グループアイコン | `groupRow-{group.name}` | なし | なし | `activeGroupID == group.id` | `person.3`。接続中は success 色 | 選択中だけでは強調しない |
| グループ名 | `groupRow-{group.name}` | なし | `group.name` | `String` | 最大 2 行 | 空表示にしない |
| メンバー数 | `groupRow-{group.name}` | なし | `"{n} members"` | `Int` | 補助テキスト | 接続中人数ではなく保存メンバー数 |
| 遷移インジケーター | `groupRow-{group.name}` | なし | なし | 固定 SF Symbol | `chevron.right` | なし |
| スワイプ削除 | `groupRow-{group.name}` | なし | `Delete` | 対象 `group.id` | 破壊操作 | フルスワイプ不可 |
| コンテキスト削除 | `groupRow-{group.name}` | なし | `Delete` | 対象 `group.id` | context menu | swipe と同一意味 |
| グループ作成ボタン | `call-groups-toolbar` | `createGroupButton` | `Create Talk Group` | Action | 右上ボタン | 押下で `Talk Group` を作成して選択 |

## 通話画面

### 親セクション

| 項目名（日本語） | 項目ID | 目的 | 実装 | 発現条件 | 表示仕様 |
|---|---|---|---|---|---|
| 通話画面 | `callScreen` | 接続、音声入出力、参加者状態を一画面で扱う | `CallView` | `selectedGroup != nil` | 画面タイトルは `selectedGroup.name` |
| 通話ツールバー | `call-toolbar` | グループ一覧へ戻る導線 | toolbar | 常時 | 左上に `Groups` |
| 通話ステータスヘッダー | `callStatusHeader` | 通話全体の状態を最上部に集約する | `statusHeader` | 常時 | 接続、入力、出力をまとめる |
| 接続/招待操作領域 | `call-primary-controls` | 主要操作をまとめる | `controls` | 常時 | 横幅に応じて横並びまたは縦並び |
| 参加者セクション | `call-participants-section` | 相手ごとの状態、出力調整、peer bus effect 設定を扱う | `VStack` | 常時 | 見出しと参加者領域 |
| 音声エラー表示領域 | `audioErrorLabel` | 音声系失敗を可視化する | `Text` | `audioErrorMessage != nil` | 赤文字 |

### ステータスヘッダー

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 状態 |
|---|---|---|---|---|---|---|
| 通話状態要約 | `callStatusHeader` | `connectionStatusIcon` | `Call status` | `callPresenceLabel`, `routeLabel`, `connectionState`, `isAudioReady` | 接続アイコン + 2 行テキスト | Idle、Waiting、Connected / Audio Idle、通話中 |
| 接続状態ラベル | `connectionStatusIcon` | `callPresenceLabel` | 接続状態名 | `String` | 1 行目 | 状態不明時も文言化する |
| 経路ラベル | `connectionStatusIcon` | `routeLabel` | 経路 | `String` | 2 行目補助テキスト | Local / Internet / Offline / Control Only |
| ローカル入力ヘッダー | `callStatusHeader` | `localMicrophoneHeaderControl` | `Input` | `GroupMember`, `Bool` | ローカル入力状態カード | Unmuted / Muted |
| ローカル入力状態ラベル | `localMicrophoneHeaderControl` | `localMicrophoneStateLabel` | `Unmuted` / `Muted` | `isMuted` | 状態テキスト | 入力状態 |
| ローカル入力メーター | `localMicrophoneHeaderControl` | `localMicrophoneMeter` | なし | `voiceLevel`, `voicePeakLevel`, `isMuted` | 値文字列なしのメーター | 入力レベルとピーク |
| ローカルミュートボタン | `localMicrophoneHeaderControl` | `localMicrophoneMuteButton` | `Mute` / `Unmute` | `Bool` | アイコン付きボタン | 押下でマイクミュート反転 |
| マスター出力グループ | `callStatusHeader` | `outputStateLabel` | `Output` | `masterOutputVolume`, `isOutputMuted`, `receiveMasterSoundIsolationEnabled` | 出力ラベル + スライダー + Voice Isolation + ミュート | OS 音量ではなく App 最終出力 |
| マスター出力スライダー | `callStatusHeader` | `masterOutputSlider` | `Output Volume` | `Float`, `0...2` | `1.0` が通常、`1.0` 超過は boost | 過大時は最終サンプルをソフトクリップ |
| マスター出力 Voice Isolation Effect | `callStatusHeader` | `masterVoiceIsolationToggle` | `Voice Isolation` | `receiveMasterSoundIsolationEnabled`。既定 `false` | `supportsSoundIsolation == true` のとき Toggle | RX master bus の SoundIsolation effect 有効/無効 |
| マスター出力ミュートボタン | `callStatusHeader` | `masterOutputMuteButton` | `Mute Output` / `Unmute Output` | `Bool` | ミュート時は赤系 | 入力や接続は止めない |
| ダッキング状態アイコン | `callStatusHeader` | `duckingStatusIcon` | なし | `isDuckOthersEnabled`, `isOtherAudioDuckingActive` | 設定 ON 時のみ `waveform` | 設定 ON と実効 ON を分ける |

### 接続/招待操作

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 異常系の考え方 |
|---|---|---|---|---|---|---|
| グループ一覧戻りボタン | `call-toolbar` | `showGroupsButton` | `Groups` | Action | 左上ボタン | 接続は維持する |
| 接続ボタン | `call-primary-controls` | `connectButton` | `Connect` | `canDisconnectCall == false` | 主要ボタン | 音声起動失敗と接続失敗を分ける |
| 切断ボタン | `call-primary-controls` | `disconnectButton` | `Disconnect` | `canDisconnectCall == true` | 主要ボタン | 音声起動失敗と接続失敗を分ける |
| 招待ボタン | `call-primary-controls` | `inviteButton` | `Invite` | `selectedGroupInviteURL` | `ShareLink` | URL が作れない場合は表示しない |

## 参加者

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 状態 |
|---|---|---|---|---|---|---|
| 参加者見出し | `call-participants-section` | なし | `Participants` | 固定文字列 | セクション見出し | なし |
| 参加者空状態 | `call-participants-section` | `emptyRemoteParticipantsLabel` | `No remote riders` | 固定文字列 | 空状態カード | 相手不在 |
| 参加者カード行 | `call-participants-section` | `remoteParticipantRow{index}` | 参加者カード | `GroupMember`, `remoteOutputVolumes[member.id]`, `remoteSoundIsolationEnabled[member.id]` | 1 参加者 1 カード | 受信音声がなくても存在 |
| 参加者名 | `remoteParticipantRow{index}` | `participantName{index}` | `member.displayName` | `String` | 最大 2 行 | 保存名 |
| 接続/認証アイコン | `remoteParticipantRow{index}` | `participantStatusSummary{index}` | なし | `connectionState`, `authenticationState` | Wi-Fi 系 + 認証系 | 接続軸と認証軸を分ける |
| コーデック表示 | `remoteParticipantRow{index}` | `participantAudioPipelineState{index}` | `PCM 16-bit` など | `AudioCodecIdentifier?` | `Label`。未観測は `--` | 最後に観測した codec |
| 参加者入力メーター | `remoteParticipantRow{index}` | `participantVoiceLevel{index}` | なし | `voiceLevel`, `voicePeakLevel`, `isMuted` | 値文字列なし | 受信後デコード済みレベル |
| 参加者出力値 | `remoteParticipantRow{index}` | `participantOutputValue{index}` | `{n}%` | `remoteOutputVolumes[member.id]` | 補助テキスト | peer bus volume |
| 参加者出力スライダー | `remoteParticipantRow{index}` | `participantOutputSlider{index}` | `{name} Output` | `Double`, `0...1`。未設定時 `1.0` | 個別出力スライダー | マスター出力とは別。peer bus volume へ即時反映 |
| 参加者 Voice Isolation Effect | `remoteParticipantRow{index}` | `participantVoiceIsolationToggle{index}` | `Voice Isolation` | `remoteSoundIsolationEnabled[member.id]`。未設定時 `false` | `supportsSoundIsolation == true` のとき Toggle | 該当 peer bus の SoundIsolation effect 有効/無効 |
| 参加者削除 | `remoteParticipantRow{index}` | なし | `Delete` | 対象 `member.id` | swipe / context menu | ローカルメンバーは対象外 |

## エラー表示

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 異常系の考え方 |
|---|---|---|---|---|---|---|
| 音声エラーメッセージ | `audioErrorLabel` | `audioErrorLabel` | 音声エラー文言 | `String` | 赤色フットノート | 画面全体を塞がず、その場で読める補助文言として扱う |

## Voice Isolationの現在の提供状態

SoundIsolation対応環境では、送信・peer・masterのVoice Isolation操作を表示する。通話開始時に実Mixerへノードを接続し、設定変更は実Audio Unitのbypassへ反映する。停止中は要求設定だけ保持し、稼働中とは表示しない。非対応環境では操作を表示せずsupport reportで区別する。

## 混在通話・機器切断の表示

| 項目 | 仕様 |
|---|---|
| 経路 | availableRoutesからLocal / Internet / Local + Internetを表示。Localだけでも他者経由の中継が可能 |
| 音声操作 | 全production routeで共通のmeter・effect・master/peer音量・muteを使用 |
| Internet失敗 | `connectivityNotice`。到達可能な参加者との接続を維持して再試行する旨を表示 |
| 機器消失 | `audioRouteNotice`とConnected / Audio Paused。理由と接続・中継の維持を明示 |
| 再開 | `resumeAudioButton`。標準Button、文字ラベルとSF Symbolを併用。認証済みpeerなしでは無効 |
| 別グループ閲覧 | activeGroup用の機器・経路通知を別groupの状態として表示しない |
| 到達確認 | 接続状態・mute解除は相手に聞こえた証明ではない。実音声の受け入れを別途行う |
