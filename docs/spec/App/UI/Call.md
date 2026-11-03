# RideCom Call 画面項目

## 目的

本書は Call タブの UI 項目を定義する。

## Standardの通話・ユーザー・グループ

Watch音声のpairが失われ、Watchでの再準備が必要な場合は、この端末のResume Audioを表示しない。Watchからの再開始案内に従う。既存pairを保持した一時停止では共通の再開操作を利用する。

初期表示はStandard。`Users` / `Groups` / `Settings`の標準TabView（`.sidebarAdaptable`。iPhoneはタブバー、iPad・Macはサイドバー）を使い（最初はUsers）、Diagnosticsは含めない。通話はタブにせず、接続先を選んだときに開く（compact幅のiPhoneは`sheet`、iPad・Macは`inspector`の右の列、`closeCallButton`で閉じる）。iPhoneで`inspector`のcompact表示（OSのシート）を使わないのは、ツールバーに…メニューを置いたその表示を一覧から開き直すとSwiftUIのガラス描画が停止したため（2026-11-03、[証跡](../../../validation/history/画面デザインと録音操作の整理.md#通話のメニューと一覧の行から設定を開く)）。通話中に通話を閉じている間は、iOSはタブバー上の`tabViewBottomAccessory`（`callAccessory`。名前と状態、`callAccessoryMuteButton`、長押しで切断）、macOSはツールバーの`callAccessoryOpenButton`から開き直す。切断すると通話を閉じて一覧へ戻り、未選択・未接続だけの画面は置かない。以下の詳細画面はSettingsのApp LayoutでAdvancedへ切り替えて使用する。Users / Groupsと参加者は人物と通常グループを共通の青いアバターとし、`person.fill`／`person.3.fill`の記号で区別する。アイコン画像の変更機能は持たず、名前と種別を併記する。Users / GroupsはStandardとAdvancedで画面構成を分け、保存状態・共通操作と同じ意味の表示部品を共用する。Callはモードに応じた画面を使用する。接続先の選択とグループ作成はUsers / Groupsタブへ集約する。画面だけを切り替え、接続・選択・ミュート・一覧の正本は同じIntercomViewModelに保つ。

| 画面・項目ID | 表示と操作 |
|---|---|
| Call / `standardCallScreen` | 人物・グループを区別する固定の丸いアイコンと相手名または通常グループ名を中央の見出しにし、縦は1列、iPhoneの横（compact高さ）では左の固定列と右の詳細一覧の2列にする。右の詳細一覧（`standardCallDetailsScroll`）だけをスクロールし、主要操作を隠さない。iPad・Macでは一覧の右の列（`inspector`、幅320〜420pt）に1列で置く。横のcompact高さでアクセシビリティ文字サイズのときは、上を情報一覧、下を3操作の固定領域（`standardCallFixedControls`）に分け、操作のラベルを記号の横に並べて全文を表示する。名前は2行まで折り返す。状態ヒーロー（`standardCallHero`）は名前を見出し、状態の語（`standardCallStatus`）をtitle3 semiboldで示し、理由があれば次の行に補足（`standardCallStatusDetail`、例: 相手の参加を待っています）を置く。状態と補足をダッシュで1行につながない。接続前・接続待ち・会話中・音声停止・音声エラーを文言と記号または進捗で示す。認証だけでは会話中にせず、音声準備も成立している状態を使う。触覚は会話中への遷移でsuccess、音声停止への遷移でwarning、接続の終了でstop、マイク／出力ミュートの切替でselectionを出す |
| `standardConnectButton` / `standardEndCallButton` | 接続はglassProminent、切断はdangerの円形glassProminentで下のラベルは`End`（日本語「切断」、`standardEndControlLabel`）。切断確認を取消すと既存通話・ミュートを維持し、確定時だけ描画時に捕捉したCallReferenceを共通endCallへ渡す。接続は共通startCallへ渡す。別の通話を閲覧中はSwitch to This Callを明示。一覧の行のタップで別の通話を置き換えるのは、確認（「通話を切り替えますか？」、`switchCallConfirmButton`の「切り替える」とキャンセル）の後だけ |
| `standardMuteButton` / `standardMicrophoneStatus` | 円形glassのmic.slash記号を固定し、ミュート中だけdangerの選択状態とする。下のラベル（`standardMuteState`）はMute／Mutedで状態を語でも示す。共通setCallMutedへ描画時のCallReferenceと希望値を渡す。ミュート・音声取得中・通話開始待ちを区別する。Watch音声選択中はマイク操作を表示せず「Watchでマイクを操作」と案内し、以前のphone mute値を状態として表示しない |
| `standardUsersList` | 保存済みユーザーだけを表示。相手の行のタップは`openDestination`で内部通話先を解決し、待機中ならその場で接続を始めてCallへ移る（[操作の流れ](../../../design/操作の流れ.md)の「選んだら接続」）。現在の通話先なら再接続せずに開き、別の通話中なら切替を確認する。開始できない場合も接続先を表示し、理由を示す。内部グループの作成や選択は要求しない。行の長押し（contextMenu）とswipeに`User Settings`（相手の設定）と`Delete`を置き、鉛筆・`info.circle`は置かない。接続中の相手の行には状態の語（`directoryRowCallStatus`、記号だけ状態色）を示す。空のときは`ContentUnavailableView`と`emptyUsersInviteButton`、10人を超えると検索（`.searchable`）を出す |
| `standardGroupsList` | 通常グループだけを表示し、進行中の通話の実状態（接続待ち・会話中・音声停止等）を行内に示す。行のタップはUsersと同じく待機中は接続を始め、別の通話中は切替を確認する。行の補助は人数（例: 4 people／4人）。行の長押し・swipeに`Group Settings`（グループの設定）と`Delete`を置く。New Groupは既存の名前入力・保存ユーザー選択Formを開く。作成確定時の既存開始処理を共用する。空のときは`emptyGroupsCreateButton`、10件を超えると検索を出す |
| Current Call | Standardでは一覧に置かず、通話のアクセサリ（`callAccessoryOpenButton`）が進行中の通話へ戻す。別の接続先を表示した後でも進行中の通話を開き直す。Advancedは一覧先頭のCurrent Call（`standardCurrentCallButton`）も維持する。保存ユーザー削除で現在の通話を隠さない |
| 招待・参加者 | 通話のツールバーの…メニュー（`callMoreMenu`）に、通常groupは`Group Settings`（`callGroupSettingsButton`）と`Add Members`（Advancedは`Add Saved Users`、`callAddMembersButton`）、個別通話は`User Settings`（`callUserSettingsButton`）、共有可能なら招待（`inviteButton`）を置く。通話の画面に共有だけのボタンを単独で置かない。参加者の名前編集と通常groupからの削除は行の長押し・swipe。既存の署名付き共有、本人名／別名編集、通常groupへの保存ユーザー追加・削除を共用する。groupで会っただけの相手をUsersへ追加しない |
| `standardSpeakerButton` / 入出力 | 出力ミュートも円形の明示選択状態とisSelected・value（Muted／Unmuted）で示し、既存toggleOutputMuteへ渡す。選択状態の塗りはアクセント色とし、隣の切断（danger）と同じ塗りを並べない。Audioのスピーカー音量は現在値の百分率（`standardSpeakerVolumeValue`）とSliderの両端の`speaker`／`speaker.wave.3`を表示する。マイク／出力ミュート、出力・参加者音量、対応機器の音声分離、機器切断後の再開。経路やcodecの診断値は出さない |
| 復旧 | 保存読込失敗・破損の既存reload/reset操作、通話・音声のエラーと再試行案内を同じ状態から表示する |

英語を原文としてString Catalogに一般画面と共通の操作・設定・アカウント案内の日本語を保持する。本人名・別名・グループ名は翻訳しない。App生成の再試行秒数、名前・人数の補間、招待・音声復旧の定型案内も翻訳対象とし、英語の単複を扱う。OSやサービスから来る任意の自由文は独自翻訳しない。Advancedの診断項目の全訳は対象外。購入商品未設定は利用不可と表示し、通知の送信・24時間利用権の完成を装わない。通話権利条件は画面側に追加しない。[共通利用権判定](../通話利用権仕様.md)が媒体準備と成立を区別し、作成不可・権利を持つ参加者待ちにはSettingsのAccessを案内する。


Call は通話開始、接続維持、参加者確認、入出力の最小操作を行う主画面である。

Connect・Disconnect・ローカルマイクの操作は[通話先と操作対象の共通境界](../通信仕様.md#通話先と操作対象の共通境界)を使う。描画時の通話先・通話世代・設定値を保持し、遅れた終了やミュートが別の通話に作用しないようにする。

## 新しい相手への直接招待

Standard／AdvancedのUsers画面は別の構成を維持し、招待の保存・表示状態・操作は同じViewModelを参照する。通常groupを作らず、共有しただけでユーザー／メンバーを表示しない。署名と保存・再送の条件は[新規相手招待の通知処理](../通信仕様.md#新規相手招待の通知処理)に従う。

| 項目ID | 表示・操作 |
|---|---|
| `inviteContactButton` | Usersの＋。押した時点で一件の招待を保存し、共通の共有sheetを開く。通常group作成の購入条件を流用せず、ログインと保存可能性を確認する |
| `contactInvitationSheet` / `shareContactInvitationButton` | Share InvitationからOS標準の共有先を選ぶ。InvitationShareは保存した同一tokenを使用し、export時にログイン世代・期限・取消・鍵を再確認する。共有の取消・Copyで新しい招待やユーザーを増やさない |
| `pendingContactInvitation-<UUID>` | Invitationsの独立した行（登録完了後の確認通知の再送も区別して表示）。招待／受諾通知の待機状態を表示し、通常の保存ユーザーと区別する |
| `contactInvitationStatus` | 未受諾、保存済みの相手、受諾通知の送信待ち・一時停止・配達確認を区別する。通常通話中の通知は通話終了待ちとし、接続や共有だけで成功と表示しない |
| `retryContactInvitationButton` | 明示的に通知を再開する。通常通話を奪わず、通信は最大60秒。表示用の独自timerを持たず、共通VMの通知所有IDと保存状態から表示を更新する |
| `cancelPendingContactInvitationButton` / `confirmCancelContactInvitationButton` | 標準の破壊的確認で、この端末の再試行を停止し保存pendingを取り消す。共有済みURLの相手側での遠隔失効を保証する文言にしない |
| `closeContactInvitationButton` | sheetを閉じ、所有している通知接続を停止する。未完pendingは明示再試行用に残す |
| `contactInvitationPreview` | `rideintercom://contact`をログイン後にViewModelで署名・期限・宛先検証して表示する。URLを開くだけではユーザー／pending／署名鍵を保存しない |
| `acceptContactInvitationButton` / `cancelContactInvitationButton` | Accept Invitationで初めて相手をUsersへ保存し、Users画面へ移る。通話とミュートは維持する。Cancelは保存せず閉じる |

共有・受諾sheetのpresentationは共通VMで一つだけ保持する。Users画面を離れる時、共有sheetを閉じる時、Appがbackgroundになる時は通知接続を止め、保存済みの相手とpendingを維持する。英語と日本語の定型文をString Catalogで切り替え、本人名を翻訳しない。

### Contact招待のUIスタックと遷移

[UIスタック](../../../design/デザインシステム.md#uiスタック)の5状態を、既存の保存状態・通知所有ID・presentationから導出する。登録の成立と通知の配達は別に扱い、一端の表示から両端の登録完了を推測しない。

| 状態 | 成立条件・表示 | 操作・遷移・復帰先 |
|---|---|---|
| Ideal | 相手がこの端末のUsersへ保存済み。作者はContact added、受諾側は保存済みと通知の状態を別々に表示する。通知完了は配達確認後の文言を使う | Usersから相手を選べる。作者の確定済み招待は再共有せず、必要な確認通知だけを再送できる。CloseでUsersへ戻る |
| Empty | 初回（Blank）または最後の保存相手の削除後、Usersが0件。No Saved Usersと招待／受諾の案内を表示し、招待も0件ならInvitations sectionを出さない | ＋で一件だけ発行して共有sheetへ。共有取消・CopyはUsersを増やさず、保存した招待だけを残す。初回と削除後は追加の履歴フラグを持たず、現在の0件から同じ空表示を使う |
| Error | 署名・期限・宛先の検証失敗はUsersに再招待案内、保存／再開／取消の失敗は対象sheetに説明を表示する。消失・期限切れの対象は利用不可表示、export時の失効は共有を拒否する | 既存のUsers・通話・保存pendingを維持する。再試行、Close／CancelでUsersへ戻る、新しいURLを受け取る。受諾の保存失敗ではpreviewを保持して戻れる |
| Partial | 検証済みpreviewだが未受諾、または相手の登録済み／未登録と通知の未完了が組み合わさる状態。登録済み・通話終了待ち・一時停止を明示し、招待行を相手の行へ代用しない | previewのAcceptで初めて登録し、Cancelは無書込。通知は明示Retryまたはローカル取消。通常通話を奪わず、保存した相手とpendingを保持してUsersへ戻る |
| Loading | 通知所有IDが対象IDと一致する間。未受諾を待つ文言／保存済みで受諾通知を送信中の文言を表示し、Emptyや配達済みと区別する | Retryは同じ招待の通知を使い、新規発行を重ねない。配達でIdeal、通話開始・background・所有画面の閉鎖・最大60秒で保存済みのPartialへ移る。取消は確認後に停止する |

検索結果のEmptyは検索機能がないため対象外。発行・署名検証・明示受諾のローカル保存は同期処理であり、別のLoading画面やUI用timerを作らず、非同期通知の状態を上表で表示する。操作不可は5状態とは別に、ログインと保存状態に基づく既存のDisabled条件を併用する。


## Advancedの接続先未選択

通話は接続先が選ばれているときだけ開くため、未選択の画面と`chooseUserButton`・`chooseGroupButton`は置かない。現在の通話があるときはCurrent Callから戻れ、保存データの復旧操作とエラーも表示する。グループの一覧と新規作成はGroupsタブが提供する。タブ移動だけでは既存通話を切り替えず、一覧での別の接続先の選択は切替の確認を経る。

## ユーザー指定の個別通話

| 項目 | 表示・操作 |
|---|---|
| Users | 直接招待関係として保存した相手名を`standardUser-{UUID}`の行に表示。共通の`selectUser`へ渡し、双方の確認済みアカウントがあれば別端末でも同じ二人の内部通話先を解決する。自分の別端末は対象外。削除済み・未知のUUIDは画面外から渡しても拒否する |
| Current Call | 進行中の個別通話を`standardCurrentCallButton`で開く。ユーザー一覧から相手を削除しても終了操作へ戻れる |
| Groups | kind=groupだけを表示。個別通話の内部ID・group作成操作を要求しない |
| 個別通話の画面 | タイトルは相手名。Advancedの`directCallHelpLabel`は通常時に個別通話であることを示し、保存ユーザー削除後は現在の通話と終了操作を維持する旨を表示する。既存通話中に別の相手を選んだときは切替の確認を出し、確認するまで切り替えない |
| Share Call Invite | StandardではCall、AdvancedではUsersの管理画面に置く`inviteButton`は特定の相手宛ての署名付き招待をOS共有画面へ渡す。保存ユーザー削除後は表示しない。通常groupのInviteとは宛先制約が異なる |
| 参加者操作 | 個別通話ではAdd Saved Users、参加者Delete、招待枠の追加を提供しない。ミュート・音量・音声効果・Disconnectは既存の共通操作を使う |

## 保存済みユーザーの操作

Groupsの`New Group`（`standardCreateGroupButton`）から標準Formを開く。名前入力（`savedUsersGroupNameField`）、ユーザー選択（`selectUser-{UUID}`）、`Create and Connect`（作成して接続。別の通話中は`Create Group`、`saveUserSelectionButton`）で保存済みの相手を使うグループを作成し、待機中ならそのまま接続する。`Cancel`（`closeSavedUsersButton`）では変更しない。

Usersの行の`User Settings`（`userSettingsView`）と作成・追加Formの鉛筆ボタン（`editUser-{UUID}`）は相手の設定を開き、本人名（`savedUserOriginalName`）も表示する。相手の設定には呼び出しの許可、内部のdirect groupがあれば招待（`userSettingsInviteButton`）、`Delete User`（`deleteUserButton`、確認`confirmDeleteUserButton`）を置き、`closeUserSettingsButton`で閉じる。`Use Shared Name`（`resetUserNameButton`）で端末の呼び名を解除して最新の本人名へ戻せる。`savedUserNameField`と`saveUserNameButton`で端末内の表示名を保存する。同じ名前の別IDは統合しない。行のDeleteは独立一覧からの削除であり、既存グループと進行中の通話を保持する。表示名変更は既存グループにも反映する。一覧が空なら、直接招待した・された相手だけが自動登録され、グループ削除後も保持されることを案内する。

StandardではCallのParticipants（`addSavedUsersButton`）、両モードで通話の…メニュー（`callAddMembersButton`）とGroup Settings（`groupSettingsAddMembersButton`）から保存ユーザーを追加する。現在のgroup IDを操作対象として固定し、直接招待関係のある保存ユーザーのうち、まだ含まれない相手を選択して追加する。自分を含め8memberまでで、重複・古い操作対象・保存失敗は確定しない。`savedUsersErrorLabel`で失敗を示す。選択だけでは相手へ通知しないことと、追加後に招待の共有が必要なことをFormに表示する。AppleログインやID宛て通知の完成を表す画面ではない。

保存ユーザーの追加はこの端末のメンバー一覧への記録だけであり、group鍵は相手へ届かない。鍵は招待URL（署名付きのgroup ID・名前・鍵）を相手が開いたときに相手の端末へ保存され、相手のgroup一覧へ自動で追加される。そのため、保存ユーザーを1人以上選んだCreate Group / Add Usersが成功したら、sheetを閉じずに同じsheetを招待の段階へ切り替える。

| 状態 | 成立条件 | 表示 | 可能な操作 | 復帰先 |
|---|---|---|---|---|
| Ideal | 保存ユーザーを1人以上含む作成・追加が保存された | 見出し`Send Invitation`、相手が開くとgroupと鍵が相手の端末に追加されInternetなしで近くで会話できる旨（`sendGroupInvitationMessage`）、共有ボタン（`addedUsersInviteButton`）、追加だけでは一覧に載るだけで後からInviteでも送れる旨 | 共有、Done（`finishAddingUsersButton`） | Doneで元の画面。作成時は新groupの通話画面 |
| Partial | 共有せずにDoneを押した | 追加済みのメンバーは一覧に残る | Group Settingsの招待（`groupSettingsInviteButton`）または通話の…メニューの`inviteButton`で後から共有 | 元の画面 |
| Error | 保存に失敗した | 選択画面のまま`savedUsersErrorLabel` | 選択の変更・再試行・Cancel | 選択画面 |
| Empty | 保存ユーザーを選ばずにgroupを作成した | 招待の段階を出さずにsheetを閉じる | 通常どおり | 新groupの通話画面 |
| Loading | 該当しない | 保存は同期処理で、共有URLはOS共有画面の要求時に作るため待ち表示を持たない | — | — |

招待の段階の表示中に対象groupが削除された場合はsheetを閉じる。共有URLは既存のInviteと同じく共有時に対象group・権利を再検証する。

Users / Groupsのルート識別子`standardUsersList` / `standardGroupsList`は、モード切替前後の既存UIテストとの互換性のためAdvancedでも維持する。状態と操作の所有者は共通のViewModelであり、識別子は画面構成の共有を意味しない。Call配下はStandard・Advanced・Commonに責務ごとに配置する。

## グループの設定と相手の設定

[操作の流れ](../../../design/操作の流れ.md)の「設定は名前の付いた入口から」に従い、StandardとAdvancedで同じ画面を使う。入口は通話の…メニューと、Users / Groupsの行の長押し（contextMenu）・swipeだけで、行のタップは接続の1つの意味に保つ。開いても選択中の通話・表示中の通話を切り替えない。

| 画面 | 項目 | 操作 |
|---|---|---|
| Group Settings（`groupSettingsView`） | 名前（`groupSettingsNameField`）、メンバー（行の長押し・swipeで`Edit Name`と`Delete`）、`Add Members`（`groupSettingsAddMembersButton`）、招待（`groupSettingsInviteButton`）、`Delete Group`（`deleteGroupButton`） | `Done`（`saveGroupSettingsButton`）で名前を保存して閉じる。名前は端末内の`renameGroup`で保存し、接続中でも再接続しない。`|`・空白だけは保存しない。`Delete Group`は確認（`confirmDeleteGroupButton`）の後に削除し、接続中なら切断する。`Cancel`（`closeGroupSettingsButton`）は名前を保存しない |
| User Settings（`userSettingsView`） | 端末での呼び名、本人の名前、Use Shared Name、呼び出しの許可、招待（`userSettingsInviteButton`）、`Delete User`（`deleteUserButton`） | `Save`で呼び名を保存。削除は確認の後で、既存groupと進行中の通話を保持する |

対象groupの消失・種別不一致では設定の内容を表示しない。設定の招待は対象group IDに固定した共有（`InvitationShare(settingsGroupID:)`）を使い、表示中の通話が別のgroupでも、共有時に対象groupの存在・鍵・権限を再検証する。通話画面の招待は従来どおり表示中の通話に固定し、選択が変われば共有しない。Advancedの通話の参加者は状態と音声操作だけを表示する。Standardの通話のメンバーは行の長押し・swipeで名前の編集と通常groupからの削除を行う。

## 通話画面

### 親セクション

| 項目名（日本語） | 項目ID | 目的 | 実装 | 発現条件 | 表示仕様 |
|---|---|---|---|---|---|
| 通話画面 | `callScreen` | 接続、音声入出力、参加者状態を一画面で扱う | `CallView` | `selectedGroup != nil` | 画面タイトルは通常group名、個別通話では相手の表示名。横のcompact高さと幅600pt以上では、状態ヘッダーと接続操作の列、参加者とエラーの列に分けてそれぞれスクロールする。触覚はStandardと共通 |
| 通話ステータスヘッダー | `callStatusHeader` | 通話全体の状態を最上部に集約する | `statusHeader` | 常時 | 接続、入力、出力をまとめる |
| 接続操作 | `connectButton` / `disconnectButton` | 通話を開始・終了する | `controls` | 常時 | 接続状態に応じて表示 |
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
| ローカルミュートボタン | `localMicrophoneHeaderControl` | `localMicrophoneMuteButton` | `Mute` | `Bool` | `mic.slash`固定のglassボタン。ミュート中だけdangerのglassProminentとisSelected | 押下でマイクミュート反転。Watch音声選択中は操作を外し、Watchでの操作案内を表示 |
| マスター出力グループ | `callStatusHeader` | `outputStateLabel` | `Output` | `masterOutputVolume`, `isOutputMuted`, `receiveMasterSoundIsolationEnabled` | 出力ラベル + スライダー + Voice Isolation + ミュート | OS 音量ではなく App 最終出力 |
| マスター出力スライダー | `callStatusHeader` | `masterOutputSlider` | `Output Volume` | `Float`, `0...2` | `1.0` が通常、`1.0` 超過は boost | マスターgain後のrx-output PeakLimiterで最終ピークを抑制 |
| マスター出力 Voice Isolation Effect | `callStatusHeader` | `masterVoiceIsolationToggle` | `Voice Isolation` | `receiveMasterSoundIsolationEnabled`。既定 `false` | `supportsSoundIsolation == true` のとき Toggle | RX master bus の SoundIsolation effect 有効/無効 |
| マスター出力ミュートボタン | `callStatusHeader` | `masterOutputMuteButton` | `Mute Output` / `Unmute Output` | `Bool` | ミュート時はアクセント色のglassProminentとisSelected | 入力や接続は止めない |
| ダッキング状態アイコン | `callStatusHeader` | `duckingStatusIcon` | なし | `isDuckOthersEnabled`, `isOtherAudioDuckingActive` | 設定 ON 時のみ `waveform` | 設定 ON と実効 ON を分ける |

### 接続操作

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 異常系の考え方 |
|---|---|---|---|---|---|---|
| 接続ボタン | `callScreen` | `connectButton` | `Connect` | `canDisconnectCall == false` | 主要ボタン | 音声起動失敗と接続失敗を分ける |
| 切断ボタン | `callScreen` | `disconnectButton` | `Disconnect` | `canDisconnectCall == true` | 主要ボタン | 音声起動失敗と接続失敗を分ける |

## 参加者

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 状態 |
|---|---|---|---|---|---|---|
| 参加者見出し | `call-participants-section` | なし | `Participants` | 固定文字列 | セクション見出し | なし |
| 参加者空状態 | `call-participants-section` | `emptyRemoteParticipantsLabel` | `No remote riders` | 固定文字列 | 空状態カード | 相手不在 |
| 参加者カード行 | `call-participants-section` | `remoteParticipantRow{index}` | 参加者カード | `GroupMember`, `remoteOutputVolumes[member.id]`, `remoteSoundIsolationEnabled[member.id]` | 1 参加者 1 カード | 受信音声がなくても存在 |
| 参加者名 | `remoteParticipantRow{index}` | `participantName{index}` | `member.displayName` | `String` | 最大 2 行 | 保存名 |
| 接続/認証状態 | `remoteParticipantRow{index}` | `participantStatusSummary{index}` | 状態の文字 | `connectionState`, `authenticationState` | Wi-Fi 系 + 認証系の記号と文字 | 接続軸と認証軸を分ける |
| コーデック表示 | `remoteParticipantRow{index}` | `participantAudioPipelineState{index}` | `PCM 16-bit` など | `AudioCodecIdentifier?` | `Label`。未観測は `--` | 最後に観測した codec |
| 参加者入力メーター | `remoteParticipantRow{index}` | `participantVoiceLevel{index}` | なし | `voiceLevel`, `voicePeakLevel`, `isMuted` | 値文字列なし | 受信後デコード済みレベル |
| 参加者出力値 | `remoteParticipantRow{index}` | `participantOutputValue{index}` | `{n}%` | `remoteOutputVolumes[member.id]` | 補助テキスト | peer source fader |
| 参加者出力スライダー | `remoteParticipantRow{index}` | `participantOutputSlider{index}` | `{name} Output` | `Double`, `0...1`。未設定時 `1.0` | 個別出力スライダー | マスター出力とは別。peer source faderへ即時反映 |
| 参加者 Voice Isolation Effect | `remoteParticipantRow{index}` | `participantVoiceIsolationToggle{index}` | `Voice Isolation` | `remoteSoundIsolationEnabled[member.id]`。未設定時 `false` | `supportsSoundIsolation == true` のとき Toggle | 該当 peer bus の SoundIsolation effect 有効/無効 |

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
| Internet失敗 | `connectivityNotice`。通常は到達可能な参加者との接続を維持して再試行する旨を表示。アカウントの既存通話との競合は、既存通話の終了・通信断時の期限待ち・再操作を案内する。通話全体が手動復帰待ちならConnectを表示する |
| 機器消失 | `audioRouteNotice`とConnected / Audio Paused。理由と接続・中継の維持を明示 |
| 再開 | `resumeAudioButton`。標準Button、文字ラベルとSF Symbolを併用。認証済みpeerなしでは無効 |
| 別グループ閲覧 | activeGroup用の機器・経路通知を別groupの状態として表示しない |
| 到達確認 | 接続状態・mute解除は相手に聞こえた証明ではない。実音声の受け入れを別途行う |

## 経路共通の操作と識別

| 対象 | 契約 |
|---|---|
| マスター・参加者音量 / effect / meter | Local / Internet / 中継で共通。経路変更で操作を隠さない |
| callStatusHeader | 独立したaccessibility container。子の`masterOutputSlider`、`masterOutputMuteButton`などの識別子を上書きしない |
| 話者設定 | origin peer IDごとに保持。中継gatewayの音量ではない |

## グループ資格の案内

| 状態 | 表示・動作 |
|---|---|
| 鍵不足・保存失敗・不正招待・command過負荷 | Call入口の `groupErrorLabel`。標準Labelをsafe area内に配置し、理由と再招待/再試行を表示する。切断後にも表示し、新しい接続は利用者の操作で開始する |
| 新規グループ作成・有効な選択/接続 | 以前のgroupエラーを解除。通話中に別groupの招待が失敗しても旧通話は維持 |

情報は色だけに依存せずテキストとアイコンで伝え、通常エラーは文脈内に表示する。[Apple HIG Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)に従い、明示的に全groupを消すresetだけ確認を要求する。

## 保存済みグループの復旧

| 項目ID | 表示・操作 | 条件と結果 |
|---|---|---|
| groupStorageStatus | Groups上部のSaved Groups Section、文字とSF Symbol | 一時アクセス失敗・破損・未知schema・鍵欠落・回収待ちを区別。固定高を設けず折り返す。同じ保存エラーを上部bannerへ重複表示しない |
| reloadSavedGroupsButton | Reload Saved Groups | 通話中は無効でDisconnectを案内。未知schemaも無効。成功時は一覧を再構成し選択とerrorを解除 |
| resetSavedGroupsButton | Reset Saved Groups and Users… | 破損時のみ標準destructive Button。標準alertに影響、退避、再招待の必要性を表示 |
| confirmResetSavedGroupsButton / cancelResetSavedGroupsButton | Reset Saved Groups / Cancel | 確認後だけ通話を終了し、元データ退避→空manifest commit→group鍵回収。Cancelを明示し、取り消しなら変更なし |
| standardCreateGroupButton | New Group | 保存読込に失敗している間は無効。鍵欠落・回収待ちだけなら他groupの利用を妨げない |

resetでrider identity・音声設定・Internet資格は変更しない。退避失敗なら元データを保持してerrorを表示する。一般commandの待機上限超過はCallの案内から、停止完了後の明示Connectを促す。

### グループ内の名前編集

AdvancedではGroups管理画面の参加者名から、StandardではCallの参加者名から名前編集を開く。対象groupを固定したFormで、`groupMemberNameField`にこの端末の呼び名、`groupMemberOriginalName`に本人名を表示する。`saveGroupMemberNameButton`で保存、`resetGroupMemberNameButton`で本人名へ戻す。保存ユーザーなら一覧の呼び名も更新し、それ以外は対象groupだけへ保存する。編集を理由にユーザー登録・通知をしない。

### Standardの直近通話

通話していないときに、現在のアカウントと保存一覧で確認できる直近宛先をUsers一覧の先頭のRecent Callに表示する（以前の通話タブの空状態から移した）。行のタップは他の行と同じ`openDestination`。`recentCallName`は現在の名前、`recentCallButton`はCall Again。描画時に示した宛先とログイン世代を共通開始操作へ渡し、削除やログイン変更後は再検証する。通話成立時の記録、設定との保存、破損時の扱いは[通信仕様](../通信仕様.md#直近の成立済み通話先)を参照する。

## 共通の操作表現

StandardとAdvancedの接続・音声再開には標準`glassProminent`、補助操作には`glass`のButtonStyleを使う。Advancedの参加者操作と、Form内の設定コントロールを維持する。Standardの背景は淡い空色のグラデーション、Advancedの本文・診断背景は既存のシステムMaterialと背景を保ち、共通の青いtintで揃える。
