# 低帯域codecの通信なし比較

2026-10-31、`de94ebef`と同じCodec・AudioCore sourceを使い、AVAudioEngine・実マイク・スピーカーを起動せず、AVAudioConverterによる周波数変換と公開StreamingCodecEncoder／Decoderを往復した。App・packageの既定値と品質判定を変更しない評価である。

## 比較条件

- 同じ4音声（speech、speech-ja、conversation-ja、conversation-reply-ja）を16／24／48kHzへ変換し、10ms刻みで投入した。PCM16とOpus48kbpsを対照に、AAC-ELDを12／16／24／32／48kbpsで比較した。4音声×21条件の計84条件。
- 同じcodec・周波数内でbitrateだけを比較する。異なる周波数間の差にはresamplingの差も含み、bitrateだけの劣化と断定しない。
- packageと基準音声・既存判定helperの27入力は前後一致。独立probeのsource hash、全JSON・再生用WAV・変換失敗logを`.validation/low-bandwidth-codec-offline`へ保管した。元の作業場所は`/private/tmp/RideIntercom-LowBandwidthProbe`。

## 結果

68条件で変換でき、16条件はnative変換に失敗した。失敗を除外して全条件合格とは扱わない。下表の「既存品質判定」は従来の波形連続性判定であり、値は4音声中の合格数。

| codec・周波数 | 12kbps | 16kbps | 24kbps | 32kbps | 48kbps |
|---|---|---|---|---|---|
| AAC-ELD 16kHz | 0/4 | 0/4 | 2/4 | 3/4 | 4/4 |
| AAC-ELD 24kHz | 変換失敗4件 | 1/4 | 3/4 | 4/4 | 4/4 |
| AAC-ELD 48kHz | 変換失敗4件 | 変換失敗4件 | 変換失敗4件 | 1/4 | 4/4 |

PCM16とOpus48kbpsは各周波数で4/4。Opusの48kbps未満は現packageが48kbpsへ補正するため、低bitrateの実測として扱わず今回の候補比較から外した。

変換できた全条件で音声timestampの最大gapは約3.6×10⁻¹⁵秒以下。会話fixtureの短い「うん」「ふん」の独立照合も通過した。照合の負例として、元音声は受理し、各相槌を消した2条件はそれぞれ拒否した。この事実だけで低bitrateの明瞭度・自然さ・雑音下の聞き取りや波形品質を保証しない。

48kHz／32kbpsと24kHz／16kbpsのAACは、このmacOS環境ではnative設定値の読み戻しが要求と一致し、実符号化も成功した。ただし従来品質判定は各1/4のため、従来の推奨を置換しない。手動の低音質選択肢の実装と、実機の聞き取り・実通信による推奨決定を分ける。16kHzの下限やOpus下限はこの評価で変更しない。

## バイト数の意味と残る確認

AAC 48kHz／48kbpsの日本語音声では、符号化本体は約49.35kbps、現在のcodec envelopeは約214.2kbpsだった。EncodedCodecFrameをJSON化した場合の大きさも記録したが、これは実RTC／ネットワークのwire bytesではない。暗号化・transport・制御・再送込みの通信量は別工程で測定する。処理wall timeも電力・電池消費へ換算しない。

既存のCoreAudio E2EはこのMacのnative音声準備で停止する問題があり、今回の通信なし評価をその成功に置き換えない。App画面からの実適用、通信経路ごとの配送・再生、実機の雑音下明瞭度・短い相槌・Bluetooth・負荷・電力は[未確認事項](../未確認事項.md)と[低帯域の課題](../../backlog/未実装課題.md#低ビットレートの許容)へ引き継ぐ。
