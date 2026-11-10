# RideCom Call 画面項目

## 目的

本書は Call タブの UI 項目を定義する。

## Standardの通話・ユーザー・グループ

Watch音声のpairが失われ、Watchでの再準備が必要な場合は、この端末のResume Audioを表示しない。Watchからの再開始案内に従う。既存pairを保持した一時停止では共通の再開操作を利用する。

初期表示はStandard。`Users` / `Groups` / `Settings`の標準TabView（Standardの`Groups`は設定の「グループタブを表示」がONのときだけ。既定はOFFで`Users` / `Settings`の2つ。OFFにしたときGroupsを表示中ならUsersへ戻し、通話・グループ・保存データは変えない。Advancedは常に`Groups`を表示する。`.sidebarAdaptable`。iPhoneはタブバー、iPad・Macはサイドバー）を使い（最初はUsers）、Diagnosticsは含めない。通話はタブにせず、接続先を選んだときに開く（compact幅のiPhoneは`sheet`、iPad・Macは`inspector`の右の列、`closeCallButton`で閉じる）。iPhoneで`inspector`のcompact表示（OSのシート）を使わないのは、ツールバーに…メニューを置いたその表示を一覧から開き直すとSwiftUIのガラス描画が停止したため（2026-11-03、[証跡](../../../validation/history/画面デザインと録音操作の整理.md#通話のメニューと一覧の行から設定を開く)）。通話中に通話を閉じている間は、iOSはタブバー上の`tabViewBottomAccessory`（`callAccessory`。状態の記号、名前と状態の語の2行の`callAccessoryOpenButton`、`callAccessoryMuteButton`、`callAccessoryEndButton`。切断は標準の`confirmationDialog`で「{接続先}との接続を切断しますか？」と確認（`callAccessoryConfirmEndButton`）。長押しのメニューに通話を開く・ミュート・切断）、macOSはツールバーの`callAccessoryOpenButton`（状態の記号と「{接続先} · {状態の語}」）から開き直す。切断すると通話を閉じて一覧へ戻り、未選択・未接続だけの画面は置かない。以下の詳細画面はSettingsのApp LayoutでAdvancedへ切り替えて使用する。Users / Groupsと参加者は人物と通常グループを共通の青いアバターとし、`person.fill`／`person.3.fill`の記号で区別する。アイコン画像の変更機能は持たず、名前と種別を併記する。Users / Groupsの一覧はSettingsと同じ`readableScrollWidth()`で、行を最大640ptで見えている領域の中央に置き、背景とスクロールバーは端まで広げる。中央に寄せる余りがシステムの余白（regular 20pt）以下の幅（iPhoneなど）はシステムの余白のままにし、行は左右に余白を取った角丸のまとまりになる（macOSのListは左右の`contentMargins`を使わないため、macOSでは`safeAreaPadding`で行を寄せる）。Users / GroupsはStandardとAdvancedで画面構成を分け、AdvancedのUsers / Groupsの行は一般向けの行の部品を使わず`AdvancedRecordRow`で実装の値を出す（Users: 呼び名、`Direct {短縮id} · N devices`または`No direct group yet`、`Name shared by this person: {displayName}`、通話中の状態。Groups: `Saved Groups {件数}`に`N members · key ready`（保存した通話の鍵がないグループ（`groupsMissingKeys`）は`key missing`）・等幅の短縮`id`・通話中の`active`、`Direct Groups {件数}`に内部のdirectグループ）。保存状態・共通操作と同じ意味の表示部品を共用する。Callはモードに応じた画面を使用する。接続先の選択とグループ作成はUsers / Groupsタブへ集約する。画面だけを切り替え、接続・選択・ミュート・一覧の正本は同じIntercomViewModelに保つ。

| 画面・項目ID | 表示と操作 |
|---|---|
| Call / `standardCallScreen` | 先頭は状態ヒーロー。ナビゲーションのタイトルは置かない。縦は1列、iPhoneの横（compact高さ）では左の固定列（幅の45%、ヒーローと操作を縦の中央）と右の詳細一覧の2列にする。右の詳細一覧（`standardCallDetailsScroll`）だけをスクロールし、主要操作を隠さない。iPad・Macでは一覧の右の列（`inspector`、幅320〜420pt）に1列で置く。横のcompact高さでアクセシビリティ文字サイズのときは、上を情報一覧、下を3操作の固定領域（`standardCallFixedControls`）に分け、操作のラベルを記号の横に並べて全文を表示する。状態ヒーロー（`standardCallHero`）は左寄せのLiquid Glassのカード（`.glassEffect`、形は`ConcentricRectangle`。縦の一覧ではそのSectionの行の背景にし、下の一覧と同じ幅にする）で、上から種別・人数（記号付き、subheadline semibold、例: グループ・4人／ユーザー）、接続先の名前（title bold、2行まで）、状態の記号と語（title3 semibold。接続中は進行表示だけwarning）、理由があれば次の行に補足（例: 相手の参加を待っています）を置く。経路は出さない。状態と補足をダッシュで1行につながない。VoiceOverではヒーロー全体を1つの見出しの要素にし、labelを種別・人数と名前、valueを状態と補足にする。操作はヒーローの外（下）に置く。接続前・接続待ち・会話中・音声停止・音声エラーを文言と記号または進捗で示す。認証だけでは会話中にせず、音声準備も成立している状態を使う。触覚は会話中への遷移でsuccess、音声停止への遷移でwarning、接続の終了でstop、マイク／出力ミュートの切替でselectionを出す |
| `standardConnectButton` / `standardEndCallButton` | 接続はglassProminent、切断はdangerの円形glassProminentで下のラベルは`End`（日本語「切断」、`standardEndControlLabel`）。切断の確認は標準の`alert`で「{接続先}との接続を切断しますか？」（`Disconnect from {name}?`。通話のアクセサリと同じ文）。接続済みの相手の行は`DisclosureGroup`（`standardPeerRow-{id}`）で、タップで開くとその人の音量のSlider（`standardPeerVolume-{id}`、数値なし）を出す。閉じている間は出さない。ミュート・スピーカー・切断の3つの円は見た目の直径64pt（横画面・低い高さは56pt。ガラスの余白7ptを引いた記号の枠で描く）で、ヒーローと同じ列の幅に均等に広げ、両端の円を列の端から4ptに置く。切断は隣と32pt以上離す。主要ボタン（`appProminentButtonStyle()`。接続・切替・音声を再開、名前の入力の「はじめる」、新しいグループの「作成して接続」、空状態の主要操作）は置いたまとまりの幅いっぱい（`.buttonSizing(.flexible)`）。空状態の主要操作は一覧の幅から余白を引いた幅で最大420pt。切断確認を取消すと既存通話・ミュートを維持し、確定時だけ描画時に捕捉したCallReferenceを共通endCallへ渡す。接続は共通startCallへ渡す。別の通話を閲覧中はSwitch to This Callを明示。一覧の行のタップで別の通話を置き換えるのは、確認（標準の`alert`、タイトル「接続を切り替えますか？」、本文「{今の接続先}との接続を切断して、{新しい接続先}に接続します。」、`switchCallConfirmButton`の「切り替える」とキャンセル）の後だけ |
| `standardMuteButton` / `standardMuteState` | 円形glassのmic.slash記号を固定し、ミュート中だけdangerの選択状態とする。下のラベル（`standardMuteState`）はMute／Mutedで状態を語でも示す。操作列の下にマイクの状態の案内文は置かない。共通setCallMutedへ描画時のCallReferenceと希望値を渡す。Watch音声選択中はマイク操作を表示せず「Watchでマイクを操作」（`standardMicrophoneStatus`）と案内し、以前のphone mute値を状態として表示しない |
| `standardUsersList` | 保存済みユーザーだけを表示。相手の行のタップは`openDestination`で内部通話先を解決し、待機中ならその場で接続を始めてCallへ移る（[操作の流れ](../../../design/操作の流れ.md)の「選んだら接続」）。現在の通話先なら再接続せずに開き、別の通話中なら切替を確認する。開始できない場合も接続先を表示し、理由を示す。内部グループの作成や選択は要求しない。行の長押し（contextMenu）とswipeに`User Settings`（相手の設定）と`Delete`を置き（Deleteは標準の`alert`で「{名前}を削除しますか？」と確認し、確定は`confirmDeleteDestinationButton`）、鉛筆・`info.circle`は置かない。接続中の相手の行には状態の語（`directoryRowCallStatus`、記号だけ状態色）を示す。空のときはListの`overlay`で一覧の領域の縦横中央に`ContentUnavailableView`（見出しと`emptyUsersInviteButton`の1つだけ。Groupsは`emptyGroupsCreateButton`）、10人を超えると検索（`.searchable`、プレースホルダー「名前で検索」）を出す。Standardの一覧に説明のfooterを置かない（Advancedは保存の規則を文で出す）。行の名前は通常の文字色で、色は状態の記号だけに付ける（`directoryRowButtonStyle`。iOSは行全体のタップを保ったまま`foregroundStyle(.primary)`） |
| `standardGroupsList` | 通常グループだけを表示し、進行中の通話の実状態（接続待ち・会話中・音声停止等）を行内に示す。行のタップはUsersと同じく待機中は接続を始め、別の通話中は切替を確認する。行の補助は人数（例: 4 people／4人）。行の長押し・swipeに`Group Settings`（グループの設定）と`Delete`を置く（Deleteは「{グループ}を削除しますか？」と確認し、接続中のグループでは本文「今の接続は切断されます。」と確定「切断して削除」）。New Groupは既存の名前入力・保存ユーザー選択Formを開く。作成確定時の既存開始処理を共用する。空のときは`emptyGroupsCreateButton`、10件を超えると検索を出す |
| Current Call | Standardでは一覧に置かず、通話のアクセサリ（`callAccessoryOpenButton`）が進行中の通話へ戻す。別の接続先を表示した後でも進行中の通話を開き直す。Advancedは一覧先頭のCurrent Call（`standardCurrentCallButton`）も維持する。保存ユーザー削除で現在の通話を隠さない |
| 招待・参加者 | 通話のツールバーの…メニュー（`callMoreMenu`）は、モードごとに別のView（`StandardCallMoreMenu`・`AdvancedCallMoreMenu`）で、`CallPanel`が選ぶ。Standardは、通常groupに`Group Settings`（グループの設定、`callGroupSettingsButton`）と`Invite Members`（メンバーを招待、`callAddMembersButton`）、個別通話に`User Settings`（相手の設定、`callUserSettingsButton`）。Standardの通常groupには、宛先のないグループのリンクの共有（`inviteButton`）を暫定で残す（メンバーを招待で新しい人を招待できるまで、保存ユーザーでない人をグループへ入れる唯一の手段のため）。Advancedは実装の操作名で、`Group Settings`／`User Settings`、`Add Saved Users`（`callAddMembersButton`）、共有可能なら`Invite`（directは`Share Call Invite`、`inviteButton`）。通話の画面に共有だけのボタンを単独で置かない。参加者の名前編集と通常groupから外す操作（確認付き）は行の長押し・swipe。既存の署名付き共有、本人名／別名編集、通常groupへの保存ユーザー追加・削除を共用する。groupで会っただけの相手をUsersへ追加しない |
| 声のインジケーター | このグループの通話中だけ、声の大小を`StandardVoiceIndicator`（SF Symbolsの可変値、`.symbolVariableValueMode(.draw)`）で示す。数値は出さない。メンバーの先頭に自分の行（「自分」、ミュート中は「ミュート中」）を置き、行末にマイクの入力（`microphone.and.signal.meter`、`diagnosticsInputLevel`、`standardVoiceIndicatorSelf`）。本人確認済みの相手の行末に届いている声（`waveform`、`GroupMember.voiceLevel`、`standardVoiceIndicator-{id}`）。音量のSliderの右端に実際の出力（`speaker.wave.3`、`diagnosticsOutputLevel`、`standardVoiceIndicatorOutput`）。値はdBFSの表示値を4段に丸め、最も小さな声より下は無音として灰色（textSecondary）、声があればvoice色。ミュート中・消音中・相手のミュート中は段の代わりにdangerの`mic.slash`／`speaker.slash`。読み上げはlabel「自分の声」「{名前}の声」「出力」、value「話しています」「無音」「ミュート中」 |
| メンバーの状態 | このグループの通話中だけ、各メンバーの名前の下に状態の語を1つ出す。話している人は「話しています」（`standardMemberSpeaking-{id}`。語は標準の副次色で、声の大小は行末の声のインジケーターが示す）、本人確認済みでミュート中の人は「ミュート中」、届いているが本人確認前は「接続中」（`standardMemberConnecting-{id}`）、届いていない人は「接続していません」（`standardMemberNotConnected-{id}`）。本人確認済みで黙っている人は語を出さない。判定は保存したメンバーの状態ではなく、今の`authenticatedPeerIDs`・`connectedPeerIDs`を使う。行は名前と状態を1つの読み上げにまとめる。未接続の人の「呼び出す」は未実装 |
| `standardSpeakerButton` / 入出力 | 相手の声を消す切替は「Silence」（消音。消音中は「Silenced」（消音中）、`standardSpeakerControlLabel`）。電話アプリの「スピーカー」（出力先の切替）と紛れないよう「Speaker」の語を使わない。VoiceOverはlabel「Silence」、value「On／Off」（オン／オフ）とisSelectedで読み、既存toggleOutputMuteへ渡す。選択状態の塗りはアクセント色とし、隣の切断（danger）と同じ塗りを並べない。音量は見出しのないSectionのSliderだけ（`standardVolumeSlider`、label「Volume」（音量）。今の出力先の音量）で、数値を出さない。100%の位置に標準の`SliderTick`の目盛を置き、100%を超えた位置では右に補足「Louder」（大きめ、`standardVolumeLouder`）を出す。左に`speaker`、右に出力の声のインジケーター。1対1の通話に説明の文は置かない。マイク／出力ミュート、出力・参加者音量、対応機器の音声分離、機器切断後の再開。経路やcodecの診断値は出さない |
| 復旧 | 保存読込失敗・破損の既存reload/reset操作、通話・音声のエラーと再試行案内を同じ状態から表示する |

英語を原文としてString Catalogに一般画面と共通の操作・設定・アカウント案内の日本語を保持する。本人名・別名・グループ名は翻訳しない。App生成の再試行秒数、名前・人数の補間、招待・音声復旧の定型案内も翻訳対象とし、英語の単複を扱う。OSやサービスから来る任意の自由文は独自翻訳しない。Advancedの診断項目の全訳は対象外。購入商品未設定は利用不可と表示し、通知の送信・24時間利用権の完成を装わない。通話権利条件は画面側に追加しない。[共通利用権判定](../通話利用権仕様.md)が媒体準備と成立を区別し、作成不可・権利を持つ参加者待ちにはSettingsのAccessを案内する。


Call は通話開始、接続維持、参加者確認、入出力の最小操作を行う主画面である。

Connect・Disconnect・ローカルマイクの操作は[通話先と操作対象の共通境界](../通信仕様.md#通話先と操作対象の共通境界)を使う。描画時の通話先・通話世代・設定値を保持し、遅れた終了やミュートが別の通話に作用しないようにする。

## 新しい相手への直接招待

Standard／AdvancedのUsers画面は別の構成を維持し、招待の保存・表示状態・操作は同じViewModelを参照する。通常groupを作らず、共有しただけでユーザー／メンバーを表示しない。署名と保存・再送の条件は[新規相手招待の通知処理](../通信仕様.md#新規相手招待の通知処理)に従う。

| 項目ID | 表示・操作 |
|---|---|
| `inviteContactButton` | Usersの＋。押した時点で一件の招待を保存し、共通の共有sheetを開く。通常group作成の購入条件を流用せず、ログインと保存可能性を確認する |
| `contactInvitationSheet` / `contactInvitationNameField` / `shareContactInvitationButton` | 未送信の送った招待は見出し「Invite Someone New」（新しい相手を招待）で、先に「Their Name」（相手の名前）を入れる。欄は空で開いてキーボードを出し、プレースホルダーは`ProvisionalName`の仮名（色と生き物の語、端末の言語、使用中の呼び名と重ならない。シートを開いている間は変えない）。空のままなら仮名を使う。名前は`ContactInvitationRecord.nickname`にこの端末だけで保存し（欄を離れたとき・Return・キャンセル・閉じたとき）、招待が成立したときに保存ユーザーの`localName`が空ならそれにする。相手には送らない。Send Invitation（招待を送る）からOS標準の共有先を選び、文面は「RideCom invitation for {呼び名}」。左上は「Cancel」。名前を入れて送る間（未送信の段）はシートを下へのスワイプで閉じず（`interactiveDismissDisabled`）、閉じるのは「Cancel」だけにする。キーボードを出したまま送ると、共有画面の上側に見えている招待のシートへのスワイプが共有画面と一緒にこのシートを閉じていたため。共有画面を閉じると招待のシートに戻り、入れた名前は残る。InvitationShareは保存した同一tokenを使用し、export時にログイン世代・期限・取消・鍵を再確認する。共有の取消・Copyで新しい招待やユーザーを増やさない |
| `pendingContactInvitation-<UUID>` | Invitations（招待中）の独立した行。タップで招待の詳細（`contactInvitationSheet`）を開き、接続はしない。Standardは破線の人物（`PendingAvatar`）・名前（送った招待は`nickname`、相手が分かれば保存ユーザーの呼び名、どちらもなければ「Invitation」。2行まで）・状態の語1つ（相手の受け入れ待ちは「Waiting to be accepted」（受け取り待ち）と`›`、受け入れ後に返信を届けている間は「Sending a reply」（返信を届けています）と`ProgressView`）。行の中の再共有は置かず、詳細から送り直す。Advancedは`Invitations {件数}`をUsersの末尾（保存ユーザーの後）に置き、`ContactInvitationRecord`の短縮`id`・`direction · state`（`canResume`）・`expiresAt`を等幅で出す |
| `contactInvitationState` / `contactInvitationStatus` | 招待中の行から開いた招待の詳細。Standardは破線の人物・種類（「You sent this invitation」（あなたが送った招待）／「Invitation from {名前}」（{名前}からの招待））・名前・状態の語1つ（`contactInvitationState`）と説明1文（`contactInvitationStatus`）・主要操作1つ。送った招待の受け取り待ちは「Waiting to be accepted」、文「{名前}がこの招待を開いて受け入れると、ユーザーに加わります。」、主要操作は同じ招待をもう一度共有する「Send Again」（もう一度送る、`shareContactInvitationButton`）とその下の1文「{名前}に、同じ招待をもう一度送ります。」。下に「Name on this device」（この端末での呼び名）の欄（今の`nickname`で開き、空にすると元の名前に戻す）。返信を届けている間（共通VMの通知所有IDがこの招待、または通話中）は「Sending a reply」と`ProgressView`で操作なし（通話中の文は「Waiting for the current call to end.」）。届ける試みが止まったら「Reply not delivered」（返信が届いていません）、文「{名前}にまだ返信が届いていません。」、主要操作「Send Again」（`retryContactInvitationButton`）と下の1文（受け取った招待は「{名前}に、招待を受け入れたことをもう一度届けます。」、送った招待は「{名前}に、返信をもう一度届けます。」）。Standardは詳細を開いた時点で通知を再開する（通常通話中は再開しない）。Advancedはこの画面を流用せず、`ContactInvitationRecord`の各値（`id`・`direction`・`state`・`canResume`・`expiresAt`・`peerMemberID`・`nickname`）と通知の`session`（`running`／`stopped`）を等幅で出し、従来の状態文（未受諾、保存済みの相手、通話終了待ち、一時停止、配達確認）と、実装の条件どおりの`Share Again`（送った未受諾）・`Retry Notification`・`Cancel Pending Invitation`／`Stop Retrying Notification`を置く。接続や共有だけで成功と表示しない |
| `retryContactInvitationButton` | 通知を再開する。通常通話を奪わず、通信は最大60秒。表示用の独自timerを持たず、共通VMの通知所有IDと保存状態から表示を更新する |
| `cancelPendingContactInvitationButton` / `confirmCancelContactInvitationButton` | 標準の破壊的確認。Standardの送った招待は「Cancel Invitation」（招待を取り消す）、本文「An invitation already sent may still be accepted until it expires.」、取り消さない側は「Keep Invitation」。受け取った招待は「Delete This Person」（この相手を削除）で、確認のタイトル「{名前}を削除しますか？」の後に招待の記録を取り消して保存ユーザーを削除する。Advancedは従来どおりこの端末の再試行を停止し保存pendingを取り消す（本文「Stops retries on this device. …」）。共有済みURLの相手側での遠隔失効を保証する文言にしない |
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

## 1対1の呼び出しの通知

1対1の接続を新しく始めたとき（一覧・Widget・Watch・Siriのどこからでも`startCall`の`.user`）に、相手が呼び出しを受け取る設定なら呼び出しの通知を1回だけ送る（`IntercomViewModel.noticeNewDirectCall(to:)`）。すでにその通話中なら送らない。グループは送らない。通知は親切な知らせであり（[製品要求](../../../requirements/製品要求.md#利用者に提供すること)）、送った結果・応答待ち・応答なし・届けられないことを画面に出さず、再送・取消・「もう一度呼び出す」も置かない。状態ヒーローは通話の状態（接続中・会話中など）のまま。Standard・Advancedの相手の設定と、Apple Watchにも手動の送信・取消を置かない。

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

Groupsの`New Group`（`standardCreateGroupButton`）から標準Formを開く。見出しは「New Group」（既存groupへの追加は「Invite Members」）。名前入力（`savedUsersGroupNameField`）は空欄で開き、選んだ保存ユーザーの名前の並び（`ListFormatter`）をプレースホルダーにして、空のまま作成するとその名前を使う。Standard（`StandardMemberSelection`）は「Your Users」（あなたのユーザー）に保存ユーザーを1人1行で並べ、行はアバター・名前・選択の印（`checkmark.circle.fill`／`circle`、VoiceOverは選択状態）だけで、行のタップは選ぶだけ（`selectUser-{UUID}`）。行に名前の編集・削除を置かず、説明の文とfooterを置かない。一覧の下（`safeAreaBar`）に「{n}/8 people including you」（自分を含めて{n}/8人、`memberSelectionCount`）と主要操作1つ（`saveUserSelectionButton`。作成は`Create and Connect`（作成して接続）、別の通話中は`Create Group`、既存groupへの追加は`Send Invitation`（招待を送る））を置く。Advanced（`AdvancedSavedUsersSelection`）は従来どおり行ごとの`Toggle`・名前の編集・削除、`Saved Users`の説明、ツールバーの`Create and Connect`／`Add Users`。選択の値と保存は両モード共通の`MemberSelection`。保存済みの相手を使うグループを作成し、待機中ならそのまま接続する。相手を加えたときは、相手の端末へグループを自動で届ける機能がまだないため、続けて招待の共有の画面（`sendGroupInvitationMessage`）を出す。`Cancel`（`closeSavedUsersButton`）では変更しない。

Usersの行の`User Settings`（`userSettingsView`）は相手の設定を開く。モードごとに別のView（`StandardUserSettingsView`・`AdvancedUserSettingsView`）で、`UserSettingsView`が選ぶ。Standardは、見本の項目だけを置く。「Name on This Device」（この端末での名前、`savedUserNameField`。今の呼び名で開き、空なら本人の名前をプレースホルダーに出す）と「Their Own Name」（本人の名前、`savedUserOriginalName`）、「Receive Calls from This Person」（この相手からの呼び出しを受け取る、`allowCallRequests-{UUID}`）、最後に赤の`Delete User`（ユーザーを削除、`deleteUserButton`。確認はタイトル「{呼び名}を削除しますか？」と「削除」（`confirmDeleteUserButton`）・「キャンセル」で、削除の同期が未実装のため本文を出さない）。`Save`（`saveUserNameButton`）では、空欄か本人の名前と同じなら呼び名を解除して本人名に従い、それ以外は端末内の呼び名として保存する。招待の共有、`Use Shared Name`、説明のfooterは置かない。Standardの相手の設定には呼び出しの送信を置かない。1対1の接続を始めると呼び出しの通知を1回だけ送る（下の[1対1の呼び出しの通知](#1対1の呼び出しの通知)）。AdvancedもUsersの行の操作（スワイプ・長押しの「User Settings」）から開く。Advancedの作成・追加Form（`AdvancedSavedUsersSelection`）の行は選ぶだけで、名前と選択中のチェックの印（`selectUser-{UUID}`、VoiceOverは選択状態）を出し、鉛筆・削除・説明・footerを置かない。端末での呼び名、本人名、`Use Shared Name`（`resetUserNameButton`）、`Call Notifications`（`Allow Call Requests`・`Send Call Request`）、内部のdirect groupがあれば招待（`userSettingsInviteButton`）、`Delete User`を置き、`closeUserSettingsButton`で閉じる。同じ名前の別IDは統合しない。行のDeleteは独立一覧からの削除であり、既存グループと進行中の通話を保持する。表示名変更は既存グループにも反映する。

StandardではCallのParticipantsの`Invite Members`（メンバーを招待、`addSavedUsersButton`）、両モードで通話の…メニュー（`callAddMembersButton`）とGroup Settings（`groupSettingsAddMembersButton`）から保存ユーザーを追加する。現在のgroup IDを操作対象として固定し、直接招待関係のある保存ユーザーのうち、まだ含まれない相手を選択して追加する。自分を含め8memberまでで、重複・古い操作対象・保存失敗は確定しない。`savedUsersErrorLabel`で失敗を示す。選択だけでは相手へ通知しないことと、追加後に招待の共有が必要なことをFormに表示する。AppleログインやID宛て通知の完成を表す画面ではない。

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

[操作の流れ](../../../design/操作の流れ.md)の「設定は名前の付いた入口から」に従う。画面はモードごとに別のView（Group Settingsは`StandardGroupSettingsView`・`AdvancedGroupSettingsView`、User Settingsは`StandardUserSettingsView`・`AdvancedUserSettingsView`）で、`GroupSettingsView`・`UserSettingsView`が選ぶ。一覧の行・メンバーの行の長押し・swipeもモードごとの修飾子（`standardDestinationRowActions`・`standardMemberRowActions`／`advanced…`）で、削除・外すの確認（`destinationDeleteConfirmation`・`memberRemoveConfirmation`）だけを安全規則として共通にする。入口は通話の…メニューと、Users / Groupsの行の長押し（contextMenu）・swipeだけで、行のタップは接続の1つの意味に保つ。開いても選択中の通話・表示中の通話を切り替えない。

| 画面 | 項目 | 操作 |
|---|---|---|
| Group Settings（`groupSettingsView`） | 名前（`groupSettingsNameField`）、メンバー（行の長押し・swipeで`Edit Name`と`Remove`。`Remove`は標準の`alert`で「{名前}をグループから外しますか？」と確認し、確定は`confirmRemoveMemberButton`）、メンバーの下の追加の行（`groupSettingsAddMembersButton`。Standardは破線のアバターと`Invite Members`（メンバーを招待）で、通話の…メニューと同じ語。Advancedは`Add Members`）、招待（`groupSettingsInviteButton`。Standardでは新しい人を招待できるまでの暫定）、`Delete Group`（`deleteGroupButton`。Standardは記号なしの赤い文字） | `Done`（`saveGroupSettingsButton`）で名前を保存して閉じる。名前は端末内の`renameGroup`で保存し、接続中でも再接続しない。`|`は保存しない。Standardの名前の欄はプレースホルダーにメンバーの名前から作った名前（例: Haruka and Kenta）を出し、空にして`Done`を押すとその名前を保存する。Advancedは空白だけの名前を保存しない。`Delete Group`は確認（`confirmDeleteGroupButton`）の後に削除し、接続中なら切断する。`Cancel`（`closeGroupSettingsButton`）は名前を保存しない |
| User Settings（`userSettingsView`） | Standardはこの端末での名前、本人の名前、この相手からの呼び出しを受け取る（暫定で呼び出す）、`Delete User`。Advancedは端末での呼び名、本人の名前、Use Shared Name、呼び出しの許可、招待（`userSettingsInviteButton`）、`Delete User`（`deleteUserButton`） | `Save`で呼び名を保存。削除は確認の後で、既存groupと進行中の通話を保持する |

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
| 参加者入力メーター | `remoteParticipantRow{index}` | `participantVoiceLevel{index}` | なし | `voiceLevel`, `voicePeakLevel`, `isMuted` | 値文字列`LEVEL n  PEAK n`（ミュート中は`MUTED`、`voiceMeterValueLabel`） | 受信後デコード済みレベル |
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
| 鍵不足・保存失敗・不正招待・command過負荷 | Call入口の `groupErrorLabel`。AdvancedはCallの内容の先頭に不透明のカード（`AdvancedCallErrorCard`。接続先がないときはそのカードだけのScrollView）で置き、`Material`の帯にしない。理由と再招待/再試行を表示する。切断後にも表示し、新しい接続は利用者の操作で開始する |
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

AdvancedではGroups管理画面の参加者名から、StandardではCallの参加者名から名前編集を開く。対象groupを固定したFormで、`groupMemberNameField`にこの端末の呼び名（見出し「この端末での呼び名」、プレースホルダーは本人の名前。空で保存すると本人の名前へ戻す）、`groupMemberOriginalName`に本人名を表示する。`saveGroupMemberNameButton`で保存、`resetGroupMemberNameButton`で本人名へ戻す。保存ユーザーなら一覧の呼び名も更新し、それ以外は対象groupだけへ保存する。編集を理由にユーザー登録・通知をしない。

### Standardの直近通話

通話していないときに、現在のアカウントと保存一覧で確認できる直近宛先をStandardのUsers一覧の先頭のRecent Callに表示する（以前の通話タブの空状態から移した）。Advancedの設計にないため、AdvancedのUsersには出さない（`RecentCallSection`は`Standard/StandardDirectoryViews.swift`）。行のタップは他の行と同じ`openDestination`。行は一覧の行と同じ`DirectoryRowLabel`で、種類のアバター、現在の名前、補足（グループは「グループ・{n}人」、人物は「ユーザー」）を出す（`recentCallButton`）。描画時に示した宛先とログイン世代を共通開始操作へ渡し、削除やログイン変更後は再検証する。通話成立時の記録、設定との保存、破損時の扱いは[通信仕様](../通信仕様.md#直近の成立済み通話先)を参照する。

## 共通の操作表現

StandardとAdvancedの接続・音声再開には標準`glassProminent`、補助操作には`glass`のButtonStyleを使う。Advancedの参加者操作と、Form内の設定コントロールを維持する。画面の背景は、上端のbackgroundTop（ライト`#CFE5F6`、ダーク`#0E2238`）から下へbackgroundBase（ライト`#EBF1F7`、ダーク`#03070D`）に変わり、変化の終わりから下は一定の色にする（`AppColorPalette`の`callScreenBackground`・`listScreenBackground`と`screenBackground(_:)`。List・Formは標準のセルのまま、背景を画面に固定する）。終わりの位置は、StandardのCall・Appleログイン・名前の入力が高さの45%（ガラスのヒーローと操作が変化の上に乗る）、Users・Groups・招待のシート・Settingsとその中の画面・AdvancedのCall・Diagnosticsが25%（行は一定の色の上に並ぶ）。macOSは標準のwindowの背景で、グラデーションを使わない（[背景のグラデーション](../../../design/カラーテーマ.md#背景のグラデーション)）。下から開くシート（メンバーを招待・新しいグループと招待の送信、グループの設定、相手の設定、メンバーの呼び名、招待の受け取り、購入、アカウントの削除と削除中の表示）も同じ25%の背景にし、Formの標準の単色にしない。面は[面の重なり](../../../design/カラーテーマ.md#面の重なり)に従い、独自に描くAdvanced・Diagnosticsのカード（`appCallCardStyle`・`appDiagnosticsCardStyle`）は不透明の`cardSurface`（`secondarySystemGroupedBackground`）に`cardBorder`の枠線、Diagnosticsの入れ子の面は不透明の`panelSurface`（`tertiarySystemGroupedBackground`）で、ガラス・Material・薄めた色にしない。ガラスはStandardの状態ヒーロー、ボタン、ナビゲーションだけ。通話のアクセサリの中のミュート（オフ）と切断は、OSのガラスの上に記号だけを置き、ミュート中だけDangerで塗った円に白い記号にする。共通の青いtintで揃える。
