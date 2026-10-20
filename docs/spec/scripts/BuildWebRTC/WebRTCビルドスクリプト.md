# WebRTCビルドスクリプト

## 目的

RideIntercomで使用するnative WebRTC SDKの `WebRTC.xcframework` を、`webrtc.googlesource.com/src` から自前ビルドするためのスクリプト群を定義する。

WebRTC本体とChromium依存ソースは巨大なため、RideIntercom repositoryには含めない。checkout、build output、SwiftPM artifactは明確に分離し、検証済みの `WebRTC.xcframework` またはzipだけをbinary targetの入力として扱う。

## スクリプト一覧

| スクリプト | 用途 | 通常実行 |
|---|---|---|
| `scripts/BuildWebRTC/update-webrtc-binary.sh` | branch解決、fetch/sync/build、隔離したRTC packageで検証・テスト、成功後の取り込みを一括実行する | 通常はこれだけを使う |
| `scripts/BuildWebRTC/doctor-webrtc-binary.sh` | 現在のWebRTC build/import状態を診断し、次に実行する具体コマンドを表示する | 失敗時に最初に使う |
| `scripts/BuildWebRTC/resolve-webrtc-branch.sh` | Chromium Dashboardからstable milestoneのWebRTC branch-headを取得する | 直接実行またはbuild scriptから自動実行する |
| `scripts/BuildWebRTC/build-current-webrtc-xcframework.sh` | 現在stableのWebRTC branchを自動取得して `WebRTC.xcframework` をビルドする | 上位スクリプトが内部で使う。buildだけを確認したい場合に使う |
| `scripts/BuildWebRTC/build-webrtc-xcframework.sh` | 指定されたbranch、platform、deployment targetでビルドする | 上位スクリプトが内部で使う。branchやplatformを固定したい場合に使う |
| `scripts/BuildWebRTC/verify-webrtc-xcframework.sh` | Info.plist、実バイナリのarchitecture、必須platform、public headersを検証する | 上位スクリプトが内部で使う。成果物だけを検証したい場合に使う |
| `scripts/BuildWebRTC/import-webrtc-xcframework.sh` | 検証済みzipをRTC package配下のbinary target入力へ取り込む | 上位スクリプトが内部で使う。既存zipだけを取り込み直す場合に使う |
| `scripts/BuildWebRTC/clean-webrtc-build-resources.sh` | WebRTC build output、SwiftPM artifact、source checkoutを削除する | build後の容量整理に使う |

## 前提

| 項目 | 標準値 | 説明 |
|---|---|---|
| depot_tools | `../depot_tools` | repository親ディレクトリから見た既定位置。`fetch`、`gclient`、`gn`、`ninja` を提供する |
| WebRTC build root | `../webrtc-build` | repository親ディレクトリから見た既定位置。WebRTC source checkoutとbuild outputを置く |
| RideIntercom repository | current directory | スクリプトと仕様ドキュメントだけを置く |
| Xcode | `xcode-select -p` | 必要な場合だけ `DEVELOPER_DIR` で上書きする |

## 通常運用

WebRTC binaryを更新する通常手順は次の1コマンドだけとする。

```bash
cd <RideIntercom repository>
scripts/BuildWebRTC/update-webrtc-binary.sh
```

このスクリプトは次の処理を順番に実行する。

