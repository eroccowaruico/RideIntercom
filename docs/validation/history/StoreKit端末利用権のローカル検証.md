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
