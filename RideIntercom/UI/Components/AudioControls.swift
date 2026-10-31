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
                Text(port.name).tag(port as AudioPortInfo)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier(accessibilityIdentifier)
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
