# RideIntercom 要求管理

## 目的

`docs/requirements` は要求の背景と現状整理、`docs/spec` は現行実装の正本を置く。  
仕様更新時は両者の整合を取ること。

## 本ドキュメント記述ルール

| 項目 | ルール |
|---|---|
| 基本ルール | .github/copilot-instructions.md |
| 採番禁止 | ルール、要求、見出し、表の識別に採番 ID や番号を付けない |
| 表現 | 曖昧な表現を避け、実装時に判断可能な文で記述する |
| 図表優先 | 認識齟齬を防ぐため、仕様は表や図を優先して記述する |
| 文章の扱い | 背景や意図は補足として文章で説明する |

## 基本要求

| 項目 | 要求 |
|---|---|
| 要求の参照先 | 実装は `docs/requirements/requirements.md` に記載の要求を満たすこと |
| 仕様更新 | 仕様確定時には `docs/spec` を更新すること |
| 画面更新 | 画面設計確定時には画面項目定義を更新すること |

## 製品要求と受け入れ

| 利用者の要求 | 現在の対応 | 正本 / 受け入れ |
|---|---|---|
| iOS/macOSでグループ通話する | 上限8人、招待URL、LocalとInternet、中継 | [通信](../spec/App/通信仕様.md)。仮想4端末とペアは自動検証、実機8人品質は未確認 |
| グループを見比べても通話が切れない | selected / activeを分離。Connectで明示切替 | [状態遷移](../spec/App/UI/画面・状態遷移.md)、App単体試験 |
| 一部離脱・Local/Internet混在でも届く経路を維持 | 元話者IDの暗号化音声を中継し重複排除 | [RTC](../spec/packages/RTC.md)。最後の橋を失う分断は継続不能。実SFU・無線は未確認 |
| 経路にかかわらず同じ音声調整 | 共通Mixer / Codec / Effectors、個別・master音量 | [音声](../spec/App/音声処理仕様.md)、実PCM自動検証 |
| 古い音声をため込まない | unordered・再送0、bounded queue・期限・再生予約上限 | RTC / Mixer / SessionManager仕様。過負荷時の欠落を許容 |
| Bluetooth等の機器消失を分かりやすく扱う | Audio Paused、理由、Resume。接続・中継は保持 | 実機通知順・音響・ロック中継続は未確認 |
| 音楽との共存・VAD・自己録音確認 | session設定、可聴受信時duck、VAD、Audio Check | [設定と効果](../manual/設定と音声効果.md)。OS/機器で実効差あり |
| 少人数試用から公開へ進める | SFU / Worker、個別資格、利用枠、lease継続 | [Worker](../spec/server/Worker.md)、[費用](../spec/server/Cost.md)。公開identity・abuse・TURN・実請求確認は未完了 |
| 責務分離と差し替え可能性 | package単位、node / backend / route factory、共通flow | [アーキテクチャ](../spec/アーキテクチャ.md)。動的plugin loaderは対象外 |
| 自動検証を繰り返せる | package、App、UI、Worker、nativeペア、Swift-Workerペア | [自動検証](../development/自動検証.md)。実機と自動結果を区別 |
| 説明と操作が一致する | 要求 → 仕様 → source → manual → 検証をリンク | [文書案内](../README.md)。情報を保持して矛盾を修正 |

## 未達と候補を保持する方針

| 区分 | 内容 / 完了条件 |
|---|---|
| 実装が必要な残件 | TURN資格、公開identity・資格発行/失効の公開運用、abuse・請求監視、詳細RTC runtime統計 |
| 実運用で確認する残件 | Mac/iPhone招待・双方向・10分・同時発話・画面ロック・Bluetooth/有線、実SFU/TURN、実測料金 |
| UIの未確認 | VoiceOver実操作、Mac/iPadのサイズ別表示、Xcode/VS Codeの新規・隠しファイル表示 |
| 初期構想の候補 | 任意メンバー構成、名前編集、QR/AirDrop専用導線、Owner調停、履歴。既存OS ShareLinkと専用機能の実装を区別 |
| 過去要求の保存 | [初期構想と対応経緯](background/初期構想と対応経緯.md)に背景・候補を保持。現行の状態は本表・現行spec・検証記録で判断 |

## 開発環境の要求

| 項目 | 要求 |
|---|---|
| エディタ | XcodeとVS Codeの両方から同じ実ファイルを編集し、同じビルド・検証入口を使用できること |
| ファイル表示 | リポジトリのディレクトリ内のファイルを参照でき、新規ファイル・フォルダの追加にも継続的に追随すること。Git追跡済みかどうかを表示条件にしない |
| ビルド分離 | 全体を閲覧するための参照をAppのcompile / resource copyへ混入させないこと |
| 継続性 | 同期設定の削除・targetへの誤所属を自動検出すること。画面確認と構造検査を区別すること |
| 正本 | [開発環境](../development/開発環境.md)に設定、操作、検証結果と未確認事項を記載すること |

## ドキュメントの役割

| パス | 役割 |
|---|---|
| `docs/requirements/background/初期構想と対応経緯.md` | 初期構想と現行との差分整理 |
| `docs/spec/App/UI/画面項目定義.md` | 現行 UI の正本 |
| `docs/spec/App/UI/画面・状態遷移.md` | 現行遷移の正本 |
| `docs/spec/App/通信仕様.md` | 現行通信仕様の正本 |
| `docs/spec/App/音声処理仕様.md` | 現行音声仕様の正本 |
| `docs/spec/App/Configuration/設定値一覧.md` | 現行設定値の正本 |
| `docs/spec/App/ログ仕様.md` | 現行診断/運用仕様の正本 |

## 更新ルール

| 項目 | ルール |
|---|---|
| 実装変更時 | まず `docs/spec` を更新する |
| 構想メモ | 実装されていない案は `docs/requirements` に残し、`docs/spec` に混ぜない |
| 記述形式 | 画面、状態、設定は表を優先する |
| 差分整理 | 削除済み機能や未実装要素は「未対応」「将来課題」と明記する |
| 詳細度 | 実装者が迷わないよう、背景、理由、現状との差分、明確な仕様、実装方針、注意点を必要に応じて記載する |
