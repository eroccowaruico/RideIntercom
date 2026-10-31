# Widget・通話状態表示と共通採番のローカル検証

2026-10-31、71527487を基準とする独立worktreeで[システム表示と通話操作](../../spec/App/システム表示と通話操作.md)を実装した。Watch targetのbuild入力は別担当の共有DTO・Watch sourceを合流し、Watch機能そのものの試験結果は別記録とした。

| 対象 | 条件と結果 |
|---|---|
| TDD | 実装前の新規testのcompile失敗を`system-surfaces-red`へ保存。表示ON/OFF・前面制約・同値抑止・消去後再生成防止・失敗・遅延開始・古い終了・設定保存・サインアウトを新規8件で確認 |
| App全体 | macOS343件成功、失敗・skip・runtime/compiler warningなし。`.validation/system-surfaces-final`。元の335件に8件を追加した構成で、後続統合HEADの件数ではない |
| ソースと資源 | 最終macOS試験の入力before/after一致。専用DerivedData、隔離保存先、所有test host回収。Simulatorは起動せず、実機・Apple・実通知には接続していない |
| SDKをまたぐ採番 | 初回はiOS/Watch SDKごとのaggregate評価で同一出力競合となり失敗。採番targetをmacOS host専用へ固定して解消。PROJECT_TEMP_DIRの予約を3productから共有 |
| 実buildと増分 | generic iOS Simulator App build成功。App／埋込Widget／埋込WatchのCFBundleVersionはすべて24、次の増分buildですべて25。projectの増分は各1、予約ログも各1。`.validation/system-surfaces-ios`のversions-first.json・versions-incremental.jsonと各build log |
| script | 採番18件成功。別予約との並行、消費時の巻戻し禁止、欠落・未来予約の拒否、extensionへの開発資格不混入、失敗後の番号継続を含む |
| 工具warning | generic buildのAppIntentsを持たないWatch targetでmetadata extraction skippedの工具warningを記録。Widget/AppのIntent metadataは生成済み |

端末認証・OS経由のWidget/Control/App手渡し、実Live Activityのロック画面・Dynamic Island・8時間終了、配布署名・portal設定は確認していない。OS認証で初期化前に停止した既知のIPC試験を反復せず、unitの成功で代用しない。package・server・独立音声E2Eはこの工程で変更／再実行していない。

## 特定通話先Widgetの追加

同じworktreeの先行patchを保全し、追加差分だけを作成した。選択用App Group投影、query、App再解決を5件で検証し、macOS App全348件成功、skip・runtime/compiler warningなし。`.validation/widget-destinations-delivery`に入力一致と所有host回収を含む結果を保存した。先行343件へ5件を追加した構成で、rootの統合HEADの件数ではない。

| 境界 | 確認した内容 |
|---|---|
| TDD | 未実装APIのcompile失敗をwidget-destinations-redへ保存。破損後に一覧が同値だと復旧しない不具合をwidget-corruption-redで再現し、現在のファイル内容も照合して再公開する修正で成功 |
| データ最小化 | JSONはversion/destinationsのみ、各候補はid/name/kindのみ。group内だけの相手は投影しない |
| 古い選択 | 名前変更は現在の名前へ解決、削除・空投影・破損では古い名前へfallbackしない。別アカウントのIDや削除した対象の開始を拒否 |
| 通話との独立 | 他の進行中通話へ切り替えない。保存ユーザー削除後も成立中の通話を維持し、共通の終了操作を許す |
| 保存と復帰 | 成功済み同値ではreloadなし。破損と書込失敗から再公開可能。サインアウトで投影を空にし、旧VMの再ログインで候補を復活させない |

実App Groupの署名・containerのOS保護・Widget追加と実IPCは別受入とした。テスト用containerは一時ファイルへ注入し、実利用データ・portal・profileを変更していない。

追加後のgeneric iOS Simulator buildも成功し、App／埋込Widget／埋込Watchは同じ番号33、予約1回を確認した（`.validation/widget-destinations-ios`）。Simulator起動やOS経由のWidget実行は行っていない。
