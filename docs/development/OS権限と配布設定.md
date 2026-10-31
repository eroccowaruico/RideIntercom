# OS権限と配布設定

## 設定の責任と状態を分ける

本書は[開発環境](開発環境.md)のOS・署名・配布設定を補う。宣言があること、profileに許可されていること、利用者のOS許可、server有効化、商品販売は別の状態である。署名なしbuildとfixture試験だけで外部サービスの利用可能とは判断しない。

| 領域 | リポジトリの設定 | 外部で成立させること |
|---|---|---|
| Appleログイン | 全通話で認証必須。AppのiOS/macOS entitlementにSign in with Apple | 対象App IDのcapabilityと、そのcapabilityを含む両OSのprofile。実Apple認証・取消・復帰 |
| 近距離通信 | `NSBonjourServices`は`_ride-intercom._tcp`と`_ride-audio._udp`。ローカルネットワーク説明を日英で同梱 | 各端末でローカルネットワークを許可。固定BonjourとUDP unicastなのでmulticastの制限付きentitlementは追加しない |
| マイク・継続音声 | 日英のマイク説明、macOS audio-input、Appのaudio background mode | 各端末のマイク許可。実Bluetooth・中断・ロック中通話の受入。カメラ、連絡先、位置情報、Watchマイクは要求しない |
| Mac sandbox | Appはsandboxとnetwork client/serverを有効。UDPの送受信に両方向が必要 | 通常sandboxの実起動と実通信。自動unitでsandboxを無効にした結果とは区別 |
| Widgetの選択用共有 | AppとWidgetに同じApp Group。Widgetは資格を持たず、Appが投影を書きextensionは読む | 両App IDへのgroup割当と両profileのgroup許可。署名済みの実App/extension間で共有できること |
| 通知 | AppだけPush entitlement。通常のalert/soundと利用者tapを使用。背景remote-notificationを要求しない | Push capability、APNs環境、server topic、provider鍵、利用者の通知許可を一致させる |
| Watch | iPhone依存の単一Watch App、対応bundle ID、専用AppIcon。音声やPushの権限は持たない | Watch App ID/profile、iPhoneとの実ペアリングとWCSession手渡し。Watch音声は未実装 |
| 状態表示 | iPhone/iPadの任意Live Activity、Mac Widgetを実装。対応端末のDynamic Islandとロック画面を使用 | OSによる表示・消去・ロック解除・手渡しを受入。Mac自身からのLive Activityは提供しない。iPhone由来のMac表示とMac native上部表示を混同しない |
| 購入 | 公開`StoreProductCatalog.production`は未設定。商品未設定時の商用条件非適用を維持 | 商品・価格・契約・Family Sharing・審査・販売許可。ローカルStoreKit fixtureは販売設定ではない |

## IdentifierとApple Developerでの設定

Apple DeveloperのCertificates, Identifiers & Profilesで、既存の登録を確認してから不足を設定する。以下は必要な登録先を示し、portalの現在の登録状況を確認済みとするものではない。

| 登録先 | Identifier | 設定 |
|---|---|---|
| Identifiers → App IDs | `com.yowamushi-inc.RideIntercom.RideIntercom` | Sign in with Apple、Push Notifications、App Groups。iOS/macOSで必要なprofileを別々に確認 |
| Identifiers → App IDs | `com.yowamushi-inc.RideIntercom.RideIntercom.Widgets` | App Groupsだけ。Appleログイン・Push・マイクをextensionへ追加しない |
| Identifiers → App IDs | `com.yowamushi-inc.RideIntercom.RideIntercom.watchkitapp` | Watch App用の明示ID。親Appのbundle IDを`WKCompanionAppBundleIdentifier`へ指定済み |
| Identifiers → App Groups | `group.com.yowamushi-inc.RideIntercom.CallWidgets` | AppとWidgetの両IDへ割り当てる。macOSでも`group.`形式は使用できるが、そのgroupを含むprofileが必要 |
| Profiles | 上記のApp/Widget/Watch IDと実際の配布先 | capability変更後に再生成／ダウンロードし、XcodeのSigning & Capabilitiesで正しいteamとprofileを選択。自動管理の場合も取得結果を検証 |
| Keys → Apple Push Notifications service | 通知provider用のkey | key ID・team ID・private keyをserver側へ設定。private keyはWorker secretへ置き、App・Git・ログへ置かない |

2026-10-31の読取監査では、既存profileファイル6件のうち現App IDに一致する4件（iOS用3、macOS用1）は期限内だったが、いずれもSign in with Appleと今回のApp Groupを含まなかった。Widget/Watchの上記IDに一致するprofileはローカル一覧に見つからなかった。これは**インストール済みprofileの不足**であり、Developer portalに登録がないと断定しない。portalは未照会である。Apple Development／Apple Distribution／Developer ID Applicationのidentityは読取で確認できたが、鍵のunlock、Apple ID再認証、profile取得・署名は実行していない。

## APNs環境を一つの設定から渡す

