# RideIntercom

## 開発を始める

| 開発環境 | このcheckoutで開くファイル | 実行 |
|---|---|---|
| Xcode | `RideIntercom.xcodeproj` | 共有scheme `RideIntercom`、My MacまたはiOS Simulator |
| VS Code | `RideIntercom.code-workspace` | `Tasks: Run Task` → `RideIntercom: …` |

[Xcode / VS Codeの開発環境](docs/development/開発環境.md)に、ファイル自動同期、package編集、ビルド・テスト・デバッグ、表示されない場合の確認方法を記載する。

## 要求と作り方を分けて読む

| 区分 | 正本 |
|---|---|
| アプリが満たすこと | [製品要求](docs/requirements/製品要求.md)、[未解決のパッケージ改善要求](docs/requirements/パッケージ改善要求.md) |
| 開発の制約 | [開発方針](docs/policies/開発方針.md) |
| 文書・計画の作り方 | [文書作成規約](docs/policies/文書作成規約.md) |
| ログ実装の制約 | [ログ記録規約](docs/policies/ログ記録規約.md) |
| 現行構造と仕様 | [アーキテクチャ](docs/spec/アーキテクチャ.md)と対応するApp/package/server仕様 |

再実行可能な検証入口は[自動検証](docs/development/自動検証.md)を参照する。

AI開発ツールの入口は[AGENTS.md](AGENTS.md)、[CLAUDE.md](CLAUDE.md)、[Copilot instructions](.github/copilot-instructions.md)。すべて同じ規約を参照する。

## ドキュメント

[文書全体の案内](docs/README.md)から、要求・アーキテクチャ・App/package/server仕様・利用マニュアル・開発手順・検証状況へ進める。
