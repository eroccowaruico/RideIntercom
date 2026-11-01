# 招待の復帰案内とXcode入力宣言

2026-11-01、`ff306083`を基準に実施したApp工程。Xcodeの保存形式・設定を受け入れたまま、通常の作業フォルダ`/Users/naohito/source/RideIntercom`で標準TestActionとRelease Archiveを検証する。package／serverの製品処理と配布binaryは変更しない。

## 変更と境界

| 対象 | 変更・確認内容 |
|---|---|
| 招待の失敗 | 期限切れ・非対応version・不正形式／署名等の理由と復帰操作を共通ViewModelで設定する。前回の成功表示を消し、新しい有効な招待で失敗表示を消す。保存処理の個別エラーと既存の認可を維持 |
| 通話の保持 | 無効な招待でgroup・鍵・進行中の通話を変更しない。招待URLの永続台帳や再送pollingは追加しない |
| 両画面の言語 | Standardに加え、Advancedも動的エラーをLocalizedStringKeyとして表示する。一般的な保存失敗文を含め日本語訳を補う |
| Xcode入力 | App／Widget／Watchの番号反映scriptへproject directoryとproject.pbxprojのread入力を追加。OS設定checkerが読むscript・権限・Info・翻訳・Watchアイコンも宣言。採番lock・予約値照合・並列処理・sandboxは維持 |

## 自動検証

最終Mac／iPhone／Archiveの402入力が一致することを確認した。各runは同じ作業フォルダ内の`.validation`に保存し、生成hostの隔離を起動前に検査する。ビルド中の共通counter増分以外のsource変更を認めない。Xcodeの構成・compiler条件・namespace・entitlementのCLI上書きは行わず、共有schemeのTestActionを使う。

| 検証 | 結果・証跡 |
|---|---|
| Mac App | 最終512テストメソッド成功。失敗・skip・runtime warningなし。`invite-recovery-native-final/macos.xcresult` |
| iPhone App／UI | 最終500件成功（App498件、英日UI2件）。実際のStandard／Advancedをassertし、画面添付も確認。失敗・skip・runtime warningなし。`invite-recovery-ios-final/ios.xcresult` |
| iPad UI | 同じ最終buildの英日UI2件成功。Standard画面の不在とAdvancedのエラー領域も確認。`invite-recovery-ipad-final/ipad.xcresult`。iPhone／iPadをshutdown |
| Release Archive | 最終Mac build296・iOS build297の未署名Archive成功。通常namespace・production APNs・App／Widget／Watchの番号一致・package／test bundle／検証fixture不混入を検査。`invite-recovery-archives-final`。未署名・未提出 |
| Python | 107件成功、33.463秒。採番・project・platform設定・既存WebRTC更新検証を含む。`invite-recovery-python/tests.log` |

## 再現した失敗

| 結果 | 修正・保持した証跡 |
|---|---|
| Widget番号反映scriptがproject directoryのreadを拒否される | `invite-recovery-red`を保持。directory入力だけではproject.pbxprojのreadが拒否されたため、両方を入力へ追加。中間失敗は`invite-recovery-red-fixed-inputs` |
| OS設定checkerのsubprocessが読めない | `invite-recovery-red-project-inputs`を保持。呼び出すscriptとその実入力を列挙し、通常の作業フォルダで成功を確認 |
| 保存データのDecodingErrorを招待不正と誤分類 | `invite-storage-red`に1テスト・2 assertionのREDを保持。decodeJoinURLの境界だけで招待形式エラーへ正規化し、credential読取の失敗は既存の保存復旧へ渡す。端末資格の失敗も新しい招待の取得へ誤分類しない |
| UI試験がURL再openでStandard起動fixtureを再適用 | 初回UIのxcresultは成功したが、添付画像でAdvancedを確認できていないことが判明。URLを再openせず画面を切り替え、Standard画面の不在とAdvancedのgroupErrorLabelをassertする試験へ修正。初回を両画面の受入証拠にはしない |
| 招待失敗の表示がnilで前回成功が残る | `invite-recovery-red-complete-inputs`に4条件・8 assertionのREDを保持。他のGroupLifecycleテストは成功。共通処理の修正後、全App回帰を成功させた |

以前の`/private/tmp/RideIntercom-account-verification`での成功を、通常workspaceにおけるscript sandboxの証明とは扱わない。Xcodeのsandboxは一時領域の読み取りを許す場合があるため、今回の通常workspaceで判明した入力不足を修正した。採番時の整合性検査を削除したり、ENABLE_USER_SCRIPT_SANDBOXINGをOFFにする回避は行っていない。

## 受入範囲

実機・Appleログイン・通知・課金・署名・提出の受入ではない。既知のCoreAudio待機、独立音声E2E、Watch自身の音声と押下中送話、無線・電池・背景動作の確認は残す。古いDerivedDataを別worktreeから再利用した際のstale path warningと、AppIntents未使用targetのmetadata省略warningはログへ保持し、warningゼロとは扱わない。
