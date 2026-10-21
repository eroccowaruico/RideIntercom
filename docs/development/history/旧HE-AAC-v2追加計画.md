# 旧HE-AAC-v2追加計画

この文書は過去の計画を原文保全した資料であり、現行の実行指示ではない。旧所在: .github/prompts/plan-heAacV2VbrCodec.prompt.md。

HE-AAC v2の追加を検討した当時の案。現行選択肢PCM / AAC-ELD v2 / Opusの実装済み仕様とは区別する。

[現行仕様](../../spec/packages/Audio/Codec.md)と[製品要求](../../requirements/製品要求.md)を優先する。以下の原文内の旧パス・採番・未確定事項は当時の記録であり、現在の参照先や完了状況を示さない。

## 当時の原文

~~~~markdown
# Plan: HE-AAC v2 VBR コーデック追加・Diag設定・接続アイコン改善

## 概要

Apple標準の `AVAudioConverter`（ハードウェアアクセラレーション）で HE-AAC v2 VBR を実装する。コーデック種別・品質をDiagnosticsで設定可能にし、リアルタイム切り替えに対応。受信側はパケットの `AudioCodecIdentifier` フィールドで各ピアのコーデックを自動判別して再生する。参加者欄にコーデック表示、接続アイコンを改善。TDD（Red→Green）で進める。

---

## 技術制約・設計方針

### HE-AAC v2 の制約
- `kAudioFormatMPEG4AAC_HE_V2` はステレオ専用（Parametric Stereo）
- モノラル音声をエンコードするには L+R にデュプリケートしてステレオ入力にし、デコード後は L ch のみ取り出す
- フレームサイズ: 2048 samples/frame @ 16kHz = **128ms** のバッファリングが必要
- `encode()` がバッファ未満の場合は `Data()` を返す（空ペイロード）
- `AudioPacketEnvelope` init が空ペイロードを検出したとき `encodedVoice = nil` にしてパケット送信自体をスキップ

### コーデック切り替えのリアルタイム性
- `IntercomViewModel.preferredTransmitCodec` を `@Observable` プロパティとして保持
- `AudioPacketSequencer.codec` に設定を反映（`var codec: AudioCodecIdentifier`）
- `MultipeerLocalTransport` は ViewModel のコーデック設定を送信時に参照
- Diagnostics で変更したら即時反映（次の voice パケットから適用）

### 受信側マルチコーデック対応
- `EncodedVoicePacket.decodeSamples()` が `codec` フィールドをスイッチして適切なデコーダを選択
- HE-AAC v2 デコーダ: `AVAudioConverter` でステレオ PCM → L ch のみ取り出す
- すでに `codec` フィールドを持つ設計なので、送信元ごとに異なるコーデックを透過的にデコード可能

### レイテンシとのトレードオフ
- HE-AAC v2: 2048 samples = **128ms** のフレームレイテンシ（インカム用途として許容範囲と判断）
- 低遅延を優先する場合は AAC-LC (1024 samples = 64ms) も選択肢として提示可能

---

## Phase 1: TDD Red（テスト先行）

**対象ファイル**: `RideIntercomTests/RideIntercomTests.swift`

以下のテストを先に記述（この段階でコンパイルエラー or 失敗が正常）:

1. `heAACv2EncodingIsAvailable` — `HEAACv2AudioEncoding()` を生成でき、`codec == .heAACv2` を確認
2. `heAACv2RoundtripEncodesAndDecodes` — 2048サンプルのサイン波を `encode` → `decode` して RMS誤差 < 0.05
3. `heAACv2EncodeReturnsEmptyDataWhenBufferNotFull` — 128サンプルの `encode` 呼び出しで `Data()` が返ること
4. `audioEncodingSelectorReturnsHEAACv2WhenPreferred` — `AudioEncodingSelector.encoder(preferred: [.heAACv2, .pcm16])` が `HEAACv2AudioEncoding` を返すこと
5. `memberActiveCodecIsUpdatedOnReceive` — 受信パケットの codec に応じて `GroupMember.activeCodec` が更新されること

---

## Phase 2: コア実装（IntercomCore.swift）

