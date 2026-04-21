## Plan: 逸脱ゼロ化の実装統制設計

RideIntercom全体に対して、方針逸脱を「発見して直す」運用から「逸脱が入らない」構造へ移行する。中核は、機能契約の固定、共通経路の単一化、Adapter境界の明文化、テスト先行ゲート、設計責務の再配置の5本柱とする。既存の抽象化基盤（Transport/AudioEncoding/RuntimeFactory）を再利用しつつ、未完了境界（Opus/GK/macOS実経路）と不十分な抽象境界を設計段階で閉じる。

**Current Position (2026-04-22)**
- 現在フェーズ: Phase D の Step 24（Domain service / UseCase への段階移設）に着手中
- 完了済み（Step 16 先行実施）: Diagnostics を構造化 snapshot 化し、UI は snapshot 表示へ移行
- 完了済み（Step 24 の一部）: 受信 packet 受理ルール、jitter drain、member state 更新を Domain service へ抽出
- 完了済み（Step 13/26 の一部）: `RouteCoordinator`/`RoutePolicy` 導入、InternetTransport を共通 packet contract 化、InternetTransportAdapter 境界を追加
- 完了済み（Step 25/28 の一部）: stateful codec session 境界導入、credential/handshake/packet crypto 責務分離、invite 生成/受理の UseCase 分離、Opus backend 差し替え境界の実装
- 進捗コミット: `98e3f23` `c32ac93` `4bcdb7d` `58edd0f` `70f76d1` `036eafb` `ddf6093` `38cb5d5` `209a7f6` `252d8eb` `d06422a` `e35fa0b` `f82f1cc` `f40f21e` `b97a53d`
- 次アクション: Step 25-28 の未達（Opusネイティブ backend 接続、Internet relay 実サーバ接続検証、OS差分統合、永続化責務の最終分離）を順次実装
- 完了判定の見方: Step 30 の4条件を全て満たすまで「設計移行中」。現時点は未達

**Execution Policy (Completion-first)**
- この計画は「ステップ番号の順守」ではなく「完了条件の充足」を目的に実行する。
- ステップ番号は依存関係の可視化にのみ使う。依存を壊さない範囲で前後・並行・先行実施を許可する。
- 実装の優先順位は常に次で決める: 1) 機能契約維持 2) 完了条件への寄与量 3) 変更リスク最小化。
- 各変更は「テスト追加/更新 -> 実装 -> 全体回帰成功」のゲートを通過しない限り完了扱いにしない。
- フェーズ完了は、そのフェーズ配下の必須完了条件をすべて満たしたときのみ宣言する。

**Execution-ready Order (実行順バックログ)**
- Wave 1: 完了条件の土台を先に固定する（Step 2 -> 3 -> 4）
- Wave 2: 境界を先に確定する（Step 6 -> 7 -> 8 -> 10）
- Wave 3: 依存の薄いドメインを先行分離する（Step 16 と Step 24 の受信系/診断系を先行）
- Wave 4: 可変リスクが高い設計を並行で確定する（Step 11, 12, 14, 15）
- Wave 5: handover と経路品質を確定する（Step 13）
- Wave 6: テスト体系を再編する（Step 18 -> 19 -> 20, 並行で Step 21, 22）
- Wave 7: 実装移行を完了させる（Step 24 完了 -> 25, 26, 27, 28）
- Wave 8: 完了判定と運用移管（Step 30 -> 31）
- 実行ルール: 各Waveは「完了条件に寄与する最小変更単位」で進め、順序よりゲート通過を優先する。

