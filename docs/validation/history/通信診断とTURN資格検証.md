# 通信診断とTURN資格の検証

検証日: 2026-10-21。対象: `codex/restore-dev-calls`。RTC `ace2042` / 再接続競合 `2a26eb2`、Worker `3f0cb3c` / 並行回収 `d1d5177`。Appと文書はこの記録を含む後続コミット。

## 指示と変更

パッケージ要求が満たされているかを実装で確認し、現実的に品質へ結びつく未達を実装する指示。調査時点では通信診断の接続とTURN資格lifecycleが未実装だった。RTCとWorkerを先に検証・コミットし、その後Appの表示と要求状態を更新した。

恒久要求は[パッケージ要求](../../requirements/パッケージ要求.md)へ残す。満たした項目を消すという従来の文書管理方針は、今回の指示に合わせて実装状態を更新する方針へ変更した。

## 採用した改善と限界

| 対象 | 結果 |
|---|---|
| 診断 | EventSourceのoverflow/expiry、ICE RTT、DataChannel送信待ち、認証済み観測経路をreport化 |
| 取得不能 | Multipeerの非公開統計、SCTP損失率はnilと理由を通知。推定値を正常としない |
| TURN | 事前の利用枠確認、所有者と試行ID、発行・更新・切断/期限/未成立の回収、失効再試行 |
| 再接続競合 | 旧session DELETE待ち中の切断で、新資格を不要に再発行する問題を先行テストで再現して修正 |
| 複数回収 | 未成立TURN資格の失効をroom上限内で並行化。API遅延を端末数だけ加算しないことを先行テストで検証 |
| App | DiagnosticsのNetworkへ共通reportを表示。古いreport、未取得、切断後を区別 |
| 費用 | TURNは既定無効。短期資格・参加者秒はbyte課金の硬い上限ではない。公開abuse・実請求監視は残る |
| 未確認 | 実Cloudflare、制限回線、実TURNの長時間更新・失効反映、実機音響・ロック・Bluetooth |

## 根拠と再実行

Cloudflareの[資格生成・失効・更新](https://developers.cloudflare.com/realtime/turn/generate-credentials/)を確認。長期秘密はWorkerのみ、端末は短期iceServersだけ受け取る。Apple HIGのAccessibility / Layout / SF Symbolsを確認し、Diagnosticsは既存GroupBoxと標準Textで表示する。

| 検査 | 証跡 |
|---|---|
| RTCの先行失敗 | /private/tmp/rtc-diagnostics-red.log、rtc-turn-red.log、rtc-reconnect-red.log |
| RTC本体 | /private/tmp/rtc-network-final.log：初回51件成功、native2件成功。競合修正後は /private/tmp/rtc-network-regression.log でRTC52件・native2件の全体回帰成功 |
| Worker | 型検査 /private/tmp/turn-cleanup-types.log。並行回収追加後16件成功 /private/tmp/turn-cleanup-green.log。先行失敗 /private/tmp/turn-cleanup-red.log |
| Swift–Workerペア | /private/tmp/turn-pair.log：HTTP/WS・lease継続・再参加が成功。外部SFUはmock |
| Appの先行失敗 | /private/tmp/rtc-app-red.xcresult |
| macOS App単体 | /private/tmp/rtc-app-green.xcresult：63テスト成功（パラメータ展開後66回）。失敗・skipなし |
| iOS Simulator UI | /private/tmp/rtc-network-ios-ui/ios-tests.xcresult：4件成功、失敗・skipなし。iPhone 17 Pro / iOS 26.4.1。文字拡大・ダーク表示のNetwork到達、設定・接続操作、起動を確認 |
| 文書・検証基盤 | /private/tmp/rtc-network-scripts/results.tsv。全段階exit 0。リンク・到達性・空階層・設定とスクリプト回帰17件成功 |

再実行は `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path RideIntercom/packages/RTC`、`npm --prefix server run type-check`、`npm --prefix server test`、`npm --prefix server run test:pair`。App/UIと文書・開発設定は` scripts/validate.sh `の対応modeを使う。


Appの再実行例:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project RideIntercom.xcodeproj -scheme RideIntercom \
  -destination 'platform=macOS,arch=arm64' -only-testing:RideIntercomTests \
  -derivedDataPath /private/tmp/rtc-app-validation/DerivedData \
  -resultBundlePath /private/tmp/rtc-app-rerun.xcresult
VALIDATION_DIR=/private/tmp/rtc-network-ui-rerun scripts/validate.sh ios-ui
VALIDATION_DIR=/private/tmp/rtc-network-scripts-rerun scripts/validate.sh scripts
```

結果ディレクトリは毎回新しい名前を使う。ツールチェーン・依存版・Simulator IDは各validationディレクトリのenvironment.txt / simulator-id.txt、UI操作の添付はxcresultへ保存する。`/private/tmp`の証跡は一時保存であり、必要なら別途保存する。この変更で全9パッケージを再実行したとは扱わない。音声系の既存結果は各履歴を参照する。

ツールチェーンはXcode 27.1 (27A9275)、Swift 6.4、macOS 27.0.1、Node 26.12.0 / npm 11.20.0。今回依存版の更新はない。XcodeのAppIntents metadata extraction skipped警告とSimulatorのSDK build記録診断が残るが、コンパイル・テストは成功。警告ゼロとは記録しない。UI添付画面でNetworkの折返し・スクロール到達を確認した。実機VoiceOver操作や全サイズの表示確認を代替しない。
