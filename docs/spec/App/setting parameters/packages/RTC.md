# RTC package 設定値

## 目的

本書は、作り直す RideIntercom App が `RTC` package へ渡す固定値、導出値、runtime event / metrics の扱いを定義する。

画面から直接設定する値は `docs/spec/App/setting parameters/App/設定値一覧.md` を正とし、本書では package adapter が決める値だけを扱う。

## CallRouteConfiguration

| package 設定 | App から渡す値 | 種別 | Diagnostics で確認する値 |
|---|---|---|---|
| `enabledRoutes` | Settings の `enabledRTCTransportRoutes`。既定は `[.multipeer, .webRTC]`。App は空集合を既定 route へ修復する | App 設定 | route capabilities / runtime status |
| `preferredRoute` | `enabledRoutes` に `.multipeer` があれば `.multipeer`。`.webRTC` のみなら `.webRTC` | adapter policy | active / preferred route |
| `selectionMode` | package default の `.automaticFallbackAndRestore` | package default | selection mode / handover state |
| `fallbackDelay` | package default | package default | runtime status の route configuration |
| `restoreProbeDuration` | package default | package default | runtime status の route configuration |
| `handoverFadeDuration` | package default | package default | runtime status の route configuration |
| `keepsPreferredRouteInStandby` | package default の `true` | package default | standby route state |
| `keepsFallbackRouteWarm` | package default の `false` | package default | handover / fallback state |

App は実体 route を直接構築しない。`CallSessionFactoryConfiguration` に display name、`CallRouteConfiguration`、`RTCAudioPolicy`、WebRTC native engine factory を渡し、RTC package の `CallSessionFactory` が `.multipeer` と `.webRTC` の route set を構築する。route 設定変更時は active RTC connection を止め、次回 `prepare` / `startConnection` では更新後の `enabledRoutes` と RTC package の fallback / restore policy を正とする。App は `enabledRoutes == []` を RTC package へ渡さず、旧 UserDefaults や不正値は既定 route へ修復する。App は package が返す route availability、failure reason、media ownership を Diagnostics または runtime status の入力として扱う。

## Settings route opt-out

| App 状態 | package へ渡す `enabledRoutes` | App の即時動作 |
|---|---|---|
| Local Network ON、Internet ON | `[.multipeer, .webRTC]` | active RTC connection があれば停止する。次回 standby / connect は RTC package が両 route を構築し、自動 fallback / restore を扱う |
| Local Network ON、Internet OFF | `[.multipeer]` | active RTC connection があれば停止する。次回 standby / connect は Multipeer route だけを有効にする |
| Local Network OFF、Internet ON | `[.webRTC]` | active RTC connection があれば停止する。次回 standby / connect は WebRTC route だけを有効にする |
| Local Network OFF、Internet OFF | 許可しない | 最後に残った route の toggle は無効化し、旧設定で空集合を読んだ場合は `[.multipeer, .webRTC]` へ修復する |

App は RTC package の route manager、route state、runtime status を置き換えない。Settings は `CallSession.setEnabledRoutes(_:)` で App-owned adapter policy を更新し、adapter は次回の RTC session / `CallStartRequest.configuration` へ渡すだけである。

## CallStartRequest / RTC 入力

| package 設定 | App から渡す値 | 種別 | Diagnostics で確認する値 |
|---|---|---|---|
| `RTCCredential` | group ID と Keychain の group secret から生成する | App 状態から導出 | credential presence のみ |
| `PeerDescriptor` | local member ID と display name から生成する | App 状態から導出 | peer ID hash / display name |
| `expectedPeers` | selected group の保存 member から生成する | App 状態から導出 | expected / connected / authenticated count |
| `RTCAudioPolicy.preferredSendFormat` | `rtcAudioFormatPreset.audioFormat` を `RTCAudioFormat` へ変換する。既定は 48kHz mono | 画面設定から導出 | audio format |
| `RTCAudioPolicy.preferredCodecs` | `CodecRuntimeReport.resolving` で選ばれた codec を先頭に置き、必要なら `.pcm16` fallback を続ける | 画面設定 + package runtime から導出 | requested / selected codec |
| `RTCAudioPolicy.maximumBitRate` | 選択 codec の active bitrate を渡す。bitrate を持たない codec は `nil` | 画面設定 + package runtime から導出 | active bitrate |
| `PacketAudioReceiveConfiguration` | package default | 固定 | playout delay / queue / drop metrics |

