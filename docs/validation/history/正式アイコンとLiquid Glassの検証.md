# 正式アイコンとLiquid Glassの検証

## 2026-11-02 Xcode Icon Composer resourceの正式登録

`RideIntercom/RideComAppIcon.icon`を単一の正式アイコンresourceとして登録した。AppとWatchの全configurationで`ASSETCATALOG_COMPILER_APPICON_NAME`を`RideComAppIcon`に統一し、Watch targetのResources phaseからApp側と同じPBXFileReferenceを使う。別のWatch package、asset catalog用PNG、symlinkは使わない。XcodeのAsset Compilerがplatform別variantを生成する。

| 対象 | 確認内容 |
|---|---|
| 回帰 | platform設定15件とsource manifestを含む関連Pythonテスト41件、文書参照検査が成功 |
| iOS / Watch | `RideIntercom` schemeのiOS Simulator build成功。埋込Watchの`Assets.car`に`RideComAppIcon`の`IconImageStack`、`Info.plist`に`CFBundlePrimaryIcon`を確認 |
| macOS | Icon Composer resourceをmacOS Asset Compilerへ渡し、`Assets.car`と`RideComAppIcon.icns`を生成。`assetutil --info`でBackground・Road・Waveformのstackを確認 |
| 限界 | 署名・インストール後のホーム画面/Dock/Watch実機表示とApp Store受理は未確認。Simulator placeholderについてXcode noteがあった |

## 2026-11-02 Dark/Light root SVGの再生成

利用者が不要pathを除去して更新した`RideComAppIcon.svg`を正本として再生成した。root直下の`dark`・`light`をappearanceとして認識し、各rootの3 groupをBackground・Road・Waveformへ対応づける。Light側groupの自動IDは、記述順ではなく参照gradient種別（radial・linear・gradientなし）とgroup数で分類する。path抽出では`visibility`を選別に使わず、各appearanceのgradient定義を出力へ保持する。Backgroundのbleed範囲からviewBoxと1354px出力を導出する。

| 対象 | 確認内容 |
|---|---|
| 生成物 | `python3 scripts/generate_app_icons.py`成功。Light/Dark layer SVG 6点、App/Mac Light PNG 7サイズ、Watch Dark PNG 1サイズの計14点を生成。`--check`で全点一致 |
| 入力・設定 | 正本SVGと生成SVG 6点のXML検査、`icon.json`のJSON解析が成功 |
| Asset Compiler | 修復後の`.icon`と共通Appearance catalogをmacOS向けに隔離compileし、`AppIcon.icns`と`Assets.car`を生成 |
| Dark solid fill | 利用者がIcon Composerで各layerへDark `fill-specializations`を保存。Asset Compiler成功。`assetutil --info`でDarkAquaのBackground / Road / WaveformがそれぞれP3 Color assetを参照し、Aquaとは異なるColor asset IDを確認。Darkの仮色は背景green、Road orange、Waveform magentaで、最終色ではない |
| OS表示・bundle | Icon Composer preview、通常App/Watch bundle build、インストール後のDock・Home Screen・Watch実機表示は未実行。Asset Compilerのvariant生成だけでOS表示完了とは扱わない |

## 2026-11-02 正本SVGの更新とグラデーション保持

利用者指定の`RideComAppIcon.svg`を生成入力の正本にした。`icon` group内の意味付きID `background`・`Road`・`Waveform`を名前で対応づけ、青い放射状背景と白い道の線形グラデーションはSVG定義ごと保持する。背景は非Glassのベース、道とターコイズ波形はGlass groupとし、Icon Composer側で前景色や不透明度を上書きしない。非表示の`BackgroundJast`と非表示の旧図案は生成対象から除外する。

| 対象 | 確認内容 |
|---|---|
| 生成物 | `python3 scripts/generate_app_icons.py --check`成功。背景・道・波形のSVG 3点とApp/Macの7サイズ・Watchの1024px PNG、計11点が一致 |
| SVG/設定 | 入力と出力SVG 4点の`xmllint --noout`、`icon.json`のJSON解析が成功 |
| ターゲット画像 | Appの16・32・64・128・256・512・1024pxとWatchの1024pxを確認。App/Watchの1024px PNGはbyte一致 |
| 文書 | `python3 scripts/check_documentation.py`成功 |
| Xcode組み込み | この変更後のIcon Composerプレビュー、Asset Compiler、App/Watch bundle buildは未実行。グラデーション保持とLiquid Glassの実機/OS描画は未確認 |

## 指示と変更範囲

2026-11-01、利用者指定の`AppIcon-4,096.svg`を正式アイコンとして採用し、Liquid Glass対応とプロジェクト内のアプリアイコンの統一を行った。SVGの輪郭・配置を保持し、背景、道とシュプール、音声波形を分離した。波形の制作上の重なりは同一SVG layer内で合成する。正本内の非表示参照画像は変更せず、配布前景へ含めない。

