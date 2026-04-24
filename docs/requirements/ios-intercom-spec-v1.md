# iOS インカムアプリ 企画書

## 目的

本書は初期構想を残しつつ、現行実装との差分を明示するための要求整理資料である。  
現行実装の正本は `docs/spec` を参照する。

## 初期構想として妥当な要求

| 要求 | 現状 |
|---|---|
| 音楽を聴きながら通話できる | 実装済み。通話セッションは `mixWithOthers` を使用 |
| 2〜6 名の同時通話 | 実装済み。`maximumMemberCount == 6` |
| 近距離は MultipeerConnectivity を利用 | 実装済み |
| Local 切断時は Internet へ移行 | 実装済み |
| Internet から Local へ自動復帰する | 実装済み。probe/handover あり |
| 起動後にグループ選択または新規作成できる | 実装済み |
| 同一グループだけ接続できる | 実装済み。groupHash と handshake で制御 |
| 招待 URL を共有して参加できる | 実装済み |
| 常時開通に近い同時通話体験 | 実装済み |
| 無音時は VAD で送信抑制する | 実装済み |

## 初期構想から削れた、または未実装の要求

| 初期構想 | 現状 |
|---|---|
| 過去接続メンバーを選んで任意構成のグループを作る | 未実装。新規作成は `Talk Group` 固定、ローカルメンバー 1 名のみ |
| AirDrop, QR, Intent など複数招待方式を持つ | 未実装。`ShareLink` による URL 共有のみ |
| Owner 選出と調停ロジック | 未実装 |
| codec を自由に切り替える | UI は残るが実送信は PCM 固定 |
| 最大 6 枠の固定カード UI | 未実装。現行はリモート参加者分だけ縦カードを並べる |

## 現行実装の要求要約

### 画面

| 項目 | 現行仕様 |
|---|---|
| タブ | Call / Diagnostics / Settings |
| グループ作成 | `Create Talk Group` のみ |
| グループ削除 | 一覧行の swipe / context menu |
| 参加者削除 | 通話画面の参加者カードから削除 |
| 招待 | 通話画面の `Invite` ボタンで共有 |

### 通信

| 項目 | 現行仕様 |
|---|---|
| Local | MultipeerConnectivity |
| Internet | 現行は未実装。将来 WebRTCInternetRoute として追加予定 |
| 認証 | group secret ベースの HMAC |
| 暗号化 | Local 音声 payload は AES-GCM |

### 音声

| 項目 | 現行仕様 |
|---|---|
| 入力 | AVAudioEngine tap + 16kHz 変換 |
| VAD | `idle/attack/talking/release` |
| 出力 | 参加者別出力 + マスター出力 |
| Audio Check | 5 秒録音 + 5 秒再生 |

## 今後の要求候補

| 優先度 | 候補 |
|---|---|
| 高 | グループ名編集、メンバー名編集、任意メンバー追加 UI |
| 高 | 招待受理 UI の明示化と失敗ハンドリング改善 |
| 中 | QR 招待、AirDrop 専用導線 |
| 中 | codec 選択 UI の再有効化 |
| 中 | Owner/調停ロジック |
| 低 | グループ履歴の richer 管理 |

## 参照先

| 領域 | 正本 |
|---|---|
| UI | `docs/spec/画面項目定義.md` |
| 状態遷移 | `docs/spec/画面・状態遷移.md` |
| 通信 | `docs/spec/通信仕様.md` |
| 音声 | `docs/spec/音声処理仕様.md` |
| 設定 | `docs/spec/設定値一覧.md` |
