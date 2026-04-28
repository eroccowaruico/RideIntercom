ライブラリ化は可能です。

k​Audio​Unit​Sub​Type​_​AUSound​Isolation は k​Audio​Unit​Type​_​Effect カテゴリの Audio Unit なので、AVAudio​Engine の任意のノードチェーンにエフェクトとして挿入できます。マイクや VoiceProcessingIO に紐付ける必要はありません。

仕組み

AVAudio​Unit​Effect でラップして AVAudio​Engine のグラフに接続するだけです:

````
import AVFAudio
import AudioToolbox

let desc = AudioComponentDescription(
    componentType: kAudioUnitType_Effect,
    componentSubType: kAudioUnitSubType_AUSoundIsolation,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0,
    componentFlagsMask: 0
)

// AVAudioEngine のノードとしてインスタンス化
AVAudioUnitEffect.instantiate(with: desc, options: []) { avAudioUnit, error in
    guard let effect = avAudioUnit else { return }
    
    let au = effect.auAudioUnit
    // パラメータ設定
    // SoundToIsolate: Voice or HighQualityVoice
    // WetDryMixPercent: 0〜100
    
    let engine = AVAudioEngine()
    engine.attach(effect)
    
    // 例: 受信バッファ → SoundIsolation → ミキサー → 出力
    engine.connect(sourceNode, to: effect, format: format)
    engine.connect(effect, to: engine.mainMixerNode, format: format)
}
````
ライブラリ設計案

用途を考えると、こんなインターフェースが自然です:
````
/// 任意の音声信号に対する Voice Isolation エフェクト
public final class VoiceIsolationEffect {
    private let effect: AVAudioUnitEffect
    
    /// AVAudioEngine のノードとして取得
    public var node: AVAudioNode { effect }
    
    /// 分離品質 (.voice / .highQualityVoice)
    public var soundType: SoundType { ... }
    
    /// Wet/Dry ミックス (0.0〜1.0)
    public var mix: Float { ... }
}
````

使い方の例:

| ユースケース | 接続 |
|---|---|
| 受信音声のノイズ除去 | Player​Node → ​Voice​Isolation → ​Mixer |
| マスター出力のクリーンアップ | Mixer → ​Voice​Isolation → ​Output​Node |
| 個別チャンネル処理 | Player​Node → ​Voice​Isolation → ​Sub​Mixer |
| マイクから取得した音声のノイズ除去 |  |

注意点

1. プラットフォーム制限: AUSound​Isolation は iOS 15+ / macOS 13+ 以降。デバイスによって利用可否が異なる可能性があるので、Audio​Component​Find​Next で存在チェックが必要
2. リアルタイム性能: ML ベースの処理なので、レイテンシが数十ms 発生する。リアルタイム通話では許容範囲だが、楽器演奏等のモニタリングには向かない
3. モノラル前提: 音声分離はモノラルチャンネルを想定した設計。ステレオ信号に適用する場合はチャンネル分割が必要になる可能性がある
4. kAUSoundIsolationSoundType_HighQualityVoice はレイテンシが大きい代わりに品質が高い。用途に応じて使い分ける

技術的にはクリーンにライブラリ化できる構造です。AVAudio​Engine のノードグラフに自由に差し込める点が、Audio Unit アーキテクチャの強みそのものです。