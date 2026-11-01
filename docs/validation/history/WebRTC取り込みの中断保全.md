# WebRTC取り込みの中断保全

2026-11-01、`30486b54`を基準にした開発scriptの修復。既存のimportが採用済みzipへ直接コピーしていたため、容量不足・中断で旧zipを壊せることを先に再現した。現在の[取り込み手順](../../development/BuildWebRTC/WebRTCビルドスクリプト.md#取り込みの中断と復帰)は、同一filesystemへstageしたzipとmetadataを検証後にdirectory単位で公開する。App／packageの製品処理・採用済みWebRTC binaryは変更していない。

## 自動検証

| 検証 | 結果・範囲 |
|---|---|
| 旧処理のRED | cpの途中でpartial bytesを書きENOSPCを注入すると旧zipが破損した。`copy-red.log`を保持 |
| 追加のRED | 検証中に追加した無関係fileを旧directoryごと再帰削除する窓を再現。`cleanup-red.log`を保持。公開直前の再確認と、既知pairだけのunlink／空dirのrmdirへ修正 |
| 新規12件 | コピー・metadata失敗、既存pair交換・初回配置、検証拒否、ENOTSUP／EIO／ENOSPC、初回競合、無関係file・symlink、実SIGKILL前後を確認。失敗・skip・ResourceWarningなし |
| 実プロセス中断 | 試験子processを実renamex_npの前／後で停止し、親からSIGKILLを送った。終了値は-9。固定pathは前なら旧pair、後なら新pairでchecksum一致。残留stageが次回importを妨げないことも確認 |
| 既存WebRTC script | 9件成功。実binaryのcamera API・slice・dSYMと、隔離した候補package検証の失敗時に採用済みartifactを維持する検査を含む |
| 実artifactの取り込み | 採用済み約93MBのzipを読み取り専用の入力として、既存verifierで検証後、一時destinationへ取り込んだ。zip／metadataのSHA-256一致。repositoryの採用zip／metadataは前後不変 |
| mainへの統合後 | 全Python119件成功、26.646秒。隔離試験と統合後の3変更ファイルのbytes一致、shell構文・文書参照・git diff checkも確認 |

証跡はmain作業領域の`.validation/webrtc-import-repair`へ集約した。隔離作業領域`/private/tmp/RideIntercom-binary-import-repair`のログ・入力hashと、統合後の`all-tests.log`を保持する。kill注入は試験側のwrapperだけで行い、製品scriptへ試験flagや待機処理を追加していない。

## 受入の境界

コピーされたstageのbytesを検証・hash化し、検証後にコピー元を再読取りして採用しない。macOSのdirectory交換が使えなければ停止し、deleteや二回のrenameへfallbackしない。非対応filesystemはENOTSUPの故障注入で確認し、実際の外付けfilesystemを試験した結果ではない。

これはプロセス中断の検証であり、電源断・kernel/filesystem crash・媒体故障の耐久性を証明しない。交換をまたいだ2ファイルの個別readを一括transactionにする機能も追加していない。source/depotの完全commit、GN、SDKと成果物hashの紐付けは後続の改善候補に残す。既存binaryの再ビルドや配布更新は行っていないため、Appの実音声・署名・Apple提出を再検証した結果とは扱わない。
