# 検証状況と証跡

## 本人名と端末内の呼び名を分離（2026-10-31）

本人名をSettingsから保存し、署名付き招待と認証済みgroupの暗号化application dataで共有する。受取側は本人名を保持したまま呼び名を編集し、Use Shared Nameで最新の本人名へ戻せる。保存ユーザーは一覧と所属groupで共通、直接招待関係のない相手は対象group内だけに保持する。名前編集で通話を切ったり、ID・鍵・ユーザー登録・通知権限を変えたりしない。契約は[名前の仕様](../spec/App/通信仕様.md#本人名と端末内の呼び名)、操作は[使い方](../manual/使い方.md#グループを作る参加する)を参照する。

証跡は`.validation/display-names-delivery/`に保持する。

| 検証 | 結果と証跡 |
|---|---|
| iOS App・UI | 最終コードでApp198件と名前編集・復元、保存ユーザー再利用、個別通話のUI3件、計201件成功。失敗・skip・runtime warningなし。`names-ios-verified/ios-tests.xcresult` |
| 画面 | `names-ui-view/`で本人名と端末内呼び名の同時表示、Use Shared Nameを目視確認。UI操作で変更・復元・再起動後の本人名保持を確認 |
| macOS App | 製品・App testの最終コードで198件成功、失敗・skip・runtime warningなし。`names-macos-final/macos-tests.xcresult`。隔離hostのみsandbox無効、通常署名・実画面は別受入 |
| 名前の境界 | 新規6件で本人名保存・ID維持、通話中の更新、再起動、別名維持と最新本人名への復元、group内限定、未認証・別group・不正名の拒否、署名付き招待・改ざん拒否、保存失敗時の元bytes保持を確認 |
| ソースと資源 | 最終iOS検証中のApp・test 116 Swiftファイルのhash一致を確認。Mac検証後の変更はUIテストの要素選択だけで、製品・unit testソースは同一。管理Simulatorを再利用してShutdownし、所有Mac hostの終了を確認 |
| 保存復旧fixture | schema 4へ追従した検証補助の5件成功。`names-recovery-fixture.log`。本実行では復旧画面UIの再実行は含めない |
| 文書 | リンク・Settings網羅・差分検査が成功。`names-documentation.log` |

未実装による赤テスト、追加した招待versionに対する旧期待値の失敗、UIのラベル集約と複数ユーザー時の対象選択による失敗も保持する。UIは元の名前が存在することと対象IDを検証する形へ修正し、最終201件で確認した。

保存形式はschema 4、Appが発行する招待は本人名を含むversion 3へ更新した。旧版へ戻す場合にこれらの新形式を開けるとは扱わない。新しいサーバー保存は追加せず、packageとserverコードは変更していない。実端末、実Apple認証、実Cloudflare、独立音声E2Eの再測定は今回の対象外。AppIntents未使用のmetadata抽出省略warningは既存のまま。全体`all --clean`の完了記録ではない。

## Apple認証とInternet端末資格のApp連携（2026-10-30）

Settingsからserver nonce取得、同じAppleユーザーのnative認証、端末資格のKeychain保存まで接続した。サインアウト時は通話を止め、古い資格を端末側で使用禁止にしてからserver失効を試みる。通信・Keychain失敗時は資格を復元せず、次にInternet設定を開いた際に失効を再試行する。保存失敗やキャンセル後に届いた不要な資格も失効を試みる。現在の契約は[App通信仕様](../spec/App/通信仕様.md#appleログインと端末内データ)、操作は[設定と音声効果](../manual/設定と音声効果.md)を参照する。

証跡は`.validation/apple-app-delivery/`に保持する。実Apple認証と公開登録の受入は[未確認事項](未確認事項.md#appleログインの実受入)へ分ける。Production/Previewの新規登録は引き続き無効が既定であり、このApp接続を配置済み公開サービスの完成とは扱わない。

| 検証 | 結果と証跡 |
|---|---|
| iOS App・UI | 最終コードでApp 192件＋設定・サインアウトUI 2件、計194件成功。失敗・skip・runtime warningなし。`apple-app-ios-verified/ios-tests.xcresult` |
| macOS App | 最終コードで192件成功。失敗・skip・runtime warningなし。`apple-app-macos-verified/macos-tests.xcresult`。隔離hostのみsandboxを無効化し、製品設定は変更していない |
| 認証・保存境界 | 新規8件でserver nonce、scopeなし、アカウント違い・再送・不正URLの拒否、保存失敗・中断後の発行資格失効、Keychain読出／削除失敗後の復元拒否、古い失効による新資格削除の防止を確認 |
| 音声検証の独立性 | 一部Appテストが実機I/Oを初期化してSimulatorのAudio Unit RPC timeoutで停止した。既存の`OfflineAudioDriver`を注入し、nativeエフェクト・PCM処理・UI占有中の送受信などの検証条件を保持したまま全件成功。App製品コード・packageの音声動作は変更していない |
| Release | Simulator向けRelease build成功。Info.plistに開発資格がなく、実行binaryに認証fixtureの選択文字列・識別子がないことを確認。`apple-app-release-isolation.json`。公開version設定は変更していない |
| UI目視 | `apple-app-ui-view/`の設定エラー画面で、説明と操作が切れず表示されることを確認。これはnative Apple認証成功画面の証拠ではない |
| ソース・資源 | 最終検証中のApp・テストのhash一致を確認。管理Simulatorを再利用してShutdown、所有Mac host終了を確認。projectの自動採番差分は機能差分から分離 |

未実装APIによる赤テスト、途中のcompile失敗、音声I/OのRPC timeoutと調査のため中断した再実行も保持する。音声fixture修正前に成功したMac 192件と、修正後の最終192件は別記録。Swiftソースの新規warningはなく、AppIntents未使用のmetadata抽出省略warningは残る。独立音声E2E・実機・Bluetooth・実Cloudflare・Apple実認証は今回再実行していない。リポジトリ全体の`all --clean`受入ではない。

## Apple認証serverと端末資格（2026-10-30）

使い捨てnonce、Apple署名・issuer・audience・期限の照合、ユーザーと端末の対応、端末資格の発行・置換・自己失効をWorkerへ実装した。公開登録はProduction/Previewとも無効を既定とする。契約と公開運用の残件は[Worker仕様](../spec/server/Worker.md#apple認証と端末資格)へ記載した。

| 検証 | 結果と証跡 |
|---|---|
| Worker全体 | 既存22件＋認証9件、計31件成功、失敗・skip・todoなし。`.validation/apple-backend-delivery/worker-final.log` |
| 認証境界 | 不正署名・issuer・audience・nonce・期限・未来iat、同時再送、別ユーザー、再認証での端末資格置換、他端末を巻き込まない失効を確認。session所有者照合を追加した最終の認証9件も`account-final.log`で成功 |
| 期限と保存 | 永続SQLiteを再利用するserver再起動とテスト側の時刻変更で、5分のnonceと30日の端末資格が復活しないことを確認。SQLite/WALに端末IDが存在し、Apple token・メール・生subject・端末秘密が存在しないことを確認 |
| 上限と停止 | 8端末登録上限でも既存端末は再認証可能。通話サービス停止中でも自己資格を失効可能。WebRTCの同時端末数の検証ではない |
| 通信契約 | 実Swift HTTP/WSとローカルWorker/DOの1件成功。`pair-final.log`。SFUはfixture |
| 型と構成 | Wrangler生成binding、TypeScript型検査、文書検査、差分検査が成功。`typecheck-final.log`。`source-manifest.json`で対象を記録 |

未実装のAPIを失敗テストで再現後に実装した。途中のKV iterableの扱いと、DO名のmetadataへApple生IDが残る問題も失敗記録に保持し、後者はハッシュ化して解消した。通常テストはApple鍵もローカルfixtureで、実Apple認証・実Cloudflare配置・運用上の削除を証明しない。今回App・RTCの実装変更は含まない。

## 通話サーバーの表示名保存を除去（2026-10-30）

RTCのjoinとWorkerの永続member・peer一覧から表示名を除去した。既存のグループ鍵による暗号化presenceで名前を交換し、端末のグループ内表示に使う。新規開発のため旧client用の互換フィールド・データ移行は追加していない。契約は[Worker仕様](../spec/server/Worker.md#表示名を保存しない境界)を参照する。

証跡は`.validation/signaling-privacy-delivery/`に保持する。

| 検証 | 結果と証跡 |
|---|---|
| RTC package | RTC 81件・native WebRTC 4件が成功。失敗・skipなし。`rtc-tests.log`。Workerとの契約1件は下記で別実行 |
| Worker | 22件成功、失敗・skip・todoなし。`worker-tests.log`。名前なしjoin、余分な表示名の非保存・非配信、認可・人数・期限・TURN・回収を確認 |
| 永続状態 | 最終の検査方法で2件を再実行して成功。`worker-privacy-final.log`。隔離したSQLiteとWALの両方を読み、実際のparticipant IDが保存され、表示名fieldとテスト用の名前が含まれないことを確認 |
| Swift–Worker契約 | HTTP/WS・workerd・SQLite DOを通す1件が成功。`worker-pair.log`。peer一覧はIDのみ、暗号化presenceから表示名を復元、双方向メッセージ、lease更新、離脱・再参加を確認。外部SFUはfixture |
| 静的確認 | TypeScript型検査、文書リンク検査、差分の空白検査が成功。`worker-typecheck.log`、`documentation.log` |
| 対象の一致 | `source-manifest.json`で今回変更した実装・テスト・文書を記録し、main統合後のhash一致を確認 |

修正前に、Swiftのjoinが表示名を送ること、Workerが名前なしjoinを拒否し、永続memberに表示名を残すことを失敗テストで確認した（`rtc-red.log`、`worker-red-storage.log`）。最初のstorage inspectionは既存DOのRPC未対応により使えず、隔離SQLiteの直接検査へ変更した経緯も`worker-red.log`へ残す。最終検査はSQLite/WALのbytesを読み、新しいNode専用SQLite APIへの依存を追加していない。

実Cloudflareへの手動デプロイ、providerの過去データ・backup削除、実端末・音声E2Eの再測定はこの工程には含まない。Appleログイン側の検証と残件は次節を参照する。

## Appleログイン必須化とアカウント別保存（2026-10-30）

全通話のAppleログイン、Keychainでの識別子保持、保存ログインによる圏外利用、取消・サインアウトによる通話停止を実装した。メール・本名を要求せず、アカウントごとにグループ・保存ユーザー・鍵・設定・端末IDを分離する。複数windowはApp所有のアカウントと通話モデルを共有する。新規開発のため既存ユーザーの移行処理は追加しない。現行契約は[通信仕様](../spec/App/通信仕様.md#appleログインと端末内データ)。

| 検証 | 結果と証跡 |
|---|---|
| iOS App・関連UI | 最終コードでApp 184件、個別通話・サインアウト・起動UI 3件、計187件成功、失敗・skipなし。`.validation/account-delivery/account-ios-shared-final/ios-tests.xcresult` |
| iOSの全画面操作 | window間の状態共有を追加する前の同じ画面構成でUI 8件成功。`.validation/account-delivery/account-ios-final/test-tree.json`。この実行にはApp音声のRPC timeout失敗が含まれるため総合成功とは扱わず、Appは上記最終187件で再確認した |
| 保存データ復旧 | 最終コードのUI 1件と、元の破損bytesの退避・空manifestの確認が成功。`account-ios-shared-final/ios-recovery.xcresult`、`recovery-verify.log`。復旧対象を検証アカウントの保存先へ追従 |
| macOS App | 最終コードで184件成功、失敗・skipなし。`account-macos-shared-final/macos-tests.xcresult`。今回の隔離hostだけsandboxを無効にして実行し、製品設定は変更していない。通常sandboxの起動は未確認 |
| 認証境界 | scopeなし・state照合・再送拒否・中断・取消・保存失敗・読出失敗時の保持・古い非同期結果の排除・削除失敗後の圏外復元拒否・削除再試行・未ログイン／別アカウントの接続拒否・通話停止を確認 |
| Releaseと音声E2E | ReleaseのSimulator buildが成功し、認証fixture選択文字列・fixture識別子・開発用接続情報の不在を確認。音声E2E targetはMac/iOS双方のcompile成功。今回は独立音声E2Eの測定を再実行していない |
| スクリプト・文書 | 復旧fixture 5件、validation runner 11件が成功。文書参照・Settings網羅・空白検査が成功 |
| 画面 | `apple-sign-in.png`にサインアウト後の画面を保存。標準Appleボタン、目的・プライバシー・圏外利用の説明を目視確認。実機VoiceOver・iPad複数windowの実操作は後続 |
| ソース・資源 | 最終検証中のApp・テスト220 Swiftファイルのhash一致を保存。検証後の変更は末尾の空行1行の削除のみで、`account-final-formatting.json`に差分を記録。管理Simulatorを再利用しShutdown、所有Mac host終了を確認。全体入口の`unchanged-inputs`は通常buildの採番で失敗し、projectの差分はビルド番号だけと別途比較した |

最初の認証テストは未実装による失敗を確認してから実装した。途中の署名不足、Mac sandbox初期化待ち、画面分割・UI要素選択の失敗、Simulator音声RPC timeoutも証跡に残す。認証テストでは不要なネイティブ音声分離をOFFにし、音声の確認は専用テストに分けた後、上記App全体検証が成功した。原因をすべて認証コードに帰属させるものではない。

Apple実ログイン用profileの自動更新は、Xcodeのアカウント資格を読めず失敗した。端末の実認証、通常署名・Mac sandbox、Bluetooth・実無線は[未確認事項](未確認事項.md#appleログインの実受入)へ残した。サーバーでのApple identity検証・ユーザー／端末登録・アカウント削除・通知・課金の完了を示す記録ではない。

## 保存ユーザーを指定する個別通話（2026-10-30）

依存順の共通設計に残っていた、保存ユーザー指定からの1対1内部groupの解決・再利用をAppへ実装した。Usersから相手名を選択し、初回は相手宛ての招待を共有する。同じ二人の再選択ではIDと鍵を再利用し、別通話の閲覧では既存接続を切り替えない。直接招待関係のない参加者を対象へ昇格させず、宛先違いの招待・参加者追加・通常groupへの読み替えを拒否する。契約は[個別通話の仕様](../spec/App/通信仕様.md#保存ユーザーを指定する個別通話)、操作は[使い方](../manual/使い方.md#保存した相手と個別に話す)を参照する。

| 検証 | 結果と証跡 |
|---|---|
| 個別通話の回帰 | 11件成功。二人の通話先・鍵の一致、順序によらない再利用、同時招待、宛先違い、削除、改ざん、保存失敗、schema移行、想定外参加者を検証。`.validation/direct-calls-delivery/direct-green-2/macos-tests.xcresult` |
| macOS App全体 | 最終コードで170件成功。失敗・skip・runtime warningなし。`.validation/direct-calls-delivery/direct-macos-final/macos-tests.xcresult` |
| iOS App・UI全体 | App 170件とUI・起動7件、計177件成功。`.validation/direct-calls-delivery/direct-ios-verified/ios-tests.xcresult` |
| iOS破損復旧 | 専用UI 1件と、元bytes退避・schema 3の空manifestを確認するホスト処理が成功。同directoryの`ios-recovery.xcresult`と`recovery-verify.log` |
| 最終UI確認 | 目視で削除後も共有案内が残る点を修正し、該当UI 1件を再実行して成功。選択、明示切替、再起動、ユーザー削除後のCurrent Callと終了、共有ボタン非表示、削除後の説明を確認。`.validation/direct-calls-delivery/direct-ui-final/ios-tests.xcresult`。上記macOS全体もこの最終修正を含む |
| 画面証跡 | `individual-call.png`、`users-and-groups.png`、`user-removed-call-retained.png`を`.validation/direct-calls-delivery`へ保存し、説明文と操作が一致することを目視した |
| 保存・文書 | Python保存復旧fixture 5件、文書の参照・到達性・Settings網羅・空directory検査、差分の空白検査が成功 |
| ソースと資源 | 最終App・テスト・fixture 20ファイルが検証コピーと一致し、`code-source-sha256.json`へ保存。Simulatorを追加せず、別作業の利用終了後に既存の管理端末を再利用し、各回のShutdownと所有Mac hostの終了を確認 |

全体iOSコマンドの`unchanged-inputs`は、通常Build/Test時の自動採番で失敗した。`build-number-comparison.json`では変更がprojectの番号15→16だけであることを元のhashと照合済み。テストの成功と、総合コマンドの非ゼロ終了を区別する。未実装APIでのred、検証中の構文修正、共有Simulator待機に至った最初のblocked結果も保存している。

保存形式はschema 3へ移行し、旧版はこの形式を開かない。旧group・users・鍵の保持と移行失敗時の非破壊性は自動検証済み。個別招待のversion 2も対応版同士で使う。初回共有を省く呼出し通知、Appleログイン・複数端末の本人確認、StoreKit・24時間の利用権判定は未実装であり、今回の完了には含めない。実機2台の実音声、実Cloudflare、macOSの実画面操作も今回の検証対象外。

## 直接招待したユーザーの保存・再利用・削除（2026-10-30）

グループから独立した端末内ユーザー保存、schema 2への移行、直接招待の受取確認、標準SwiftUIによる一覧・表示名編集・グループ再利用・一覧削除をAppへ実装した。同席しただけの参加者はグループ情報に残すが、ユーザー一覧には登録しない。一覧削除後も所属と通話を維持し、受取確認の再送で復活させない。package・Workerは変更していない。

| 検証 | 結果と証跡 |
|---|---|
| macOS App全体 | 最終コードで159件成功、失敗・skipなし。`.validation/users-delivery/users-macos-regression-final/macos-tests.xcresult` |
| iOS App・UI全体 | App 158件とUI 6件、計164件成功。招待受取、グループ削除、再起動、表示名編集、新規／既存グループへの再利用、一覧削除後の参加者維持、再起動後も一覧に戻らないことを画面操作で確認。`.validation/users-delivery/users-ios-final-verified/ios-tests.xcresult` |
| iOS破損復旧 | 専用UI 1件とホスト側の元bytes退避・空manifest確認が成功。同じ出力directoryの`ios-recovery.xcresult`と`recovery-verify.log` |
| 最終追加回帰 | 全体iOS検証後に、破損reset後も招待者を保存する修正と、別参加者の応答で未完了の招待を消さない照合を追加。iOSのUserDirectoryTests 14件成功。`.validation/users-delivery/users-ios-regression-final/ios-tests.xcresult`。この変更を上記macOS 159件にも含めた |
| scripts・文書 | 保存復旧fixtureのPython 5件、文書参照・到達性・空directory・Settings網羅検査、差分の空白検査が成功。検証用worktreeでもAppソースを列挙できるよう、テスト補助の相対path処理を修正 |
| 目視 | `saved-users.png`、`group-with-saved-user.png`、`user-removed.png`を`.validation/users-delivery`へ保存。ユーザー選択・説明文・追加後の参加者・削除後の空一覧を確認 |
| ソース一致 | 最終Appコード・テスト・関連文書29ファイルが検証コピーと一致。`scoped-source-sha256.json`を保存。全体検証の`unchanged-inputs`は、別作業で変更された通常Build/Test時の自動採番により失敗している。`build-number-comparison.json`でprojectのビルド番号以外の差分がないことを別途確認した。テスト成功と、この総合コマンドの非ゼロ終了を区別する |
| 資源回収 | 既存の管理Simulatorを再利用し、各実行後のShutdownと所有Mac hostの終了を確認。一般用のSimulatorや他作業のアプリは停止していない |

初回の全体iOS実行では、検証コピーのpath誤りに加え、既存音声テストのOS初期化でRPC timeoutとプロセス終了が発生した。path処理を修正し、macOS終了後のiOS単独実行では上記164件と復旧が成功した。並行実行が原因とは断定せず、失敗logとsummaryは`earlier-failures`へ保持した。

Appleログイン、課金判定、ID宛て通知、1対1の内部グループ解決は未実装。招待・追加を購入者相当に限定する条件と、グループ内だけの相手へグループ外で接触させない境界は[利用権とデータ保持の設計](../backlog/利用権とデータ保持の設計.md)へ反映した。現在の連絡先や受取確認を、将来の公開通知サービスの認可証明には使わない。実機・Bluetooth・実Cloudflare・macOSの実画面操作・購入は今回の検証対象ではない。

## AAC設定表示とSimulator資源管理（2026-10-30）

利用者の指摘は48 / 24 / 16 kHzの切替に伴うAAC候補の変化だった。対応値の変化自体は既存仕様で、segmented Pickerが項目名を画面に表示せず関係が伝わっていなかった。`Codec`・`Sample Rate`の項目名と、候補・選択値の補正理由を追加した。音声codecの実装や品質下限は変更していない。

| 確認 | 結果・境界 |
|---|---|
| iOS App・UI | `RideIntercomTests`とAAC回帰UIテスト、計146件成功、失敗・skipなし。48/24/16 kHzの候補と、PCM/OpusからAACへ戻した後の候補維持・値の選択を検証。スクリーンショットで項目名と説明を確認 |
| macOS App | 145件成功、失敗・skipなし。共通SwiftUIのビルド成功。macOSでの実画面操作は未実施 |
| scripts | 65件成功。記録消失時の再発見、一般端末の保持、起動中端末の保護、削除失敗時の作成禁止、作成前の棚卸し・記録、旧モードのhost回収を回帰試験で確認 |
| 端末の整理 | 停止済みの旧`RideIntercom Audio E2E 65438c7c`と`RideIntercom Recovery Tests`を削除。simctlが報告したdataPathSizeの合計は2,197,897,216 bytes。空き容量の実測値ではない。一般用途の端末は保持 |
| 再利用・排他 | `RideIntercom Audio E2E 844ea91b`（`7D7F5941-E066-4869-B7DD-B1E5140010A1`）を継続使用。共通lockが音声E2E実行中の別所有者を拒否。新規端末の作成なし。通常検証入口も同じprepare・journal・lockを使う |
| 音声の追加測定 | 最初のpipeline-only測定は100ms条件でmissingActiveRatio=0.0047489824となり失敗。並行ビルド終了後の隔離再測定と、旧モードhost回収の共通化後の最終測定は20ms/100ms両条件が合格。各測定中のsource hash一致、同一端末再利用、終了時のShutdown・host不在を確認。初回不合格は消さず保持し、並行負荷が原因と断定しない |
| 検証範囲 | 今回は全package・Worker・全UI suiteの再実行ではない。実iPhone、Bluetooth、実無線、VoiceOverの実操作は未確認。AppIntents未使用によるmetadata抽出省略warningは残る |
| 証跡 | UIは`/tmp/RideIntercom-AAC-green.xcresult`と`/tmp/ride-aac-green-images`、macOSは`/tmp/RideIntercom-AAC-Mac.xcresult`。棚卸し・削除は`/tmp/RideIntercom-Simulator-Reconcile`、初回音声失敗は`/tmp/RideIntercom-AAC-resource-smoke`、隔離再測定は`/tmp/RideIntercom-AAC-resource-isolated`、最終測定は`/tmp/RideIntercom-AAC-resource-final`。一時領域のため永続保存ではない |

## 結果を読む基準

| 区分 | 意味 |
|---|---|
| 実装済み | sourceと現行仕様に存在する。成功・実機確認を意味しない |
| 自動検証済み | 指定された版・条件・コマンドで成功。現行HEADでの再実行と過去記録を区別 |
| 実サービス未確認 | 実Cloudflare SFU / TURN / 請求をローカルfixtureで保証しない |
| 実機未確認 | Mac/iPhoneの音響、無線、10分、ロック、Bluetooth/有線は別途 |
| 未対応 | 必要なAPI・UI・運用がまだない。マニュアルに操作可能と書かない |

## 現在の確認と記録

[未確認事項](未確認事項.md)に確認待ちと条件、[自動検証範囲](自動検証範囲.md)にテストの担当範囲をまとめる。未実装作業は[課題](../backlog/README.md)へ分ける。

| 領域 | 記録 |
|---|---|
| 共通化と二巡の再点検 | [責務境界・探索電力・設定遷移・lifecycleの検証](history/音声境界の共通化と再点検.md) |
| 近距離・圏外通信 | [peer-to-peerの成立条件・Local優先・検証](history/近距離オフライン通信.md) |
| 無音通信・電力負荷 | [削減内容・通信量・同一性・遅延の検証](history/無音通信と電力負荷の削減.md) |
| リアルタイム会話・UDP音声 | [遅延・連続性・権限切り分けの検証](history/リアルタイム音声の遅延と連続性.md) |
| 音声の途切れ・同一性 | [修復前の再現](history/音声同一性と途切れの再現.md)、[原因・修復・再検証](history/音声の連続性修復.md) |
| iOS音声E2E・切断／無音 | [実発話・全設定・サーバーモックと修復の検証](history/iOS音声E2Eと通話障害修復.md) |
| 全体監査・ローカル基盤 | [全体敵対的レビュー・修正・残存リスク](history/全体敵対的レビュー.md)、[全ファイルの調査台帳](history/全体監査ファイル台帳.json) |
| 責務分解・保存復旧・待機制御 | [変更・検証・残存リスク](history/責務分解と保存復旧.md)、[既存テストの移動対応](history/責務分解テスト対応.json) |
| 不要コードと全回帰 | [整理・不具合修正・要求とのテスト対応](history/不要コード整理と回帰検証.md) |
| RTC / native / App / TURN | [通信診断とTURN](history/通信診断とTURN資格検証.md)、[混在通話](history/混在通話検証.md) |
| Worker / Swiftペア / 費用 | [Cloudflare](history/Cloudflare検証.md)、[品質点検](history/品質点検.md)、[費用試算](../development/Cloudflare費用試算.md) |
| 音声・UI | [音声エフェクト](history/音声エフェクト接続検証.md)、[混在通話](history/混在通話検証.md) |
| 開発環境 | [構造検査の記録](history/文書役割分離記録.md) |
| 配布・採番・Organizer | [配布ビルド採番とOrganizer認証調査](history/配布ビルド採番とOrganizer認証調査.md) |
| 文書・ログ整合 | [文書整理](文書整理記録.md)、[要求構造整理](history/要求構造整理記録.md)、[役割分離](history/文書役割分離記録.md) |

## 再実行

[自動検証](../development/自動検証.md)を入口とする。`scripts/validate.sh`は実行ごとのenvironment / logs / results.tsv / xcresultを保持し、一部の失敗を全体成功にしない。`/private/tmp`内の過去証跡は永続保存ではない。

## Xcode参照修復の確認（2026-10-21）

対象は`2b55397`上の未コミット作業ツリー。既存のproject設定・Info.plist変更を保持し、Repositoryのコンテナ判定と自己project参照を修正した。

| 確認 | 結果・境界 |
|---|---|
| 修正前の切り分け | `xcodebuild -list`で9 local packageを解決。CLIのmacOS buildも成功しており、利用者のXcode画面のエラーはCLIでは再現しなかった |
| 自己参照 | Xcode起動中に除去した自己参照が再生成された。利用者がXcodeを終了後、`explicitFileTypes`のfolder指定を保持して残った自己参照を除去 |
| 回帰 | `python3 -m unittest scripts.tests.test_development_setup`の6件成功。開発設定・文書検査も成功 |
| 最終build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project RideIntercom.xcodeproj -scheme RideIntercom -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/RideIntercom-XcodeRepair CODE_SIGNING_ALLOWED=NO`成功。ログは`/tmp/rideintercom-xcode-build-final.log`。error / warning / package読み込みエラーなし。実行前後のprojectファイルSHA-1は`ab96e3e1f1a10e977c9fe8fc77cd42d892fd6462`で一致 |
| 残る確認 | Xcode再起動後のエラー消失・自己参照非再生成・navigator表示は画面操作権限がなく未確認。署名・アプリ起動・iOS buildは今回未実行 |

### 再起動後の検査修正と推奨設定反映（同日）

上記の修復後、Xcodeは`explicitFileType = folder`の参照も`projectReferences`へ再登録した。最初の検査は種別を区別せず拒否していたため、利用者のbuildを`PhaseScriptExecution`で停止させた。folder種別は許容し、projectとして解釈される自己参照だけを拒否するよう修正した。自己参照レコードの非再生成を完了条件とした上記の判断は訂正する。

| 確認 | 結果・境界 |
|---|---|
| 再発回帰 | Xcode保存後のfolder参照と、明示種別が推定種別より優先されるケースを追加。設定検査の7件成功 |
| 推奨設定 | 利用者の画像の提案に従い、projectと3 targetのDebug・Releaseで`DEAD_CODE_STRIPPING = YES`、projectで`STRING_CATALOG_GENERATE_SYMBOLS = YES`を反映。Xcode 27.1で確認し`LastUpgradeCheck = 2710`へ更新 |
| Appテストの追随 | 既存のInfo.plist編集で説明文がビルド設定から生成される構成になっていた。`appInfoPlistEnablesBackgroundAudioMode`が元ファイルの説明文を要求して失敗したため、生成済みApp bundleの値を検証するよう修正。Info.plistの既存編集は維持 |
| 最終検証 | 上記buildコマンドを`test -only-testing:RideIntercomTests`として実行し`TEST SUCCEEDED`。ログは`/tmp/rideintercom-xcode-settings-final-test.log`、xcresultは`/tmp/RideIntercom-XcodeRepair/Logs/Test/Test-RideIntercom-2026.10.21_21-57-19-+0900.xcresult`。文書検査も成功 |
| 境界 | AppIntents依存がないためmetadata抽出を省略するXcode toolのwarningは残る。Xcode画面の推奨通知の消失・iOS build・署名は未確認 |

## iOS配布のiCloud署名修復（2026-10-21）

対象は`50243f5`上の作業ツリー。利用者によるproject形式・対応platform等の変更を保持して検証した。

| 確認 | 結果・境界 |
|---|---|
| 元の失敗 | 利用者の22:21:49のxcdistributionlogsでApp Store Connectエラー90046を確認。iCloud環境の値が空と判定され、Productionが必要とされた。元のArchiveと配布ログには空のコンテナ一覧とCloudKit権限があった |
| 原因と修正 | App・packageのSwiftコードにCloudKit利用がなく、保存先は端末内ファイルとKeychain。未使用の`com.apple.developer.icloud-container-identifiers`と`com.apple.developer.icloud-services`をentitlementsから除去。APNs・マイク権限は保持 |
| 回帰 | `appDoesNotRequestUnusedICloudServices`が修正前に失敗し、修正後のAppテスト全体で`TEST SUCCEEDED`。ログは`/tmp/rideintercom-icloud-before-test.log`と`/tmp/rideintercom-icloud-after-test.log`。最初の個別filter実行は対象を選択できず、検証実績に含めない |
| iOS Archive | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild archive -project RideIntercom.xcodeproj -scheme RideIntercom -destination 'generic/platform=iOS' -archivePath /tmp/RideIntercom-DistributionRepair.xcarchive -derivedDataPath /tmp/RideIntercom-DistributionRepair`で`ARCHIVE SUCCEEDED`。署名済みAppにiCloud権限がないことを確認 |
| 配布書き出し | `xcodebuild -exportArchive`を`method=app-store-connect`、`destination=export`、`signingStyle=automatic`、`manageAppVersionAndBuildNumber=false`、`uploadSymbols=false`で実行し`EXPORT SUCCEEDED`。IPAは`/tmp/RideIntercom-DistributionExport/RideIntercom.ipa`。展開したAppでiCloud権限なし・APNs productionを確認し、`codesign --verify --deep --strict`成功 |
| 証跡 | Archiveログは`/tmp/rideintercom-distribution-archive.log`、exportログは`/tmp/rideintercom-distribution-export.log`。開発設定・文書・plist・差分検査成功。AppIntents未使用によるmetadata抽出省略warningは残る |
| 未確認 | App Store Connectへの再アップロード・サーバー側検証は未実行。ローカル書き出し成功はApple側の受理を保証しない。旧Archiveは変更されないため、新Archiveを使って再送する |

## iOS配布のアイコン・WebRTCシンボル修復（2026-10-21）

同じ`50243f5`上の作業ツリーで、利用者の選択に従いRideIntercomの仮アイコンを新規生成した。AppIconには画像が未登録で、WebRTCは`enable_dsyms=false`だった。

| 確認 | 結果・境界 |
|---|---|
| アイコン | 紺・白・ターコイズで道路と音声波形を表した仮素材を登録。iOS用1024pxとmacOS用16〜1024px。生成条件は[開発環境](../development/開発環境.md)に記録 |
| WebRTC再ビルド | 同じsource revision `2a990ce0cc`のiOS arm64を`enable_dsyms=true`で再ビルド。Simulator・macOS binaryは既存出力を維持。`DebugSymbolsPath`付きでiOS実機dSYMを同梱 |
| 継続防止 | build scriptでiOS実機dSYM生成を有効化。検証スクリプトで宣言・DWARF欠落・binaryとのUUID不一致を拒否。欠落を拒否するテストが修正前に失敗し、修正後に成功 |
| 成果物採用 | `ASSEMBLE_ONLY=true WEBRTC_BRANCH=branch-heads/8078 scripts/BuildWebRTC/update-webrtc-binary.sh`成功。隔離したRTCNativeWebRTC build、RTC test run 51件とnative test run 2件成功後に取り込み。zipは97,147,343 bytes。SHA-256は隣接metadataが正本 |
| 回帰テスト | `python3 -m unittest discover -s scripts/tests -v`の36件成功。Appは`xcodebuild test -only-testing:RideIntercomTests`で`TEST SUCCEEDED`。開発設定・文書・差分検査も成功 |
| Archive | `/tmp/RideIntercom-DistributionReady.xcarchive`で`ARCHIVE SUCCEEDED`。`CFBundleIcons`と`CFBundleIcons~ipad`のprimary icon名が`AppIcon`。`AppIcon60x60@2x.png`が120×120、`AppIcon76x76@2x~ipad.png`が152×152 |
| シンボル | Archive内WebRTC.frameworkと`dSYMs/WebRTC.framework.dSYM`のarm64 UUIDが`4C4C4470-5555-3144-A11C-BA59995DD9EB`で一致。旧ArchiveのUUIDとは異なるため旧Archiveへの流用不可 |
| 配布書き出し | `method=app-store-connect`、`destination=export`、`uploadSymbols=true`で`EXPORT SUCCEEDED`。IPAは`/tmp/RideIntercom-DistributionReadyExport/RideIntercom.ipa`。IPA内のアイコン名・サイズ、iCloud権限なし・APNs production、`codesign --verify --deep --strict`成功を確認 |
| 証跡 | `/tmp/rideintercom-distribution-ready-archive.log`、`/tmp/rideintercom-distribution-ready-export.log`、`/tmp/rideintercom-distribution-ready-app-tests.log`、`/tmp/rideintercom-distribution-script-tests.log`、`/tmp/rideintercom-webrtc-symbol-update.log`。一時領域のため永続保存ではない |
| 残るwarning | WebRTC vendor sourceの`tracksWithMediaType:`非推奨、AppIntents未使用によるXcode metadata抽出省略。今回の配布エラーとは別に残る |
| 未確認 | App Store ConnectへのアップロードとApple側の受理は未実行。macOS/SimulatorのdSYM同梱は今回のiOS配布修復対象外。旧Archiveを再送せず、上記の新Archiveまたは修正後に作成したArchiveを使う |

## カメラ不要の配布バイナリ修復（2026-10-22）

対象は`d201c80`上の作業ツリー。App Store ConnectからVersion 1.0 / Build 1に`ITMS-90683`が通知された。利用者の「カメラは不要」という指示に従い、利用していないカメラの目的文字列を追加せず、WebRTCのカメラAPIを除去した。

| 確認 | 結果・境界 |
|---|---|
| 原因の証拠 | 旧Archive内WebRTCに`AVCaptureSession`、`AVCaptureDeviceDiscoverySession`、`AVCaptureVideoDataOutput`、`AVCaptureVideoPreviewLayer`等の参照が存在。Appにカメラ機能はなく、SDK内の未使用実装が検出要因と考えられる |
| 修正 | 同じWebRTC revision `2a990ce0cc`の全5構成を再ビルド。撮影・プレビュー・撮影位置helperをGN入力から除去し、成果物検証でカメラAPI・headerの混入を拒否。上流checkoutの変更は終了時に復元。package検証・取り込み後にAppのbuild番号のみ2へ更新 |
| 回帰 | 全sliceのカメラAPI不在テストは修正前に失敗、修正後に成功。scripts全38件成功。隔離RTCテスト51件と実WebRTCによるSDP・双方向packet転送2件成功 |
| Appテスト | macOSの`RideIntercomTests`全109件成功（パラメータ展開後112件）。失敗・skip 0件。専用storage namespace `CameraFreeValidation`を使用 |
| ArchiveとIPA | Version 1.0 / Build 2でArchive・App Store向けIPA書き出し成功。アプリ本体とWebRTCの外部シンボルに`AVCapture`・`RTCCamera`なし。`NSCameraUsageDescription`なし。IPAの`codesign --verify --deep --strict`成功 |
| dSYM | Archive内WebRTCとdSYMのarm64 UUIDが`4C4C445B-5555-3144-A1A3-0ADBD6A1CAA0`で一致 |
| 成果物 | `/tmp/RideIntercom-CameraFree-Build2.xcarchive`、`/tmp/RideIntercom-CameraFree-Build2-Export/RideIntercom.ipa`。採用zipのSHA-256は隣接metadataが正本 |
| 証跡 | `/tmp/rideintercom-camera-red.log`、`/tmp/rideintercom-camera-free-rebuild.log`、`/tmp/rideintercom-camera-free-import.log`、`/tmp/rideintercom-camera-script-tests.log`、`/tmp/rideintercom-camera-free-app-tests.log`、`/tmp/rideintercom-camera-free-archive.log`、`/tmp/rideintercom-camera-free-export.log`、`/tmp/rideintercom-camera-free-upload.log`。一時領域のため永続保存ではない |
| 検証境界 | 最初のsandbox内実行はXcode cacheへの書き込み・既存テストのprocess確認が拒否され、必要なアクセスを許可して再実行。AppIntents未使用によるmetadata抽出省略warningは残る。実機通話品質・Apple側の処理完了はローカル成功から判断しない |
| App Store Connect | 2026-10-22 00:04 JSTに`Upload succeeded`・`EXPORT SUCCEEDED`を確認。Version 1.0 / Build 2は`Uploaded package is processing`。アップロード成功であり、Apple側の処理完了・審査承認を意味しない |
