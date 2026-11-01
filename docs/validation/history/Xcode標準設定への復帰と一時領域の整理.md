# Xcode標準設定への復帰と一時領域の整理

2026-11-01の「Xcode標準のお作法で使えるようにする」「独自buildの場所をなくす」「不要な/tmpを削除する」という指示に対応した。通常checkoutのmainとXcode既定のDerivedDataを使用する。Xcodeで保存された製品名RideComへの変更を保持した。

## 実装した変更

| 対象 | 現行の扱い |
|---|---|
| Version / Build | projectのMARKETING_VERSION / CURRENT_PROJECT_VERSIONをApp・Widget・Watchが継承する。既存の1.0.0 / 315を維持し、毎buildの採番aggregate・lock・project書換えを削除 |
| Info.plist | Xcode標準の生成を使う。Widget・Watchの専用Python phaseを削除。Appは独自InfoキーとDebug手動試用の接続設定を渡す小さなphaseだけを残し、Release・Archive・検証構成には実接続資格を入れない |
| project参照 | root全体の再帰同期と自己project参照を除去し、編集対象folderごとの同期参照に整理。新規root項目は標準Add Filesで追加する |
| 推奨設定 | WidgetのRegister App GroupsとprojectのMissing Localizability解析を有効化。Watch schemeに標準のRun / Profile / Analyzeを追加 |
| CLI検証 | shared schemeの構成とXcodeで解決された生成先を読む。専用DerivedData・一時project・compiler条件や署名設定のCLI上書きを削除。秘密を含み得るbuild settings全体を保存しない |
| テスト構成 | Debug-Validation・Debug-StoreKitValidationを利用し、Releaseと同じ最適化で内部APIを検査するRelease-Validationを追加。音声E2EのTestActionも検証構成へ統一 |
| 資源 | SwiftPMは標準.buildを使用。Mac・iOS・StoreKit・音声検証は既存lockで排他し、Simulatorを再利用。同じbinary pathだけを理由にGUI利用中のアプリを終了しない |
| 入力一致 | ビルド番号も含めて前後のSHA-256を完全一致で検査し、自動採番だけを除外する例外を廃止 |
| Widget | 配置時に選択した保存ユーザー／groupの専用操作へ統一。汎用の直近再開Widgetを削除し、現在通話の宛先と設定先が一致する場合だけ終了・ミュートを表示 |

## 検証記録

| 検証 | 結果・証跡 |
|---|---|
| 検証スクリプト | Python125件成功。`.validation/xcode-standard-final-20261101/python-tests-complete.log` |
| Mac App | 526件成功、skip・実行時警告なし。host隔離・入力一致も成功。`.validation/xcode-standard-macos-current-20261101` |
| iOS App単体 | 512件成功。`.validation/xcode-standard-ios-fixed-20261101`。同runの設定UI失敗は別に保持 |
| iOS設定UI | fixtureの入力を消して閉じる修正後に1件成功。音声セッションの同期操作による実行時警告1件があり、共通acceptanceは失敗のまま。`.validation/xcode-standard-ios-settings-cleared-20261101` |
| ローカルStoreKit | 標準TestPlanの対象1件・商品取得を確認。正しいplanで39件中38件成功、週券finishの検査1件失敗。skip・実行時警告なし、HEAD・入力一致は成功。`.validation/xcode-standard-storekit-plan-native-final-20261101`。後続診断で購入fixtureの公開観測が未成立と判明したため、この1件の同期を残す |
| TestPlan設定の追従 | 同じbuildでXcodeValidationTests 10件成功、入力一致・警告なし。`.validation/xcode-standard-storekit-plan-configuration-20261101` |
| Release-Validation | Mac／iOS双方の音声test target buildとhost隔離が成功、入力一致も成功。音声測定自体は未実行。`.validation/xcode-standard-release-hosts-final-20261101` |
| 静的検査 | 開発設定、文書参照、project構文、差分検査成功 |

