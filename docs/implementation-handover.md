# RideIntercom Implementation Handover

このページは初見実装者向けの最短導線。

## 変更手順

1. 仕様の一次根拠を確認する。
- docs/ios-intercom-spec-v1.md
- docs/spec-traceability.md

2. 変更対象の層を先に決める。
- Application: ViewModel 状態集約とユースケース呼び出し
- Domain: 音声処理・経路判定・認証ロジック
- Platform Adapter: OS/API 依存処理
- Test Support: NoOp/Fake/Virtual 実装

3. 先にテストを追加する。
- Contract 観点のテストを先に追加
- ViewModel 直接変更時は既存回帰テストの補強を先に行う

4. 実装は最小差分で入れる。
- 1責務ずつ分離し、外部振る舞いは維持
- ドメイン判断を ViewModel に戻さない

5. 全体回帰を通してからコミットする。
- focused tests
- RideIntercomTests 全体

## 必須テスト

- 単体全体:
  - DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project RideIntercom.xcodeproj -scheme RideIntercom -destination 'platform=macOS' -only-testing:RideIntercomTests

- 変更に応じた focused tests:
  - コーデック変更: audioPacketSequencer, audioEncodingSelector, opus/heAAC tests
  - 経路変更: routeCoordinator, handover, viewModel transport transition tests
  - 受信処理変更: remoteAudioPipelineService, remoteAudioPacketAcceptanceService, jitter tests
  - 招待/セキュリティ変更: groupInviteToken, handshake, encryptedAudioPacketCodec tests

## 依存追加条件

- 新規依存は次を全て満たす場合のみ追加する。
- 標準フレームワークで代替できない。
- Domain 層に OS 依存 import を持ち込まない。
- 既存テスト経路で Fake/NoOp 実装を維持できる。
- セキュリティ/音声品質の改善を定量で説明できる。

## 実行時トグル

- Internet relay 接続先:
  - 環境変数 RIDEINTERCOM_INTERNET_URL に WebSocket URL を設定すると InternetTransport が URLSession adapter を利用する。
  - URL は ws/wss スキームかつ host 必須。条件を満たさない値は無効として Loopback adapter にフォールバックする。
  - 未設定時は Loopback adapter を使う。

- Opus backend:
  - 環境変数 RIDEINTERCOM_ENABLE_SYSTEM_OPUS=1 を設定すると System Opus backend の導入を試行する。
  - 導入できない環境では既存の fallback（PCM への降格）を維持する。

## Adapter 追加条件

- 追加先は Platform 層に限定する。
- 追加 Adapter は既存 Port 契約を満たす。
- Application/Domain 側に OS 条件分岐を増やさない。
- Contract test と Adapter test を同時追加する。

## 完了判定ゲート

- docs/spec-traceability.md の対応行が更新されている。
- 変更対象の受け入れ条件に紐づくテストが追加または更新されている。
- RideIntercomTests が成功している。
- UI/Application/Domain/Platform の依存逆流が発生していない。