### Step 2-1: データモデル追加
- `AudioCodecIdentifier` に `.heAACv2` を追加
- `HEAACv2Quality` enum を新規追加:
  ```swift
  enum HEAACv2Quality: String, CaseIterable {
      case low = "Low (~16 kbps)"
      case medium = "Medium (~24 kbps)"
      case high = "High (~40 kbps)"
      var bitRate: Int { ... }
  }
  ```
- `GroupMember` に `var activeCodec: AudioCodecIdentifier?` を追加（`init` デフォルト引数 `= nil`、Codable 互換）

### Step 2-2: HEAACv2AudioEncoding 実装
- `final class HEAACv2AudioEncoding: AudioEncoding` を追加
- `var quality: HEAACv2Quality`
- 内部 `[Float]` サンプルバッファ（フレームサイズ = 2048）
- `AVAudioConverter` を lazy init:
  - エンコード用: モノラル Float32 16kHz → ステレオ HE-AAC v2 VBR
    - 入力: `AVAudioFormat(.pcmFormatFloat32, sampleRate: 16000, channels: 2)` （L=R=mono sample）
    - 出力: `AVAudioFormat(streamDescription: &asbd)` where `mFormatID = kAudioFormatMPEG4AAC_HE_V2`
    - `converter.bitRateStrategy = AVAudioBitRateStrategy_Variable`
  - デコード用: 上記の逆（HE-AAC v2 → ステレオ Float → L ch抽出）
- `encode(_ samples: [Float]) throws -> Data`:
  - サンプルをバッファに追加
  - `guard buffer.count >= frameSize else { return Data() }`
  - フレームサイズ分のサンプルを取り出してエンコード → `Data`
- `decode(_ data: Data) throws -> [Float]`:
  - 圧縮バッファを生成してデコード → ステレオ PCM → L ch抽出 → `[Float]`

### Step 2-3: AudioEncodingSelector 更新
```swift
case .heAACv2:
    return HEAACv2AudioEncoding()
```

### Step 2-4: EncodedVoicePacket 更新
- `make(frameID:samples:codec:)` に `.heAACv2` ケース追加
- `decodeSamples()` に `.heAACv2` ケース追加

### Step 2-5: AudioPacketSequencer にコーデック設定を追加
- `var codec: AudioCodecIdentifier = .pcm16` を追加
- `makeEnvelope(for:sentAt:)` を更新: `codec` を `AudioPacketEnvelope` init に渡す

### Step 2-6: AudioPacketEnvelope の codec パラメータ対応
- `init(groupID:streamID:sequenceNumber:sentAt:packet:)` に `codec: AudioCodecIdentifier = .pcm16` 追加
- voice ケース: `EncodedVoicePacket.make(frameID:, samples:, codec: codec)` 呼び出し
- **空ペイロード対応**: `make` が空 `Data` を返したとき（= HE-AAC バッファリング中）は `encodedVoice = nil`, `kind = .keepalive` として扱い、送信時にスキップ

### Step 2-7: MultipeerLocalTransport のコーデック反映
- `var preferredCodec: AudioCodecIdentifier = .pcm16` プロパティを追加
- `send(_ packet: OutboundAudioPacket)` で `sequencer.codec = preferredCodec` をセット
- `func setPreferredCodec(_ codec: AudioCodecIdentifier)` を追加

### Step 2-8: IntercomViewModel のコーデック設定
- `private(set) var preferredTransmitCodec: AudioCodecIdentifier = .pcm16` を追加
- `private(set) var transmitCodecQuality: HEAACv2Quality = .medium` を追加
- `func setPreferredTransmitCodec(_ codec: AudioCodecIdentifier)` を追加（`localTransport?.setPreferredCodec(codec)` を呼ぶ）
- `func setTransmitCodecQuality(_ quality: HEAACv2Quality)` を追加

### Step 2-9: 受信時の activeCodec 更新
- `handleReceivedPacket(_ packet: ReceivedAudioPacket)` で:
  ```swift
  group.members[memberIndex].activeCodec = packet.envelope.encodedVoice?.codec
  ```

---