既定のDerivedDataで実行し、ビルド番号を含めて入力一致を確認した。Xcodeで解決されたswift-logは1.16.2であり、この依存版を証跡へ記録した。Xcode生成の文字列カタログには抽出キー／状態の更新があるが、既存の翻訳本文は変更していない。利用者によるIcon Composerの編集は別差分として保全する。

前段のMac526件成功は製品名変更前の入力に対する結果である。iOS全体536件のうち535件成功・設定UI1件失敗のrunでは、別作業の製品名変更が検証途中に入り入力一致も失敗した。これらを最終入力での全件成功へ読み替えない。製品名変更後の破損group復旧UIは個別runで成功した。

OSのパスワード保存提案がfixtureの資格入力後にタブを覆うことを録画で確認した。アプリのSecureFieldやAutoFillは変更していない。不正URLの保存失敗を確認した後に、テストで入力したダミー資格を通常のdelete操作で消してから閉じる。保存失敗後のタブ操作という目的を保ち、OSのパスワード保存先へfixtureを渡さない。名称変更後の日本語期待値が旧製品名のまま残ったテストも修正した。

### StoreKit設定とfixtureの切分け

専用schemeから`Configuration/StoreKit.xctestplan`を選び、既存のローカル商品とsigned-out fixtureを明示した。CLIが選ぶxctestrunもschemeのdefault plan名と一致させ、古い自動生成planへfallbackしない。実Appleアカウントや独自library注入を追加していない。

初回は商品の取得に失敗して29/39成功だった。TestPlan追加の途中ではtargetのcontainer参照を誤り、新descriptorのtargetが空になっていた。古いdescriptorで成功した39件を新planの成功証拠から除外し、project基準のcontainerとplan名照合を修正した。選択子の誤りで0件だったrunも失敗のまま保持する。新しい正しいdescriptorの1件試験は成功したが、別チャットの文書commitによりHEAD一致だけ失敗したため、現HEADで39件と設定suiteを確認し直した。

残る週券finish試験は、`.validation/xcode-standard-storekit-fixture-state-20261101/fixture-state.log`で、購入API完了後もweekHistory=false、weekUnfinished=false、refresh後weekAdopted=falseを確認した。monthlyはすべてtrueでstatus gateへ到達した。単に「unfinishedに無い」と検査すると未公開の週券でも成功してしまう。200msの期限や製品のfinish処理が原因と断定せず、次工程でfixtureの公開観測と採用を明示して同期する。一時診断コードは除去済みで、この診断runの成功を取引完了の成功と扱わない。

## 一時領域の削除

| 対象 | 結果 |
|---|---|
| 再生成可能なcache | DerivedData84件、SwiftPM／module cache53件、合計137directoryを削除。du集計で約110.70GiB。物理空き容量の増加を実測した値ではない |
| cache内の証跡 | Logs／TestResultsの9,196fileをderived-cache-evidence.tarへ退避しbyte照合してから元cacheを削除 |
| 旧source・patch・検証物 | 528,475fileをretained-artifacts.tar.gzへ退避しbyte照合。旧項目と__pycache__計1,947件を削除。archiveは約27.9GiB |
| 除外 | 稼働processとlsofの参照、他アプリ・OS管理の一時物、共通Simulatorのlease／lockを残す。登録済みworktreeは通常mainの1件 |

証跡は`.validation/tmp-cleanup-20261101/summary.json`と同directoryのarchive・照合記録に保存した。失敗一覧は空。過去文書に記録された/tmp上の旧証跡はこの退避物から追跡し、通常buildの場所として再利用しない。

## 確認範囲

Xcode GUIでの実操作、WatchのRun／Profile、実端末の音声・Widget／CarPlay操作、配布profile、Organizerからの提出とApple側の受理は別の受入である。外部swift-logとUI test targetにはAppIntents metadata抽出省略のSDK警告が残り、productionのIntent欠落とは区別する。音声経路自体の測定成功を、build構成やhost隔離の成功で代用しない。
