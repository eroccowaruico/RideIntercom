# 検証状況と証跡

## 結果を読む基準

| 区分 | 意味 |
|---|---|
| 実装済み | sourceと現行仕様に存在する。成功・実機確認を意味しない |
| 自動検証済み | 指定された版・条件・コマンドで成功。現行HEADでの再実行と過去記録を区別 |
| 実サービス未確認 | 実Cloudflare SFU / TURN / 請求をローカルfixtureで保証しない |
| 実機未確認 | Mac/iPhoneの音響、無線、10分、ロック、Bluetooth/有線は別途 |
| 未対応 | 必要なAPI・UI・運用がまだない。マニュアルに操作可能と書かない |

## 現在の確認と記録

[未確認事項](未確認事項.md)に確認待ちと条件、[自動検証範囲](自動検証範囲.md)にテストの担当範囲をまとめる。未実装作業は[課題](../backlog/README.md)へ分ける。

| 領域 | 記録 |
|---|---|
| 全体監査・ローカル基盤 | [全体敵対的レビュー・修正・残存リスク](history/全体敵対的レビュー.md)、[全ファイルの調査台帳](history/全体監査ファイル台帳.json) |
| 責務分解・保存復旧・待機制御 | [変更・検証・残存リスク](history/責務分解と保存復旧.md)、[既存テストの移動対応](history/責務分解テスト対応.json) |
| 不要コードと全回帰 | [整理・不具合修正・要求とのテスト対応](history/不要コード整理と回帰検証.md) |
| RTC / native / App / TURN | [通信診断とTURN](history/通信診断とTURN資格検証.md)、[混在通話](history/混在通話検証.md) |
| Worker / Swiftペア / 費用 | [Cloudflare](history/Cloudflare検証.md)、[品質点検](history/品質点検.md)、[費用試算](../development/Cloudflare費用試算.md) |
| 音声・UI | [音声エフェクト](history/音声エフェクト接続検証.md)、[混在通話](history/混在通話検証.md) |
| 開発環境 | [構造検査の記録](history/文書役割分離記録.md) |
| 文書・ログ整合 | [文書整理](文書整理記録.md)、[要求構造整理](history/要求構造整理記録.md)、[役割分離](history/文書役割分離記録.md) |

## 再実行

[自動検証](../development/自動検証.md)を入口とする。`scripts/validate.sh`は実行ごとのenvironment / logs / results.tsv / xcresultを保持し、一部の失敗を全体成功にしない。`/private/tmp`内の過去証跡は永続保存ではない。
