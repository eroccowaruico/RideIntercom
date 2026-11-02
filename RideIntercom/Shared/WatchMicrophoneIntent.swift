/// Owns push-to-talk across Watch scene transitions. The microphone is open only
/// while pressed in the active scene; any other scene closes it until a new press.
struct WatchMicrophoneIntent {
    enum Scene { case active, inactive, background }

    private(set) var scene: Scene = .active
    private(set) var isOn = false

    mutating func setScene(_ scene: Scene) {
        self.scene = scene
        if scene != .active { close() }
    }

    mutating func request(_ on: Bool) {
        if !on { close() }
        else if scene == .active { isOn = true }
    }

    mutating func close() { isOn = false }
}
