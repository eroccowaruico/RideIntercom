# iPhone間の音声途切れと受信待ちの学習

## 依頼と引継ぎの位置

2026-11-03、利用者から「iPhone実機同士で試すと音声が完全にブツブツに切れるので、理由を調べて直して」と依頼された。条件は両端末が同じWi-Fiに接続した状態。利用者は、過去に原因を一つずつ自動テスト付きで直し、iPhone同士の自動テストは全codecで通り、実機も問題なかったと指摘した。本書は作業の区切りの引継ぎであり、実機での受入は済んでいない。続きは[実機確認待ち](../実機確認待ち.md)の「iPhone同士で報告された音声の途切れ」行と、[バックログ](../../backlog/リアルタイム会話の遅延と連続性改善.md#送信側で欠けるpcm16-16khz)から再開する。

## iPhone音声E2Eが止まっていた原因

2026-11-01以降、iPhone Simulatorのnative入力が0Hzとなり、音声E2Eは測定前に失敗していた。利用者の言う全codec合格はこれより前の結果で、11/1〜11/2のWatch対応で入った音声変更はiPhone音声E2Eを通っていなかった。

原因はMacの機器構成だった。既定入力（Elgato Wave:3、48kHz）と既定出力（Studio Displayのスピーカー、96kHz・8ch）が別機器のとき、systemDefaultに従う専用Simulatorの入力が0Hzとなる。`AudioDuplexIO.prepare`をテストへ加えても解消しなかった。`scripts/audio_e2e.py`がロック取得後に、入出力を持つ48kHzのhost機器（既定入力を優先）へ専用Simulatorを固定し、終了時に元へ戻すようにした（`9384c86e`）。該当機器が一意に決まらなければ測定前に失敗する。

## 実機の途切れの原因と修正

受信のadaptive再生は2msの開始待機から始め、遅れたpacketが来ると待ちを伸ばすが、無音中・省略無音からの復帰ごとに2msへ戻していた。既存試験もそれを要求していた。iPhone間のWi-Fiでは同じ相手のpacketが数十ms保持され、まとめて届くことが繰り返される。そのため発話を再開するたびに、次の停止で音が欠ける。自動化の揺れは最大4ms程度で、この条件を試していなかった。

利用者の承認（揺れの分を覚えておく）を受け、AudioMixerの`MixerPCMSource`を次のように変更した。契約の正本は[AudioMixer仕様](../../spec/packages/Audio/AudioMixer.md)と[App設定](../../spec/App/Configuration/Bindings/Audio/AudioMixer.md)。

| 変更 | commit | 理由・観測 |
|---|---|---|
| 期限切れpacketの余分な到着時間を相手ごとに学習し、会話の間でも保つ。10秒保持後に1秒10msで解放 | `fb1d5524` | 0.5秒ごと60ms停止の試験で、修正前は4発話で5回欠落。修正後は最初の発話の学習中だけ |
| 到着を描画位置でなく単調到着時刻（`schedule(_:packetizationJitter:arrivedAt:)`）で測る | `e07a7359` | 描画位置で測ると出力mute／復帰の時計変化を揺れと誤学習し、E2Eで通信16〜23msに対し待ち156〜162ms |
| 待ち上限以上の余分な到着時間（開始時の滞留など）は学習しない | `c8155c55` | 500ms滞留後も待ちが35ms以下へ戻ることを試験 |
| 学習量は余分な到着時間＋2 packet | `3bd507f7`（1 packetの`8c9e0488`を戻した） | 1 packetではE2EのMac受信AACに受信段の欠落1.1%が残った |
| sourceの停止・再開でも学習値を保つ | `f47dc6ff` | 入出力の切替ごとに学習をやり直して欠落していた |
| 通話の受信窓は0.12秒のまま（学習は最大約59ms） | `3577537d`で0.3秒にし、`0fd3cec7`で戻した | 0.3秒では出力時計の開始前に溜まった最大0.3秒の待ちが通話中に残った（iPhone受信AACで401ms） |

## 検証結果

| 検証 | 結果 |
|---|---|
| AudioMixer package | 71件成功。無線停止、揺れのない回線、描画時計の飛び、滞留、停止・再開を含む |
| App単体（macOS） | 619件中618件成功。失敗は以前からの`LocalStoreKitTests.wrongProductTypeAndUnverifiedCompletionNeverFinish`。`LocalStoreKitTests`本体は40分停止したため除外して再実行 |
| iOS単独realtime（固定後、修正前） | `.validation/audio-e2e-20261103-170750-798816`。9条件で連続性・同一性の失敗なし。遅延は計測余裕込み136〜142msで125ms基準超過 |
| Local quick（修正前） | `.validation/audio-e2e-20261103-171259-918553`。既定は欠落0。Opus 24kHzのMac受信で受信段0.7%（最長50ms）、PCM16 16kHzで復号直後から欠落 |
| 両経路quick（2 packet・上限0.12秒） | `.validation/audio-e2e-20261103-231635-932221`（Local）は受信段の欠落が全条件0。既定の遅延108〜116ms。Opusは欠落0だが遅延124〜142msで基準超過 |
| 両経路quick（停止・再開保持の前） | `.validation/audio-e2e-20261103-232709-798065`。Mac受信の既定で受信段0.97%（最長40ms）。iOS受信のLocalは全条件で受信0の接続不成立が混在。実行中にWatch schemeが外部から書き換わりsource-stabilityも失敗 |

`f47dc6ff`以降の最終E2Eは、別sessionが音声E2Eのロックを保持していたため未実行である。実機・実無線での受入も未実施。

## 残る課題

| 課題 | 状態と次の一手 |
|---|---|
| 実機受入 | 同じWi-Fiの2台で発話・間・再開を繰り返し、最初の発話以降に途切れがないこと、DiagnosticsのRXでreset・adjustmentが会話ごとに増えないことを確認する |
| 最終E2E | `python3 scripts/audio_e2e.py --matrix quick`を再実行し、受信段（mixed）の欠落0と既定の遅延を確認する |
| Opusの遅延 | Mac側の約12msの到着揺れを学習した分だけ基準を超える。承認済みの方針どおりの増加として扱うか、学習量・基準を見直すかは未決定 |
| PCM16 16kHz・出力復帰後の送信側欠落 | 復号直後から0.3〜1.8%欠ける。受信の学習とは独立。[バックログ](../../backlog/リアルタイム会話の遅延と連続性改善.md#送信側で欠けるpcm16-16khz) |
| 約59msを超える無線停止 | 受信窓0.12秒では吸収できない。広げる場合は出力時計開始前の滞留処理を先に直す |

## 作業上の注意

- 音声E2EのロックとSimulatorは他sessionと共有する。`exclusive-run: failed`は待つだけにし、他sessionの実行中にSimulatorの音声設定を変えない。
- XcodeはschemeとString Catalogを書き直し、ビルドのたびにビルド番号を進める。[開発方針](../../policies/開発方針.md#ビルドが更新する追跡ファイル)どおり別commitで取り込む。
- 古いcommitを別worktreeでビルドすると、ローカルpackageが「Folder」として開かれ`Missing package product`で失敗した。二分探索は今回は行っていない。
- 2026-11-04の区切りで本作業のworktree（二分探索用）は削除済み、作成したbranchはない。他sessionの`design/tabbar-tests`と関連worktreeは稼働中のため残した。

## 残したworktreeとbranchの引継ぎ

2026-11-04 08:06時点。本作業で作ったworktree（`43e7b7c5`の二分探索用）は削除済みで、作ったbranchはない。以下は別session（scratchpad `c8f99b3e-…`）のもので、同sessionのxcodebuildが07:16から実行中、`wt9`のファイルも07:45に更新されていたため削除していない。中身は変更せず、時点の差分だけを`.validation/worktree-handoff-20261104/`（Git管理外）へ写した。稼働中のため、引き継ぐ時点で差分を取り直す。

| 対象 | HEAD | 未コミット（08:06） | 保全ファイル | 引継ぎ |
|---|---|---|---|---|
| worktree `wt8`（detached） | `9b1c1668`（main祖先） | `project.pbxproj`のビルド番号577→578だけ | `wt8.patch`（SHA-256 `a1d723b6…0ba1`）、`wt8.status.txt` | mainは既に578以上へ進んでいるため取り込み不要。同sessionの終了後に削除できる |
| worktree `wt9`／branch `design/tabbar-tests` | `9b1c1668`（main祖先、branch固有のcommitなし） | `SignedInContentView.swift`からiOSの`tabBarMinimizeBehavior(.onScrollDown)`を外し、[Call仕様](../../spec/App/UI/Call.md)の該当記述を削る作業中 | `wt9.patch`（SHA-256 `92f63c77…86f9`）、`wt9.status.txt` | 未検証の作業途中。採否は同sessionの結論、または利用者の判断を待つ。採用する場合はmainへ統合後にbranchとworktreeを削除する |
| branch `preview`（ローカルとorigin） | `b6423d00` | なし | なし | 開発用Cloudflare設定の固定preview用。mainへ統合済み（`main..preview`は0件）。[Cloudflare試用手順](../../development/Cloudflare試用手順.md#固定プレビューの継続運用)の運用branchのため残す |

2026-11-04、`wt8`・`wt9`の持ち主のsessionが、`wt9`の作業（`tabBarMinimizeBehavior`を外す）をmainへ統合したうえで両worktreeとbranch `design/tabbar-tests`を削除した（[2026-11-04の区切りと引継ぎ](画面デザインと録音操作の整理.md#2026-11-04の区切りと引継ぎ)）。未追跡ファイルは両worktreeとも0件。削除するときは`git worktree list`で稼働を確認し、未コミット差分があれば先に保全ファイルと照合する。
