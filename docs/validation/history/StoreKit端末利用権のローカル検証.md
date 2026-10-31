# StoreKit端末利用権のローカル検証

2026-10-31、`3a5b0b4ebbd65ff92df9287b7d08e9d07fdc82d8`から隔離したworktreeのApp追加差分を検証した。現行契約は[利用権仕様](../../spec/App/利用権仕様.md)、再実行は`python3 scripts/validate_storekit.py --output .validation/storekit-日時`を参照する。公開商品は未設定であり、販売・実App Storeアカウント・実課金・実Cloudflareの受入結果ではない。

| 対象 | 条件と結果 |
|---|---|
| 最終実行 | `.validation/storekit-verified-final`。macOSの標準Apple Development Debug署名、App Sandbox無効、専用DerivedData。実マイク・スピーカー・UI操作・Macのロック操作なし |
| テスト数 | 13件成功、失敗・skip・runtime warningなし。実StoreKit 3件、fixture/pure unit 10件 |
| 週券の実取引 | 非更新型、過去購入日、7日期限、複数購入、後続券の返金でも先行有効券を保持、手動syncで期限不変、実updatesの返金反映 |
| 月額の実取引 | autoRenewableの署名済み期限と一致。現在の購入と、過去90日・更新なしの署名済み失効購入を区別 |
| 月額の実猶予 | ローカルの支払失敗・10秒更新を使用し、検証済みRenewalInfoの猶予期限と一致。有効期限直前とちょうどの判定を確認。試験環境ではTransaction.expirationDateも猶予期限まで延長されたため、両者に必ず差があるとは仮定しない |
| unitの主な範囲 | 週券の購入瞬間・7日境界、猶予・返金・upgrade・billing retry、未検証と購入なしの区別、独立した有効券、未設定時の無通信、復元失敗、更新のまとめ直し、アカウント退役・再取得 |
| 入力整合 | source-before/afterでソース・fixture・設定が一致。projectの自動build連番の増加だけを許容し、raw hashも保持 |
| cleanup | 専用DerivedData内の所有testhostを終了。cleanup・xcresult読取・非empty/no-skip受入・入力不変の全stage成功 |

## 環境差と残る受入

| 対象 | 確認した制約・未確認 |
|---|---|
| macOSの署名 | unsignedではStoreKitの購入操作がnotEntitled、ad-hoc署名ではinvalidDeviceVerificationとなった。検証を迂回せず、標準Debug署名で成功した |
| 既存iOS Simulator | lease排他の下で専用端末を再利用し、unit 10件は成功。実StoreKit 2件はnotEntitledで失敗した。成功へ読み替えず、実StoreKitの受入根拠は後続のmacOS成功とした。Simulatorはfinallyでshutdownし、他端末を操作・新規作成していない |
| StoreKitの強制失効API | この環境のexpireSubscription直後の取引に旧状態が残ったため、失効取引の確認は公式の過去日付購入・更新なしを使った。強制失効APIの反映確認は成功としていない |
| Appleの販売環境 | 実商品登録、価格、月額Family Sharing、標準無料トライアル、Apple sandbox・TestFlight、実家族アカウント間の共有/取消、購入開始と提供後のfinishは別途確認する |
| 通話への適用 | 本検証の対象はStoreKitの読取・期限・復元・更新・ログイン寿命。グループ作成・招待・開始への制限を提供済みとはしていない |

StoreKitTestをimportするとSDK内部の旧型参照に関するdeprecated警告が初回module生成時に出た。App追加ソースのコンパイル警告ではなく、標準unitではこのimportを行わない。最終結果のruntime warningは0件。初期失敗のxcresultは隔離DerivedDataと`.validation/storekit-local-ios`、`.validation/storekit-local-final`へ保全した。

## 追加レビューによる複数購読と待機状態の確認

同日、本人購入とFamily Sharingの複数購読を単一latestで選んでいた箇所、およびstop直後のstartが旧読取待ちに阻まれる箇所を修正した。上記13件の当初証跡は保持し、追加回帰を含む後続実行を別に記録する。