## Phase 3: UI（ContentView.swift）

Phase 2 と並行可。

### Step 3-1: DiagnosticsView に送信コーデック設定パネルを追加
- `TransmitCodecPanel` を新規 `private struct` として追加
- コーデック Picker (Segmented): `"PCM 16-bit"` / `"HE-AAC v2 VBR"`
  - `accessibilityIdentifier("transmitCodecPicker")`
- HE-AAC v2 選択時のみ品質 Picker (Segmented): Low / Medium / High
  - `accessibilityIdentifier("heAACv2QualityPicker")`
- `DiagnosticsView.body` の VStack に `TransmitCodecPanel(viewModel: viewModel)` を先頭付近に追加

### Step 3-2: ParticipantSlotView にコーデック表示を追加
- VoiceMeterView の直下に `member?.activeCodec` ラベルを追加:
  ```swift
  if let codec = member?.activeCodec {
      Text(codecLabel(codec))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("participantCodec\(index)")
  }
  ```
- `codecLabel(_ codec: AudioCodecIdentifier) -> String`:
  - `.pcm16` → `"PCM 16-bit"`
  - `.heAACv2` → `"HE-AAC v2"`
  - `.opus` → `"Opus"`

### Step 3-3: 接続状態アイコン改善

**ParticipantSlotView.statusIconName** (各参加者のコネクト状態):
```
.connected  → "wifi"               (緑)
.connecting → "wifi.exclamationmark" (橙)
.offline    → "wifi.slash"          (グレー)
nil (empty) → "person.badge.plus"   (グレー)
```

**CallView.connectionIconName** (全体の接続状態ヘッダー):
```
.idle                                → "wifi.slash"
.localConnecting / .internetConnecting → "wifi.exclamationmark"
.localConnected / .internetConnected   → "wifi"
.reconnectingOffline                   → "exclamationmark.triangle.fill"
```

---

## Phase 4: テスト Green

```bash
# 単体テスト
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme RideIntercom \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -only-testing:RideIntercomTests

# UIテスト
RUN_UI_TESTS=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -scheme RideIntercom \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -only-testing:RideIntercomUITests
```

1. Phase 1 で記述した 5 件のテストを全てグリーンにする
2. 既存の 129 件のテストも引き続き全パス確認
3. UIテストも全パス（accessibilityIdentifier 変更があれば合わせて修正）

---

## 対象ファイル

| ファイル | 変更内容 |
|---------|---------|
| `RideIntercom/IntercomCore.swift` | コーデック実装・データモデル・ViewModel |
| `RideIntercom/ContentView.swift` | UI（Diag設定・参加者コーデック表示・接続アイコン） |
| `RideIntercomTests/RideIntercomTests.swift` | TDDテスト追加（Phase 1 → Phase 4） |
| `RideIntercomUITests/RideIntercomUITests.swift` | 必要に応じてアクセシビリティID修正 |

---

## スコープ外

- ControlMessage によるコーデックネゴシエーション（パケット内 `codec` フィールドで受信側は自動対応済み）
- Opus 実装（既存スタブのまま）
- Internet Transport へのコーデック伝播

---

## 検討事項・リスク

1. **HE-AAC v2 のモノラル制限**: Apple の AVAudioConverter が mono 入力で HE-AAC v2 を拒否した場合、HE-AAC v1（`kAudioFormatMPEG4AAC_HE`）に自動フォールバック、または UI に両方のオプションを追加する
2. **128ms レイテンシ**: HE-AAC v2 のフレームサイズ (2048 samples) により最低 128ms のフレームレイテンシが発生。インカム用途として許容するか、AAC-LC (64ms) も選択肢として追加するかを確認
3. **`GroupMember.activeCodec` の Codable 互換性**: 古いグループデータに `activeCodec` が無い場合は `nil` になり自然なデフォルト（未受信）として機能するため問題なし
4. **`HEAACv2AudioEncoding` のインスタンス共有**: `EncodedVoicePacket.make` で毎回新しい encoder を生成するとバッファが失われる。`AudioPacketSequencer` に encoder インスタンスを保持させて共有する設計が必要

~~~~