| 順序 | 処理 | 失敗時の扱い |
|---|---|---|
| branch解決 | `WEBRTC_BRANCH` 未指定時にstable branch-headを取得する | 取得不能なら `WEBRTC_BRANCH=branch-heads/<number>` の指定を案内する |
| source取得 | `WEBRTC_BUILD_ROOT/src` がなければ `fetch --nohooks webrtc_ios` から開始する | `depot_tools` 不備なら設定値を案内する |
| sync/build | cleanなsourceをbranchへ切替え、`gclient sync`、`gn gen`、`ninja` でiOS/macOS sliceをビルドする | 中断する。旧出力の自動再組み立てで成功に置き換えない |
| 成果物検証 | Info.plistと実バイナリのarchitecture、必須slice、`WebRTC.h` のimport先を検証する | 欠落があれば採用しない。空のdirectoryも失敗 |
| 隔離取り込み | 一時directoryへRTC packageをコピーし、候補zipを取り込む | repository内の採用済みzipとmetadataは維持 |
| SwiftPM検証 | 一時packageで `RTCNativeWebRTC` をビルドする | 失敗時は旧成果物を維持 |
| テスト | 一時packageで `RTC` testsを実行する | 失敗時は旧成果物を維持 |
| 採用 | 検証した候補zipをrepositoryへコピーしSHA-256と日時を記録する | 一時directoryは終了時に削除 |

通常の更新でsource checkoutや`out`全体を削除しない。tracked source変更があるcheckoutでは停止する。手動の `ASSEMBLE_ONLY` は残すが、更新処理の自動fallbackには使わない。異なるbranchの古い成果物を新branchとして採用することを避ける。


固定branchで再現する場合も、上位スクリプトに `WEBRTC_BRANCH` を渡す。

```bash
cd <RideIntercom repository>
WEBRTC_BRANCH=branch-heads/7727 \
scripts/BuildWebRTC/update-webrtc-binary.sh
```

## 失敗時の入口

失敗時に手作業で原因を選ばない。まず診断スクリプトを実行する。

```bash
cd <RideIntercom repository>
scripts/BuildWebRTC/doctor-webrtc-binary.sh
```

診断スクリプトは次を確認し、不足があれば `NEXT:` として次の具体コマンドを表示する。

| 確認 | 判断 |
|---|---|
| Xcode Developer directory | `DEVELOPER_DIR` がXcode本体を向いているか |
| depot_tools | `gclient` と `fetch` が存在するか |
| branch解決 | Chromium Dashboardからstable branchを取れるか |
| source checkout | `../webrtc-build/src` があるか |
| build output | iOS device、iOS simulator、macOS x64、macOS arm64のframeworkがあるか |
| xcframework | header検証に通る `WebRTC.xcframework` があるか |
| zip | `WebRTC-<branch>.xcframework.zip` があるか |
| imported artifact | RTC package配下のbinary target zipとmetadataがあるか |
| SwiftPM build | `RTCNativeWebRTC` がimport済みbinaryでビルドできるか |

SwiftPM検証を省略して状態だけ見たい場合は次のようにする。

```bash
cd <RideIntercom repository>
RUN_SWIFTPM_CHECK=false scripts/BuildWebRTC/doctor-webrtc-binary.sh
```

## 通常ビルド

`scripts/BuildWebRTC/build-current-webrtc-xcframework.sh` は下位スクリプトである。通常は `scripts/BuildWebRTC/update-webrtc-binary.sh` を使う。buildだけをやり直したい場合に限り、現在stableのWebRTC branch-headを自動取得して、iOS device、iOS simulator、macOSのsliceをビルドする。

```bash
cd <RideIntercom repository>
scripts/BuildWebRTC/build-current-webrtc-xcframework.sh
```

出力先は次の通りとする。

| 出力 | パス |
|---|---|
| xcframework | `../webrtc-build/src/out/WebRTC.xcframework` |
| zip | `../webrtc-build/src/out/WebRTC-<branch>.xcframework.zip` |
| checksum | build scriptの最後に表示される `shasum -a 256` の値 |

## プロジェクトへの取り込み

`scripts/BuildWebRTC/import-webrtc-xcframework.sh` は下位スクリプトである。通常は `scripts/BuildWebRTC/update-webrtc-binary.sh` から自動実行される。検証済みzipだけをRTC package配下へ取り込む。WebRTC source checkoutとbuild outputはrepositoryへ入れない。

