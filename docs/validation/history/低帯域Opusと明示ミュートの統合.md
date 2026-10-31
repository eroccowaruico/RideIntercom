# 低帯域Opusと明示ミュートの統合

2026-10-31。CarPlay Widgetの実装を反映した`b46c9946`に、単独検証済みのCodec変更を別コミット`9567d997`として取り込んだ。その後のApp工程でOpusの24／32kbps選択とSiri／Shortcutsの明示ミュートを統合した。packageの変更とAppの追従を同じコミットへ混在させない。

現行の値・保存は[設定値一覧](../../spec/App/Configuration/設定値一覧.md#opusの低帯域手動候補)、外部操作は[通信仕様](../../spec/App/通信仕様.md#ショートカットとsiriの通話操作)を参照する。

## 実装と確認の範囲

| 項目 | 実装と境界 |
|---|---|
| Opusの手動候補 | OSで対応を確認できる24／32kbpsを追加し、既定48kbpsと従来48〜128kbpsの選択を維持。保存した24／32は復元するが、その他の48未満の値を読み込んだだけで低音質へ切り替えない |
| 設定の共通化 | codec／format別の既存能力cacheを共通化し、画面更新ごとにconverterを作らない。通話中の送信設定変更で受信と接続を維持。Stepperは上下限を超える値へ変更しない |
| 明示ミュート | 既存App所有者・現在の通話参照・共通操作を利用する必須BoolのIntent。前面実行と端末認証を維持し、同じ値の再実行で反転させない。無通話時の設定変更だけで接続や録音を開始しない |
| 翻訳 | Localizableへ7key、AppShortcutsへ1phraseを追加。統合前の全keyとCarPlayの追加文言を保持したことを照合 |
| 個別の先行検証 | Codec全38件、Opus App全453件とStepper境界修正後の関連10件、Siri関連21件をそれぞれ隔離工程で確認。先行結果は[低帯域比較](低帯域codecの通信なし比較.md)と[明示ミュート](ショートカットの明示ミュート検証.md)へ保持 |

## 統合検証

| 確認 | 証跡 |
|---|---|
| Mac App全体 | `.validation/opus-shortcuts-final-macos`。485件成功、失敗・skip・runtime warningなし。生成ビルド番号以外の399入力が前後一致。build 258の専用StorageNamespaceをtest host起動前に確認し、終了後の所有host残存なし |
| 変更のない共通部品 | 読取監査で177入力を前後照合。AudioCore 14件、Codec 38件、Effectors各5／5／8／11件、RTC 92件とnative 4件、Worker 78件・型検査・dry-run・Swift接続1件、検証script Python 105件・Node 4件の成功証跡が該当入力に対応することを確認。App検証へ件数を合算しない |
| iPhone Simulator初回 | build 259、単体471件と既存UI 20件が成功、新Opus UI 1件は失敗。`Decrement`という試験側の検索が、実際の`opusBitRateStepper-Decrement`と一致しなかった。skip・runtime warningなし、399入力が前後一致。失敗bundleとAX診断を保持し、全体成功へ書き換えない |
| UI試験の修正範囲 | 新Opus試験メソッド内のIncrement／Decrement参照4か所だけを、実AX identifierへ修正。他398入力と全既存試験メソッドは不変。Mac全体・iOS単体・既存UIの結果を引き継ぎ、新Opus UIを限定再検証した |
| 下限の実操作確認 | locator修正後は24kbpsへ到達したが、下限の`isEnabled == false`という試験期待が失敗した。録画では24kbps時に減算ボタンが灰色となることを確認。製品sourceは変えず、試験を実際に減算操作して24kbpsを維持する確認へ変更した。再実行前の失敗と録画を別証跡へ保持 |
| iPhone Simulator補完 | build 261の新Opus UI 1件と破損データ回復UI 1件・fixture照合が成功。16／24／48kHzそれぞれで24→32→48の選択、codec切替後の保持、24kbpsで減算しても24を維持することを確認。399入力一致、専用namespaceを起動前に確認、終了後は専用SimulatorをShutdownしleaseを解放。製品source不変のため成功済み単体471件と既存UI 20件を再実行しない |
| iPad Simulator初回 | build 264の英語・日本語の回転／シート／通話UI 2件は成功。新Opus UIはcodec欄が画面最下部に見えた時点で止まり、下のStepperがlazy Formで未生成のため存在確認に失敗。画像・AXを保持し、既存`revealSettingsControl`で対象欄までスクロールする1行を新Opus試験内へ追加した。製品sourceと既存試験は不変 |
| 最終UI sourceの確認 | スクロール処理を追加した同一sourceで、iPad build 265・iPhone build 266の新Opus UI各1件が成功。失敗・skip・runtime warning 0、各399入力が前後一致。新Opusメソッド以外は不変のため、既存iPad英日2件・iPhone UI 20件・破損回復1件・単体471件の結果を保持する。両専用SimulatorはShutdown、共通lease再取得／解放と所有process残存0を確認 |
| 起動前の隔離確認 | 検証用の一時helperでbuild-for-testingとtest-without-buildingを分け、生成Infoの`RideIntercom.Validation.*`と開発用接続資格の不在を確認してから起動する。製品sourceや標準検証scriptの仕様変更ではない |
| Release成果物 | 署名なしMac build 262（App／Widget）とiOS Simulator build 263（App／Widget／Watch）が成功。両方warning・error 0、399入力一致。内包物の版番号、device family、APNs production、開発資格なし、英日権限文言、Watch icon、Mac WebRTC privacy manifestとbinary hashを確認 |
| Intentと翻訳の成果物 | ReleaseのApp／WidgetにOS 27以降・main process・背景実行の既存Intentが保持されることを確認。Appの明示ミュートは必須Bool、前面実行・端末認証として抽出され、英日response／Siri phraseがcompiled resourceへ含まれることを確認。実Siri発話の受入とは区別 |
| native bitrateの意味 | Appが解決したconfigurationから試験内で実StreamingCodecEncoderを作り、保持するAVAudioConverterのbitrateを変換前後に読み戻す。稼働中Appの送信encoderそのものや実ネットワークの測定とは区別する |

Mac全体と各iOS／iPadのbuild-for-testing logには、それぞれAppIntentsに依存しないRideIntercomUITests targetに対する既知のmetadata抽出省略warningが1件ある。Swift compile・runtime warningは0。失敗runではXcodeの診断回収に`simctl`を発見できないerror 72が付随したが、専用Simulatorの回収はRunner側で成功し、最終成功runに同診断errorはない。Mac unitは署名entitlementとApp Sandboxを外した専用fixtureであり、署名配布や実Apple認証の受入ではない。

証跡はmainの`.validation/opus-shortcuts-delivery`にも保持する。低帯域の聞き取り、雑音下の明瞭度、実通信量・遅延・電池、Siriの実発話・OSによる質問と起動は別受入。Watch自身の音声と押下中送話モード、CoreAudioの実device-clock試験2件の未完了を、このApp検証の成功で置き換えない。