| 対象 | 条件と結果 |
|---|---|
| 最終追加実行 | `.validation/storekit-review-final`。18件成功（unit 15件、実StoreKit 3件）、失敗・skip・runtime warningなし。test・所有host cleanup・xcresult受入・source/fixture/config不変の全stage成功 |
| 複数購読 | 公式group statuses配列の全件を評価。unitで本人の有効購読と新しいfamilyShared取消の両方を残し、同一系列の過去更新だけをまとめることを確認。実家族アカウント間の共有試験は別の受入のまま |
| 待機と再開始 | 非協調の旧読取が残る間もstop直後に再取得でき、遅れて完了した空結果で新snapshotを上書きしないことを確認 |
| 初回の権利 | 購読状態照会が未完了でも、端末内で検証済みの購入・期限を先に利用できる。再照会の途中で既知の検証済み猶予を失わないことを確認 |
| read期限 | テスト用30msで非協調readの待機を解除し、既知期限内の権利を保持して、期限後に取得不能へ戻り手動再取得できることを確認。本番read/status期限は15秒で、TaskGroupの終了待ちを用いない |
| 標準認証シート | AppStore.syncにはread期限を適用しない。テスト用read期限20msを超える60msの認証待機でも失敗へ変えず、入力完了後にreadできることを確認 |
| DerivedData再利用 | 既定を`/private/tmp/RideIntercom-StoreKit`に固定。既定path・明示pathの両方で既存exclusive_runのlock競合時に実行を拒否し、出力作成・build・cleanupを開始しないことを確認（`lock-probe.json`） |

