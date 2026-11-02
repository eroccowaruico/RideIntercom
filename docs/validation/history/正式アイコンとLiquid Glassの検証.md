# 正式アイコンとLiquid Glassの検証

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