`RideIntercom/AppIcon.icon`をApp・Watchで共用する。Watchだけ前景を92%にして円形マスクの内側へ収める。Appの16〜1024pxとWatchの1024pxも同一SVGから更新した。UI内のSF Symbolsとpackage・serverは変更対象に含めない。

## 確認と証跡

ローカル証跡は`.validation/app-icon/`。署名・インストール・実サービス通信を伴わない。描画にはXcode 27.2付属の`ictool`、配布アセットには`actool`を使用する。

| 対象 | 確認内容 |
|---|---|
| 図案の一致 | `python3 scripts/generate_app_icons.py --check`成功。2つの前景SVGと8つのPNGを正本から再生成してbyte一致。1024pxのApp/Watch PNGは不透明 |
| 外観 | `previews/`にiOSのDefault・Dark・ClearLight・ClearDark・TintedLight・TintedDark、macOS/WatchのDefaultを出力成功。部品の継ぎ目とWatchの円形内の配置を目視確認。比較画像は`preview.png` |
| アセット変換 | macOS・iPhone/iPad・watchOSの3変換成功、warning/errorなし。`asset-compilation.json`と各`*-actool.log`に結果を保存 |
| Xcode組み込み | Watch Debug、Mac Release、iOS Release（Watch埋込を含む）の3build成功。`watch-build.log`、`macos-build.log`、`ios-build.log`へ保存。実bundleの`Assets.car`に背景＋2前景の3層stackと両vectorを確認。iOSに120px・152px PNG、Macに`AppIcon.icns`、Watchに`CFBundleIcons`を確認 |
| 設定・文書 | 開発設定・platform設定の既存検査、関連Python19件、文書参照検査が成功。失敗・skipなし |

Mac buildのwarningは0。Watchでは既知の`AppIntents.framework`依存なしによるmetadata抽出省略warningがあり、iOS buildに埋め込んだWatchでも同じwarningを保持した。アイコンのコンパイルwarningとbuild errorは0。build番号は標準処理で297から300へ進み、公開バージョンは変更していない。bundle検査の集計は`verification.json`、展開したasset情報は`*-bundle-assets.json`へ保存した。

初回のsandbox内描画はOSサービスへ接続できず失敗した。許可されたCLI実行へ切り替えた後、不要なSVG色空間設定が現Xcodeで読めないことを切り分けて除去した。`xcodebuild -dry-run`は現Xcodeで廃止されていたため、組み込みは実buildで確認した。画面操作の権限は使用していない。これらの途中失敗を最終成果物の成功へ読み替えない。

インストール後のホーム画面・Dock・Watch実機の動的な照明、壁紙を透過するクリア表示、Apple側の配布受理は[未確認事項](../未確認事項.md#正式アプリアイコンのos表示)に残す。

## 置き換えた暫定素材の由来

正式採用前は、紺・白・ターコイズの道路と音声波形の仮アイコンを内蔵image generationで新規生成し、`sips`で各寸法へ変換して登録していた。当時は正式デザイン承認済みとは扱っていなかった。旧`開発環境.md`にあった生成指示を履歴として保持する。

> Create a temporary production-quality app icon for RideIntercom, a group voice intercom app used by riders while moving. Square 1024x1024 full bleed opaque image, no transparency, no rounded outside corners, no mockup or surrounding margin. Deep navy background with a simple bold original turquoise and white emblem combining two flowing road lanes and a compact sound wave / conversation motif. Clean geometric vector-like rendering, highly legible at 60 pixels, minimal shapes, balanced centered composition, premium restrained style. No text, no letters, no logos, no Apple SF Symbols, no gradients that reduce contrast. This is the actual icon artwork filling the entire canvas.


## 共有カスタム記号の追加

2026-11-02、改訂デザインの `ridecom.glyph` を共通 `Shared/Appearance.xcassets` のsymbolsetとして作成した。インストール済みSF Symbols 27の実Template v4.0を基に、正本Road.svgの2pathとWaveform.svgの23pathを3つのmasterへ均等変換で配置した。d・fill-rule・順序を保持し、ブランド形状に架空のweight変形を加えていない。重なるpathを一つのsymbol layerへまとめると穴が生じることをnative描画で確認し、各pathを独立paint layerにして原形を保持した。Roadはprimary、Waveformはsecondaryの色roleを持ち、mono/paletteで利用できる。

独立macOS actool compile、NSImageの名前読込とsymbol configurationが成功し、正本SVGとnative mono/palette画像を比較した。`.validation/design-glyph-targets-20261102` の標準iOS Simulator buildでApp・Widget・Watchすべてのcatalog組込みが成功、入力指紋も一致した。証跡は `/tmp/ridecom-glyph-check` のRESULT.md・Load.swift・actool.log・native画像。この単位は記号資産の成立確認であり、サインイン・Island等への実配置は後続の画面単位で確認する。
