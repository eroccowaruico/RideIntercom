# 低帯域codecの通信なし比較

証跡内のprobe manifestは`Package.swift.evidence`として元bytesを保持し、`source-evidence-paths.json`で元名とhashへ対応付ける。XcodeのRepository表示が証跡コピーを別packageとして探索することを避けるためで、再実行時はリポジトリ外へコピーして元名へ戻す。測定時の入力hashは変更しない。

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

## Opusの低帯域比較とpackage手動候補の追加

2026-10-31、`550825b0`基準の隔離worktreeで追試した。前節のAAC比較と当時のOpus48kbps制約は過去記録として保持する。先に`OpusOptions`の下限だけを実験的に8kbpsへ開き、結果を保存して元へ戻した後、製品範囲を24〜128kbpsへ広げる独立package工程を実施した。App・server・既定48kbps・波形判定閾値は変更していない。

### 入力・実変換と連続性

| 項目 | 条件・結果 |
|---|---|
| 音声入力 | 前節と同じ4音声・10ms投入・16／24／48kHz。Opus8／12／16／24／32／48kbpsの72条件とPCM16対照12条件、計84条件 |
| 入力同一性 | 先行比較の26入力が一致。相槌照合helperを含む27入力、実験ごとのprobe sourceは実行前後一致 |
| native実適用 | 別converterを作って推測せず、実際のStreamingCodecEncoderが持つAVAudioConverterからbitRate・入出力sampleRate・5ms packet・bitRateStrategyを符号化前後に読み戻した。Opus72条件すべて要求値と一致 |
| 変換 | 84／84条件成功、encode／decode失敗0、timeout0。実AVAudioEngine・マイク・スピーカー・Simulator・ネットワークを使用していない |
| 時刻・sample | 復号timestampの最大gap約3.6×10⁻¹⁵秒。末尾の入力に対する出力不足は約1.958〜2.688msで、codecの最終packet／priming境界。ネットワークの欠落ではない |
| 相槌 | すべてのOpus候補の2会話音声で「うん」「ふん」の独立照合成功。元音声を受理し各相槌を除いた2負例を拒否するoracleも再buildして成功 |

従来の音声波形判定（match成功かつmissingActiveRatioが0）は、各16／24／48kHzで同じ結果となった。missingActiveRatioは参照音声の活動区間に対する復号後のエネルギー不足であり、packet／sample／timestampの欠落数ではない。低帯域圧縮で強く減衰した区間も含み、通信損失と断定しない。

| Opus目標kbps | 8 | 12 | 16 | 24 | 32 | 48 |
|---|---|---|---|---|---|---|
| 各周波数の従来音声判定 | 1／4 | 1／4 | 1／4 | 4／4 | 4／4 | 4／4 |
| 全音声・周波数の最大missingActiveRatio | 0.04094 | 0.04386 | 0.04386 | 0 | 0 | 0 |
| 最長エネルギー不足区間 | 100ms | 100ms | 100ms | 0 | 0 | 0 |
| 最小alignment correlation | 0.70758 | 0.79437 | 0.84589 | 0.92156 | 0.93225 | 0.94940 |
| 最小matched-window ratio | 0.76744 | 0.90244 | 0.90244 | 1 | 1 | 1 |

### 短時間の波形誤差

音声4入力とは別に、既存`opusSteadyToneDoesNotIntroduceShortBursts`と同じ48kHz・600Hz・2秒・12位相×3振幅（0.074／0.075／0.076）×量子化あり／なしの72条件を各bitrateで比較した。300ms settling、2ms窓、振幅下限、誤差上限0.006は変更していない。native monoのpan gainを既存と同じ方法で補正した。

| 目標kbps | 変換成功 | 既存波形条件の合格 | 最大2ms窓誤差 |
|---|---|---|---|
| 8 | 72／72 | 0／72 | 0.076132 |
| 12 | 72／72 | 0／72 | 0.101144 |
| 16 | 72／72 | 0／72 | 0.029600 |
| 24 | 72／72 | 28／72 | 0.014563 |
| 32 | 72／72 | 54／72 | 0.008757 |
| 48 | 72／72 | 72／72 | 0.004540 |

全432条件で復号sample数の下限を満たした。8kbpsの一部では復元振幅も既存下限を下回った。波形誤差による不合格は、変換不可や連続packet欠落とは別の事実である。24／32kbpsはこの音質差を許容する手動候補として提供し、48kbpsの既定・品質推奨・既存回帰の閾値は維持する。AACの手動低帯域候補とも同じ区別で扱う。

### 符号化量とenvelope量

4音声の合計bytesを合計入力時間で割った平均kbps。左がnative圧縮data、右がpackageのJSON／base64 envelope。CVBR・無音を含むため目標bitrateと平均圧縮量は一致しないが、native設定の読み戻しは上記のとおり一致した。外側EncodedCodecFrameのJSON量も各JSONへ記録した。暗号・transport header・制御・再送等を含む実通信量ではない。

| 目標kbps | 16kHz data／envelope | 24kHz data／envelope | 48kHz data／envelope |
|---|---|---|---|
| 8 | 8.12／147.45 | 8.12／147.46 | 8.12／147.45 |
| 12 | 10.84／152.07 | 10.82／152.08 | 10.79／152.04 |
| 16 | 13.62／157.51 | 13.62／157.57 | 13.62／157.55 |
| 24 | 19.14／164.74 | 19.14／164.74 | 19.15／164.75 |
| 32 | 24.66／171.91 | 24.67／171.96 | 24.67／171.92 |
| 48 | 35.71／187.18 | 35.71／187.18 | 35.72／187.20 |