```bash
cd <RideIntercom repository>
scripts/BuildWebRTC/import-webrtc-xcframework.sh
```

取り込み先は次の通りとする。

| 出力 | パス |
|---|---|
| binary target zip | `RideIntercom/packages/RTC/BinaryArtifacts/WebRTC/WebRTC.xcframework.zip` |
| metadata | `RideIntercom/packages/RTC/BinaryArtifacts/WebRTC/WebRTC.xcframework.metadata` |

特定のzipを取り込む場合は `WEBRTC_XCFRAMEWORK_ZIP` を指定する。

```bash
cd <RideIntercom repository>
WEBRTC_XCFRAMEWORK_ZIP=../webrtc-build/src/out/WebRTC-branch-heads-7727.xcframework.zip \
scripts/BuildWebRTC/import-webrtc-xcframework.sh
```

この方式の採用により、`RideIntercom/packages/RTC/Package.swift` は外部配布packageではなく、package内のlocal binary target `WebRTC` を参照する。

## branch固定ビルド

`scripts/BuildWebRTC/build-webrtc-xcframework.sh` は下位スクリプトである。特定のWebRTC branch-headでbuildだけを再現する場合は `WEBRTC_BRANCH` を明示する。

```bash
cd <RideIntercom repository>
WEBRTC_BRANCH=branch-heads/7727 \
scripts/BuildWebRTC/build-webrtc-xcframework.sh
```

`WEBRTC_BRANCH` を指定しない場合、`scripts/BuildWebRTC/build-webrtc-xcframework.sh` は `scripts/BuildWebRTC/resolve-webrtc-branch.sh` を呼び出してstable branch-headを取得する。

## platform指定

Appに採用する成果物はiOS device、iOS Simulator、macOSの全sliceを必須とする。`IOS`、`MACOS` はビルド対象を制御するが、片方だけの成果物は最終検証・取り込みには合格しない。

```bash
cd <RideIntercom repository>
IOS=true \
MACOS=true \
scripts/BuildWebRTC/build-current-webrtc-xcframework.sh
```

| 変数 | 標準値 | 対象 |
|---|---|---|
| `IOS` | `true` | iOS deviceとiOS simulator |
| `MACOS` | `true` | macOS universal binary |
| `ASSEMBLE_ONLY` | `false` | `true` の場合は既存の `src/out/*/WebRTC.framework` からxcframeworkとzipだけを作る |
| `RUN_SWIFTPM_VALIDATION` | `true` | `scripts/BuildWebRTC/update-webrtc-binary.sh` 用。`false` の場合は `RTCNativeWebRTC` build検証を省略する |
| `RUN_TESTS` | `true` | `scripts/BuildWebRTC/update-webrtc-binary.sh` 用。`false` の場合はRTC package testsを省略する |
| `IOS_DEPLOYMENT_TARGET` | `26.4` | iOS sliceのdeployment target |
| `MACOS_DEPLOYMENT_TARGET` | `26.4` | macOS sliceのdeployment target |

## 既存成果物からの再組み立て

途中で失敗し、iOS / macOSの `WebRTC.framework` が生成済みの場合は、再コンパイルせずにxcframeworkだけを組み立て直せる。

```bash
cd <RideIntercom repository>
ASSEMBLE_ONLY=true \
IOS=true \
MACOS=true \
scripts/BuildWebRTC/build-webrtc-xcframework.sh
```

この指定では `fetch`、`gclient sync`、`gn gen`、`ninja` を実行しない。既存の `../webrtc-build/src/out/*/WebRTC.framework` だけを入力にする。

## iOSとmacOSの差分

| platform | WebRTC build target | framework構造 | スクリプトでの扱い |
|---|---|---|---|
| iOS device | `framework_objc` | `WebRTC.framework/Headers` | arm64 device sliceとしてxcframeworkへ追加する |
| iOS simulator | `framework_objc` | `WebRTC.framework/Headers` | x86_64とarm64を `lipo` で統合する |
| macOS | `mac_framework_objc` | `WebRTC.framework/Versions/A/Headers` | x86_64とarm64を `lipo` で統合する |

