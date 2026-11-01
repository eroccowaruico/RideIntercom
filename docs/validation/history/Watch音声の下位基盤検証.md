# Watch音声の下位基盤検証

2026-11-01。基準commit `6ac543876075b761eb993fa22c857b6e4a272847`にCodecとRTCのpackage差分を適用して検証した。Watch Appへの媒体接続を完了した結果ではない。Watch側AudioMixerの試作は採用せず、通話・混合・DSPはiPhoneに置く。

| 対象 | 結果と証跡 |
|---|---|
| Codec | Mac全43テスト成功。CoreMediaでAACのnative形式を取得し、ELDv2のcore rateとPCM時計の差を扱う。破損cookie拒否と従来nativeデコードとの比較を含む。`.validation/watch-codec-aac-package/` |
| Watch compile | Codecはarm64／arm64_32とテストtarget、RTCはarm64_32のSDK compile成功。実Watch実行の結果ではない |
| RTC | RTC単体104件とNative WebRTC 4件の計108件成功。うち媒体pairの新規11件。暗号化、方向、停止、順序逆転、metadata拒否を含む。`.validation/watch-device-link-package/` |
| Worker pair | ローカルfixtureによる別統合suite成功。最初の依存不足はlockfileのoffline復元後に再実行。実Cloudflareへ接続していない。`.validation/watch-device-worker-pair-retry/` |
| Mac App | 標準schemeのbuildと全App単体525テスト、parameterを含む625実行成功。失敗・skip・runtime warningなし。`.validation/watch-media-package-app-macos-retry/` |
| iOS App | 専用iPhone Simulatorでbuildと全App単体511テスト、parameterを含む611実行成功。失敗・skip・runtime warningなし。UI試験は今回の範囲外。`.validation/watch-media-package-app-ios-retry/` |
| 入力と回収 | packageの検証入力と適用後sourceを照合。App検証中のsource/configurationは自動build番号以外不変。所有Mac hostを回収し、専用Simulatorを終了 |

初回App buildは旧worktree保全データ内のproject／package再検出で失敗した。元データを検査済みtarへ保全して再実行した上記結果と区別し、初回ログも保持する。詳細は[作業領域の引継ぎ](作業領域の引継ぎと整理.md#保全データとxcodeの再検出)を参照する。

既定codec・bitrateは変更していない。Watch音声の背景開始・実媒体配送・マイク／スピーカー・電池消費・遅延を成功と扱わない。現行package契約は[Codec](../../spec/packages/Audio/Codec.md)と[RTC](../../spec/packages/RTC.md)、App接続の残作業は[Watch設計](../../backlog/機能拡張の実装前整理.md#watch音声の確定範囲と接続設計)を参照する。
