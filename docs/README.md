# RideCom ドキュメント

[画面デザインと録音操作の整理](validation/history/画面デザインと録音操作の整理.md)に、Standard／Advancedの録音ボタン表示と画面改修の検証・未確認境界を記録する。

[音声デバイスpackageの検証](validation/history/音声デバイスpackageの検証.md)に、backend抽出とWatch Simulatorでの実行結果を記録する。

[Watch音声のApp接続とデバイス分離](validation/history/Watch音声のApp接続とデバイス分離.md)に、ローカル媒体往復・Mac全体の基準検証と、音声デバイスへの分離／Watch Simulatorの後続工程を記録する。

[Xcode標準設定への復帰と一時領域の整理](validation/history/Xcode標準設定への復帰と一時領域の整理.md)に、独自採番・一時buildの廃止、指定先Widgetの照合、検証結果と未解決の警告、一時物の保全・削除を記録する。

[Watch音声の下位基盤検証](validation/history/Watch音声の下位基盤検証.md)に、AAC・媒体pairの単独検証とMac／iOS App回帰、実Watch未接続の境界を記録する。

**開発作業では、[小さく動く単位での検証・コミットと未コミットの滞留管理](policies/開発方針.md#小さく動く単位で検証・コミットする)を着手前と区切りに必ず適用する。**

## 目的から読む

| 目的 | 最初に読む | 次に読む |
|---|---|---|
| 通話を使いたい | [使い方](manual/使い方.md) | [設定と音声効果](manual/設定と音声効果.md)、[困ったとき](manual/困ったとき.md) |
| アプリの根本要求を把握したい | [製品要求](requirements/製品要求.md) | [要求の分類](requirements/README.md)、[パッケージ要求](requirements/パッケージ要求.md) |
| 開発・文書作成のルールを知りたい | [開発方針](policies/開発方針.md) | [文書作成規約](policies/文書作成規約.md)、[ログ記録規約](policies/ログ記録規約.md) |
| 構造を理解・変更したい | [アーキテクチャ](spec/アーキテクチャ.md) | 対応するApp / package / server仕様 |
| 設定を実装したい | [App設定値](spec/App/Configuration/設定値一覧.md) | 同階層Bindings、package契約、Settings画面仕様 |
| 開発・試用を始めたい | [Xcode / VS Code](development/開発環境.md) | [自動検証](development/自動検証.md)、[Cloudflare試用手順](development/Cloudflare試用手順.md) |
| これから作るものを知りたい | [課題](backlog/README.md) | 実装作業と未採用候補 |
| 何をまだ確認していないか | [未確認事項](validation/未確認事項.md) | 試験条件と必要な環境 |
| どこまで動いたか知りたい | [検証状況](validation/README.md) | 条件・commitを明記した履歴 |

## 配置の規則

| 配置 | 正本にする情報 | 他の文書との関係 |
|---|---|---|
| requirements | 製品・packageの目的、背景、統一して求める方針 | Howは最小限。実装詳細・状態はspec/validation、課題はbacklogへ置く |
| backlog | 未実装課題・未採用候補・実装前の設計案 | 実装時は仕様へ反映し、確認待ちは検証へ引き継ぐ |
| policies | 開発方針、文書作成規約、共通ログ記録規約 | 製品が提供する機能とは別の制約。ツール入口はこの正本を参照 |
| manual | 現在の画面操作、効果、反映、保存、切り分け | 内部API値はspecを参照。実装・検証済みの操作を案内する |
| spec/App | UI、状態、group/transport、音声composition、ログ | Appの責務単位で実装と対応 |
| spec/App/Configuration | 利用者設定とAppがpackageへ渡す固定・導出値 | BindingsはApp採用値。package自体の既定・許容範囲とは区別 |
| spec/packages | package単独の型・API・責務・platform差・report | Appの採用設定はApp仕様、packageの普遍的契約はpackage仕様へ置く |
| spec/server | WorkerのAPI・資格・利用枠・費用条件 | マニュアルと開発手順から参照 |
| development | エディタ、build、検証、WebRTC更新、試用手順、費用仮定。historyは過去計画 | 現行の手順と、履歴として参照する旧計画を分離 |
| validation | 未確認事項、試験範囲、受け入れ結果。historyに過去の記録 | テスト実績は対象のソースと条件に紐づける |
| design | UIの共通デザイン・アイコン規則 | App/UIが適用先を定義 |

## 保守するとき

実装変更時は、要求への影響 → 課題の設計案 → 実装と同じ変更で所有者の仕様 → 設定・操作マニュアル → 検証状況を確認する。文書移動では本文を保持してリンクとこの索引を更新する。過去の失敗・残件・判断理由は履歴へ残す。

`python3 scripts/check_documentation.py`はローカル参照、索引からの到達性、Settings項目の仕様記載、空文書ディレクトリ、開発ツール入口の参照を検査する。`scripts/validate.sh`からローカルで実行する。GitHub Actionsの自動triggerは費用制約により停止している。文章の意味や実機品質の自動証明ではない。

## 文書一覧

### 要求

| 文書 | 役割 / 表題 |
|---|---|
| [requirements/README.md](<requirements/README.md>) | 要求の入口 |
| [requirements/パッケージ要求.md](<requirements/パッケージ要求.md>) | パッケージ要求 |
| [requirements/製品要求.md](<requirements/製品要求.md>) | 製品要求 |

### 開発・文書の規約

| 文書 | 役割 / 表題 |
|---|---|
| [policies/ログ記録規約.md](<policies/ログ記録規約.md>) | ログ記録規約 |
| [policies/文書作成規約.md](<policies/文書作成規約.md>) | 文書作成規約 |
| [policies/開発方針.md](<policies/開発方針.md>) | 開発方針 |

### 未実装課題と候補

| 文書 | 役割 / 表題 |
|---|---|
| [backlog/README.md](<backlog/README.md>) | 課題と候補 |
| [backlog/改善候補.md](<backlog/改善候補.md>) | 改善候補 |
| [backlog/未実装課題.md](<backlog/未実装課題.md>) | 未実装課題 |
| [backlog/利用権とデータ保持の設計.md](<backlog/利用権とデータ保持の設計.md>) | 確定した利用権・発信条件、データ保持と次工程への受入条件 |
| [backlog/機能拡張の実装前整理.md](<backlog/機能拡張の実装前整理.md>) | 追加要望の全体点検、実装前の判断事項と成立条件 |

### 利用マニュアル

| 文書 | 役割 / 表題 |
|---|---|
| [manual/使い方.md](<manual/使い方.md>) | 通話を始める・続ける・終える |
| [manual/困ったとき.md](<manual/困ったとき.md>) | 困ったときの確認 |
| [manual/状態の見方.md](<manual/状態の見方.md>) | 通話・音声・接続状態の見方 |
| [manual/設定と音声効果.md](<manual/設定と音声効果.md>) | 設定と音声効果 |

### 全体アーキテクチャ

| 文書 | 役割 / 表題 |
|---|---|
| [spec/アーキテクチャ.md](<spec/アーキテクチャ.md>) | アーキテクチャと文書の対応 |

### App仕様と設定

| 文書 | 役割 / 表題 |
|---|---|
| [spec/App/Configuration/Bindings/Audio/AudioMixer.md](<spec/App/Configuration/Bindings/Audio/AudioMixer.md>) | AudioMixer package 設定値 |
| [spec/App/Configuration/Bindings/Audio/Codec.md](<spec/App/Configuration/Bindings/Audio/Codec.md>) | Codec package 設定値 |
| [spec/App/Configuration/Bindings/Audio/Effectors/DynamicsProcessor.md](<spec/App/Configuration/Bindings/Audio/Effectors/DynamicsProcessor.md>) | DynamicsProcessor package 設定値 |
| [spec/App/Configuration/Bindings/Audio/Effectors/PeakLimiter.md](<spec/App/Configuration/Bindings/Audio/Effectors/PeakLimiter.md>) | PeakLimiter package 設定値 |
| [spec/App/Configuration/Bindings/Audio/Effectors/SoundIsolation.md](<spec/App/Configuration/Bindings/Audio/Effectors/SoundIsolation.md>) | SoundIsolation package 設定値 |
| [spec/App/Configuration/Bindings/Audio/Effectors/VADGate.md](<spec/App/Configuration/Bindings/Audio/Effectors/VADGate.md>) | VADGate package 設定値 |
| [spec/App/Configuration/Bindings/Audio/SessionManager.md](<spec/App/Configuration/Bindings/Audio/SessionManager.md>) | SessionManager package 設定値 |
| [spec/App/Configuration/Bindings/RTC.md](<spec/App/Configuration/Bindings/RTC.md>) | RTC package 設定値 |
| [spec/App/Configuration/設定値一覧.md](<spec/App/Configuration/設定値一覧.md>) | RideCom App 設定値一覧 |
| [spec/App/UI/Call.md](<spec/App/UI/Call.md>) | RideCom Call 画面項目 |
| [spec/App/UI/Diagnostics.md](<spec/App/UI/Diagnostics.md>) | RideCom Diagnostics 画面項目 |
| [spec/App/UI/Settings.md](<spec/App/UI/Settings.md>) | RideCom Settings 画面項目 |
| [spec/App/UI/アイコン適用.md](<spec/App/UI/アイコン適用.md>) | RideCom UI アイコン適用 |
| [spec/App/UI/全体構成.md](<spec/App/UI/全体構成.md>) | RideCom UI 全体構成 |
| [spec/App/UI/共通画面遷移.md](<spec/App/UI/共通画面遷移.md>) | RideCom 共通画面遷移 |
| [spec/App/UI/共通項目.md](<spec/App/UI/共通項目.md>) | RideCom UI 共通項目 |
| [spec/App/UI/画面・状態遷移.md](<spec/App/UI/画面・状態遷移.md>) | RideCom 画面・状態遷移 |
| [spec/App/UI/画面項目定義.md](<spec/App/UI/画面項目定義.md>) | RideCom 画面項目定義 |
| [spec/App/Watch操作.md](<spec/App/Watch操作.md>) | iPhone依存Watchの操作・音声デバイス接続と実機受入の境界 |
| [spec/App/通知仕様.md](<spec/App/通知仕様.md>) | 通常通知の許可・直接相手のgrant・tapから共通通話操作への接続 |
| [spec/App/システム表示と通話操作.md](<spec/App/システム表示と通話操作.md>) | Widget・Control・任意のLive Activity・Macメニューと共通通話操作 |
| [spec/App/利用権仕様.md](<spec/App/利用権仕様.md>) | StoreKitの読取・期限・復元・ログイン寿命 |
| [spec/App/配布環境の利用権仕様.md](<spec/App/配布環境の利用権仕様.md>) | 配布環境の利用権仕様 |
| [spec/App/ログ仕様.md](<spec/App/ログ仕様.md>) | RideCom App ログ仕様 |
| [spec/App/通話利用権仕様.md](<spec/App/通話利用権仕様.md>) | 共通操作・媒体許可・24時間起算点 |
| [spec/App/通信仕様.md](<spec/App/通信仕様.md>) | RideCom App 通信仕様 |
| [spec/App/音声処理仕様.md](<spec/App/音声処理仕様.md>) | RideCom App 音声処理仕様 |

### パッケージ仕様

| 文書 | 役割 / 表題 |
|---|---|
| [spec/packages/Audio/AudioCore.md](<spec/packages/Audio/AudioCore.md>) | AudioCore 仕様 |
| [spec/packages/Audio/AudioDevice.md](<spec/packages/Audio/AudioDevice.md>) | 遠隔音声デバイスのbackend・AAC・媒体接続 |
| [spec/packages/Audio/AudioMixer.md](<spec/packages/Audio/AudioMixer.md>) | AudioMixer 仕様 |
| [spec/packages/Audio/Codec.md](<spec/packages/Audio/Codec.md>) | Codec 仕様 |
| [spec/packages/Audio/Effectors/DynamicsProcessor.md](<spec/packages/Audio/Effectors/DynamicsProcessor.md>) | DynamicsProcessor 仕様 |
| [spec/packages/Audio/Effectors/PeakLimiter.md](<spec/packages/Audio/Effectors/PeakLimiter.md>) | PeakLimiter 仕様 |
| [spec/packages/Audio/Effectors/SoundIsolation.md](<spec/packages/Audio/Effectors/SoundIsolation.md>) | SoundIsolation 仕様 |
| [spec/packages/Audio/Effectors/VADGate.md](<spec/packages/Audio/Effectors/VADGate.md>) | VADGate 仕様 |
| [spec/packages/Audio/SessionManager.md](<spec/packages/Audio/SessionManager.md>) | SessionManager 仕様 |
| [spec/packages/Overview.md](<spec/packages/Overview.md>) | Package 統合仕様 |
| [spec/packages/RTC.md](<spec/packages/RTC.md>) | RTC パッケージ仕様 |

### サーバー仕様

| 文書 | 役割 / 表題 |
|---|---|
| [spec/server/Worker.md](<spec/server/Worker.md>) | Cloudflare Worker / SFU 仕様 |
| [spec/server/通知.md](<spec/server/通知.md>) | 通知宛先と呼出しAPI・保存範囲・未受入境界 |

### 開発手順と過去計画

| 文書 | 役割 / 表題 |
|---|---|
| [development/BuildWebRTC/WebRTCビルドスクリプト.md](<development/BuildWebRTC/WebRTCビルドスクリプト.md>) | WebRTCビルドスクリプト |
| [development/Cloudflare試用手順.md](<development/Cloudflare試用手順.md>) | Cloudflare試用手順 |
| [development/Cloudflare費用試算.md](<development/Cloudflare費用試算.md>) | Cloudflare 音声通話の費用試算 |
| [development/history/旧機能拡張の着手順.md](<development/history/旧機能拡張の着手順.md>) | 初期の機能依存順と実装追記の履歴 |
| [development/history/旧HE-AAC-v2追加計画.md](<development/history/旧HE-AAC-v2追加計画.md>) | 旧HE-AAC-v2追加計画 |
| [development/history/旧アーキテクチャ再編計画.md](<development/history/旧アーキテクチャ再編計画.md>) | 旧アーキテクチャ再編計画 |
| [development/history/旧音声入出力と画面改修計画.md](<development/history/旧音声入出力と画面改修計画.md>) | 旧音声入出力と画面改修計画 |
| [development/音声E2Eテスト.md](<development/音声E2Eテスト.md>) | MacとiPhone Simulatorの双方向発話、設定マトリクス、資源の再利用 |
| [development/自動検証.md](<development/自動検証.md>) | ビルド・起動と自動検証 |
| [development/OS権限と配布設定.md](<development/OS権限と配布設定.md>) | OS権限・profile・App Group・APNs・商品設定の境界と受入 |
| [development/開発環境.md](<development/開発環境.md>) | Xcode / VS Codeの開発環境 |

### 検証と履歴

[作業領域の引継ぎと整理](validation/history/作業領域の引継ぎと整理.md)に、過去worktreeの保全・回収と別チャットからの引継ぎを記録する。

[音声開始の完了待ちと中断処理](validation/history/音声開始の完了待ちと中断処理.md)は、Watch音声基盤とAppの開始・終了・中断の順序を扱う。

[正式アイコンとLiquid Glassの検証](validation/history/正式アイコンとLiquid Glassの検証.md)は、利用者指定SVGから全アプリアイコンへの統一と、各外観・platformの描画と組み込みを扱う。

[通常グループの代表端末検証](validation/history/通常グループの代表端末検証.md)は、本人単位の人数と保存、既存通話維持・端末切替のApp検証を扱う。

| 文書 | 役割 / 表題 |
|---|---|
| [validation/history/グループの代表端末とWatch通知操作の統合.md](<validation/history/グループの代表端末とWatch通知操作の統合.md>) | 代表端末・Watch通知・統合App検証とCoreAudio受入の境界 |
| [validation/history/Macメニューバーの通話操作.md](<validation/history/Macメニューバーの通話操作.md>) | 任意のMac表示・古い操作拒否・設定保持のローカル検証 |
| [validation/history/低帯域codecの通信なし比較.md](<validation/history/低帯域codecの通信なし比較.md>) | 84条件のnative変換・従来品質・短い相槌と通信量の境界 |
| [validation/history/外部通話操作と低帯域設定の統合.md](<validation/history/外部通話操作と低帯域設定の統合.md>) | 共通通話操作・低帯域候補・iPad/OS設定を合流した検証 |
| [validation/history/WebRTCマニフェスト配置の修正.md](<validation/history/WebRTCマニフェスト配置の修正.md>) | Mac用SDKリソースの配置修正・全payload保持・RTC単独検証 |
| [validation/history/OS設定と埋込productの監査.md](<validation/history/OS設定と埋込productの監査.md>) | 設定不足・署名入力・埋込productの読取監査とbuild検証 |
| [validation/history/Widget表示と共通採番のローカル検証.md](<validation/history/Widget表示と共通採番のローカル検証.md>) | Widget表示・古い操作・3product共通採番の検証 |
| [validation/history/複数端末の経路断と自動復旧.md](<validation/history/複数端末の経路断と自動復旧.md>) | 仮想4端末の経路同時断・異なる復帰順・残存音声の回帰 |
| [validation/history/検証アプリの起動前確認.md](<validation/history/検証アプリの起動前確認.md>) | 生成hostの保存先確認・起動拒否・CLI共通化の検証 |
| [validation/history/検証プロセスの終了と回収.md](<validation/history/検証プロセスの終了と回収.md>) | timeout・中断時の所有子孫回収と結果保持 |
| [validation/history/公開通話APIの頻度制限.md](<validation/history/公開通話APIの頻度制限.md>) | 通話APIの近似頻度制限・cleanup維持・ローカル回帰 |
| [validation/history/CarPlay Widget背景操作のローカル検証.md](<validation/history/CarPlay Widget背景操作のローカル検証.md>) | Widget背景Intent・停止操作・名前なし投影の局所検証 |
| [validation/history/ショートカットの明示ミュート検証.md](<validation/history/ショートカットの明示ミュート検証.md>) | 必須BoolによるSiri／Shortcutsの明示mute・実行条件・翻訳の局所検証 |
| [validation/history/低帯域Opusと明示ミュートの統合.md](<validation/history/低帯域Opusと明示ミュートの統合.md>) | Opus手動候補とSiri操作のApp統合・入力一致・実受入との境界 |
| [validation/README.md](<validation/README.md>) | 検証状況と証跡 |
| [validation/history/通知Appの接続と認可の検証.md](<validation/history/通知Appの接続と認可の検証.md>) | 通知HTTP・端末内同意・取消・ログイン世代・共通通話操作のローカル検証 |
| [validation/history/通知とMacメニューの統合.md](<validation/history/通知とMacメニューの統合.md>) | 通知・Mac表示・容量回復・iPhone/iPad操作と配布生成物の統合検証 |
| [validation/history/StoreKit端末利用権のローカル検証.md](<validation/history/StoreKit端末利用権のローカル検証.md>) | StoreKitの署名・期限・返金・復元の局所検証 |
| [validation/history/音声境界の共通化と再点検.md](<validation/history/音声境界の共通化と再点検.md>) | 音声・RTC境界の共通化と二巡の再点検 |
| [validation/history/近距離オフライン通信.md](<validation/history/近距離オフライン通信.md>) | AP・セルラー不在とLocal優先の調査・検証 |
| [validation/history/音声同一性と途切れの再現.md](<validation/history/音声同一性と途切れの再現.md>) | 複数発話の全文照合と通信なし結合試験による途切れの再現 |
| [validation/history/Cloudflare検証.md](<validation/history/Cloudflare検証.md>) | Cloudflare 試用準備の検証記録 |
| [validation/history/初期構想と対応経緯.md](<validation/history/初期構想と対応経緯.md>) | 初期構想と対応経緯 |
| [validation/history/品質点検.md](<validation/history/品質点検.md>) | Cloudflare試用前の品質点検 |
| [validation/history/復旧検証記録.md](<validation/history/復旧検証記録.md>) | dev 復旧検証記録 |
| [validation/history/文書役割分離記録.md](<validation/history/文書役割分離記録.md>) | 要求・仕様・課題・検証の役割分離 |
| [validation/history/混在通話検証.md](<validation/history/混在通話検証.md>) | 混在グループ通話・音声機器切断の検証 |
| [validation/history/要求構造整理記録.md](<validation/history/要求構造整理記録.md>) | 要求と開発規約の構造整理記録 |
| [validation/history/責務分解と保存復旧.md](<validation/history/責務分解と保存復旧.md>) | 責務分解・保存復旧・設定待機の検証 |
| [validation/history/通信診断とTURN資格検証.md](<validation/history/通信診断とTURN資格検証.md>) | 通信診断とTURN資格の検証 |
| [validation/history/音声エフェクト接続検証.md](<validation/history/音声エフェクト接続検証.md>) | 音声エフェクトのApp接続と自動検証 |
| [validation/文書整理記録.md](<validation/文書整理記録.md>) | 文書構造と実装整合の点検記録 |
| [validation/未確認事項.md](<validation/未確認事項.md>) | 実機以外にも残るテスト・環境・外部受入と阻害条件 |
| [validation/実機確認待ち.md](<validation/実機確認待ち.md>) | 物理端末・周辺機器・実無線での確認だけが残る範囲 |
| [validation/自動検証範囲.md](<validation/自動検証範囲.md>) | 自動検証範囲 |

### デザイン

| 文書 | 役割 / 表題 |
|---|---|
| [design/アイコン定義.md](<design/アイコン定義.md>) | RideCom アプリ内アイコン定義（SF Symbols）。アプリアイコンは対象外 |
| [design/デザインシステム.md](<design/デザインシステム.md>) | RideCom デザインシステム |
| [design/カラーテーマ.md](<design/カラーテーマ.md>) | 白・青・緑のカラーテーマと色トークン（実装前） |
| [design/一般向け/画面構成とレイアウト.md](<design/一般向け/画面構成とレイアウト.md>) | 一般向け画面・Watch・Widgetの画面構成とレイアウト案（実装前）。見本は[デザイン見本](<design/一般向け/デザイン見本.html>) |
| [design/詳細画面/診断と詳細画面の構成.md](<design/詳細画面/診断と詳細画面の構成.md>) | 詳細表示（Advanced）の診断・通話・設定画面の構成案（実装前）。見本は[詳細画面見本](<design/詳細画面/詳細画面見本.html>) |
| [design/アプリアイコン配色案.md](<design/アプリアイコン配色案.md>) | アプリアイコン配色の検討記録。現行の配色を維持し、今後の検討で守る制約を残す |