最大envelopeは目標24kbpsで232／234／234bytes、32kbpsで248／249／251bytes、48kbpsで282／285／286bytes（16／24／48kHz）。48kHzでは48→24kbpsでdataは約46%、envelopeは約12%減った。目標値の半減を実通信量の半減とは扱わない。

### 製品差分・回帰・証跡

| 項目 | 確認した範囲 |
|---|---|
| 公開範囲 | `OpusOptions`を24〜128kbpsへ変更。24kbpsは検証して提供する製品上の下限で、OSの技術下限ではない。初期化／Codable／property変更は同じclampを使う |
| TDD | 元の48kbps下限で追加3試験が41件の期待違反を報告。製品変更後、既存normalizationの旧48期待を24／32へ揃え、既存35＋追加3の全38試験が成功。既定48kbpsのRealtime波形72条件も変更なしで成功 |
| 追加回帰 | 24／32kbps×16／24／48kHzで実native値・実復号・短い音声と無音の連続性。8〜256kbps入力のinit／decode／mutation正規化。実圧縮payloadの24＜32＜48を検査 |
| RTCへの影響 | RTCはCodec packageに依存せずbitrateをmetadataとして運ぶ。変更した公開clampを呼ばず、packet形式・暗号・配送処理・既定値も不変。既存relay契約には32kbpsのmetadata保持がある。本工程でRTC実装変更や無関係な全経路試験は追加していない |
| 実験の保全 | `.validation/opus-lowbandwidth`へ84音声JSON／WAV／log、432波形JSON／log、oracle、前後hash、実験floor8 patchと入力、製品RED／GREENを保持。独立probeは`/private/tmp/RideIntercom-OpusProbe`、製品worktreeは`/private/tmp/RideIntercom-opus-lowbandwidth` |
| 実行OS | 実験84＋432条件と製品38試験のnative実測はmacOSのみ。iOSでは同じsourceを使うが、この工程ではSimulatorを起動しておらず、iOS native bitrateの実適用は未確認。Mac結果で代替しない |
| 境界 | 8／12／16kbpsも実験では変換可能。品質差のある追加候補として残し、恒久非対応とはしない。Appの24／32kbps選択は次のApp工程。実機聴感、雑音下の明瞭度、通信経路全体の量・遅延、電池は未受入 |

実験のfloor8を元に戻した時点でも従来35試験を成功させた。製品範囲24の最終試験は別のsource hashとlogを保持し、実験binaryの成功を製品sourceの再実行と混同しない。

## Opus手動候補のApp接続

packageコミット`95636f0`から独立したApp工程で、既存Stepper・設定保存・送信設定更新へ24／32kbpsを接続した。package、server、既定48kbpsと品質閾値は変更していない。App選択肢は明示24／32と従来48〜128kbpsであり、packageの公開範囲全体とは区別する。追加候補のnative能力は既存cacheを共用して確認する。

| 検証 | 結果・境界 |
|---|---|
| TDD | 追加の不正低値復旧と日本語説明の2試験が変更前に31件の期待違反。構文／不足importの初回build失敗も別logへ保持し、実行時REDと混同しない |
| Mac App | App453試験・51suite成功。Stepper上下限をnil closureで標準disabledへ揃えた最終小修正後は、Opus＋AACの関連10試験を再実行して成功。24／32×16／24／48kHzのUserDefaults保存復元、codec／周波数切替、成立した通話中の送信設定とRTC policy更新、受信側再起動なし、対象外低値を48へ戻すこと、既定不変を確認 |
| native実適用 | 新App試験`OpusLowBandwidthAppTests.manualChoiceConfigurationCreatesNativeEncoder`で、Appが解決した設定から実StreamingCodecEncoderを生成し、そのAVAudioConverterのbitrate・sample rateを読み戻して符号化・復号した。Appの実送信中encoderそのものの読み戻しではない。24／32×3周波数はMacで成功 |
| iOS／Widget build | generic iOS署名なしbuild成功。App・Widget・Watchが同じbuild番号で埋め込まれた。Simulator起動・iOS native converterの実行・実署名は行っていない |
| 英日 | 追加説明の日本語unitと、生成済みen／jaのLocalizable.strings値を照合。24／32の低品質表記は既存の翻訳を再利用 |
| UI操作 | 既存UI suiteへ`testOpusManualLowBandwidthChoicesSurviveFormatAndCodecChanges`を追加。24→32→48の操作、各周波数とcodec切替、低品質表示を検査する。コンパイル成功、操作実行は統合先で行うため未確認 |
| 入力と回収 | 各検証のApp／test／package／Widget／Watchの315入力がMac試験・iOS buildの前後一致。453試験時点から最終境界小修正までの差分も別hashとして保持。専用namespaceとDerivedDataを使用し、所有App hostの残留0。package差分0 |
| warning | Swift compile warningなし。AppIntentsを持たないUITest bundle／Watchのmetadata extraction skippedという既知の工具warningは記録し、0件と報告しない |
| 証跡 | `/private/tmp/RideIntercom-opus-app/.validation/opus-app`へRED／GREEN xcresult、generic iOS build、前後hash、生成resource、host回収を保管 |

iOS native実適用の次の受入は、既存iOS App単体試験のdestinationで上記native試験を実行すること。AVAudioEngine・実マイク・スピーカーは不要だが、Mac実測やiOSコンパイル成功では代替しない。実機聴感と実通信量・電池の未確認も引き続き維持する。
