# iOS インカムアプリ 企画書

## 目的

本書は初期構想を残しつつ、現行実装との差分を明示するための要求整理資料である。  
現行実装の正本は `docs/spec` を参照する。

## 初期構想として妥当な要求

| 要求 | 現状 |
|---|---|
| 音楽を聴きながら通話できる | 実装済み。通話セッションは `mixWithOthers` を使用 |
| 2〜8 名の同時通話 | 実装済み。`maximumMemberCount == 8` |
| 近距離は MultipeerConnectivity を利用 | 実装済み |
| Local 切断時は WebRTC へ移行 | RTC経路切替は自動テスト済み。Cloudflare実サービスを跨ぐ通話の継続品質は未確認 |
| WebRTC から Local へ自動復帰する | RTCにprobe/handoverあり。Appは未使用SFUの先行接続を無効化。実サービスでの復帰は未確認 |
| 起動後にグループ選択または新規作成できる | 実装済み |
| 同一グループだけ接続できる | 実装済み。groupHash と handshake で制御 |
| 招待 URL を共有して参加できる | 実装済み |
| 常時開通に近い同時通話体験 | 実装済み |
| 無音時は VAD で送信抑制する | 実装済み |

## 初期構想から削れた、または未実装の要求

| 初期構想 | 現状 |
|---|---|
| 過去接続メンバーを選んで任意構成のグループを作る | 未実装。新規作成は `Talk Group` 固定、ローカルメンバー 1 名のみ |
| AirDrop, など共有機能での複数招待方式を持つ | |
| Owner 選出と調停ロジック | 未実装 |
| codec を自由に切り替える | UI は残るが実送信は PCM 固定 |
| 最大 8 枠の固定カード UI | 未実装。現行はリモート参加者分だけ縦カードを並べる |

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
| Internet | Cloudflare SFU用RTC/WorkerとApp設定を実装。招待制の自動検証済み経路。実アカウント接続・TURN・公開identityは未確認/未対応 |
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
| UI | `docs/spec/App/UI/画面項目定義.md` |
| 状態遷移 | `docs/spec/App/UI/画面・状態遷移.md` |
| 通信 | `docs/spec/App/通信仕様.md` |
| 音声 | `docs/spec/App/音声処理仕様.md` |
| 設定 | `docs/spec/App/setting parameters/App/設定値一覧.md` |

## Cloudflare 試用から公開への要求

| 要求 | 実装 / 残件 |
|---|---|
| 少人数で費用を抑える | SFU容量課金、SQLite DO Hibernation、個別端末資格、参加者秒の前払い枠。全課金項目は `docs/spec/server/Cost.md` |
| 手動再接続を減らす | 同一SFU sessionのlease自動更新。WS一時切断はmediaとは別に復帰 |
| 公開できる構成へ進む | SFUとWorker契約を固定し、公開登録/資格発行/失効・abuse対策を追加する。招待制registryを公開登録完成と呼ばない |
| 検証区分 | 自動検証、実Cloudflare未確認、実機未確認を分ける。実測料金で試算条件を更新 |
