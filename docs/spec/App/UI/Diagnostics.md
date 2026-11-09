# RideCom Diagnostics 画面項目

## 表示実装の所有

| 所有者 | 責務 |
|---|---|
| DiagnosticsInput | 更新時にViewModelから必要な値だけsnapshot化。子ViewはViewModelを保持しない |
| TransmitPipelinePresentation / ReceivePipelinePresentation | snapshotから状態・理由・step・peer表示を純粋に導出。副作用やObservable状態を持たない |
| LiveTransmitPipelineView / LiveReceivePipelineView | 表示順と画面構成。既存の項目・更新周期・識別子を維持 |
| PipelineComponents / ReceiveMixViews / DiagnosticsPipelineDetails | 必要な表示値だけ受け取る描画部品。色とアイコンの対応も描画側に置く |


各pipeline行とeffect stageは、既存状態を色と記号で示し、VoiceOverの値に状態語と既存の詳細を含める。`passing`はPassing（checkmark）、`waiting`はWaiting（pause）、`blocked`はBlocked（octagon）、`idle`はIdle（dashed circle）とする。Passingには累計のpacket・frame数に基づく状態も含まれ、現在の流量を証明しない。特大文字では行の名前・package・詳細を折り返す。effect stage chipは、色と記号の`PipelineStepState`が`waiting`と`unavailable`、`bypassed`と`idle`を同じ値にまとめるため、名前の右にまとめる前の`AudioEffectStageRuntimeState`の値（`active`・`waiting`・`unavailable`・`bypassed`・`idle`）をそのまま文字で出し、VoiceOverの値にもその語を使う。

## 目的

本書は Diagnostics タブの UI 項目を定義する。

Diagnostics はログを読む代替ではない。音声 pipeline の現在状態は送信/受信パイプラインで見せ、現在状態一覧は pipeline から読み取れない App 状態と network quality に絞る。

## 入力データ

Diagnostics は package から得た runtime snapshot / report を正とする。App は表示名、折り返し、severity への写像だけを担当し、mixer 経路、effect chain、codec fallback、SessionManager resolved 値、RTC 接続状態を App 固有の固定値で作り直さない。

| 入力 | 主な参照先 | 描画先 |
|---|---|---|
| `AudioMixerSnapshot` | `audioMixerSnapshot` | TX Bus、TX FX、Peer Buses、Mix Down、RX Master、Master FX、mixer graph |
| `MixerBusSnapshot.effectChain` | `transmitEffectChainSnapshot`、`receivePeerEffectChainSnapshot(peerID:)`、`receiveMasterEffectChainSnapshot` | effect stage chip の順序、状態、detail |
| `CodecRuntimeReport` | `codecRuntimeReport`、`selectedTransmitCodec` | Codec / Decode |
| `VADGateRuntimeSnapshot` | `vadGateRuntimeSnapshot` | VAD stage、発話状態、noise floor、threshold、gain |
| `VoiceIsolationRuntimeSnapshot` | SoundIsolation report / AudioMixer effect metadata | SoundIsolation stage |
| `DynamicsProcessorRuntimeSnapshot` | DynamicsProcessor report / AudioMixer effect metadata | DynamicsProcessor stage |
| `PeakLimiterRuntimeSnapshot` | 接続したTX / RX出力Limiterの実設定 | 起動前・停止後はruntime stageを表示しない |
| `SessionManager` report / snapshot | session、input、output、voice processing の直近 report | Session、Input、Output |
| `RTC.RouteMetrics` | `lastRouteMetrics` | Network Quality |
| `RTCRuntimeStatus` | `remoteRuntimeStatuses` | remote package runtime 状態の入力 |
| App 状態 | group、invite、display name、local UI state | Call、Invite、参加者名 |

## 画面構成