macOS sliceでは、配布済みbinaryと同様にpublic headersが不足する場合がある。`scripts/BuildWebRTC/build-webrtc-xcframework.sh` はmacOSの `gen/sdk/WebRTC.framework/Headers` を優先してpublic headersを補完し、`gen/sdk` が存在しない場合のみiOS device sliceをfallbackとして使う。その後 `scripts/BuildWebRTC/verify-webrtc-xcframework.sh` で必須headerと `WebRTC.h` がimportするheaderの存在を検証する。

## 成果物検証

build後、binary targetへ差し替える前に必ず検証する。

```bash
cd <RideIntercom repository>
scripts/BuildWebRTC/verify-webrtc-xcframework.sh \
  ../webrtc-build/src/out/WebRTC.xcframework
```

検証対象headerは次の通りとする。

| header |
|---|
| `WebRTC.h` |
| `RTCAudioSource.h` |
| `RTCAudioTrack.h` |
| `RTCConfiguration.h` |
| `RTCDataChannel.h` |
| `RTCDataChannelConfiguration.h` |
| `RTCIceCandidate.h` |
| `RTCIceServer.h` |
| `RTCMediaConstraints.h` |
| `RTCPeerConnection.h` |
| `RTCPeerConnectionFactory.h` |
| `RTCSessionDescription.h` |

## 後片付け

標準ではdry-runで削除対象だけを表示する。

```bash
cd <RideIntercom repository>
scripts/BuildWebRTC/clean-webrtc-build-resources.sh
```

実際に削除する場合は `DRY_RUN=false` を明示する。

```bash
cd <RideIntercom repository>
DRY_RUN=false scripts/BuildWebRTC/clean-webrtc-build-resources.sh
```

| `CLEAN_MODE` | 削除対象 | 用途 |
|---|---|---|
| `build-output` | `../webrtc-build/src/out` | build outputだけを消し、source checkoutは残す |
| `swiftpm` | `RideIntercom/packages/RTC/.build/workspace-state.json`、`RideIntercom/packages/RTC/.build/artifacts/rtc/WebRTC`、`RideIntercom/packages/RTC/.build/artifacts/extract/rtc`、debug用 `WebRTC.framework`、WebRTC adapter build output、WebRTC関連の旧 `checkouts`、WebRTC関連の旧 `repositories` | SwiftPMが展開したWebRTC binary artifact、古い解決状態、旧remote package cacheを消す |
| `source` | `../webrtc-build` | WebRTC source checkout全体を消す |
| `all` | 上記すべて | ディスク容量を大きく空ける |

通常は `build-output` の削除に留める。source checkoutを残すと、次回は `gclient sync` と差分buildで済む可能性が高い。

## よくある確認

| 確認 | コマンド | 期待 |
|---|---|---|
| depot_tools確認 | `../depot_tools/gclient --version` | `gclient.py` のusageが表示される |
| branch自動解決 | `scripts/BuildWebRTC/resolve-webrtc-branch.sh` | `branch-heads/<number>` が表示される |
| shell構文確認 | `bash -n scripts/BuildWebRTC/build-webrtc-xcframework.sh` | 出力なしで終了する |
| 既存artifact検証 | `scripts/BuildWebRTC/verify-webrtc-xcframework.sh <WebRTC.xcframework>` | header欠落があれば失敗する |
| zipの作り直し | `scripts/BuildWebRTC/build-webrtc-xcframework.sh` | 既存zipを削除してから作成し、削除済みheaderがarchiveに残らない |

## 失敗時の判断

手作業でこの表から選ぶ前に、必ず `scripts/BuildWebRTC/doctor-webrtc-binary.sh` を実行する。表は診断結果の背景説明として使う。

