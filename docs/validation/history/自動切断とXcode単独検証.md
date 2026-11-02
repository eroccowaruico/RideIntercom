# 自動切断とXcode単独検証

2026-11-01、`ad65a667`を基準とするApp工程。通常3時間・Watch5分という回答を反映し、13段階の自動切断、Settingsの個別保存、全入口の共通終話を実装した。package／serverの製品処理は変更していない。現行の動作は[通信仕様](../../spec/App/通信仕様.md#自動切断タイマー)、操作は[Settings](../../spec/App/UI/Settings.md#自動切断)を参照する。

## 実装した境界

| 対象 | 確認内容 |
|---|---|
| タイマー | 全13値の直前／到達、通常とWatchの初期値・独立保存・reset、相手待ち・音声準備失敗・再接続中の期限維持、重複開始とmuteで延長しないこと |
| 終了と再開始 | 期限後の古いcallback／開始／mute要求を拒否。機器変更と期限到達が重なっても一時停止を残さず、次の明示開始と音声準備が成立する |
| 利用権 | 購入者ありで開始してからの24時間猶予と分離。猶予終了前に再開した通話が24時間境界をまたぐ試験は、今回の自動切断期限内という独立条件で維持 |
| XcodeのTest | 共有schemeのTestActionから専用Debug構成・明示fixture・検証namespaceを選ぶ。通常Run／Release Archiveは通常設定。検証指定不足から通常Keychainへfallbackしない |
| OS表示・通知 | 検証namespaceではApp Group解決／Widget更新／Live Activity／Watch Connectivity／OS通知を行わない。通常namespaceの正例も確認 |
| 保存復旧UI | TestSupportがその回のUUIDを含む破損bytesを準備し、実repositoryのreset後に空manifestと同じbytesの退避を再起動時に検査。外部CLIによるcontainer指定は不要。symlink・通常namespace・別UUIDは拒否 |
| 配布物 | local Swift packageの各rootをAppのresourceコピーから除外。Watchの共有scopeを実Sources phaseへ接続。App・Widget・Watchの保存先と共通ビルド番号を検査 |

## 自動検証

検証用作業領域は`/private/tmp/RideIntercom-account-verification`。各runの`.validation`にコマンド・xcresult・生成hostの起動前検査・入力のSHA-256・所有資源の回収を保存する。専用iPhone／iPadを順に再利用し、実機は使わない。

| 検証 | 結果・証跡 |
|---|---|
| 統合後の標準Xcode Test | CLI固有のcompiler／namespace／entitlement上書きなしで、Mac全App510件・ローカルStoreKit39件成功。`timer-xcode-accepted-native`。専用構成の生成hostを起動前に検査、失敗・skip・runtime warningなし |
| 統合後のiPhone | App単体496件＋タイマーUI1件、自己完結した破損復旧UI1件成功。`timer-xcode-accepted-ios`。初期3時間／5分、15分／1分への独立変更、再起動後の保持、初期値への戻しを確認 |
| 統合後のiPad | 同じbuildでタイマー保存と英語・日本語の回転／大きい文字／sheet操作の3件成功。`timer-xcode-accepted-ios/ipad-ui.xcresult`。両Simulatorをshutdown |
| 統合後のRelease Archive | Xcode保存形式のままMac build283・iOS build284が成功。`timer-xcode-accepted-archives`。App／Widget／Watchの番号一致、通常namespace、entitlements／package／test bundleのresource不混入、実WebRTC frameworkのprivacy manifestを確認。unsigned・未提出 |
| 統合後のPython入口 | 107件成功、26.063秒。`timer-xcode-accepted-python-final`。Xcodeの旧形式・保存後形式に対応したWidget削除fixture、実package rootの所属検査を含む |
| 統合前のMac全App | 507件成功、失敗・skip・runtime warningなし。`timer-xcode-macos-final`。その後のWatch Sources・package除外・期限時の機器変更修正は次行で補完 |
| 最終変更のMac回帰 | Xcode構造・隔離・復旧とタイマー25件、同じbuildの既存通話lifecycle／音声pipeline45件成功。`timer-xcode-macos-followup-final`、`timer-xcode-macos-nested` |
| iPhone全App／UIの初回 | 518件中517成功、失敗は新timerの子Picker識別子が見つからない1件。既存UI21件は成功。`timer-xcode-ios-final`。失敗のため復旧UIとiPadは後続へ延期し、成功扱いにしない |
| ローカルStoreKit | 39件成功。`timer-xcode-storekit`。Xcode専用StoreKit構成と付属fixtureを使用し、実購入・Apple配布を行わない |
| Python入口 | 104件成功。`timer-xcode-script-check`。不要になった外部復旧fixtureの6件は削除し、実repositoryと自己完結したUIの検証へ置き換えた |
| Release Archive | Mac／iOSのunsigned標準Archive成功。`timer-xcode-archives-final`。App・Widget・Watchの通常namespace、production APNs、同一build内の番号一致、test bundle／package source／cache／認証・復旧fixture文字列の不在を検査 |

## 失敗を保持して修正した内容

| 初回の結果 | 対応 |
|---|---|
| Macの音声開始失敗試験がticker停止を期待して失敗 | 相手待ち・音声準備失敗でもタイマーが進む仕様へ期待を修正。音声資源の回収・再試行・明示終了時のticker停止は維持。`timer-xcode-macos`の失敗を保持 |
| iOS buildでWatchから共有scopeを参照できない | WatchのSources phaseへの接続漏れを修正し、実targetからfileRefまで辿る構造試験を追加。`timer-xcode-ios`と初回iOS Archiveの失敗を保持 |
| Mac ArchiveにRTCのtest bundleが混入 | 親packagesだけの除外では各Swift package containerがresourceになることを実ログで確認。9rootを明示除外し、不混入を実Archiveで検査。`timer-xcode-archives`の失敗を保持 |
| 期限後・次tick前の機器変更でpauseが残る | fake音声の回帰試験でREDを確認し、通話が継続している場合だけpauseへ移る1条件を追加。次の通話の音声成立まで確認 |
| 新timerの子PickerをUIから取得できない | 既存のTransmitCodecPanelと同じ`accessibilityElement(children: .contain)`をSectionの親識別子の前へ追加。見出し・Section ID・個別Picker IDを保持。既存の設定panelは全体UIで検出できており変更しない |
| Xcode保存形式でPythonのWidget削除fixtureが失敗 | `dstSubfolderSpec`という旧形式の数値でphaseを選ぶfixtureが何も外せていなかった。Widgetの実fileRef→BuildFile→AppのCopyFiles phaseを辿り、1 entryを実際に外したことを確認するfixtureへ修正。製品checkerとApp処理は変更しない。`timer-xcode-accepted-python`の初回107件中1失敗を保持 |
| Mac回帰のnested suite指定が対象にならない | `AppTests/CallLifecycleTests`と`AppTests/AudioPipelineTests`の正しい識別子で既存buildを再利用し45件を確認。最初の25件を既存suiteまで確認した結果として数えない |

## Xcode保存内容の統合

利用者の「Xcode中心なので受け入れて作業してほしい」という回答に従い、mainのXcode保存形式を基準に統合した。既存185 objectを保持し、検証構成・参照20 objectを追加。shellScriptの配列、dstSubfolder、runpathの配列、日本語region、folderとしてのproject参照を維持し、変更する13 objectの項目と新規構成の意味をJSON比較した。4構成の自動採番を共通にし、検証済みの番号を巻き戻さない。

Xcodeが省くことのある親packagesの例外だけに検査を依存させず、Appが参照する同期groupと、そのApp向け例外に各local package rootが含まれることを確認する。親だけの除外は拒否し、実rootが揃っていれば親なしでも通す。別targetやgroupから外れた例外での偽の合格も拒否する。App／WidgetのentitlementsはXcode保存どおり署名入力として保持し、resourceへの不混入は実Archiveで別に確認する。

各native runは404入力の前後一致を確認し、生成counterの増分だけを許容した。native検証後のsource差分はPythonのWidget削除fixture1ファイルのみで、別のPython全107件の成功で確認した。App・project・配布物の処理は再変更していない。初回iPhone失敗の診断収集ではXcode内部のsimctl検索エラーも発生したが、xcresult・失敗理由・元logを保持し、global xcode-selectの変更で解消したとは扱わない。

## 2026-11-02の再確認

利用者の「念のため」の再確認指示に対し、`fc9af519`の実装と自動試験を照合した。選択肢は1分・3分・5分・10分・15分・30分・1時間・2時間・3時間・6時間・8時間・12時間・24時間の13値で、無制限はない。通常3時間・Watch 5分を別keyで保存し、範囲外の保存値は初期値へ戻す。不一致はなく、実装・仕様は変更していない。

| 再確認した条件 | 対応する試験 |
|---|---|
| 13値・無制限なし・初期値・通常／Watchの独立保存 | `CallDisconnectTimerTests.supportedDurationsAreFiniteAndSettingsRoundTripIndependently` |
| 全値が境界時刻で終了し、tickerを止める | `everyIntervalExpiresAtItsBoundary` |
| 一時切断・自動復帰・重複開始・mute・設定変更で期限を延長しない | `reconnectAndDuplicateStartDoNotExtendTheCurrentDeadline` |
| Watch開始はWatch用時間を使い、重複開始で更新せず、通常設定へ混入しない | `watchStartUsesItsOwnSettingWithoutChangingThePhoneSetting` |
| 期限後の遅れた接続成立・mute解除で通話を復活させない | `delayedRecoveryAfterTheDeadlineCannotRestartAudio`、`expiredStartBeforeTheNextTickEndsTheCallWithoutStartingAnother`、`watchSnapshotCannotUnmutePastAShorterCallDeadlineBeforeTheNextTick`、`microphoneToggleCannotUnmuteAnExpiredCallBeforeTheNextTick` |
| 手動終了・切替で旧期限を破棄し、次の明示開始は可能 | `manualSwitchAndStopDiscardThePreviousDeadline` |
| 音声機器の切替で期限を更新しない | `WatchControlTests.switchingToWatchStopsPhoneCaptureAndRetainsTheCallDeadline`、`deviceChangeAtTheDeadlineDoesNotPauseTheNextCall` |

Macで`CallDisconnectTimerTests`・`WatchControlTests`・`WatchAudioIntegrationTests`の28件が成功した。実OSの背景・ロック・画面消灯・長い復旧中の期限動作は引き続き[未確認事項](../未確認事項.md#自動切断の実os受入)で扱う。

## 受入の範囲

Apple HIGのAccessibility・Layout・SF Symbolsを確認し、既存のForm／Section／Pickerと`timer` symbol、標準の可変高さ・ラベルを使った。UI試験による操作確認と、実VoiceOver・実OS背景動作は区別する。

既存SDKのApp Intents未使用targetに対するmetadata省略warningはログへ保持しており、warningゼロとは扱わない。実CoreAudioを必要とするpackage検証の既知の待機失敗、独立音声E2E、実Wi-Fi／セルラー／SFU、Apple認証・署名・TestFlight処理・家族共有は本結果で代用しない。Watch自身のマイク／スピーカーと押下中だけ送話するモードは未実装。現在のWatch設定はiPhoneへの開始操作に適用する。実背景・画面消灯・時計変更・電池と費用の効果は[未確認事項](../未確認事項.md#自動切断の実os受入)へ残す。