Appleの[StoreKit 2紹介](https://developer.apple.com/videos/play/wwdc2021/10114/)で、同じ商品に本人購入とFamily Sharingの複数状態があり得ること、および配列を評価する必要を確認した。独自の購入台帳、端末間ロック、定期サーバー照会は追加していない。

## 配布由来の表示と再確認の接続

同日、一般向けUIを統合した`4a4e97b6882111f6501cf1c16421dd08f104f20f`へ配布作業worktreeをfast-forwardし、配布差分と自動build番号を含む未コミット6ファイルのSHA一致を確認してからStoreAccessSectionを接続した。

| 対象 | 条件と結果 |
|---|---|
| 専用回帰 | `.validation/distribution-ui-final`。29件成功（配布11件、既存unit 15件、実StoreKit 3件）。失敗・skip・runtime warningなし。test・所有host cleanup・summary・acceptance・source/fixture/config不変の全stage成功 |
| UI関連unit | 配布状態、購入状態、StandardPresentation、StandardMessageLocalizationの28件成功。画面の新しいfixtureやUI専用の状態層は追加していない |
| 表示 | originがtestDistributionの場合だけ「テスト配布で利用可能」とし、利用権の見出しへ変更。購入由来の期限・設定済み商品の購入復元は保持 |
| 再確認 | 判定不能からrefreshだけで再取得し、商品未設定でも購入read・sync・updates観測を増やさず利用可能へ戻ることをunitで確認。実行中は既存handleからbusyを導出 |
| 製品版・購入なし | 商品設定済みでverified productionかつ購入取引なしの場合はnotPurchased。unknownを経てproductionへ戻っても購入者相当にならないことをunitで確認 |
| 日本語 | 新しい6キーが実App bundleへ含まれること、既存の全翻訳値を保持することを確認（`localization.json`）。画面専用fixtureは追加していない |
| 残る受入 | 実TestFlight・App Store版、実機・圏外・配布切替は未確認。注入した配布状態のunit成功を、実配布環境の識別成功とは扱わない |

同時refresh/restoreは既存処理へまとめる契約を仕様へ記録した。新しいqueue・lock・サーバー台帳は追加していない。標準の再実行scriptへ配布unitを対象追加した1行はroot側の変更と一致させ、配布patchからは除外した。


## 標準購入入口と提供後の取引完了

同日、`71527487062db6c207fa59e70e41cad1c3f6d54d`から隔離した`RideIntercom-purchase-flow`で、StoreKit標準購入画面と現在ログイン世代への採用後のfinishを追加した。公開商品・価格は未設定のままで、実Appleアカウント・実購入・Cloudflareへ接続していない。

| 対象 | 条件と結果 |
|---|---|
| 専用回帰 | `.validation/purchase-flow-verified`。39件成功（既存29件、新しいpurchase unit 3件、実StoreKit 7件）。失敗・skip・runtime warningなし。test・所有host cleanup・summary・acceptance・source/fixture/config不変の全stage成功 |
| 標準画面 | StoreView(products:)、storeProductsTask、onInAppPurchaseCompletionを現SDKでコンパイル。取得した全IDと商品の種別を確認してから表示し、StoreViewの重複する復元ボタンは非表示。実画面を操作した受入結果ではない |
| 実購入API | SKTestSessionのローカル設定とdisableDialogsで実Product.purchaseを呼び、検証済み履歴の再取得後に権利を反映。成功通知だけを残して履歴を消した場合は購入済みにならないことを確認 |
| 取消・承認待ち | 公式のpurchase APIへの取消エラーとAsk to Buyを使用。取消・承認待ちだけでは権利を与えず、承認後の実updatesで権利反映とfinishを確認 |
| 提供順と範囲 | 受領を拒否したsource読取は未完了を維持。現在世代のAccessが署名済みsnapshotを受領後にfinishし、別商品の未完了取引、種別不一致、未検証completionはfinishしない |
| 再取得と旧ユーザー | 古いアカウントのcompletionは権利を付けず未完了を維持。新モデルのstartと明示restoreで未完了を回収。プロセス自体の強制終了・再起動ではなくモデルの作り直しを試験した |
| 月額の過去更新 | ローカルのforceRenewalで複数の未完了更新を作成。表示は最新期間だけでも、履歴全verified IDとの照合で過去更新もfinishすることを確認 |
| 状態照会の待機 | 月額statusをgateで止め、期限前に採用した週券をfinishし、同じ実Product.purchaseから次の週券を買えることを確認。timeout後に新しく届いたrenewalと、stop後の新renewalは古い読取でfinishされない |
| 試験上の補正 | SKTestSessionの設定を各testでresetToDefaultStateしてAsk to Buy等を分離。forceRenewalの非同期反映をbounded待機で確認。意図的にdeliveryを遅らせる試験にも非deliveryのupdates観測を先に設置し、StoreKitのobserverなしruntime warningを解消。先行失敗のxcresultは保持 |
| 残る受入 | 実StoreViewでの商品表示から購入成功・認証シート・VoiceOver、実商品設定・価格・販売開始、実Apple sandbox/TestFlight・家族共有の実アカウント連携は未確認。ローカルの実Product.purchase成功をこれらの受入へ読み替えない |


### iOSの購入入口と取得不能からの復旧

| 対象 | 条件と結果 |
|---|---|
| 共通UIのビルド | `.validation/purchase-ios-build`のgeneric iOS Simulator build成功。Simulator起動なしで実行し、入力不変を確認 |
| UI受入 | `.validation/purchase-ui-recovery`。専用StoreKit UI schemeの1件成功、失敗・skip・runtime warningなし。既存の専用Simulatorをshared run.lockとSimulatorLeaseで再利用し、終了時にshutdown。新規作成・他のSimulator操作なし |
| 実操作 | SettingsからView Purchasesへ進み、取得不能の表示、Try Againによる再取得、Doneで設定へ戻る操作、購入とRestoreの両ボタンが再びenabledかつhittableであることを確認。スクリーンショット2枚をxcresultへ保持。15秒の期限到達自体のUI実測ではなく、初回読取後の再操作を確認した |
| 発見したUI差分 | Section全体のaccessibility containerが行ボタンの親frameをラベル幅にして操作できなかった。識別子をAccess見出しへ置き、sheetを購入ボタンへ付けてnativeな行のhit testingを維持するよう修正 |
| 失敗実験 | 成功購入を試みる専用試験のSKTestSession操作でSKInternalErrorDomain Code=3（設定保存・override・disableDialogs・clearTransactions）が発生。`.validation/purchase-ui-red`、`purchase-ui-green`、`purchase-ui-products`のxcresultと成功試験の実験ソースを保全。成功へ読み替えず、通常suiteへ失敗試験を含めない |
| 環境差の根拠 | [Apple DTSの既知問題の説明](https://developer.apple.com/forums/thread/826971)にCLIからのStoreKit設定同期と同じCode=3の報告がある。ただし当該説明は異なるOS版の履歴であり、今回の原因を同一バグと断定しない。標準のSimulator署名で再現し、StoreKit内部ファイルや署名の迂回は行っていない |
| 独立した未確認ゲート | 有効なfixture商品を標準StoreViewへ表示し、購入ボタンから購入して利用可能・期限まで到達するiOS UIの成功は未確認。macOSの実Product.purchase成功と、取得不能を使ったUI復旧成功から代用しない |
