# App から package への要望と現状の回避

本ドキュメントは解決済みの内容を残さないこと。
パッケージ更新時はこのドキュメントを参照して、App 側で回避している内容が解消されているか確認すること。
パッケージ更新時は本ドキュメントを編集や更新を一切しないこと。

## 目的

本書は、App 側で見つかった package の不足責務だけを記録する。

App を作り直す前提では、App 側の暫定実装や既存コードの棚卸しは本書に残さない。`docs/spec/packages` の仕様で吸収すべき不足が見つかった場合だけ、package 要求として追記する。

## 現在の package 要求

| 状態 | 内容 |
|---|---|
| 追加要求 | なし |
| 解決済み | `d54673f58d7769d017edd8bc751d3aa0f4fb5a9a` の SessionManager / RTC / AudioCore API を App 実装へ反映済み。App 側で package 不足として残す内容はない |

## 追記ルール

| 記録する項目 | 内容 |
|---|---|
| package | 変更対象 package |
| 不足している責務 | App ではなく package が持つべき責務 |
| App に暫定実装しない理由 | package 独立性、OS差分吸収、準異常系処理、runtime 情報通知、設定受け取りのどれに関わるか |
| App から消す条件 | どの package API / runtime event / report があれば App が同一呼び出しで使えるか |

## App 作り直し時の扱い

| 項目 | 方針 |
|---|---|
| App 側暫定実装 | 作り直し前の都合として扱い、本書には残さない |
| package に既にある責務 | `docs/spec/packages` と `docs/spec/App/setting parameters/packages` を参照し、App 仕様へ重複定義しない |
| 新しい不足の判断 | App が OS 差分、継続可能な準異常系、runtime report/event、設定受け取りを自前で補う必要が出た場合だけ追記する |
