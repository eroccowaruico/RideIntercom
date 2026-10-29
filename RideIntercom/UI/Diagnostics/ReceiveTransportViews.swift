import SwiftUI
import AudioCore
import AudioMixer
import RTC
import SessionManager

struct ReceiveRTCPeersGroup: View {
    let step: PipelineStep
    let peers: [ReceivePeerBusSnapshot]

    private let columns = [
        GridItem(.adaptive(minimum: 148), spacing: AppSpacing.xs, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            CompactPipelineStepRow(step: step, accessibilityIdentifier: "\(step.accessibilityIdentifier)-summary")

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ReceiveInlineGroupHeader(title: "RTC Peers", detail: "\(peers.count) peers")

                if peers.isEmpty {
                    ReceiveInlineEmptyRow(text: "No connected peer")
                        .accessibilityIdentifier("receive-rtc-peers-empty")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: AppSpacing.xs) {
                        ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                            ReceivePeerRTCChip(peer: peer)
                                .accessibilityIdentifier("receive-peer-rtc-\(index)")
                        }
                    }
                }
            }
            .padding(.leading, CompactPipelineLayout.childIndent)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("receive-rtc-peers")
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(step.accessibilityIdentifier)
    }
}

struct ReceiveDecodePeersGroup: View {
    let step: PipelineStep
    let peers: [ReceivePeerBusSnapshot]
    let droppedFrameCount: Int

    private let columns = [
        GridItem(.adaptive(minimum: 148), spacing: AppSpacing.xs, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            CompactPipelineStepRow(step: step, accessibilityIdentifier: "\(step.accessibilityIdentifier)-summary")

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ReceiveInlineGroupHeader(title: "Peer Decode", detail: dropDetail)

                if peers.isEmpty {
                    ReceiveInlineEmptyRow(text: "No peer codec metadata")
                        .accessibilityIdentifier("receive-codec-peers-empty")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: AppSpacing.xs) {
                        ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                            ReceivePeerCodecChip(peer: peer)
                                .accessibilityIdentifier("receive-peer-codec-\(index)")
                        }
                    }
                }
            }
            .padding(.leading, CompactPipelineLayout.childIndent)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("receive-codec-peers")
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(step.accessibilityIdentifier)
    }

    private var dropDetail: String {
        droppedFrameCount > 0 ? "DROP \(droppedFrameCount)" : "\(peers.count) decoders"
    }
}

struct ReceiveInlineGroupHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            Text(title)
                .font(AppTypography.caption2)
                .foregroundStyle(AppColorPalette.textTertiary)

            Text(detail)
                .font(AppTypography.caption2Mono)
                .foregroundStyle(AppColorPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

struct ReceiveInlineEmptyRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.s) {
            Image(systemName: "minus.circle")
                .foregroundStyle(AppColorPalette.neutral)
                .frame(width: AppSize.iconS)
                .accessibilityHidden(true)

            Text(text)
                .font(AppTypography.caption2Mono)
                .foregroundStyle(AppColorPalette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

struct ReceivePeerRTCChip: View {
    let peer: ReceivePeerBusSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.s) {
            Circle()
                .fill(peer.state.color)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(peer.displayName)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AppColorPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(peer.connectionLabel) / \(peer.authenticationLabel)")
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(peer.state.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.s)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColorPalette.panelSurface.opacity(0.36))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("RTC peer \(peer.displayName)")
        .accessibilityValue("\(peer.connectionLabel), \(peer.authenticationLabel)")
    }
}

struct ReceivePeerCodecChip: View {
    let peer: ReceivePeerBusSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.s) {
            Circle()
                .fill(peer.state.color)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(peer.displayName)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AppColorPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("DEC \(codecLabel(peer.activeCodec))")
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(peer.state.color)
                    .lineLimit(1)

                Text("RX \(peer.receivedFrameCount)")
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(AppColorPalette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.s)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColorPalette.panelSurface.opacity(0.36))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Decode peer \(peer.displayName)")
        .accessibilityValue("\(codecLabel(peer.activeCodec)), received \(peer.receivedFrameCount)")
    }

    private func codecLabel(_ codec: AudioCodecIdentifier?) -> String {
        guard let codec else { return "Unknown" }
        if codec == .pcm16 { return "PCM" }
        if codec == .mpeg4AACELD || codec == .mpeg4AACELDv2 { return "AAC" }
        if codec == .opus { return "Opus" }
        return codec.rawValue
    }
}

