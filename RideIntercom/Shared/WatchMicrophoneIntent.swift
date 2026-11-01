/// Owns the user's microphone intent across Watch scene transitions.
struct WatchMicrophoneIntent {
    enum Mode: Hashable { case hold, toggle }
    enum Scene { case active, inactive, background }

    private(set) var mode: Mode = .hold
    private(set) var scene: Scene = .active
    private(set) var isOn = false

    mutating func setMode(_ mode: Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
        close()
    }

    mutating func setScene(_ scene: Scene) {
        self.scene = scene
        if scene == .background || (scene == .inactive && mode == .hold) { close() }
    }

    mutating func request(_ on: Bool) {
        if !on { close() }
        else if scene == .active { isOn = true }
    }

    mutating func close() { isOn = false }
}
