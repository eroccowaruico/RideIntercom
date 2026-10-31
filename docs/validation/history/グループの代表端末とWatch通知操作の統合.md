# グループの代表端末とWatch通知操作の統合

2026-10-31、`2d90250d6028d31743d0e4f0668356b1a7fbf57d`のAppへ、通常グループの代表端末とWatchからの呼出し・通知応答を統合した。App／package／serverの変更工程を分け、先行したWebRTCの配置修正と固定通知categoryを利用する。実機とMacのロック解除を使わず、自動検証可能な範囲を確認した。

## 同時に揃えた境界

| 対象 | 最終実装 |
|---|---|
| 人数と端末 | 確認済み本人ごとに通常グループへ代表1台を保存する。本人未確認のLocalはmember IDで区別。旧代表が有効な参加中は維持し、離脱後は新しいchallengeで確認した別端末へ交換する |
| 満員時 | 独立レビューで、プロフィール候補の7端末制限がID順で継続代表を落とす不具合を検出。継続する同membershipの確認済み代表を優先し、通常グループの一時候補を14端末とした。人数上限8人は変えない |
| 保存と音声 | 交換時にgroup ID・秘密鍵・呼び名・自分の位置・24時間起点を保持。保存失敗なら旧保存を残し、新端末の音声を許可しない。共通の代表参加者集合を音声・利用権・完全終話・表示・直近通話へ使う |
| 関係の範囲 | グループ参加だけではSavedUser・その端末鍵・通知許可を増やさない。本人principalで既存の直接相手の名前を参照し、一覧からの削除後もグループと通話を残す |
| Watch呼出し | 保存相手の現在の用途別許可だけを投影し、明示操作をiPhoneの既存notifications.sendへ渡す。受付を配送成功や通話成立と表示せず、現在requestIDだけ取消できる |
| 通知応答 | iOSへ固定categoryと「iPhoneで応答」の背景actionを登録。受信ON、期限、取消、直接相手、現在ログインを共通処理で再確認し、別通話を勝手に切り替えない。Watch本体の通常tap・Watch音声とは区別する |

