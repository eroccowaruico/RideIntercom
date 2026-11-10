import SwiftUI
import RTC

struct AudioPortPicker: View {
    let title: String
    let selection: Binding<AudioPortInfo>
    let ports: [AudioPortInfo]
    let accessibilityIdentifier: String

    var body: some View {
        Picker(LocalizedStringKey(title), selection: selection) {
            ForEach(ports) { port in
                label(port).tag(port as AudioPortInfo)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// The app's own choices read in the person's language; a device keeps the name the system gives it.
    private func label(_ port: AudioPortInfo) -> Text {
        switch port.id {
        case AudioPortInfo.systemDefault.id: Text("Auto")
        case AudioPortInfo.receiver.id: Text("Receiver")
        case AudioPortInfo.speaker.id: Text("Speaker")
        default: Text(verbatim: port.name)
        }
    }
}

struct AudioCheckMeterSection: View {
    let title: String
    let systemImage: String
    let level: Float
    let peakLevel: Float
    let isMuted: Bool
    let accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            Label(title, systemImage: systemImage)
                .font(AppTypography.subheadlineStrong)
            VoiceMeterView(
                level: level,
                peakLevel: peakLevel,
                isMuted: isMuted,
                showsValueText: false
            )
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}
