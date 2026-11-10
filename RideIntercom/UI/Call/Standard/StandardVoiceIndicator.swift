import SwiftUI

/// How loud a voice is, as a symbol's variable value in a few steps. No numbers.
/// A still, grey symbol shows where the voice stops: no input, not arriving, or not playing.
struct StandardVoiceIndicator: View {
    enum Kind {
        /// This device's microphone.
        case input
        /// One person's voice as it arrives.
        case peer
        /// What actually plays.
        case output
    }

    let kind: Kind
    let level: Float
    /// The microphone is muted (input, or the person's own), or the output is muted.
    var isSilenced = false
    let label: Text

    var body: some View {
        let step = Self.step(for: level)
        Group {
            if isSilenced {
                Image(systemName: kind == .output ? "speaker.slash" : "mic.slash")
                    .foregroundStyle(AppColorPalette.danger)
            } else {
                Image(systemName: symbol, variableValue: step)
                    .symbolVariableValueMode(.draw)
                    .foregroundStyle(step > 0 ? AppColorPalette.voiceLevel : AppColorPalette.textSecondary)
            }
        }
        .frame(minWidth: 28)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(isSilenced ? Text("Muted") : step > 0 ? Text("Speaking") : Text("Silent"))
    }

    private var symbol: String {
        switch kind {
        case .input: "microphone.and.signal.meter"
        case .peer: "waveform"
        case .output: "speaker.wave.3"
        }
    }

    /// The dBFS display level rounded to quarters, so the symbol does not flicker;
    /// anything below the quietest speech counts as silence.
    static func step(for level: Float) -> Double {
        let display = Double(VoiceLevelIndicatorState(level: level, peakLevel: level).displayLevel)
        guard display >= 0.2 else { return 0 }
        return max(0.25, (display * 4).rounded() / 4)
    }
}
