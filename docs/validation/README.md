# 検証状況と証跡

## 結果を読む基準

| 区分 | 意味 |
|---|---|
| 実装済み | sourceと現行仕様に存在する。成功・実機確認を意味しない |
| 自動検証済み | 指定された版・条件・コマンドで成功。現行HEADでの再実行と過去記録を区別 |
| 実サービス未確認 | 実Cloudflare SFU / TURN / 請求をローカルfixtureで保証しない |
| 実機未確認 | Mac/iPhoneの音響、無線、10分、ロック、Bluetooth/有線は別途 |
| 未対応 | 必要なAPI・UI・運用がまだない。マニュアルに操作可能と書かない |

## 領域別の受け入れ

| 領域 | 自動検証・記録 | 残件 |
|---|---|---|
| package / RTC / native | [混在通話と共通音声](history/混在通話検証.md) | 実無線 / 実SFU。旧per-route API整理は未完了。通信診断は[追加検証](history/通信診断とTURN資格検証.md)を参照 |
| Worker / Swiftペア / 費用 | 同記録、[初回Cloudflare記録](history/Cloudflare検証.md)、[Cost](../spec/server/Cost.md) | 実TURN・制限回線、公開identity・abuse、実請求監視 |
| App / UI | [通信診断](history/通信診断とTURN資格検証.md)、[音声エフェクト](history/音声エフェクト接続検証.md)、[品質点検](history/品質点検.md)、[混在通話](history/混在通話検証.md) | 実機、VoiceOver実操作、Mac/iPad各サイズ |
| 開発環境 | [Xcode / VS Code](../development/開発環境.md) | エディタ画面での新規・隠しファイル表示は利用者指定で後続 |
| 文書整合とログ修正 | [文書整理記録](文書整理記録.md) | 機械検査は文章の意味・全APIの網羅性を保証しない |
| 要求と規約の分離・名前と空階層 | [要求構造整理記録](history/要求構造整理記録.md) | 製品要求と開発規約の意味的な整合は変更ごとにレビューする |

## 再実行

[自動検証](../development/自動検証.md)を入口とする。`scripts/validate.sh`は実行ごとのenvironment / logs / results.tsv / xcresultを保持し、一部の失敗を全体成功にしない。`/private/tmp`内の過去証跡は永続保存ではない。
