# 配布ビルド採番とOrganizer認証調査

確認日は2026-10-29。利用者の指示は、公開バージョンを勝手に変更せず、App Store Connect／TestFlight用のビルドだけを採番し、内部のRun・Buildでは増やさないこと。手順は[開発環境](../../development/開発環境.md#app-storetestflight用の採番とarchive)、版の判断基準は[開発方針](../../policies/開発方針.md#公開バージョンとビルド番号)を正本とする。

## Organizerの認証エラー

Xcode 27.1（27A9275）の配布ログとmacOSのクラッシュ記録を照合した。

| 観測 | 判断・境界 |
|---|---|
| 19:08:54 JSTの配布失敗 | `IDEDistribution.critical.log`に`NSCocoaErrorDomain Code=4097`、`connection to service named com.apple.dt.Xcode.ITunesSoftwareService`と`account (null)`。同時刻のApple製XPCサービスが`EXC_BAD_ACCESS / SIGBUS`で終了 |
| クラッシュスタック | `CDTransporterDefaults`、`CDAuthContext`、`ContentDelivery`の環境設定参照が再帰。アプリ実行コードのスタックではない |
| 19:13の再試行 | 認証後にアップロード検証へ進み、使用済みビルド4以下として拒否。認証表示だけからログイン期限切れとは判断できない |
| 修正範囲 | 確認した認証失敗はXcode側サービスの異常終了に伴う接続切断。アプリ設定でこのクラッシュが直る根拠はなく、資格情報やXcode設定を削除していない。別問題のビルド番号管理を修正 |

証跡は`~/Library/Logs/DiagnosticReports/com.apple.dt.Xcode.ITunesSoftwareService-2026-10-29-190855.ips`と、一時領域の`RideIntercom_2026-10-29_19-08-52.533.xcdistributionlogs`。認証障害の再発防止は未確認。

## 採番・Archive・書き出し

`b5591e43`の隔離コピーに今回の採番設定とスクリプトを反映し、同時進行中の音声変更を含めずに検証した。元の作業ツリーの配布基準は4に維持。検証コピーはXcodeで開いていないため、実行時だけ`pgrep`を置き換えて「Xcode起動中」のガードを通過させた。採番・ビルド・署名・書き出しには実際のAppleツールを使用した。

| 確認 | 結果 |
|---|---|
| スクリプト回帰 | `python3 -m unittest discover -s scripts/tests -p test_distribution_archive.py -v`の5件成功。採番がArchiveより先に実行されること、採番失敗時の停止、Archive失敗時のlock解除、重複実行・既存Archive・Xcode起動時の拒否、呼出元からの相対パスを検証 |
| 配布Archive 1回目 | `scripts/archive_app_store.sh ios /tmp/RideIntercom-FinalNumber5.xcarchive`で`ARCHIVE SUCCEEDED`。署名済みAppの`CFBundleVersion=5`、`CFBundleShortVersionString=1.0`。Archive側のApplicationPropertiesも一致 |
| 間に挟んだ内部Build | 同じコピーでDebug・generic iOS・`CODE_SIGNING_ALLOWED=NO`の`xcodebuild build`が成功。Appは`1.0 (5)`を維持。projectファイルのSHA-256はBuild前後で一致 |
| 配布Archive 2回目 | 同じ入口で`/tmp/RideIntercom-FinalNumber6.xcarchive`を作成し成功。署名済みAppとArchive情報がともに`1.0 (6)` |
| IPA書き出し | build 5のArchiveに`scripts/ExportOptions.plist`を指定して`xcodebuild -exportArchive`が成功。`/tmp/RideIntercom-FinalNumber5-Export/RideIntercom.ipa`内のAppも`1.0 (5)`を維持 |
| 構造確認 | 開発設定、plist、shell構文、差分検査成功。文書検査は対象変更だけの隔離コピーで成功。元の作業ツリーでは別作業の未追跡バックログ文書「リアルタイム会話の遅延と連続性改善」への入口リンク不足で失敗し、対象外として維持 |
| 残る境界 | AppIntents未使用によるmetadata抽出省略warningあり。macOSの実Archive、OrganizerのGUI設定保持、アップロード、Apple側の受理・TestFlight配信は未検証 |

ログは`/tmp/rideintercom-final-number5.log`、`/tmp/rideintercom-number5-normal.log`、`/tmp/rideintercom-final-number6.log`、`/tmp/rideintercom-final-number5-export.log`。一時領域のため永続保存ではない。検証前の対象project設定のSHA-256は`2ccf2562e192b3a5dd6f704094bcb3ffcaccb35b1a905167573ed446e066fdf8`、採番スクリプトは`fbc0f648ee1fb2d93e11cad187e5ac1c0fd3b5b7ac65daf6742207b6e9323186`。

## 採用しなかった方式

schemeのArchive Pre-actionで`agvtool`を実行すると、project上は新番号でも、そのArchiveには読み込み済みの旧番号が入った。Archiveを開始する前に採番する専用入口を採用した。また、ターゲットごとに番号が異なる状態では`agvtool`が低い番号を基準にしたため、project共通設定を全ターゲットに継承させた。通常Buildでの採番や生成Info.plistの独自前処理は最終変更に含めていない。


## Xcode標準Archiveへの統合（2026-10-30）

利用者から、専用コマンドを基本NGとし、XcodeのArchiveで自動採番し、通常Run・Buildと公開バージョンは変更せず、XcodeのBuild欄・project設定・配布物を揃えるよう指示があった。上記の専用コマンド方式を置き換えた。要求は[開発方針](../../policies/開発方針.md#公開バージョンとビルド番号)へ追記し、[要求の入口](../../requirements/README.md)から参照する。

| 修正 | 理由・境界 |
|---|---|
| 共通xcconfig | 既存の手元のApp設定7を`Configuration/BuildNumber.xcconfig`へ移し、projectのDebug・Releaseから全targetへ継承。ナビゲータ直下で見える。手元の公開バージョン1.0.0は変更せず、今回のコミットへ既存の公開バージョン差分を混ぜない |
| Xcode内の採番 | AppのBuild Phaseから`prepare_archive_info.py`を呼び、Archiveのinstall actionでだけ採番。通常のbuild actionは読み取るだけ。CLIの専用入口と旧テストは削除 |
| 読み込み済み設定への対策 | xcconfig更新だけでは当該Archiveのbuild settingsは古いため、ビルド専用の入力Info.plistへ予約番号を入れる。`GENERATE_INFOPLIST_FILE=NO`で旧番号の再上書きを避け、署名前の通常のplist処理へ渡す |
| 古い版情報の生成を除去 | agvtoolを使わなくなったため`VERSIONING_SYSTEM=apple-generic`を除去。読み込み済みの旧番号を持つ`*_vers.c`を生成しない |
| 並行実行と復旧 | file lock、atomic replace、各ビルド固有の生成先により番号と成果物を固定。破損・欠落は自動初期化せず停止。採番後の失敗は欠番として維持 |
| 周辺処理の保護 | 実行中のXcode、アプリ、他のビルドを停止せず、既存DerivedDataも削除しなかった。検証は専用の一時コピー・DerivedDataと低優先度・2ジョブで実行 |

検証コピーのsourceは`1913cc99`を基準とし、その後に手元のproject設定（公開バージョン1.0.0、ビルド7）と今回の変更を反映した。同時進行のRTC修正は含めない。元の作業ツリーでは検証のために採番していない。

| 確認 | 結果 |
|---|---|
| 自動テスト | `python3 -m unittest discover -s scripts/tests -p test_archive_numbering.py -v`の8件成功。旧設定値を保持した環境での連続採番、8並列の重複防止、内部Buildの不変、欠落・破損・書込失敗、プラットフォーム別metadataを検証 |
| 標準Archive | 専用コマンドを使わず、既存のRideIntercom schemeの`xcodebuild archive`でiOS 8→9、macOS 10の生成に成功。最終設定でもiOS 11、macOS 12の署名済みArchiveに成功し、`codesign --verify --deep --strict`成功 |
| 内部Build | 間に実行したmacOS Release Buildは8を維持。iOS Debug Buildは10を維持し、実行前後のproject・ソースInfo.plist・xcconfigのSHA-256が一致 |
| 設定・実体の一致 | 最終Archive内AppとOrganizerのApplicationPropertiesがそれぞれ1.0.0 (11)／1.0.0 (12)で一致。Xcodeの`-showBuildSettings`が共通xcconfigの最新番号を解決することも確認 |
| 既存metadata | 変更前のiOS/macOS生成plistと全キーを比較。差分は採番したCFBundleVersionと、検証コピーへ引き継いだ既存の公開バージョン変更のみ。権限説明、暗号化免除、アイコン、URL scheme、Bonjour、背景音声、scene、launch、画面方向などを保持 |
| IPA | 最終iOS Archiveを既存ExportOptionsで書き出し成功。IPA内Appも1.0.0 (11)を維持し、書き出しで再採番しない |
| 構造確認 | 開発設定・文書・plist・差分検査成功。並行作業のproject参照・公開バージョン差分・RTCソース・検証文書は今回のコミットから除外 |
| 残る境界 | 既存Xcode画面を操作してのArchiveクリックやBuild欄の再描画は実施せず、同じscheme/build phaseを標準xcodebuildで検証。AppIntents未使用のmetadata省略warningは従前どおり。アップロード、Apple受理、TestFlight配信は未実施 |

主な証跡は`/tmp/ride-archive-integration-final11.log`、`/tmp/ride-archive-integration-final12-mac.log`、`/tmp/ride-archive-integration-mac-build.log`、`/tmp/ride-archive-integration-debug.log`、`/tmp/ride-archive-integration-final11-export.log`、`/tmp/ride-archive-integration-final-settings.json`。一時領域のため永続保存ではない。採番スクリプトのSHA-256は`499b62d64098bf063f6890e9baf6a79d2c0ee2dad4855135379e296fc9987d11`。


## project設定への集約（2026-10-30）

利用者から、Xcodeで管理できればよく、Configuration内のロックなど余分なファイルは不要と指摘があった。これらはOrganizerの生成物ではなく、前節の採番スクリプトが作った補助ファイルである。最新の採番値9を保持して、番号の正本をXcode projectの`CURRENT_PROJECT_VERSION`へ戻した。さらに利用者から、構成別の番号を持たず、Debugが100回連続してもRelease／Archiveが続いても、すべて共通の連番を進めるよう指示があった。Archive限定の採番を撤回し、全ビルドを同じ規則に統一した。

| 変更・確認 | 結果 |
|---|---|
| 補助ファイルの除去 | `BuildNumber.xcconfig`と残存する`BuildNumber.lock`を削除し、空のConfigurationディレクトリも削除。参照と旧ignore設定も除去 |
| 同時採番 | 既存の.xcodeprojディレクトリ自体へOSのlockを掛けるため、新規の常設lockファイルは不要。書換え用の一時ファイルはatomic replace後に残さない。更新直前にprojectの別保存を検出した場合は上書きせず失敗させる |
| 最終的な採番規則 | `build`／`install` actionで共通の10進連番を毎回1増やす。Debug・Release・Archiveでリセットせず、日付や別カウンタを導入しない。公開バージョンと他のproject設定は保持。署名前の入力plistへ予約番号を渡す |
| 回帰 | `test_archive_numbering.py`の11件成功。Debug 100回→Release 3回→Archive 3回→Debugの107連続、7桁から8桁への増分、8並列での重複防止、別設定・lockファイルの不在、他設定の保持、失敗時の動作を確認 |
| 移行方式の先行確認 | `95f363aa`の隔離コピーで、採番専用設定を除いても標準iOS Archiveが9→10→11となり、AppとOrganizer情報・署名の整合を確認。この時点の通常Build据え置き規則は、その後の指示で全ビルド採番へ置き換えた |
| 最終規則の実ビルド | 同じ隔離コピーを境界試験用に9999997から開始し、標準Debug Build=9999998、Release Build=9999999、署名済みArchive=10000000を確認。公開バージョン1.0.0を維持し、project・App・Organizerの番号が各ビルドで一致。8桁のApp Store側受理を確認するアップロードは行っていない |
| 移行 | 実行中ビルドがないことと旧lockを確保できることを確認してから、元の作業ツリーの番号9を移行。既存プロセスは停止せず、別作業のproject参照・グループ管理変更は保持 |
| 確認範囲 | 文書・開発設定・plist・差分検査成功。既存Xcode画面の操作とアップロードは実施していない |

証跡は`/tmp/ride-project-number-10.log`、`/tmp/ride-project-number-build.log`、`/tmp/ride-project-number-before-build.sha256`、`/tmp/ride-project-number-11.log`、最終規則の`/tmp/ride-shared-number-debug.log`、`/tmp/ride-shared-number-release.log`、`/tmp/ride-shared-number-archive.log`。一時領域のため永続保存ではない。現行の操作・要求は[開発環境](../../development/開発環境.md)と[開発方針](../../policies/開発方針.md#公開バージョンとビルド番号)を参照する。