代表交換の[先行440件](通常グループの代表端末検証.md)と候補選択の追加3件、Watchの[関連63件](../README.md#watchからの呼出しとiphoneでの通知応答)を統合した。候補選択は先に追加2件の失敗を再現し、修正後に対象12件を成功させた。旧membershipの証明再利用も拒否する。各先行結果は統合後の試験と区別して残す。

## 統合後の検証

最終証跡の集約先は`.validation/group-watch-delivery`、元のxcresult等は同フォルダーの`evidence-locations.json`で対応付ける。通話エンジンはfixtureを使い、実サービス資格を注入していない。

| 検証 | 結果と範囲 |
|---|---|
| Mac App | 全448件成功。失敗・skip・runtime warningなし |
| iOS App | 単体442件成功。初回の通常UI20件中4件の失敗は、下記の探索修正と関連再実行で解消 |
| iPhone UI | 通常20件の全ケースに成功結果がある。初回の他class 7件、関連class再実行11件、Adaptive再実行1件、最終RecoveryWorkflow 1件を対応付ける。最終sourceで全20件を一括再実行した結果とは区別する |
| 破損保存の復旧 | fixture準備→UI 1件→保存内容照合が成功。破損データを消さずに回復し、現在のschema 8を検証 |
| iPad UI | 英語・日本語の各1件成功。対象Simulatorは専用leaseを使い、終了後shutdown |
| unsigned Release | macOSのApp／Widgetと、iOS SimulatorのApp／Widget／Watchをbuild。埋込版番号一致、APNs production、開発用接続資格なし、対応端末family、権限文言とWatch iconを確認。署名／実機配布の受入とはしない |
| 復旧fixtureの単体 | schema 8の正常値が旧検査で拒否され、旧schema 4が受理されるREDを再現。4・7・9、非空group、不正usersを拒否する検査へ更新し、Python scripts全99件成功 |
| 入力 | 各App検証の389入力がbefore／after一致。古いMac／iOS結果から後で変えたのはUI探索1ファイル、復旧fixtureと試験の2ファイル、辞書順を戻したcatalog 2ファイル。App処理は不変。catalogはJSONの意味と元の試験時byte列を再構成したSHA-256を照合 |

UIの初回失敗は、大きな文字のFormで説明欄が長くなり、従来の固定回数swipeで操作対象へ届かなかったためである。設定画面へ入る処理と対象までスクロールする処理を分け、対象のframeとviewportで方向を決めた。その再実行ではAdaptive sheetの未生成Saveのframe参照と、装飾headerへ`isHittable`を要求する誤りを検出して修正した。最後に説明文にも同じ可視範囲判定を適用し、RecoveryWorkflowと破損復旧を成功させた。失敗のxcresult・画面・探索結果を保持し、Appの設定項目を減らしてテストを通していない。

UI buildの一部では、AppIntentsを使わないtest／Watch targetに対するXcodeの`Metadata extraction skipped, no AppIntents.framework dependency found`警告が残る。これをruntime warningやAppのコンパイル警告と混同せず、無警告の全工程成功とは記録しない。通常UIの未成功ケースは残っていない。

## 共通基盤のheadless回帰

`2d90250d`の隔離worktreeで`validate.sh headless`を1回実行した。22工程のうち20成功、次の2工程は失敗のまま残した。全体exit codeは1であり、全体ゲート成功とは扱わない。統合前のpackage/server/script 174入力と照合した。その後に変更した復旧fixtureとその試験の2入力はApp統合側で再検証し、headlessの結果へ混ぜない。この工程に新しいApp変更を含むとは記載しない。

| 工程 | 結果 |
|---|---|
| AudioCore／Codec | 14件／35件成功 |
| DynamicsProcessor／PeakLimiter／SoundIsolation／VADGate | 5件／5件／8件／11件成功 |
| RTC | ローカル92件＋native WebRTC 4件成功 |
| Worker／Swift–Worker pair | 74件／1件成功。Miniflareと代替providerを使用し、実Cloudflareへ接続していない |
| 検証スクリプト | Python 98件、Cloudflare用4件成功 |
| AudioMixer | `RealtimeRenderBoundaryTests.testAdaptivePlayerPreparesItsClockBeforeTheFirstUtterance`からmainMixerNode／CoreAudio RPC待機。122.735秒で所有stageを限定終了（-15） |
| SessionManager | `OutputDeviceFormatTests.testOutputReportsTheRunningDeviceRatherThanTheProvisionalGraphFormat`からmainMixerNode／AudioDeviceCreateIOProcID待機。60.821秒で所有stageを限定終了（-15） |

停止した2工程のsampleと終了理由を保持し、Swift親と独立process groupのXCTest子を、PIDと専用実行pathを照合して回収した。550入力のbefore/after一致、所有process残存0、隔離treeのGit差分なしを確認。元cacheは変更せずAPFS cloneを再利用した際、元の絶対pathを無視するstale-file warningが812行発生し、記録している。これはwarningなしのclean buildではない。SDK／品質判定を緩めたり、OSサービスを再起動したり、同じ試行を反復したりしていない。

既存の独立audio E2Eも、ViewModel生成より前のmainMixerNode／HALC待機で測定を開始できていない。今回のpackage側の停止はこの境界に一致するが、OS故障やMacロックが原因と確定する証拠ではない。基盤の成功した試験やApp fixtureを、実音声測定の成功に置き換えない。

## 残る受入

Mac音声サービスが利用可能になった後、同一の確定sourceで停止した2 package工程と独立duplex E2Eを確認する。実Apple認証・署名profile・App Group・APNs・Watch転送／背景起動・実機音声と無線・電力は引き続き別の受入である。Watch自身の音声とCarPlayのWidgetボタン操作は後続へ残し、今回のiPhone操作だけで代替しない。電話型通話を求めないとの確認によりCallKit試作は未統合で停止した。CarPlayは専用VoIP方式でなくWidget操作の条件で進める。[未確認事項](../未確認事項.md)と[CarPlay Widgetの実行条件](../../backlog/機能拡張の実装前整理.md#carplay-widgetのボタン操作とcallkit不採用)を参照する。
