# WebRTCマニフェスト配置の修正

2026-10-31、App工程と分離したRTC artifact工程で、MacのSDKマニフェスト誤配置を修正した。対象はbranch-heads/8078の既存ZIPであり、音声・ABI・カメラ除外・SDKの申告内容は変更していない。

## 原因と修正

上流のmacOS bundleは`bundle_contents_dir`が既に`WebRTC.framework/Versions/A`を指す一方、privacy manifest出力にも`Versions/A/Resources`を付加していた。その結果、組み立てに使う個別frameworkの時点で`Versions/A/Versions/A/Resources/PrivacyInfo.xcprivacy`に配置されていた。repositoryのassemblyがその構造をコピーし、既存検証にprivacy配置の検査がなかったため通過していた。

組み立て先で既知の二重配置だけを正規の`Versions/A/Resources`へ移動する。外部checkoutは変更しない。全sliceを事前検査し、正しい配置なら何もしない。欠損・重複・plist不正・framework外へ出る／循環／壊れたsymlink・sealed Mac resourceは自動修復せず拒否する。verify/importは検査のみを行い、不正ZIPで既存artifactを上書きしない。

## Artifactの同一性

| 対象 | 結果 |
|---|---|
| 元ZIP SHA-256 | `48a42a11449e29d7a99ecda7051d4c86ee0f8863ed7bfd5bc5578019ebb2a3d8` |
| 修正ZIP SHA-256 | `5fb5e50877814a2e552fdff14cd21cb02f2b1c1d26f6a175e05f14682e7f3788` |
| ZIP変更 | manifestのパス1件を変更、空になったdirectory entry3件を削除。残る315 entryのpayloadはすべて同一 |
| Manifest | 全slice共通の845 bytesを保持。SHA-256 `eb9337f2dee5992f74ae2b10f78f526d3eec1da8cfde029131081c0b18579614` |
| Mach-O・dSYM | 全ファイルのbytesとUUIDを保持。再コンパイル・lipo・再署名なし |
| iOS Simulator署名 | 既存CodeResourcesを保持し、`codesign --verify --strict`成功 |
| Mac署名 | 元からx86_64はunsigned、arm64はlinkerのad-hocでresource sealなし。その状態を保持し、完成した配布署名とは扱わない |
| 標準Resources | `WebRTC.framework/Resources/PrivacyInfo.xcprivacy`から正規の実体へ到達し、同一bytesを読める |

## ローカル検証

| 対象 | 確認 |
|---|---|
| TDD | 新規8件の初回は正常ケース以外の7件が想定どおり失敗。追加した外部Info.plist symlinkも失敗を再現して修正 |
| 配置・assembly・import | 既存と追加を合わせたscript 23件成功。正常・欠損・既知誤配置・plist不正・外部／循環symlink・重複・署名保護・全slice事前検査・idempotence・失敗時の既存artifact保持をfixtureで確認 |
| 実artifact | privacy配置、各slice architecture、dSYM UUID、camera除外、公開headerの既存検査を通過 |
| RTC単独 | 隔離したpackageへ候補ZIPを取り込み、`RTCNativeWebRTC`をbuild。ローカルRTC 92件とnative WebRTC 4件が成功（失敗・skip・警告0）。実Worker資格を必要とする`WorkerPairTests`は対象外として明示する |

証跡は作業worktreeの`.validation/webrtc-privacy-red`、`.validation/webrtc-privacy-green`、`.validation/webrtc-privacy-artifact`に保存した。`payload-invariants.json`に全entryのbefore/after名とSHA-256、`signature-and-resources.json`に署名結果と標準パス到達を記録している。外部ビルドtreeとApp sourceは変更していない。

## App同梱の確認

続いて`6c8ea8c8`へ同じartifact・scriptを取り込み、App sourceを変更せず署名なしgeneric macOS Releaseをbuildした。`.validation/webrtc-privacy-app-macos`でApp内の標準Resourcesから上記manifest SHA-256へ到達し、Mac Mach-OのSHA-256 `9a6180cfdb7c0fd57c80a97d649aeff2754925047836ec9b9d046ca792679d02`も元のままであることを確認した。388入力のbefore/afterが一致し、既知の二重directoryは残っていない。既存の所有DerivedDataを再利用し、cache削除は不要だった。

初回buildは成功したが、補助検査が解決済み`/private/tmp`と未解決`/tmp`を比較して停止した。両方を正規化して同じ生成物を検査し直した。最初の再集計では既存results.tsvを作り直そうとして停止したため、再集計専用の読取経路に分けた。製品source・生成物は変更せず、buildを重複実行していない。初回理由とpostbuild helperを証跡へ保持する。

## 次の受入境界

Archiveのprivacy report、署名済み最終artifactとApple側の受理は別工程である。SDKのplist形式や配置が正しいことだけで、申請内容や理由コードの審査結果は確定しない。