| 症状 | 原因候補 | 対応 |
|---|---|---|
| `depot_tools was not found` | `DEPOT_TOOLS_DIR` が違う | `DEPOT_TOOLS_DIR=/path/to/depot_tools` を指定する |
| `failed to resolve current WebRTC branch` | Chromium Dashboardへ到達できない | `WEBRTC_BRANCH=branch-heads/<number>` を明示する |
| `RTCAudioSource.h file not found` | macOS sliceのpublic headers不足 | build後に `verify-webrtc-xcframework.sh` を実行し、不足が残る場合は成果物を採用しない |
| `gn gen` / `ninja` が失敗 | WebRTC branchとXcode/SDKの組み合わせ不整合 | branchを固定するか、対応するXcodeを `DEVELOPER_DIR` で指定する |
| ディスク容量不足 | WebRTC source treeまたはbuild outputが大きい | `clean-webrtc-build-resources.sh` で `build-output` または `source` を削除する |

## 採用条件

| 条件 | 完了基準 |
|---|---|
| build成功 | `WebRTC.xcframework` とzipが生成される |
| header検証成功 | `verify-webrtc-xcframework.sh` が成功する |
| checksum記録 | zipのSHA-256をbinary target更新時に記録する |
| repository保護 | WebRTC source treeと巨大なbuild outputをcommitしない |

## 取り込み方式の判断

| 方式 | 利点 | 注意点 |
|---|---|---|
| zipをrepositoryに含める | checkout後すぐにSwiftPMで解決できる。外部配布URLが不要 | Git repositoryが約30MB増える。更新のたびにbinary diffではなくzip全体が履歴に残る |
| zipをrelease等へ置く | repository本体を軽く保てる。SwiftPM checksumで固定できる | private配布、URL管理、checksum更新の運用が必要 |
| xcframework directoryをrepositoryに含める | 中身を直接確認しやすい | ファイル数が多く、symlinkやframework構造の差分管理が重い |

現時点ではzipが約30MBでGitHubの単一ファイル上限を下回るため、初期採用はrepository同梱で成立する。更新頻度が上がる、またはartifactが大きくなる場合はrelease配布へ移す。
## 更新処理の回帰テスト

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -m unittest discover -s scripts/tests -v
```

| ケース | 確認 |
|---|---|
| 空のxcframework | headersが見つからないまま成功にしない |
| candidateのSwiftPM検証失敗 | 採用済みzipとmetadataが変わらない |

resolverはOSの証明書ストアを利用するcurlで公式Chromium Dashboardへアクセスする。証明書検証を無効化しない。
worktreeが通常checkoutと異なる場所にある場合は `DEPOT_TOOLS_DIR` と `WEBRTC_BUILD_ROOT` を明示する。

## 現行SDKとの組合せ

| 項目 | 採用内容 |
|---|---|
| 確認日 | 2026-10-21 |
| stable branch | `branch-heads/8078` (Chromium Dashboardから解決) |
| source revision | `2a990ce0cc` |
| Xcode | 27.1 (27A9275) |
| vendor build警告 | `RTCFileVideoCapturer.m` の `tracksWithMediaType:` にApple SDKの非推奨警告が発生 |
| GN設定 | WebRTC本体だけ `treat_warnings_as_errors=false`。警告はログに保存し、compiler/linker errorは失敗のまま扱う。App/自作packageのwarning設定は変更しない |
| 成果物 | iOS arm64、iOS Simulator arm64/x86_64、macOS arm64/x86_64 |
| 採用ゲート | slice/header検証、隔離packageのRTCNativeWebRTC buildとRTC全28テスト成功 |
| checksum | binary隣接の `WebRTC.xcframework.metadata` を正本とする |

ビルドで生じたvendor警告をゼロとは記録しない。生成済みの同じbranchの全sliceを `ASSEMBLE_ONLY=true` で取り込む場合も、更新スクリプトによる隔離検証を省略しない。
