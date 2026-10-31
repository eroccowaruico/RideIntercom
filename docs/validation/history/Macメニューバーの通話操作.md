# Macメニューバーの通話操作

## 対象と境界

2026-10-31、標準MenuBarExtraを同じAppCallOwnerの現在通話へ接続した。初期OFF、名前なしの状態表示、明示mute、表示した参照の終話、既存main windowへ戻る操作を対象とする。[現行仕様](../../spec/App/システム表示と通話操作.md)を参照。

基準は`de94ebef`上のroot統合worktreeの未コミットApp/Watch/Widget/OS設定を隔離worktreeへコピーしたもの。`.validation/menu-bar/baseline-source.json`に352ファイルの入力hashを保存し、manifest SHA256は`5b3a6a97e99f6568558fb3ac706fba6eb19152d96174bd031fb7665a78de5861`。package、server、商品設定、外部profileは変更していない。

## 実行記録

| 確認 | 結果・証跡 |
|---|---|
| TDD先行 | 新API未実装によるcompile失敗を`red.log`／`red.xcresult`へ保持 |
| 初回局所試験 | 5件成功。設定保存、OFFと音声resetの通話継続、重複mute、古い終了、ログイン置換、権利未成立の状態投影。`green.log`／`green.xcresult` |
| 最終App回帰 | Mac 395件成功（追加6件、失敗0・skip0）。日本語compiled resourceを含む。`final-macos.log`／`final-macos.xcresult`／`final-summary.json` |
| Release build | fixture条件なし、署名なしgeneric macOSのApp＋Widget build成功。arm64／x86_64、共通build 235。`release-build.log` |
| 入力固定 | source manifest 375入力は自動採番以外一致。testはbuild 234。元hashと採番を前後で保持し、正規化比較結果を`results.json`へ保存 |
| 構造 | 文書／開発構造checkと既存OS設定・採番24試験が成功。新target・entitlementは追加なし |

専用DerivedDataは`/tmp/RideIntercom-MenuBar`。`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`、`RIDEINTERCOM_VALIDATION`、専用storage namespace、`ENABLE_APP_SANDBOX=NO`で通信なしのunit fixtureを用いる。macOS 26.4を最低対応のまま維持し、27.2 SDKでcompileする。実OSメニュー操作・VoiceOver・画面復帰は[未確認事項](../未確認事項.md#macメニューバーのos受入)で別管理し、unit結果で代用しない。

最終App試験とRelease buildにコンパイラ／runtime warningはない。先行局所試験でUIテストbundleに出たAppIntents metadata省略warningは既知の工具出力として保持する。Mac用WebRTCのprivacy manifest配置不備はこのApp工程では未修正であり、Release build成功を配布準備完了とは扱わない。