**Steps**
1. Phase A: 機能契約固定化（設計は固定しない）
2. [docs/ios-intercom-spec-v1.md](docs/ios-intercom-spec-v1.md) の要求を一次ソースとし、実コードと既存テストを照合して「維持すべき機能契約」を機械判定可能な受け入れ条件へ再定義する。[docs/implementation-status.md](docs/implementation-status.md) は補助情報としてのみ扱い、未記載の仕様や実装済み挙動がある前提で鵜呑みにしない。設計やクラス構造は固定対象に含めない。*blocks all later steps*
3. 機能契約をテスト化する。API契約、状態遷移、音声送受信、招待、暗号化、handoverを「設計非依存の振る舞いテスト」に変換し、リファクタ前の回帰ガードにする。*depends on 2*
4. 逸脱の判定基準を文章ではなくチェック可能な規約として定義する。対象は「View層でのOS分岐禁止」「Transport bypass禁止」「コーデック直叩き禁止」「テスト未追加変更の禁止」。*depends on 2*
5. Phase B: 目標アーキテクチャの確定
6. 全体構造を「Application」「Domain」「Platform Adapter」「Test Support」の4層に再配置する。Applicationは画面状態とユースケースのオーケストレーションのみ、Domainは音声・接続・認証の純粋ロジック、Platform AdapterはAVFoundation/Multipeer/CoreAudio/Keychain等のOS依存、Test SupportはFake/NoOp/Virtual実装のみを持つ。*depends on 3,4*
7. 音声送受信と状態更新の単一経路を明文化し、入口を [RideIntercom/IntercomCore.swift](RideIntercom/IntercomCore.swift#L2308) 周辺のイベント処理契約へ集約する。入力は「MicrophoneFrame」「TransportEvent」「UserIntent」、出力は「RenderedAudio」「UIState」「DiagnosticsSnapshot」に限定し、契約外更新を禁止する。*depends on 6*
8. ViewModelの責務を縮小し、「画面状態の集約」「ユースケース呼び出し」「イベント反映」に限定する。VAD、handover、packet filter、jitter、codec選択、認証判定は ViewModel から分離して Domain service へ移す。*depends on 6,7*
9. ユースケース境界を `ConnectGroupCall` `DisconnectGroupCall` `HandleMicrophoneInput` `HandleTransportEvent` `GenerateInvite` `AcceptInvite` `SelectAudioRoute` に分解し、それぞれが単一責務で完結するよう設計する。各ユースケースは副作用を直接持たず、必要な副作用はPort経由で要求する。*depends on 8*
10. 音声パイプラインを `Capture -> Resample -> VAD -> PreRoll -> Encode -> Encrypt -> Sequence -> Transport` と `Transport -> Decrypt -> Decode -> Filter -> Jitter -> Mix -> Render` の双方向フローとして固定し、各段を差し替え可能な境界に分解する。境界間のデータ型は `AudioFrame` `EncodedFrame` `EncryptedPacket` `ReceivedFrame` `PlaybackFrame` に統一する。*depends on 7,8*
11. コーデック境界を stateful へ拡張する設計を確定する。対象は [RideIntercom/IntercomCore.swift](RideIntercom/IntercomCore.swift#L1410) の AudioEncoding、[RideIntercom/IntercomCore.swift](RideIntercom/IntercomCore.swift#L1605) の AudioEncodingSelector、[RideIntercom/IntercomCore.swift](RideIntercom/IntercomCore.swift#L1620) の EncodedVoicePacket。設計上は `AudioEncoderSession` と `AudioDecoderSession` を分離し、frame accumulation, flush, reset を契約化する。*depends on 10*
12. Transport抽象を Local/Internetの二択固定から方式拡張可能な構造へ変更する。`Transport` は接続路ではなく「packet route capability」として扱い、経路選択は `RouteCoordinator` に分離する。`TransportEvent` は受信イベント、リンク状態、認証状態、経路品質に分解し、handover判定に必要な測定値を明示的に持つ。*depends on 10, parallel with 11*
13. handover設計を `RouteCoordinator` と `RoutePolicy` に分ける。`RouteCoordinator` は現在経路・候補経路・切替中状態を管理し、`RoutePolicy` は RTT, jitter, packet loss, peer count に基づいて切替可否を判定する。二重送信期間、復帰条件、offline 退避条件を数値で定義する。*depends on 12*
14. 認証・暗号化設計を `GroupCredentialProvider` `HandshakeService` `PacketCryptoService` に分割する。グループ秘密導出、handshake検証、payload暗号化を別責務にし、Transport実装やViewModelが秘密導出ロジックを持たないようにする。*depends on 10,12*
15. OS差分はPlatform層に限定し、UIとApplication層から #if を排除する設計へ段階移行する。対象は [RideIntercom/ContentView.swift](RideIntercom/ContentView.swift#L1)、[RideIntercom/PlatformAudioInputSupport.swift](RideIntercom/PlatformAudioInputSupport.swift#L35)、[RideIntercom/PlatformAudioSessionSupport.swift](RideIntercom/PlatformAudioSessionSupport.swift#L1)。各Platform実装は同一Portを満たすAdapterとして定義し、利用側は能力フラグだけを見る。*depends on 6, parallel with 11-14*
16. Diagnosticsを設計対象として昇格させる。表示値は ViewModel がその場で組み立てるのではなく、`DiagnosticsSnapshotBuilder` が音声・接続・認証・経路品質・デバイス状態を集約して生成する。UIは snapshot のみを表示する。*depends on 8,10,12,14*
17. Phase C: TDDゲートの完全化
18. Red-Green-Refactorの順序を必須化し、機能追加ごとに先行テストテンプレートを作成する。優先ケースは Opus fallback、GK handover、複数peer並行、再認証、ジッタ期限切れ。*depends on 3,6-16*
19. テスト責務を `Contract Tests` `Domain Scenario Tests` `Application Integration Tests` `Platform Adapter Tests` `UI Flow Tests` に再編する。Contract Tests は設計差し替え時の互換保証、Scenario Tests は仕様シナリオ、Integration Tests はユースケース連結、Adapter Tests はOS依存差分、UI Flow Tests は起動1回の回帰に限定する。*depends on 18*
20. 単体テストは ViewModel中心からユースケース・ドメインサービス中心へ移し、ViewModelは状態写像の薄いテストへ縮小する。中心は [RideIntercomTests/RideIntercomTests.swift](RideIntercomTests/RideIntercomTests.swift#L6) だが、最終的には責務別ファイルへ分割する。*depends on 19*
21. UIテストを「1回起動で複数ケース」に固定し、接続導線、診断導線、招待導線、削除導線の回帰セットを標準化する。対象は [RideIntercomUITests/RideIntercomUITests.swift](RideIntercomUITests/RideIntercomUITests.swift#L30)。*depends on 18, parallel with 19-20*
22. macOS/iOS共通テスト経路を維持するため、Platform実装差分の契約テストを追加する。実デバイス依存を避け、NoOp/Fake/Virtual transport を標準経路にする。*depends on 18, parallel with 19-21*
23. Phase D: 実装移行順序の確定
24. まず `Domain service` と `UseCase` を新設し、既存 ViewModel からロジックを移設する。移設順は VAD/Transmission -> Packet Receive/Filter -> Jitter/Playback -> Handover -> Invite/Credential とする。各段階で外部振る舞いを維持し、古い経路を段階的に削除する。*depends on 20-22*
25. P1: Opus実装完了とfallback保証。対象は stateful codec session 導入と既存機能契約の保持。PCM/HE-AAC/Opus の優先順位、利用不可時の降格規則、空payload処理、flush条件を明文化する。*depends on 11,20*
26. P2: InternetTransport実装とhandover実運用経路。対象は `RouteCoordinator` `RoutePolicy` `InternetTransportAdapter` の成立。Local と Internet を同一 packet contract で扱い、経路差を payload ではなく adapter に閉じ込める。*depends on 12,13,20*
27. P3: macOS実経路をiOS共通経路へ統合する。対象は Platform層差分のみで成立することの実証であり、Application/Domain層にOS条件分岐を残さない。*depends on 15,22*
28. P4: 招待/永続化/セキュリティの運用完成。対象は URL招待、期限、Keychain、同一グループ制約の回帰固定であり、秘密情報と表示情報の保存責務を分離したまま成立させる。*depends on 14,16,20-22, parallel with 25-27 where independent*
29. Phase E: 完了判定
30. 逸脱ゼロ判定は「仕様トレーサビリティ100%」「主要回帰テストの定常成功」「既存機能契約の欠落0件」「Application/Domain/Platform責務の逆流0件」で行う。責務の逆流とは、UIからPlatform APIへ直接依存すること、Platform詳細がDomainへ侵入すること、ViewModelが業務ルールを再保持することを指す。*depends on 24-28*
31. 運用移管用に、初見実装者向けの最短導線（変更手順、必須テスト、依存追加条件、Adapter追加条件）を1ページ化して完了とする。*depends on 30*

**Target Architecture**
- Application層: `IntercomViewModel` を薄い状態投影層へ縮小し、画面イベントをユースケースへ渡す。表示用の集約以外でドメイン判断を持たない。
- Domain層: `VoicePipelineService` `RouteCoordinator` `HandshakeService` `InviteService` `DiagnosticsSnapshotBuilder` を中心に、純粋ロジックを閉じ込める。
- Platform Adapter層: `AudioInputPort` `AudioOutputPort` `TransportPort` `SecretStorePort` `ClockPort` を実装し、AVFoundation/MC/CoreAudio/Keychain/GameKit を隔離する。
- Test Support層: `NoOpAudioInputMonitor` `VirtualDuplexTransport` のような既存ダブルを Port 準拠に整理し、テスト専用実装を本番実装から分離する。

**Design Rules**
- UIは Application 層の状態だけを読む。Transport や Codec へ直接触れない。
- Application 層は Port 実装型を知らず、protocol か interface のみを見る。
- Domain 層は Foundation 依存までに抑え、AVFoundation や MultipeerConnectivity を import しない。
- Platform Adapter 層は業務ルールを持たず、失敗変換・データ変換・API呼び出しに限定する。
- Diagnostics はデバッグ文字列ではなく構造化スナップショットを正として扱う。
- 追加機能は既存クラスへの条件分岐追加ではなく、ユースケースか Domain service の追加で吸収する。

**Migration Strategy**
- Step 1: 機能契約テストを先に固定する。
- Step 2: 新しい Domain service と UseCase を並行実装し、既存 ViewModel から呼び出す。
- Step 3: 既存ロジックを一責務ずつ移し、旧ロジックを削除する。
- Step 4: Port 契約が揃った時点で Platform実装を差し替える。
- Step 5: 旧設計に依存するテストを、振る舞いベースのテストへ置き換える。

**Source Priority**
- 一次根拠は [docs/ios-intercom-spec-v1.md](docs/ios-intercom-spec-v1.md) と現行コードおよび既存テストとする。
- [docs/implementation-status.md](docs/implementation-status.md) は補助情報として扱い、差分や不足が見つかった場合は仕様・コード・テストを優先する。
- 仕様未記載だが既存機能として成立している振る舞いは、テストで先に保護してから要否を判断する。
- 仕様と実装が衝突した場合は、ユーザー体験と既存機能維持を優先しつつ、判断結果を明文化してから設計を進める。

**Relevant files**
- /Users/naohito/source/RideIntercom/.github/copilot-instructions.md — 開発方針の一次ソース。逸脱定義とPRゲート基準の根拠
 - /Users/naohito/source/RideIntercom/RideIntercom/PlatformAudioOutputSupport.swift — 再生・ミックス境界。Playback port 分離の対象
- /Users/naohito/source/RideIntercom/docs/ios-intercom-spec-v1.md — 要求/仕様/受入条件。トレーサビリティ表の参照元
- /Users/naohito/source/RideIntercom/docs/implementation-status.md — 補助的な進捗メモ。未記載仕様や実装差分がある前提で参照する
- /Users/naohito/source/RideIntercom/RideIntercom/IntercomCore.swift — 中核境界（Transport, AudioEncoding, JitterBuffer, RuntimeFactory, ViewModel）
- /Users/naohito/source/RideIntercom/RideIntercom/PlatformLocalTransportSupport.swift — MC実装とLocalTransport切替境界
- /Users/naohito/source/RideIntercom/RideIntercom/PlatformAudioSessionSupport.swift — iOS/macOS AudioSession Adapter差分
- /Users/naohito/source/RideIntercom/RideIntercom/PlatformAudioInputSupport.swift — マイク権限、入力tap、SoundIsolation境界
- /Users/naohito/source/RideIntercom/RideIntercom/ContentView.swift — UI層の共通構造。OS分岐禁止の監視対象
- /Users/naohito/source/RideIntercom/RideIntercomTests/RideIntercomTests.swift — TDDゲートの主戦場（契約・統合・回帰）
- /Users/naohito/source/RideIntercom/RideIntercomUITests/RideIntercomUITests.swift — 1回起動複数ケース方針の実行対象

**Verification**
1. 要求トレーサビリティ検証: docs要求ごとに実装シンボルとテストケースが1:1で紐づくことを確認
2. 責務境界検証: UI/Application/Domain/Platform 間の依存方向が一方向であることを確認
3. テスト検証: Contract/Scenario/Integration/UI Flow の各テスト群が成功することを確認
4. 回帰検証: 主要シナリオ（VAD、ジッタ、暗号化、認証、handover、招待）を定常セットで連続成功
5. 実運用検証: iOS/macOS双方で同一操作手順により接続・通話・診断が成立し、経路差がUIに漏れないことを確認

**Decisions**
- 対象範囲は全体（既存コード含む段階是正）
- 今回成果は設計完了計画（実装担当へ即ハンドオフ可能な粒度）
- 既存機能は維持するが、既存設計は固定しない（機能契約を守る範囲で再設計を許可）
- 後方互換は優先しない。安定運用と将来拡張の両立を優先

**Further Considerations**
1. `UseCase` を struct で持つか actor/class で持つかは、可変状態の有無で決定する。状態を持つのは codec session, route coordination, jitter のみとする
2. `DiagnosticsSnapshot` の項目は UI文言ではなく、 route, auth, peers, tx, rx, play, drop, jitter, input/output level の構造体で保持する
3. Opus/GKの順序は並行可能だが、品質リスク低減の観点でOpus先行を推奨