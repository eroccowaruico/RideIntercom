# 検証状況と証跡

## 接続中の本人名と端末署名の照合（2026-10-31）

group認証だけで保存ユーザーの本人名を上書きできる問題を修正した。接続ごとの確認値、group・送信者・宛先・revision・名前へ署名し、直接招待で保存した端末鍵と照合する。確認済み本人が異なる場合も更新しない。検証済みの応答だけを保存処理へ渡し、グループ内だけの相手は一覧へ追加しない。[現行契約](../spec/App/通信仕様.md#本人名と端末内の呼び名)を参照する。

証跡は`.validation/peer-profile-delivery/`。

| 検証 | 結果 |
|---|---|
| 再現 | group認証済みIDの自己申告だけで保存ユーザー名が変わる失敗を先に確認。最初の個別テスト指定は0件のため検証器が失敗扱いにし、スイート全体で再現し直した。途中のtest helperのRTC import不足も保持。`development/` |
| App | 最終ソースでmacOS・iOS各243件成功、失敗・skip・runtime warningなし。Macのsandbox無効化は検証ホスト限定。`macos/`、`ios/` |
| 本人・接続境界 | 2つのAppモデルで招待・証明交換・名前更新・呼び名維持を確認。別鍵、別の確認済みアカウント、改変payload、古いrevision・接続・宛先を拒否。peer消失・切断・全経路失敗・サインアウトで確認状態を破棄。未知group／memberの応答で保存編集を使用不能にしない |
| 通信・処理 | 未確認peerの確認再送は間隔を広げ、確認後は停止。同じ問い合わせへの返信は署名済みbytesを再利用し、連打時に鍵の読込・署名・返信を増やさない |
| 関連UI | 本人名・受け取った呼び名の編集と復元の1件成功。iOS Appと合わせ244件成功。専用Simulator終了済み。`ios/` |
| Release・静的 | iOS Simulator Release build、fixture不在、文書・開発設定・diff検査成功。既知のAppIntents未使用metadata省略warningのみ。App/test 142ファイルの検証前後hash一致。`source-manifest.json` |

今回の実装は接続中の名前更新と、その根拠となる端末確認まで。音声transportのgroup認証は変更しておらず、複数端末の1対1宛先・自分の別端末判定・通知・利用権の認可は後続へ接続する。名前・端末証明のserver保存は追加していない。実機・実サービス・全package/Worker/音声E2Eを含む最終受入は未完である。

## 招待共有の遅延生成と実行時の再確認（2026-10-31）

Call・Diagnosticsの表示更新から招待発行を外し、OSの共有データ要求時にURLを生成する。標準ShareLinkとURLの転送形式を使い、共有対象のgroup ID・現在のログイン世代・保存状態・個別通話の宛先を再確認する。[Call仕様](../spec/App/UI/Call.md#接続招待操作)と[通信仕様](../spec/App/通信仕様.md#永続化と入力検証の所有)を参照する。

証跡は`.validation/invitation-sharing-delivery/`。

| 検証 | 結果 |
|---|---|
| 再現と修正 | 診断表示20回でKeychain読込・鍵作成が起きる失敗を先に再現。修正後はどちらもゼロ。共有時のURL転送互換性、最新の本人名、招待IDの新規発行、画面切替・group削除・再ログイン・保存競合後の古い共有拒否を確認。`development/` |
| App | 最終ソースでmacOS・iOS各236件成功。失敗・skip・runtime warningなし。Macのsandbox無効化は検証ホスト限定。`macos/`、`ios/` |
| 共有UI | iOSでOS共有画面の表示、Copy、Callへの復帰の1件成功。Appと合わせ237件成功。専用Simulator終了済み。スクリーンショットとアクセシビリティ階層は`ios/ios-tests.xcresult`に保持 |
| 途中の検証 | 初回の個別通話UIは成功したが、共有UIはCopyをButtonとして探して失敗。実階層のCellへ修正して再検証した。iOSのテストマクロ警告2箇所も解消。初回結果は`ui-first/`へ保持し、全成功の最終runと区別する |
| Release・静的 | iOS Simulator Release buildとfixture不在、文書・開発設定・diff検査成功。既知のAppIntents未使用metadata省略warningのみ。App/test 140ファイルの最終検証前後のhash一致。ReleaseのAppソースも一致。`source-manifest.json`、`release-source-manifest.json` |

表示からの不要処理を除いた確認であり、実機の消費電力を測定した結果ではない。実機・macOSのロック解除を伴う共有操作・全package/Worker/音声E2Eを含む最終受入は未完。接続中の本人確認と保存ユーザー名更新、複数端末の1対1宛先、削除・通知の認可は残タスクとして継続する。

## 直接招待の端末署名と保存ユーザーの本人対応（2026-10-31）

招待URL・受取証明・ACKを用途別の端末署名で保護し、受取人の端末鍵も招待専用秘密の認証対象にした。自分のHTTPS登録先から取得済みの発行鍵で確認できた公開ユーザーIDだけを保存ユーザーへ対応付ける。同じ本人の端末は呼び名を保持して統合し、端末IDの流用・鍵の変更・本人IDの不一致は拒否する。[現行契約](../spec/App/通信仕様.md#永続化と入力検証の所有)と[残る接続点](../backlog/未実装課題.md#実装の接続点と残作業の再点検)を参照する。

証跡は`.validation/invitation-identity-delivery/`。

| 検証 | 結果 |
|---|---|
| App | macOS・iOS各232件成功、失敗・skip・runtime warningなし。署名の用途・ID・鍵・発行元の境界、同一ユーザーの端末統合、呼び名保持、保存再起動、旧形式のデータ保持を確認。Macのsandbox無効化は検証ホスト限定。`macos/`、`ios/` |
| 関連UI | 保存ユーザー再利用、1対1通話、本人名と呼び名の編集・復元の3件成功。iOS Appと合わせ235件成功、専用Simulator終了済み。`ios/` |
| 攻撃・削除境界 | 公開受取証明の鍵差替え、不正署名による保存編集停止、招待双方の一覧削除後の古いURL／受取証明による再登録を拒否。失敗を先に再現したログと、旧manifest読込・途中のcompile失敗も`development/`へ保持 |
| Release | iOS Simulator Release build成功。ログイン検証fixtureのマーカー不在。既知のAppIntents未使用metadata省略warningのみ。`release/` |
| 静的・ソース | 文書・開発設定・diff検査成功。App/testの138ファイルは最終検証前後で一致。`source-manifest.json` |

今回の対応は直接招待と保存ユーザーまで。接続中の相手の本人確認、複数端末の個別通話宛先、通知の用途別許可、Appからの削除完結は後続に残る。証明が未取得・期限切れ・別発行元でも、本人IDとして統合せず端末鍵を確認してLocal招待を継続する。Worker・packageは変更しておらず今回の再検証対象に含めない。実機・実Apple認証・実サービスの設定と、全package/Worker/音声E2Eを含む最終受入は未完である。

## 署名付き端末証明の発行とApp保存（2026-10-31）

Internet登録に、公開ユーザーID・端末ID・member ID・端末公開鍵を結ぶES256証明の取得と検証を追加した。App自身のHTTPS登録先から発行公開鍵を取得し、不一致の応答では新資格を回収する。資格と証明を同じKeychain項目へ保存し、端末秘密鍵は別のアカウント別項目に保持する。[現行契約](../spec/server/Worker.md#ユーザーと端末の署名付き証明)と[残る接続点](../backlog/未実装課題.md#実装の接続点と残作業の再点検)を分ける。

証跡は`.validation/device-identity-delivery/`。

| 検証 | 結果 |
|---|---|
| Worker / DO | 47件成功、失敗・skipなし。Bearer由来のID、公開鍵の妥当性、証明の内容と期限、秘密の非公開、削除・再登録、未設定署名鍵を確認。`server/server-final.log` |
| Swift–Worker | 実HTTP/WSとローカルDOの結合1件成功。外部SFUはmock。`server/pair.log` |
| App | macOS・iOS各226件成功、失敗・skip・runtime warningなし。JOSE生成署名をSwift/CryptoKitで検証し、別のユーザー・端末・member・鍵・発行元・用途、期限境界、再起動、サインアウト、鍵欠落／破損を確認。Macのsandbox無効化は検証ホスト限定。`macos/`、`ios/` |
| 関連UI | 登録の頻度制限案内と、登録不可でもLocalログインを維持する2件成功。専用Simulatorは終了済み。`ui/` |
| Release | iOS Simulator Release build成功。ログイン検証fixtureのマーカー不在。既知のAppIntents未使用metadata省略warningのみ。`release/` |
| 静的・ソース | TypeScript、文書、開発設定、diff検査成功。App/test・serverの137ソースは検証前後で一致。`source-manifest.json` |

未実装APIの404と、Appが証明取得へ進まない失敗を先に再現した。途中のCryptoKit import不足によるcompile失敗も保持する。今回の完了は自分の証明取得・検証・保存までであり、相手端末のchallenge署名、直接招待と保存ユーザーの結合、通知許可は未完。実サービスの署名鍵設定・Apple認証・実機、全package/音声E2Eを含む最終受入も未完である。

## 公開ユーザーIDと削除後の再登録（2026-10-31）

公開ユーザーIDを認証用DO locatorから分離し、サインアウト・全端末資格の期限切れ・再ログインでは維持、アカウント削除で破棄する。再登録時の新IDは並行登録でも一致させる。Appの登録応答検証を同じ契約へ変更した。WebRTC予約は内部IDを使い、削除前の資源が残る間の追加接続を拒否する。[Worker契約](../spec/server/Worker.md#apple認証と端末資格)を参照する。

証跡は`.validation/account-identity-delivery/`。

| 検証 | 結果 |
|---|---|
| Worker / DO | 45件成功、失敗・skipなし。削除後のID更新、全資格失効後の同一性、並行登録、再起動、削除再送、通話枠の迂回拒否を含む。`server/server.log` |
| Swift–Worker | 実HTTP/WSとローカルDOの結合1件成功。外部SFUはmock。`server/pair.log` |
| App | macOS・iOSそれぞれ220件成功、失敗・skip・runtime warningなし。公開IDと内部locatorを分離した正常応答と、不正locatorの拒否を確認。Macのsandbox無効条件は検証ホストだけ。`macos/`、`ios/` |
| ソース・静的確認 | iOS検証前後のApp/test・serverソースhash一致。TypeScript、文書、開発設定、diff検査成功。専用Simulatorは終了済み。既知のAppIntents未使用metadata省略warningは継続 |

修正前に削除後の同一IDとAppの応答拒否を再現した証跡も保持する。UI・Release・音声処理は今回変更しておらず、その再検証は含めない。公開IDと保存ユーザー・相手端末の本人確認、端末内アカウント削除、通知許可は後続に残る。実Apple認証・実機・全package/音声E2Eを含む最終受入の完了ではない。

## 直接招待の発行確認と再受理の制限（2026-10-31）

group参加者による直接招待の自己申告を拒否するため、発行者のアカウント別Keychain鍵、招待専用秘密、相手IDに結び付いた受取証明をAppへ接続した。同じ招待と受取人のIDを固定し、一覧削除後の再送・URL再受理・受取IDの書換えによる再登録を拒否する。[現行契約](../spec/App/通信仕様.md#永続化と入力検証の所有)を参照する。

証跡は`.validation/invitation-authority-delivery/`。

| 検証 | 結果 |
|---|---|
| Mac App | 219件成功、失敗・skip・runtime warningなし。検証限定の独立Macホスト・sandbox無効条件を継続。`macos/` |
| iOS App | 最終ソース219件成功、失敗・skip・runtime warningなし。`ios/` |
| 関連UI | 保存ユーザーの再利用、1対1の通話先と一覧削除、サインアウトの3件成功。App 219件と合わせ222件成功したrunを`ios-ui/`へ保持。後続はテストファイルの末尾空白だけを整形してApp全件を再実行し、UIが参照するApp・UITestソースは同一であることを`ui-source-manifest.json`で照合。専用Simulatorは終了済み |
| 境界と鍵 | 偽の自己申告、相手・group・招待者・期限・招待ID・受取IDの改変、期限境界、同一URL再受理、別アカウント、Keychain再起動・読取失敗・同時初期化を確認。2つのAppモデルでURL共有→受理→認証後の受取証明→双方の保存→ACK→一覧削除→再送拒否を通した |
| 秘密の保持 | 招待専用秘密をgroup内受取メッセージ・manifestへ保存しないことを確認。発行者の鍵は既存値を上書きせずKeychainへ作成する |
| Release | iOS Simulator Release build成功、ログイン／Internetの検証fixtureマーカー不在。新しいSwift warningなし。既知のAppIntents未使用metadata省略warningは残る。`release/` |
| ソース・静的確認 | 最終App/testソース119ファイルのhashは検証前後で一致。文書・開発設定・diff検査成功。`source-manifest.json` |

未発行receiptの受理と、同一リンク再受理でIDが変わる失敗を先に再現し、`red.log`と`reopen-red.log`へ保存した。途中のfixtureのActor隔離、旧version期待値・同一端末IDを使っていた2端末fixtureの失敗も保持し、修正後の成功と区別する。

これは端末側の直接招待確認である。招待URLそのものを渡せば所持者へ招待情報が渡る。Appleユーザーと端末の認証対応、アカウント再登録、通知先の用途別許可・解除は後続に残り、この受取証明を公開通知APIの認可として完成扱いしない。実機・実Apple認証・全package/Worker/音声E2Eを含む最終受入は今回の範囲外。


## ログイン世代と機能間の境界（2026-10-31）

残タスク全体の関連を点検し、同じアカウントへの再ログインで古い操作主体が復活する問題と、ログアウト後の保存・招待・Internet資格設定の入口を修正した。ログイン世代はメモリ内だけに持ち、通常の資格確認で通話モデルを作り直さない。Keychain読取失敗からの再読込では新しいログインを画面へ通知する。[現行契約](../spec/App/通信仕様.md#appleログインと端末内データ)と[未完成の接続点](../backlog/未実装課題.md#実装の接続点と残作業の再点検)を区別する。

証跡は`.validation/account-boundary-app-delivery/`。

| 検証 | 結果 |
|---|---|
| Mac App | 211件成功、失敗・skip・runtime warningなし。独立Macホストのsandbox無効化は従来の検証限定条件を継続。`macos/` |
| iOS AppとUI | 214件成功（App 211件＋ログイン・Internet設定・サインアウトのUI 3件）、失敗・skip・runtime warningなし。専用Simulatorを終了。`ios/` |
| 回帰 | 同一アカウント再ログイン・別アカウント切替・失効callback中の拒否・ログアウト後の保存と資格変更・Keychain復旧を追加。修正前の失敗も`red-macos-tests.log`、`recovery-red-macos-tests.log`に保持 |
| ソース・静的確認 | Appとtestのソースhashは最終検証の前後で一致。`source-manifest.json`。文書・開発設定・diff検査成功 |

これはAppの変更範囲の検証であり、全package・Worker・音声E2Eを含む最終受入の完了ではない。実Apple認証・実機・Apple grant取消は未確認。直接招待receiptに発行の裏付けがない問題、ユーザーと端末の対応、削除後の再登録は修正対象として残している。


## アカウント端末登録の削除API（2026-10-31）

認証したアカウントの全端末資格を削除し、成功応答を失った再送で再登録後の資格を消さないserver処理を追加した。App操作とApple認可取消は後続であり、機能全体の完了とは扱わない。[契約](../spec/server/Worker.md#アカウントの端末登録削除)を参照する。

証跡は`.validation/account-delete-server/`。

| 検証 | 結果 |
|---|---|
| Worker / DO | 43件成功、失敗・skipなし。追加2件で全端末失効、他アカウントの維持、並行再送、削除前challengeの拒否、再登録後の再送、再起動・24時間経過・サービス停止中の削除を確認。`final.log` |
| Swift–Worker | ローカルDOとの実HTTP/WS契約1件成功。外部SFUはmock。`pair.log` |
| 型・文書 | TypeScript、文書・diff検査成功。`type-check-final.log`、`documentation.log` |
| 失敗履歴 | 未実装APIの404を確認。最初の実装では同期KVのIterableをMapとして扱ったため型・実行が失敗し、正しい反復へ修正。`red.log`、`green.log`、`type-check.log` |

## 接続競合のApp案内と明示再開（2026-10-31）

検証済みRTCの手動復帰通知をAppへ接続した。アカウントの既存通話と競合した際、Callに復帰方法を表示してLocal音声は維持する。全体が再試行しない失敗ならidleへ戻し、Connectから再操作できる。新しい判定状態をAppへ重複保持せず、共通eventの意味を維持する。

証跡は`.validation/account-connection-app-delivery/`。

| 検証 | 結果 |
|---|---|
| macOS App | 207件成功、失敗・skip・runtime warningなし。追加4件でadapterの通知、Local音声維持、Connectへの復帰、Localの独立した再試行を確認。隔離テストhostのみsandbox無効 |
| iOS | App 207件と既存の登録・頻度制限・サインアウトUI 3件、計210件成功。失敗・skip・runtime warningなし。専用Simulatorは終了済み |
| Release | iOS Simulator向けRelease build成功。Swift warningなし。AppIntents未導入によるmetadata抽出省略warningのみ |
| ソース・文書 | iOS実行前後のApp・テスト116ファイル一致。文書・diff検査成功 |

型追加後のApp未追従によるcompile失敗を赤テストとして保持した。package工程とApp工程のコミットを分け、App検証が完了した状態でmain・previewへ統合する。これは実Apple・実Cloudflare・実機の受入完了を意味しない。

## WebRTC競合の手動復帰契約（2026-10-31）

RTC packageが既知の409 codeを解釈し、HTTP再送・route再接続を繰り返さず手動復帰を通知する。Local経路は維持し、明示的なprepareで再試行を許す。serverやAppに文字列判定を重複させない。[契約](../spec/packages/RTC.md#ユーザー操作を必要とする接続拒否)を参照する。

証跡は`.validation/account-connection-rtc/`。409の本文をそのまま表示しないこと、不明code・不正JSON・過大本文・異なるHTTP statusを専用案内にしないこと、ICE/joinの両方の失敗回収、単独routeとLocal併用、明示再開を検証する。

| 検証 | 結果 |
|---|---|
| RTC package | 規定の直列実行で86件とnative WebRTC 4件、計90件成功。失敗・skip・compile warningなし。`final-typed.log` |
| Swift–Worker | 分離したローカルDOとのHTTP/WS契約1件成功。`pair-typed.log` |
| 文書・差分 | package仕様のリンク・diff検査成功。`documentation.log` |

続く点検で、全routeが手動復帰待ちでも定期処理のタイマーが残る点を修正した。`.validation/blocked-route-idle/`に赤テストと成功した4件を保持する。全route待機時の停止、Local併用時の継続、明示再開、通常再試行・診断処理を確認した。packageだけの変更で、AppのAPI・表示は変えていない。

初回の専用案内テストは未実装のHTTP文言で失敗した。route試験の初回compileでは新しいeventの未定義に加えてtest内の選択mode名の誤りがあり、正しい既存modeに直した。通常のpackage実行では別工程用WorkerPairがskipとなるため、その実行は最終合格の根拠にせず、規定の対象分離で検証する。

## ユーザー単位のWebRTC予約（2026-10-31）

serverの確認済みuserIDを既存の利用枠予約に対応付け、room・端末をまたぐ追加接続を拒否する。App・packageの変更とは分けて検証した。契約と媒体回収の限界は[Worker仕様](../spec/server/Worker.md#ユーザー単位のwebrtc接続予約)を参照する。

証跡は`.validation/account-connection-server/`に保持する。

| 検証 | 結果 |
|---|---|
| Worker / DO | 41件成功、失敗・skipなし。追加5件で並行要求・別ユーザーの独立性・header偽装、TURN準備と更新、再起動と期限、失効失敗、SFU作成後の失敗回収を確認。`final.log` |
| Swift–Worker | 実HTTP/WSとローカルDOの契約1件成功。SFUはmock、実媒体は対象外。`pair.log` |
| 型・文書 | TypeScript、文書・diff検査成功。`type-check.log`、`documentation.log` |
| 失敗履歴 | 実装前に追加4件が200と409の差で失敗した記録を保存。`red.log` |

公開登録は既定で無効のまま。実サービスの媒体回収時間・実機での複数端末受入は[未確認事項](未確認事項.md)、RTC/Appの専用案内と復旧時の例外方針は[残課題](../backlog/未実装課題.md)で継続する。

## 登録制限時のApp案内とXcode更新への追従（2026-10-31）

Internet登録のHTTP 429を待機時間付きで案内し、同じ設定画面での再操作を期限まで抑止する。端末登録上限の409は別の案内にし、失敗で既存のログイン・保存資格を失わない。仕様は[通信仕様](../spec/App/通信仕様.md)、操作は[Settings](../spec/App/UI/Settings.md)を参照する。

証跡は`.validation/enrollment-app-delivery/`に保持する。

| 検証 | 結果 |
|---|---|
| macOS App | 203件成功、失敗・skip・runtime warningなし。待機期限、取消後の遅延応答、資格保存を伴わない失敗、不正なRetry-Afterの上限を含む。隔離テストhostだけsandboxを無効化し、製品設定は維持 |
| iOS AppとUI | App 203件・UI 3件、計206件成功、失敗・skip・runtime warningなし。登録制限の案内、登録不能時のログイン維持、サインアウトを確認。UIのスクリーンショットとアクセシビリティ情報を保存 |
| 開発スクリプト | 72件成功。package親のfolder強制指定を拒否する回帰検査を含む |
| Release | iOS Simulator向けRelease build成功。生成binaryにAppleログイン・頻度制限のfixture識別子と型がなく、検証用compile条件もない。Swift warningなし、AppIntents未導入によるmetadata抽出省略の既知warningのみ。初回のsandbox権限制限によるbuild失敗も保存 |
| ソース照合 | 最終iOS実行前後のApp・テスト116ファイルが一致。Mac実行後の差分はUIテストのスクロール補正のみ |

作業中にXcodeが27A9275から27B52へ更新された。標準初回セットアップは承認後も非対話sudoで実行できず、利用者がセットアップとCommand Line Tools更新を完了した。CoreSimulator 1174.21、Swift 6.4.2を確認。packageの親を明示的なfolderにする2箇所の指定を外すことで、9個のlocal packageを再び読み込めた。App targetからのpackage除外、live Repository表示、project自己参照のfolder指定は維持した。

初回iOS実行では設定項目の追加によりボタンが画面外となり、UI 2件が失敗した。共通スクロール操作を適用して上記206件で再確認した。実Apple認証・実機・通常署名とMac sandbox起動の受入は[未確認事項](未確認事項.md)に残る。

## Apple登録入口の過剰アクセス制限（2026-10-31）

challenge作成とApple token検証の前に、送信元別・location全体の頻度を制限する。1つのchallengeに対する検証試行も5回までに抑え、並行送信・DO再起動で枠を戻さない。登録端末数の上限は一時的な頻度制限と区別した。契約は[Worker仕様](../spec/server/Worker.md#apple認証と端末資格)を参照する。

証跡は`.validation/enrollment-server-delivery/`に保持する。

| 検証 | 結果 |
|---|---|
| Worker / DO | 36件成功、失敗・skipなし。新規5件で送信元と全体の制限、偽装forwarding header・device変更、設定不備時の拒否、並行・再起動後の試行回数、制限中の資格失効と既存API継続を確認。`final.log` |
| Swift–Worker | 実HTTP/WSとローカルDOを通る1件成功。SFUはmock。Xcode本体を指定した最終実行にwarningなし。`pair-xcode.log` |
| 型・設定・文書 | Wrangler型再生成、TypeScript検査、dry-run bundle、文書とdiff検査が成功。公開登録の既定はfalseのまま |
| 失敗履歴 | 未実装の赤テストを保存。Miniflareは空の送信元headerを自動補完するため、その試験を不正な長さのedge値へ補正。初回pairのCommandLineTools由来リンクwarningはDEVELOPER_DIRを明示して解消 |

これはローカルの登録入口の検証であり、実Apple認証・実Cloudflare配置・分散攻撃や請求額の上限の証明ではない。アプリ側の待機・端末上限の案内は続く工程で接続する。packageとAppの製品コードはこの工程では変更していない。


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