| 項目 | 値・契約 |
|---|---|
| Build Setting | `RIDEINTERCOM_APNS_ENVIRONMENT`。Debugは`development`、Releaseは`production` |
| App Info | `RideIntercomAPNsEnvironment`へ同じ変数を展開 |
| iOS entitlement | `RideIntercom/RideIntercom.entitlements`の`aps-environment`へ同じ変数を展開 |
| macOS entitlement | `RideIntercom/RideIntercom-macOS.entitlements`の`com.apple.developer.aps-environment`へ同じ変数を展開。SDK条件でファイルを切り替える |
| 登録先 | AppはInfoの`development`をserverの`sandbox`、`production`を`production`へ対応付ける |
| 通常Archive | schemeのRelease／productionを使用。Export後の実entitlementも確認する。profileやexportによる再署名がInfoと違う環境に変わったartifactは配布しない |
| Releaseの開発署名試用 | development profileで試用する場合は、単一Build Settingを`development`へ明示上書きし、App Infoと署名を一緒に合わせる。公開Archiveと混同しない |

APNsの実行に必要なserver設定は`NOTIFICATIONS_ENABLED`、`APNS_TOPIC`、`APNS_ENVIRONMENT`。secretは`APNS_PRIVATE_KEY`、`APNS_KEY_ID`、`APNS_TEAM_ID`、既存の`DEVICE_IDENTITY_SIGNING_KEY`である。topicはWidget/WatchではなくAppの`com.yowamushi-inc.RideIntercom.RideIntercom`とする。[通知server仕様](../spec/server/通知.md)に従い、main/previewの既定`NOTIFICATIONS_ENABLED=false`と空topicをこの監査では変更しない。環境別のWorker設定、通知用binding/migration、App側登録・取消が揃った後、明示された実サービス受入で確認する。通知の有効化で音声サービス・購入商品を同時に有効化しない。

## 商品と配布の残設定

[利用権仕様](../spec/App/利用権仕様.md)に従い、App Store Connect → 対象App → In-App Purchasesで個人用の1週間非更新型商品、Subscriptionsで月額自動更新商品と購読groupを設定する。月額のFamily Sharingは商品側で有効にする方針で、週券は対象外。商品ID・価格・試用日数・地域・契約／税務／銀行情報・審査用説明の設定と受入を完了し、販売開始の明示許可があるまで公開catalogへIDを入れない。今回の商品設定・販売開始は未実施であり、未設定を購入済みに見せない。

App Privacy、プライバシーポリシーURL、年齢区分、審査連絡先、配布地域、TestFlightの配布先もApp Store Connect側の設定である。端末内の名前・group情報、serverが保持するアカウント／端末識別子・通知先・通知grant、短時間の通話中継、診断の実運用を確認して回答する。既存PrivacyInfo.xcprivacyのRequired Reason API宣言や、ローカル設定試験を「収集なし」の証拠にしない。

## 生成物での確認

`python3 scripts/check_platform_configuration.py`は、OS別entitlement、App Group、APNs環境の接続、日英権限説明、Watchアイコン、埋込product、近距離設定を読み取り検査する。通常のCheck Development Setupからも実行する。portalやOS許可は変更しない。

Xcodeで通常のRelease Archiveを生成し、Organizerから実際の配布先へexportした**最終artifact**を確認する。iOSは展開したPayload内、macOSは.app内のInfo.plistを使用する。

```sh
codesign --verify --deep --strict /path/to/RideIntercom.app
codesign -d --entitlements :- /path/to/RideIntercom.app
codesign -d --entitlements :- /path/to/RideIntercom.app/PlugIns/RideIntercomWidgets.appex
plutil -extract RideIntercomAPNsEnvironment raw /path/to/RideIntercom.app/Info.plist
```

macOSではWidgetが`Contents/PlugIns`、Infoが`Contents/Info.plist`にある。AppとWidgetのentitlementに同じApp Groupがあり、AppだけにAppleログイン・APNs・音声権限があること、APNsのdevelopment/productionがApp Infoと対応することを確かめる。WatchはiOS Appの`Watch/RideIntercomWatch.app`に埋め込まれ、App・Widget・Watchの`CFBundleVersion`が一致し、Watchの`Assets.car`と`CFBundleIcons`にAppIconがあることを確認する。macOS AppにはWatchを埋め込まない。raw profile、証明書、device token、鍵を検証記録へ貼らない。

profile更新後の端末受入は、Appleログイン、OSのマイク／ローカルネットワーク／通知許可、App Group候補表示、削除・サインアウト後の古いWidget操作拒否、実APNs受信と取消、Watch操作、ロック中継続の順で個別に記録する。Mac nativeの任意MenuBarExtraは後続のApp工程で[実装](../spec/App/システム表示と通話操作.md#macメニューバー)した。実メニュー・VoiceOverの受入は別に記録する。

根拠：Appleの[ローカルネットワーク](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)、[Mac App Group](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)、[APNs登録](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)、[APNs環境](https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment)、[アイコンasset](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)。

## MacのSDKプライバシーリソース

管理WebRTC artifactの二重配置は[独立artifact工程](../validation/history/WebRTCマニフェスト配置の修正.md)で修正した。App buildでも標準の`WebRTC.framework/Resources/PrivacyInfo.xcprivacy`への同梱と元のmanifest内容を確認済み。更新時は[WebRTC組み立て・検証手順](BuildWebRTC/WebRTCビルドスクリプト.md#sdkプライバシーマニフェストの配置)を適用し、配布前には署名済み最終artifactとArchiveのprivacy reportを別に受け入れる。
