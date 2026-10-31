# OS設定と埋込productの監査

2026-10-31、Widget追加後の独立worktreeを基準としてOS権限・署名入力・配布設定を監査した。[設定手順](../../development/OS権限と配布設定.md)にrepo内と外部の境界を記録した。

| 確認 | 結果 |
|---|---|
| TDD・構造 | 未実装checkerと不足設定の失敗を先に保存。設定6件と既存開発構造8件の計14件成功。Watch AppIcon欠落、APNs環境の不正値、mac用entitlementの欠落、network受信許可の欠落、Widget埋込削除を検出する |
| iOS Debug build | generic iOS Simulator build成功。App／Widget／Watch全build34、家族1/2・1/2・4、最低OS26.4、AppのAPNs環境development、背景audioのみ。日英InfoPlist.strings、WatchのAssets.carとAppIcon metadataを実生成物で確認 |
| Mac Release build | generic macOS build成功。App／Widget全build35、最低OS26.4、APNs環境production、日英権限説明を確認。Watchは非埋込。署名は無効にしてbuildしており、実App Group共有や通常sandbox起動の証明ではない |
| profile読取 | 最初はsandbox内のCMS decodeが失敗し、権限付きのread-onlyで確認。6ファイル中現App ID一致4件は期限内だがAppleログイン・今回のApp Groupがなく、Widget/Watchの現ID一致なし。証明書identity種別の存在のみ確認。portal未照会、鍵のunlock・再認証・署名・profile変更なし |
| 権限最小化 | 固定Bonjour＋unicastをコードとApple TN3179で確認し、multicast entitlementを追加しなかった。通知担当がalert/tapのみと確認し、未使用のremote-notification background設定を削除。Watch/Widgetへマイク・Appleログイン・通知資格を付与しない |
| アイコンとprivacy | Watchは既存Appの1024原画を無加工で再利用。アイコンの新デザインや実機の見え方は未評価。Required Reason API宣言と実サービスの収集内容・App Privacy回答は別の受入として維持 |

証跡は`.validation/platform-audit`。設定テストのred/green、generic build log、各productの選択したmetadata、秘密値を除いたprofile-summaryを保持した。iOS buildのAppIntents未使用Watch targetでmetadata extraction skippedの既知工具warningのみ。実機・OS許可・Developer portal・実APNs・購入販売・独立音声E2Eは実施していない。

## Mac WebRTCのmanifest配置不良

App自身のmanifestとiOS WebRTCのmanifestは標準位置にあった。一方、Mac埋込frameworkのmanifestは`Versions/A/Versions/A/Resources/PrivacyInfo.xcprivacy`にあり、標準の`Resources/PrivacyInfo.xcprivacy`は不在だった（`.validation/platform-audit/resources.json`）。元の管理zip、SwiftPM展開物、外部checkoutのmacos-x64 build出力にも同じ二重配置を確認した。Appのembedが新たに移動したものではない。

`build-webrtc-xcframework.sh`のMac assemblyは元frameworkを`cp -RP`で保持し、`verify-webrtc-xcframework.sh`はslice・dSYM・camera除外・headerを検証するが、manifestの配置は検証していなかった。最初に二重配置を作った操作までは特定していない。App工程ではpackage/artifactを変更せず、正規配置・各sliceの検査・zip/checksum更新・App再同梱を独立工程へ引き継ぐ。Mac配布の未完了条件として保持する。

最終の局所設定試験は新規6件＋既存開発構造8件＋共通採番18件の32件成功。Watch iconの画像hashはApp原画と一致し、iOS/Macの生成物にentitlement sourceファイルがresourceとして混入していないことも確認した。