`diagnosticsPagePicker`でOverview、TX、RX、Network、Appliedを切り替える。5ページの選択には、全ページが一目で見える標準のsegmented Pickerを使う。iOSのアクセシビリティ文字サイズでは5つの区画が入らないため、同じ識別子の標準NavigationLinkから選択List（`diagnosticsPageSelection`、選択中にcheckmark）を開き、選ぶと元の画面へ戻る。幅600pt以上ではOverview以外のページの左にOverviewの内容（Pipelineの要約と症状の案内）を並べる。旧来の概要カード（Audio Path / Call / Network Quality / Invite）は[Overview](../../../design/詳細画面/診断と詳細画面の構成.md#overview)のとおり廃止し、どこにも表示しない（行の値はAppliedのCall・Inviteが引き続き使う）。画面内のページ選択は表示状態であり、ViewModelのsnapshotや通話状態を作り直さない。Overviewの `diagnosticsOthersCannotHearButton` はTX、`diagnosticsCannotHearButton`・`diagnosticsAudioDropsButton`・`diagnosticsAudioDelayedButton` はRXへ移動する。これらはページと該当する段へ移動し展開する案内であり、原因を自動診断した結果ではない。TXの各段とRXの相手および出力詳細は標準DisclosureGroupで開閉する。

TX/RXは従来のpipeline、Networkは、経路（Local・Internet）ごとのカード（`diagnosticsNetworkLocal`／`-Internet`）に、ラベルと値の2列で`RTT`、`Loss`（`· Jitter`）、`Send queue`、`Event drops`（`Overflow n · Expired n`。どちらかが0でなければ警告の記号）を並べる。見出しの右に「Updated n s ago」（経過15秒超は`· Stale`）を出す。最後に観測した経路は`Paths`のカード（`diagnosticsNetworkPaths`）に1人1行で、名前・`Direct group path`／`Relayed`と経路・短縮IDの経路と経過秒を出す。session全体のevent dropsはカードの上の1行。Appliedは`Requested → Applied`のカードで、1行に項目名・値（要求と適用が違えば「要求 → 適用」）・判定を置く。判定は、実装が比べている行（Codec・Session・Input sample rate）だけに出し、同じなら「Same」（success）、違えば「⚠ Differs」（warning）。Codecは`CodecIdentifier.displayName`と`48 kHz · 48 kbps`の単位で出す。経路が一致する単一の最新metricsのみ利用し、未取得値をNot measuredとする。Overviewは先頭の判定（`diagnosticsVerdict-TX`／`-RX`、`PipelineVerdict`）で、TX・RXそれぞれ最初のblocked／muted、なければ最初のwaitingの段を`TX: Waiting at VAD`の形で太字に、その段のdetailを理由として下の行に出す。全段passingは`Passing`、全段idleは`Idle`、passingの後にidleが残るときは`Idle at {段}`。状態は文字サイズに合わせて大きくなる8ptの点（idleは破線の輪）と語で示す。続けて`Pipeline`に、TXとRXの全段を方向ごとに1行（`diagnosticsStageDots-TX`／`-RX`）で、段名と状態の点を並べる（幅が足りなければ折り返す。VoiceOverは「TX: Session Passing, …」と1要素で読む）。`Participants`（見出しに自分以外の人数）は1人1行で、名前・観測した経路（`Local · direct`／`Local · relayed`／`Internet`、未観測は`—`）・保存された`PeerConnectionState`の点と語（`Connected`／`Connecting`／`Offline`。Offlineは薄く）。`Network`は経路が観測されたときだけ、1経路1行で経路名・相手数・`RTT`（未取得は`Not measured`）。最後に症状の4つのボタン（`.glass`、幅に合わせて折り返す）。TX/RXは機器、VAD、観測経路、相手別情報と出力buffer/resetを既存値から表示し、差分履歴を持たない毎秒値はNot measuredとする。Appliedはcodec、Sessionの要求と解決済み設定、stream実測sample rate、未計測のIO buffer、Unsupported、Ducking、機器、VAD、isolation、Call/InviteおよびInternet Serviceを表示する。Sessionの解決済み設定はハードウェア実測と区別し、未取得はNot measuredとする。

| 項目名（日本語） | 項目ID | 目的 | 実装 | 更新周期 | 表示仕様 |
|---|---|---|---|---|---|
| 診断画面 | `diagnosticsScrollView` | package runtime report と App 状態を要約する | `DiagnosticsView` | 表示中0.5秒。開く時点は即時、非表示のsnapshot作成は5秒 | `TimelineView` + `ScrollView` |
| 送信パイプライン | `liveTransmitPipelineView` | ローカル送信がどこまで進んでいるかを読む | `LiveTransmitPipelineView` | 0.5 秒 | compact row。effect chain は TX bus 内に内包表示 |
| 受信パイプライン | `liveReceivePipelineView` | 受信音声が出力までどこまで進んでいるかを読む | `LiveReceivePipelineView` | 0.5 秒 | compact row。peer bus は複数行一覧、effect chain は該当 bus 内に内包表示。RX master FXは実グラフの内容のみを表示する |

### Diagnosticsの状態と遷移

[UIスタック](../../../design/デザインシステム.md#uiスタック)の5状態を、既存のpackage report・snapshotの有無と各段の状態から導出する。ページ選択は表示状態だけを変え、どの状態でも全5ページへ移動できる。

| 状態 | 成立条件・表示 | 操作・遷移・復帰先 |
|---|---|---|
| Ideal | 通話中で各段がRunning、Networkの最新metricsが15秒以内。Overviewの要約は`Running` | 症状の案内から該当ページと段へ移動して展開する。ページ選択でOverviewへ戻る |
| Empty | 通話先・通話がなく、reportが未取得。各段はIdle、Networkは接続を促す`Not measured`の文言、Appliedの未取得値は`Not measured` | 通話はCall／Users／Groupsから開始する。Diagnosticsから通話を開始・変更しない |
| Error | いずれかの段がBlocked（session・codec・RTC等の失敗）。Overviewの要約が最初のblockedの段と理由を示し、記号と語で色以外でも区別する | 「Others can't hear me」はTXの最初の未成立段へ移動する。復旧操作は各機能の画面（Call・Settings）で行う |
| Partial | 一部の段がWaiting／Muted、Networkが15秒超で`Stale`、相手や経路の値が未取得。取得済みの値と`Not measured`を並べ、未取得値を推測で埋めない | 値は0.5秒ごとの更新で自然に変わる。経路の再接続はDiagnosticsから行わない |
| Loading | 画面を開いた直後。表示時に即時のreport公開を要求し、届くまでは直前のsnapshotまたはEmptyの表示を使う。専用の読込画面は持たない | 次の0.5秒更新で該当状態へ移る |

## 送信パイプライン

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 状態・異常系の考え方 |
|---|---|---|---|---|---|---|
| SessionManager sessionステップ | `liveTransmitPipelineView` | `pipeline-session-step` | Session | `AudioSessionSnapshot`, `audioSessionProfile`, 直近 session report | 状態アイコン + profile | session error は blocked |
| SessionManager inputステップ | `liveTransmitPipelineView` | `pipeline-input-step` | Input | `AudioInputStreamCapture` snapshot、voice processing report、`isMuted` | stream format、frame count、mute | ミュートは故障ではなく waiting |
| AudioMixer TX busステップ | `liveTransmitPipelineView` | `pipeline-mixer-step` | TX Bus | `AudioMixerSnapshot` の `tx-bus` / source / routing 状態 | `source count -> FX count` として表示 | mixer 未開始は neutral |
| AudioMixer effect chainステップ | `liveTransmitPipelineView` | `pipeline-effects-step` | FX Chain | `AudioMixerSnapshot` の `tx-bus.effectChain` から導出した `transmitEffectChainSnapshot.stages` | TX bus 配下の inline stage chip として表示 | stage 内の unavailable / bypassed を warning 以下で表示 |
| codec ステップ | `liveTransmitPipelineView` | `pipeline-codec-step` | Codec | `preferredTransmitCodec`, `selectedTransmitCodec` | requested と selected を表示。fallback 時は `requested -> selected / Fallback` | fallback は warning |
| RTC ステップ | `liveTransmitPipelineView` | `pipeline-rtc-step` | RTC | `sentVoicePacketCount`, route, media ownership | packet 送信数と route | 送信 0 は未発話または未接続として読む |

## 送信 effect chain 表示

effect chain は AudioMixer package の `MixerBusSnapshot.effectChain` を正として、App の `transmitEffectChainSnapshot` から表示する。Diagnostics は effect の既定値や stage 配列を持たない。Diagnostics では FX Chain 行の下へ stage chip をインライン表示し、TX bus の内包関係が見えるようにする。

| stage | accessibilityIdentifier | package | 表示する状態 |
|---|---|---|---|
| SoundIsolation | `pipeline-effect-stage-sound-isolation` | SoundIsolation | enabled / bypassed / unavailable |
| VADGate（Mixer前段） | TX effect stage IDは持たない | VADGate | speech / silent / muted、感度preset、noise floor、threshold、gainはruntime reportに保持するが、現行画面に専用詳細行はない。tx-busのFX chipには含めない |
| DynamicsProcessor | `pipeline-effect-stage-dynamics-processor` | DynamicsProcessor | leveling ready / idle |
| PeakLimiter | `pipeline-effect-stage-peak-limiter` | PeakLimiter | peak guard ready / idle |

| 拡張ルール | 仕様 |
|---|---|
| stage 追加 | AudioMixer package の `tx-bus.effectChain` に stage が追加されれば Diagnostics の表示順へ反映する |
| 固定文字列禁止 | `SoundIsolation -> VADGate -> DynamicsProcessor -> PeakLimiter` のような固定文言や default 値を UI の正本にしない |
| 一覧性 | stage が増えた場合は FX Chain 行の内側で折り返し、ログを読まなくても各 stage の現在状態を読めるようにする |

## 受信パイプライン

| 項目名（日本語） | 親項目 | 項目ID | ラベル | データ仕様 | 表示仕様 | 状態・異常系の考え方 |
|---|---|---|---|---|---|---|
| RTC受信ステップ | `liveReceivePipelineView` | `receive-pipeline-rtc-step` | RTC RX | route、connected peer count、authenticated peer count、受信 packet count、media ownership | route と総 RX count。peer別の接続・認証・経路は下の参加者内訳に表示 | 受信 0 は未発話または未接続として読む |
| Codec decodeステップ | `liveReceivePipelineView` | `receive-pipeline-codec-step` | Decode | peer ごとの `activeCodec`、peer ごとの RX count、drop count | codec の集約サマリは出さない。peer別のdecode codecは下の参加者内訳に表示 | drop は warning |
| peer busステップ | `liveReceivePipelineView` | `receive-pipeline-peer-bus-step` | Peer Buses | `AudioMixerSnapshot` の RX peer bus、authenticated peer count、peer 別 RX / JIT / PLAY / level / volume / `receivePeerEffectChainSnapshot(peerID:)` | bus 数と RX count。peer別の音量・FX要約・待機frame数は下の参加者内訳に表示 | peer なしは neutral / waiting |
| receive mix downステップ | `liveReceivePipelineView` | `receive-pipeline-mix-step` | Mix Down | `AudioMixerSnapshot.routes`、peer bus count、受信 packet count | `n routes -> rx-master` として複数 peer が master に集約されることを表示 | bus なしは waiting |
| receive master busステップ | `liveReceivePipelineView` | `receive-pipeline-master-bus-step` | RX Master | `AudioMixerSnapshot` の `rx-master`、played frame count、master volume、source bus count | source bus count と OUT volume。mix 後の 1 本の master bus として表示 | 再生 0 は waiting |
| master effect chainステップ | `liveReceivePipelineView` | `receive-pipeline-master-effects-step` | Master FX | `AudioMixerSnapshot` の `rx-master.effectChain` + `rx-output.effectChain` から導出した `receiveMasterEffectChainSnapshot.stages` | RX Master 配下に適用される ordered stage chip として inline 表示（Isolation → master fader → 出力Limiter） | stage 単位で unavailable / bypassed を表示 |
| outputステップ | `liveReceivePipelineView` | `receive-pipeline-output-step` | Output | output renderer snapshot、mute、volume | stream format、frame count、mute | mute / volume 0 は warning |

## 受信 mix topology 表示

`LiveReceivePipelineView` はRTC RX、Decode、Peer Busesの段を1行ずつ並べ、その下に参加者ごとの内訳（`diagnosticsReceiveDetails`）を置く。内訳の見出し`receive-mix-topology`（Participants）の下で、自分以外のメンバーを標準DisclosureGroupで開閉する。peerが増えても巨大なcard gridへせず、開いた参加者だけ詳細行を表示する。Overviewの「I can't hear someone」「Audio drops out」は全参加者を開いた状態でこの位置へ移動する。

| 項目 | accessibilityIdentifier | 表示する状態 |
|---|---|---|
| 参加者内訳 | `diagnosticsReceiveDetails` | 見出しと参加者の一覧。通話先がなければNo participants |
| 内訳の見出し | `receive-mix-topology` | Participants |
| 参加者行 | メンバーIDを`id`に持つDisclosureGroup | 表示名（2行まで）。開くと、送信側のミュート（`mic.slash.fill`と語）、送信側のcodec・bitrate・VAD・isolationと報告の経過秒（15秒超はStale）、RTC RXの接続・認証・経路（Internet／Local direct／Local relayed）、Decode codec、Peer Busの音量・FX要約・待機frame数。offlineはOfflineだけを表示する。未取得値はNot measured |
| master mix row | `receive-master-mix-card` | source bus count、総 RX、PLAY、master volume / mute、RX master effect summary、出力 level |

## 受信 effect chain 表示

受信側は peer bus と receive master bus のそれぞれに ordered stages を持つ。Diagnostics は AudioMixer package snapshot 由来の `receivePeerEffectChainSnapshot(peerID:)` と `receiveMasterEffectChainSnapshot` を描画するだけで、effect の default 値や stage 配列を持たない。peer 側は全体で 1 つの共有 Peer FX 行にまとめず、参加者内訳の各参加者にstageの要約（`effectSummary`）として表示する。stage別のchipと識別子は持たない。

| chain | stage | accessibilityIdentifier | package | 表示する状態 |
|---|---|---|---|---|
| Peer FX | SoundIsolation | 参加者内訳の`FX`要約（stage別の識別子なし） | SoundIsolation | enabled / bypassed / unavailable |
| Master FX | SoundIsolation | `receive-master-effect-stage-sound-isolation` | SoundIsolation | enabled / bypassed / unavailable |
| Master FX | PeakLimiter | `receive-master-effect-stage-peak-limiter` | PeakLimiter | final peak guard ready / idle |

| 拡張ルール | 仕様 |
|---|---|
| stage 追加 | AudioMixer package の peer bus または master bus の `effectChain` に stage が追加されれば Diagnostics の表示順へ反映する |
| RX master limiter | 実グラフのrx-outputに存在するPeakLimiterを、master volume後の最終stageとして表示する |
| 固定文字列禁止 | 受信側も固定の effect 名列挙や default 値を UI の正本にしない |
| 一覧性 | peer chain は peer row 内、master chain は RX master row 内で別々に表示し、どちらで処理が止まっているかをログなしで読めるようにする |
| 表示順検証 | Diagnostics の effect chip は `AudioEffectChainSnapshot.stages` の登録順をそのまま使う。任意 stage を追加した順序が UI 表示用 model へ保持されることをテストする |

## Mixer graph 描画形式

AudioMixer package は UI 描画用の専用 DTO ではなく、現在の信号経路を説明する `MixerGraphSnapshot.nodes` / `edges` を返す。Diagnostics がグラフ表示を持つ場合はこの形式をそのまま使う。

| graph 要素 | 描画仕様 |
|---|---|
| `source` node | マイク入力または peer audio source として表示する |
| `busInput` node | bus 内の集約点として表示する |
| `effect` node | `MixerEffectSnapshot` の順序、状態、metadata を chip または node に表示する |
| `busFader` node | bus volume / mute の表示に使う |
| `output` node | final output として表示する |
| `sourceToBusInput` edge | source から bus input への接続として描く |
| `busSignal` edge | bus input、effect chain、fader の順序として描く |
| `busRoute` edge | RX peer bus から RX master bus への mix route として描く |
| `outputRoute` edge | RX master から output への接続として描く |

## 受信 peer metadata

| 項目 | 仕様 |
|---|---|
| codec metadata | keepalive metadata に remote peer の active codec を載せ、受信側の `GroupMember.activeCodec` に反映する |
| decode 表示 | Diagnostics は `activeCodec` を Decode ステップ内の `receive-peer-codec-{index}` に `DEC ...` として表示する。未受信または metadata 未到達の場合は `Unknown` とする |
| RTC 接続表示 | `GroupMember.connectionState` と `GroupMember.authenticationState` を RTC ステップ内の `receive-peer-rtc-{index}` に表示する |

## 現在状態一覧

| 項目名（日本語） | 項目ID | ラベル | データ仕様 | 表示仕様 | severity |
|---|---|---|---|---|---|
| Appliedの通話カード | `diag-call-route-summary` | `Call` | `connectionLabel`, selected group summary | `CALL {state}` / selected group | 接続中は ok、未接続は neutral |
| Appliedの招待カード | `diag-invite-summary` | `Invite` | 招待可否、invite status、selected group | `INVITE ...` / group summary | 招待操作の前提が揃えば ok。表示更新では鍵の読込・作成や招待署名を行わない |

## 一覧性のルール

| 項目 | 仕様 |
|---|---|
| 表示粒度 | 1 カードは 1 つの層だけを示す。複数層の原因推測を 1 行へ詰め込まない |
| 文字量 | summary は 1 行、detail は補足。長文ログや stack trace は置かない |
| 色 | ok / warning / error / neutral をカード左アイコン色で示す |
| 表示順 | Appliedの`Requested → Applied`の後に、Call、Inviteの順。各カードは`State`の行（summary）と補足（detail）。RTT・loss・jitterはNetworkの経路ごとのカードに出す |
| ログとの関係 | Diagnostics で現在値を読み、ログは操作境界や失敗の後追い調査に使う |
| 環境差異 | unsupported / ignored は warning 以下に留め、継続可能な状態として表示する |
| パイプライン表示 | 各 pipeline step を大きな独立 card にしない。1 step は compact row、stage は親 row の内側の chip として表示する |
| 受信 peer 表示 | peer bus は複数人を前提に 1 peer 1 行で表示する。peer 数が増えても topology 全体を巨大 card grid にしない |
| overview の重複禁止 | Session、Input、Output、Codec、Mixer、Authentication など pipeline で読める値は現在状態一覧へ再掲しない |

## Accessibility Identifier

既存 UI テストと調査導線を壊さないため、一覧カードは旧 debug label の identifier を維持する。

| カード | accessibilityIdentifier |
|---|---|
| Call | `realDeviceCallDebugSummaryLabel` |
| Network Quality | `receptionDebugSummaryLabel` |
| Invite | `inviteDebugSummaryLabel` |

## 診断と適用状態の区別

実Mixerを毎回作り直して表示用の仮ノードを足す処理は使用しない。`AppAudioPipeline.snapshot` のbus、source、sink、routeをそのまま報告する。VADはMixer前段で実行するのでMixerのeffect chipには追加しない。上記stage IDは実ノードを配線した場合の表示契約であり、現在のSoundIsolation / DynamicsProcessor / PeakLimiter適用を示すものではない。

## 確認導線と実音声の区別

| 順序 / 項目 | ID / 表示 | 契約 |
|---|---|---|
| 概要 | `audioPathSummary` / Call / Network / Invite | 現在の媒体所有者を最初に表示。長い値は行数で切り捨てない |
| Internet Service | `internetServiceCheckStatus` | 保存前、確認中、認証済み、失敗をテキスト表示。tokenを含めない |
| Check Internet Service | `checkInternetService` | RTCのcheckServiceを呼ぶ。資格がない場合と確認中はdisabled。SFU媒体を作らない |
| 認証成功後 | active session数、予約参加者秒/月枠、対象月 | Workerの設定と端末認証の確認。SFU App Secretの正当性や音声成功とは別 |
| Local packet音声 | 既存TX/RX pipeline | 実際のMixer/codecのruntime reportを表示 |
| 全経路の音声 | Shared packet audio / TX/RX pipeline | 実際のPCM・packet・effect reportを表示。Internet失敗詳細をNetworkへ表示し、未提供のRTT/lossは未測定とする |
| Network | 測定値が全てnilならneutral | 不明をloss 0%や正常と扱わない |

Audio CheckはSettingsに置く。端末内の録音再生、サービス認証、ペアの媒体、実機の音響品質を別の確認として扱う。

## Network診断

| 表示 | identifier | 意味 |
|---|---|---|
| Network | `networkDiagnosticsSummary` | RTCNetworkDiagnosticsの表示。計測処理はRTC/native側が所有 |
| RTT / send queue | 同上 | ICE transport RTTをms、DataChannel送信待ちをbyte表示。未取得をNot availableとする |
| Event drops | 同上 | session / route / engine / transportのoverflowとexpired。ネットワーク損失率ではない |
| Direct group path / Relayed | 同上 | 最後の認証済み受信経路。短縮peer IDを矢印で並べる。到達保証ではない |
| Not measured / stale | 同上 | 未取得、または15秒を超えたreport。古い数値を正常値として表示しない |

値は標準Textで折り返し・選択でき、色やアイコンだけに依存しない。切断・接続切替・世代変更時に旧reportを消去する。