group secret は group list へ保存せず、Keychain から取得して credential 生成にだけ使う。ログと Diagnostics には secret、token、認証 MAC、鍵材料を出さない。

## ApplicationDataMessage

| package 設定 | App から渡す値 | 種別 |
|---|---|---|
| `namespace` | `rideintercom.keepalive` | 固定 |
| `delivery` | `.unreliable` | 固定 |
| `payload` | `{ "activeCodec": AudioCodecIdentifier? }` | App 状態から導出 |
| `namespace` | `rideintercom.peerMuteState` | 固定 |
| `delivery` | `.reliable` | 固定 |
| `payload` | `{ "isMuted": Bool }` | App 状態から導出 |

Application Data の App-owned namespace と payload schema は App が所有する。RTC package は payload の意味を解釈しない。`rideintercom.rtc.runtimeStatus` は RTC package-owned namespace であり、App-owned payload として扱わない。

## Runtime status / package report

| 設定 / API | App から渡す値 | 種別 | Diagnostics で確認する値 |
|---|---|---|---|
| `RTCRuntimeStatusPolicy.isAutomaticBroadcastEnabled` | `RouteManager` default の `true` | package default | runtime status 受信有無 |
| `RTCRuntimeStatusPolicy.periodicInterval` | `RouteManager` default の `5` 秒 | package default | remote status `generatedAt` |
| `CallSession.updateRuntimePackageReports(_:)` | App が集約した `RTCRuntimePackageReport` 配列 | runtime report | status `packageReports` |
| `RTCRuntimeStatusTransport.namespace` | `rideintercom.rtc.runtimeStatus` | package-owned | remote runtime status |

App 側の report 更新間隔は 0.5 秒を下限とする。RTC は package report 更新を受けたときに `reason == .packageReportsChanged` の runtime status を送信できるため、接続中の peer には package 設定や操作状態が変更時と定期周期の両方で届く。

## Runtime event / metrics の App 側処理

| Event / metrics | App の扱い | UI 反映 | ログ |
|---|---|---|---|
| connection state | Call 表示用の connection summary へ要約 | Call / Diagnostics | `rtc.connection.started`、`rtc.connection.failed` |
| route state | active / standby / unavailable を保持 | Diagnostics の Route 行 | `rtc.route.changed` |
| handover | media 所有と出力を同期 | Call / Diagnostics | `rtc.route.handover.started`、`rtc.route.handover.completed` |
| member update | participant 表示へ反映 | Call Participants | debug |
| `RouteMetrics` | RTT、jitter、packet loss、queue、drop を要約 | Diagnostics の Quality 行 | warning threshold 超過時だけ |
| `RTCRuntimeStatus` | peer ごとの runtime status と package report を保持 | Diagnostics の package runtime 入力 | 通常ログ禁止 |
| received audio packet | `ReceivedAudioPacket` を App 音声 composition の decode へ渡す | 参加者 level / Reception | 高頻度通常ログは禁止 |
| application data | namespace ごとに App が decode | participant mute state | decode 失敗のみ debug |
| route scoped error | route availability / runtime status として扱い、通話全体の `linkFailed` には変換しない | Diagnostics | warning |
| session failed / no enabled route | 通話全体の失敗として扱う | Call エラー / Diagnostics | error |

## App 画面に出さない値

| 値 | 扱い |
|---|---|
| route fallback / restore policy | adapter policy として扱い、通常 UI では切り替えない |
| route quality threshold | package 仕様または adapter policy 側で扱う |
| packet audio jitter / lifetime | package default と metrics を正とする |
| sequence / duplicate filter | package 仕様を正とする |
| handshake / 暗号化詳細 | package 仕様を正とし、App は結果だけを扱う |
| WebRTC native 型 | App API と UI へ露出しない |

詳細な route、packet audio、WebRTC、handover の仕様は `docs/spec/packages/RTC.md` を正とする。
