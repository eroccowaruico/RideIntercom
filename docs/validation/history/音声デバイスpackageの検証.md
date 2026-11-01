# 音声デバイスpackageの検証

2026-11-01。Watch音声をApp固有のcodec・媒体処理から分離し、SessionManagerの既存backend契約で交換できるAudioDeviceを追加した。App追従前のpackage単独検証を記録する。

| 範囲 | 結果 |
|---|---|
| SessionManager | Swift Testing 66件とXCTest 1件成功。native出力変換、非同期session、停止とscheduleの競合、native停止失敗後の再試行を含む |
| AudioDevice / Mac | 9件成功。双方向の暗号化AAC、元形式、明示bitrate、部分音声破棄、無音抑止、停止・取消、復旧時gate閉鎖を確認 |
| iOS / watchOS SDK | 両build成功、compiler warning 0 |
| Watch Simulator | watchOS 27.2、Apple Watch Series 12 46mmで標準xcodebuild testを実行。9件成功（引数別13実行）、skip・runtime warning 0。AppIntents metadata省略のtool warning 1件は保持 |
| 所有端末の終了 | 専用WatchとiPhoneの両方をShutdown。既存の他端末・ペアを操作しない |
| 入力の照合 | source hashはすべて一致。実行中に外部のskill追加commitが入り、HEADを含む厳密な一致stageは失敗のまま保持。source変更なしを別に記録 |

証跡は`.validation/audio-device-package-20261101/final/`。`input-boundary.json`と`watch-summary.json`、nativeログ、cleanup結果を保持した。元のHEADは`adea0a73`、終了時HEADは`0013462e`。HEADだけの相違をsource一致の結果へ書き換えていない。

初回点検ではcodecと端末媒体の差し替え境界を整理し、再点検ではrendererのschedule／stopの競合と停止失敗後の再試行を修正した。二重のmix・VAD・通話sessionを追加していない。Appへの接続、WatchConnectivityの実配送、実Watchの背景・ロック中の開始・無線・電池はこのpackage試験の保証範囲に含めない。
