import SwiftUI

struct ContentView: View {
    @State private var viewModel = IntercomViewModel.makeForCurrentProcess()
    @State private var selectedTab: AppTab = .call

    var body: some View {
        let _ = viewModel.uiEventRevision
        TabView(selection: $selectedTab) {
            Tab("Call", systemImage: "waveform.circle.fill", value: .call) {
                NavigationStack {
                    CallEntryView(viewModel: viewModel)
                }
            }
            .accessibilityIdentifier("callTab")

            Tab("Diagnostics", systemImage: "gauge", value: .diagnostics) {
                NavigationStack {
                    DiagnosticsView(viewModel: viewModel)
                        .navigationTitle("Diagnostics")
                }
            }
            .accessibilityIdentifier("diagnosticsTab")

            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                NavigationStack {
                    SettingsView(viewModel: viewModel)
                        .navigationTitle("Settings")
                }
            }
            .accessibilityIdentifier("settingsTab")
        }
        .onOpenURL { url in
            if (try? viewModel.acceptInviteURL(url)) != nil {
                selectedTab = .call
            }
        }
    }
}

private enum AppTab: Hashable {
    case call
    case diagnostics
    case settings
}

private struct CallEntryView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Group {
            if viewModel.selectedGroup == nil {
                GroupSelectionView(viewModel: viewModel)
                    .navigationTitle("Groups")
            } else {
                CallView(viewModel: viewModel)
                    .navigationTitle(viewModel.selectedGroup?.name ?? "Call")
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                viewModel.showGroupSelection()
                            } label: {
                                Label("Groups", systemImage: "person.3.fill")
                            }
                            .accessibilityIdentifier("showGroupsButton")
                        }
                    }
            }
        }
    }
}

private struct GroupSelectionView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        List {
            Section("Recent Groups") {
                if viewModel.groups.isEmpty {
                    Text("Create a group to start a call.")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(AppColorPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .appCallCardStyle()
                        .listRowInsets(EdgeInsets(top: AppSpacing.m, leading: AppSpacing.screen, bottom: AppSpacing.m, trailing: AppSpacing.screen))
                        .listRowBackground(Color.clear)
                }

                ForEach(viewModel.groups) { group in
                    Button {
                        viewModel.selectGroup(group)
                    } label: {
                        HStack(spacing: AppSpacing.xl) {
                            Image(systemName: "person.3")
                                .foregroundStyle(AppColorPalette.textSecondary)
                                .frame(width: AppSize.iconM)

                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(group.name)
                                    .font(AppTypography.rowTitle)
                                    .lineLimit(2)
                                Text("\(group.members.count) members")
                                    .font(AppTypography.subheadline)
                                    .foregroundStyle(AppColorPalette.textSecondary)
                            }

                            Spacer(minLength: AppSpacing.xl)

                            Image(systemName: "chevron.right")
                                .font(AppTypography.footnoteStrong)
                                .foregroundStyle(AppColorPalette.textTertiary)
                        }
                        .appCallCardStyle()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: AppSpacing.m, leading: AppSpacing.screen, bottom: AppSpacing.m, trailing: AppSpacing.screen))
                    .listRowBackground(Color.clear)
                    .accessibilityLabel(group.name)
                    .accessibilityValue("\(group.members.count) members")
                    .accessibilityHint("Opens the call screen for this group.")
                    .accessibilityIdentifier("groupRow-\(group.name)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            viewModel.deleteGroup(group.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.deleteGroup(group.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.automatic)
        .scrollContentBackground(.hidden)
        .background(AppColorPalette.callScreenBackground)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.createTrailGroup()
                } label: {
                    Label("Create Trail Group", systemImage: "plus")
                }
                .accessibilityIdentifier("createGroupButton")
            }
        }
        .accessibilityIdentifier("groupSelectionList")
    }
}

private struct CallView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.screen) {
                statusHeader
                controls

                VStack(alignment: .leading, spacing: AppSpacing.l) {
                    Text("Participants")
                        .font(AppTypography.sectionTitle)
                        .foregroundStyle(AppColorPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if remoteMembers.isEmpty {
                    Text("No remote riders")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(AppColorPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .appCallCardStyle()
                        .accessibilityIdentifier("emptyRemoteParticipantsLabel")
                } else {
                    VStack(spacing: AppSpacing.l) {
                        ForEach(Array(remoteMembers.enumerated()), id: \.element.id) { index, member in
                            RemoteParticipantRowView(
                                index: index,
                                member: member,
                                outputVolume: Binding(
                                    get: { Double(viewModel.remoteOutputVolume(for: member.id)) },
                                    set: { viewModel.setRemoteOutputVolume(peerID: member.id, value: Float($0)) }
                                )
                            )
                            .accessibilityIdentifier("remoteParticipantRow\(index)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    guard let selectedGroup = viewModel.selectedGroup else { return }
                                    viewModel.removeMember(member.id, from: selectedGroup.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    guard let selectedGroup = viewModel.selectedGroup else { return }
                                    viewModel.removeMember(member.id, from: selectedGroup.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                if let audioErrorMessage = viewModel.audioErrorMessage {
                    Text(audioErrorMessage)
                        .font(AppTypography.footnote)
                        .foregroundStyle(AppColorPalette.danger)
                        .accessibilityIdentifier("audioErrorLabel")
                }
            }
            .padding(AppSpacing.screen)
        }
        .background(AppColorPalette.callScreenBackground)
        .accessibilityIdentifier("callScrollView")
        .accessibilityIdentifier("callScreen")
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxl) {
            HStack(alignment: .center, spacing: AppSpacing.xl) {
                HStack(spacing: AppSpacing.l) {
                    Image(systemName: connectionIconName)
                        .imageScale(.large)
                        .foregroundStyle(connectionStatusColor)
                        .frame(width: AppSize.iconM)

                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text(viewModel.callPresenceLabel)
                            .font(AppTypography.rowTitle)
                            .lineLimit(2)
                            .accessibilityIdentifier("callPresenceLabel")
                        Text(viewModel.routeLabel)
                            .font(AppTypography.captionStrong)
                            .foregroundStyle(AppColorPalette.textSecondary)
                            .lineLimit(2)
                            .accessibilityIdentifier("routeLabel")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Call status")
                .accessibilityValue("\(viewModel.callPresenceLabel), \(viewModel.routeLabel)")
                .accessibilityIdentifier("connectionStatusIcon")

                Spacer()
            }

            if let localMember {
                LocalMicrophoneHeaderControl(
                    member: localMember,
                    isMuted: viewModel.isMuted,
                    onToggleMute: { viewModel.toggleMute() }
                )
            }

            HStack(alignment: .center, spacing: AppSpacing.xl) {
                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    Label("Output", systemImage: "speaker.wave.2.fill")
                        .font(AppTypography.captionStrong)
                        .foregroundStyle(viewModel.isOutputMuted ? AppColorPalette.danger : AppColorPalette.textSecondary)

                    Slider(
                        value: Binding(
                            get: { Double(viewModel.masterOutputVolume) },
                            set: { viewModel.setMasterOutputVolume(Float($0)) }
                        ),
                        in: 0...Double(IntercomViewModel.maximumMasterOutputVolume)
                    )
                    .accessibilityLabel("Output Volume")
                    .accessibilityValue(outputPercentLabel)
                    .accessibilityIdentifier("masterOutputVolumeSlider")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    viewModel.toggleOutputMute()
                } label: {
                    Image(systemName: viewModel.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: AppSize.tapPrimary.width, height: AppSize.tapPrimary.height)
                }
                .appSecondaryButtonStyle()
                .tint(viewModel.isOutputMuted ? AppColorPalette.danger : AppColorPalette.buttonProminentBackground)
                .accessibilityLabel(viewModel.isOutputMuted ? "Unmute Output" : "Mute Output")
                .accessibilityValue(outputPercentLabel)
                .accessibilityIdentifier("masterOutputMuteButton")
            }
        }
        .appCallCardStyle()
        .accessibilityIdentifier("callStatusHeader")
    }

    private var localMember: GroupMember? {
        viewModel.selectedGroup?.members.first
    }

    private var remoteMembers: [GroupMember] {
        Array(viewModel.selectedGroup?.members.dropFirst() ?? [])
    }

    private var outputPercentLabel: String {
        let percent = Int((viewModel.masterOutputVolume * 100).rounded())
        let label = viewModel.masterOutputVolume > IntercomViewModel.normalMasterOutputVolume ? "Output Boost" : "Output"
        return viewModel.isOutputMuted ? "Output Muted" : "\(label) \(percent)%"
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppSpacing.l) {
                primaryConnectionButton

                if let inviteURL = viewModel.selectedGroupInviteURL {
                    inviteLink(inviteURL)
                }
            }

            VStack(alignment: .leading, spacing: AppSpacing.l) {
                primaryConnectionButton

                if let inviteURL = viewModel.selectedGroupInviteURL {
                    inviteLink(inviteURL)
                }
            }
        }
    }

    private var primaryConnectionButton: some View {
        Group {
            if viewModel.canDisconnectCall {
                Button {
                    viewModel.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle.fill")
                }
                .accessibilityIdentifier("disconnectButton")
            } else {
                Button {
                    viewModel.connectLocal()
                } label: {
                    Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                }
                .accessibilityIdentifier("connectButton")
            }
        }
        .appProminentButtonStyle()
        .controlSize(.large)
        .accessibilityValue(viewModel.callPresenceLabel)
    }

    private func inviteLink(_ inviteURL: URL) -> some View {
        ShareLink(
            item: inviteURL,
            subject: Text("RideIntercom Invite"),
            message: Text("Join \(viewModel.selectedGroup?.name ?? "RideIntercom")")
        ) {
            Label("Invite", systemImage: "square.and.arrow.up")
        }
        .appSecondaryButtonStyle()
        .controlSize(.large)
        .simultaneousGesture(TapGesture().onEnded {
            viewModel.reserveInviteMemberSlot()
        })
        .accessibilityLabel("Invite Group")
        .accessibilityHint("Opens sharing options for this group invite.")
        .accessibilityIdentifier("inviteButton")
    }

    private var connectionIconName: String {
        switch viewModel.connectionState {
        case .idle:
            "wifi.slash"
        case .localConnecting, .internetConnecting:
            "wifi.exclamationmark"
        case .localConnected, .internetConnected:
            "wifi"
        case .reconnectingOffline:
            "exclamationmark.triangle.fill"
        }
    }

    private var connectionStatusColor: Color {
        switch viewModel.connectionState {
        case .idle:
            AppColorPalette.neutral
        case .localConnecting, .internetConnecting:
            AppColorPalette.warning
        case .localConnected, .internetConnected:
            AppColorPalette.success
        case .reconnectingOffline:
            AppColorPalette.danger
        }
    }
}

private struct DiagnosticsView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let snapshot = viewModel.diagnosticsSnapshot
            let now = context.date.timeIntervalSince1970

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.screen) {
                    LiveTransmitPipelineView(viewModel: viewModel)

                    VStack(alignment: .leading, spacing: AppSpacing.m) {
                        Text("Live Status")
                            .font(AppTypography.sectionTitle)
                        DiagnosticRow(
                            icon: "checklist",
                            value: "CALL \(viewModel.connectionLabel) / \(viewModel.isAudioReady ? "AUDIO READY" : "AUDIO IDLE")"
                        )
                            .accessibilityIdentifier("realDeviceCallDebugSummaryLabel")
                        DiagnosticRow(icon: "clock.arrow.circlepath", value: snapshot.reception.summary(now: now))
                            .accessibilityIdentifier("receptionDebugSummaryLabel")
                        DiagnosticRow(icon: "waveform.path.ecg", value: snapshot.audio.summary)
                            .accessibilityIdentifier("audioDebugSummaryLabel")
                        DiagnosticRow(icon: "speaker.wave.2.fill", value: snapshot.playback.summary)
                            .accessibilityIdentifier("playbackDebugSummaryLabel")
                        DiagnosticRow(icon: "exclamationmark.triangle.fill", value: snapshot.codecSafetySummary)
                            .accessibilityIdentifier("codecSafetyDebugSummaryLabel")
                        DiagnosticRow(icon: "person.2.fill", value: snapshot.connectionSummary)
                            .accessibilityIdentifier("connectionDebugSummaryLabel")
                        DiagnosticRow(icon: "checkmark.seal.fill", value: snapshot.authenticationSummary)
                            .accessibilityIdentifier("authenticationDebugSummaryLabel")
                        DiagnosticRow(icon: "antenna.radiowaves.left.and.right", value: snapshot.localNetwork.summary(now: now))
                            .accessibilityIdentifier("localNetworkDebugSummaryLabel")
                    }

                    VStack(alignment: .leading, spacing: AppSpacing.m) {
                        Text("Identity & Route")
                            .font(AppTypography.sectionTitle)
                        DiagnosticRow(icon: "network", value: snapshot.transportSummary)
                            .accessibilityIdentifier("transportDebugSummaryLabel")
                        DiagnosticRow(icon: "person.text.rectangle.fill", value: snapshot.localMemberSummary)
                            .accessibilityIdentifier("localMemberDebugSummaryLabel")
                        DiagnosticRow(icon: "person.3.sequence.fill", value: snapshot.selectedGroupSummary)
                            .accessibilityIdentifier("selectedGroupDebugSummaryLabel")
                        DiagnosticRow(icon: "number", value: snapshot.groupHashSummary)
                            .accessibilityIdentifier("groupHashDebugSummaryLabel")
                        DiagnosticRow(icon: "square.and.arrow.up", value: snapshot.inviteSummary)
                            .accessibilityIdentifier("inviteDebugSummaryLabel")
                    }

                    VStack(alignment: .leading, spacing: AppSpacing.m) {
                        Text("Input Config")
                            .font(AppTypography.sectionTitle)

                        DiagnosticRow(
                            icon: "hifispeaker.2",
                            value: viewModel.isAudioDeviceSelectionLive ? "SESSION ACTIVE / I/O ROUTING LIVE" : "SESSION IDLE / I/O ROUTING NEXT START"
                        )
                        .accessibilityIdentifier("audioIOApplyStateLabel")

                        DiagnosticRow(icon: "slider.horizontal.3", value: viewModel.audioInputProcessingSummary)
                            .accessibilityLabel("Audio input processing")
                            .accessibilityValue(viewModel.audioInputProcessingSummary)
                            .accessibilityIdentifier("audioInputProcessingSummaryLabel")
                    }
                }
                .padding(AppSpacing.screen)
            }
            .accessibilityIdentifier("diagnosticsScrollView")
        }
    }
}

private struct SettingsView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Form {
            AudioIOPanel(viewModel: viewModel)
            AudioCheckPanel(viewModel: viewModel)
            TransmitCodecPanel(viewModel: viewModel)
            SoundIsolationPanel(viewModel: viewModel)
            VADThresholdPanel(viewModel: viewModel)
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settingsScrollView")
    }
}

private struct AudioIOPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            if viewModel.availableOutputPorts.count > 1 {
                Picker("Output", selection: Binding(
                    get: { viewModel.selectedOutputPort },
                    set: { viewModel.setOutputPort($0) }
                )) {
                    ForEach(viewModel.availableOutputPorts) { port in
                        Text(port.name).tag(port)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("audioCheckOutputPicker")
            }

            if viewModel.availableInputPorts.count > 1 {
                Picker("Input", selection: Binding(
                    get: { viewModel.selectedInputPort },
                    set: { viewModel.setInputPort($0) }
                )) {
                    ForEach(viewModel.availableInputPorts) { port in
                        Text(port.name).tag(port)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("audioCheckInputPicker")
            }
        } header: {
            Label("Audio I/O", systemImage: "slider.horizontal.3")
        }
        .accessibilityIdentifier("audioIOPanel")
    }
}

private struct TransmitCodecPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            Picker("Codec", selection: Binding(
                get: { viewModel.preferredTransmitCodec },
                set: { viewModel.setPreferredTransmitCodec($0) }
            )) {
                Text("PCM 16-bit").tag(AudioCodecIdentifier.pcm16)
                Text("HE-AAC v2 VBR").tag(AudioCodecIdentifier.heAACv2)
                Text("Opus").tag(AudioCodecIdentifier.opus)
            }
            .pickerStyle(.segmented)
            .disabled(true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transmitCodecPicker")

            if viewModel.preferredTransmitCodec == .heAACv2 {
                Picker("HE-AAC v2 Quality", selection: Binding(
                    get: { viewModel.heAACv2Quality },
                    set: { viewModel.setHEAACv2Quality($0) }
                )) {
                    ForEach(HEAACv2Quality.allCases, id: \.self) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("heAACv2QualityPicker")
            }
        } header: {
            Label("Transmit Codec", systemImage: "antenna.radiowaves.left.and.right")
        }
        .accessibilityIdentifier("transmitCodecPanel")
    }
}

private struct AudioCheckPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text("Call")
                Spacer()
                VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                    Text(viewModel.isAudioReady ? "Call Live" : "Call Idle")
                        .font(AppTypography.bodyStrong)
                        .foregroundStyle(viewModel.isAudioReady ? AppColorPalette.success : AppColorPalette.textSecondary)
                        .accessibilityIdentifier("liveAudioStateLabel")
                    Text(viewModel.audioCheckPhase.rawValue)
                        .font(AppTypography.captionStrongMono)
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier("audioCheckPhaseLabel")
                }
            }

            VStack(alignment: .leading, spacing: AppSpacing.m) {
                Label("Microphone Input", systemImage: "mic.fill")
                    .font(AppTypography.subheadlineStrong)
                VoiceMeterView(
                    level: viewModel.diagnosticsInputLevel,
                    peakLevel: viewModel.diagnosticsInputPeakLevel,
                    isMuted: viewModel.isMuted,
                    showsValueText: false
                )
                .accessibilityIdentifier("audioCheckInputMeter")
            }
            .listRowSeparator(.hidden)

            VStack(alignment: .leading, spacing: AppSpacing.m) {
                Label("Speaker Output", systemImage: "speaker.wave.2.fill")
                    .font(AppTypography.subheadlineStrong)
                VoiceMeterView(
                    level: viewModel.diagnosticsOutputLevel,
                    peakLevel: viewModel.diagnosticsOutputPeakLevel,
                    isMuted: false,
                    showsValueText: false
                )
                .accessibilityIdentifier("audioCheckOutputMeter")
            }
            .listRowSeparator(.hidden)

            Text(viewModel.audioCheckStatusMessage)
                .font(AppTypography.footnote)
                .foregroundStyle(AppColorPalette.textSecondary)
                .lineLimit(nil)
                .accessibilityIdentifier("audioCheckStatusLabel")

            Button {
                viewModel.startAudioCheck()
            } label: {
                Label("Record 5s and Play", systemImage: "record.circle.fill")
            }
            .appProminentButtonStyle()
            .controlSize(.large)
            .disabled(viewModel.audioCheckPhase == .recording || viewModel.audioCheckPhase == .playing)
            .accessibilityValue(viewModel.audioCheckPhase.rawValue)
            .accessibilityIdentifier("audioCheckButton")
        } header: {
            Label("Audio Check", systemImage: "waveform")
        }
        .accessibilityIdentifier("audioCheckPanel")
    }

    private var statusColor: Color {
        switch viewModel.audioCheckPhase {
        case .idle:
            AppColorPalette.neutral
        case .recording:
            AppColorPalette.danger
        case .playing:
            AppColorPalette.success
        case .completed:
            AppColorPalette.info
        case .failed:
            AppColorPalette.danger
        }
    }

}

private struct SoundIsolationPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        if viewModel.supportsSoundIsolation {
            Section {
                Toggle(
                    "Sound Isolation",
                    isOn: Binding(
                        get: { viewModel.isSoundIsolationEnabled },
                        set: { viewModel.setSoundIsolationEnabled($0) }
                    )
                )
                .accessibilityIdentifier("soundIsolationToggle")
            } header: {
                Label("Sound Isolation", systemImage: "waveform")
            }
            .accessibilityIdentifier("soundIsolationPanel")
        }
    }
}

private struct VADThresholdPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            HStack {
                Text("Voice Activity Detection Threshold")
                Spacer()
                Text(String(format: "%.4f", viewModel.voiceActivityDetectionThreshold))
                    .font(AppTypography.captionStrongMono)
                    .foregroundStyle(AppColorPalette.textSecondary)
            }

            Slider(
                value: Binding(
                    get: { Double(viewModel.voiceActivityDetectionThreshold) },
                    set: {
                        let minValue = Double(VoiceActivityDetector.minThreshold)
                        let maxValue = Double(VoiceActivityDetector.maxThreshold)
                        let clamped = min(max(minValue, $0), maxValue)
                        let step = 0.00025
                        let snapped = (clamped / step).rounded() * step
                        viewModel.setVoiceActivityDetectionThreshold(Float(min(max(minValue, snapped), maxValue)))
                    }
                ),
                in: Double(VoiceActivityDetector.minThreshold)...Double(VoiceActivityDetector.maxThreshold)
            )
            .accessibilityIdentifier("voiceActivityDetectionThresholdSlider")
        } header: {
            Label("VAD Threshold", systemImage: "waveform.badge.mic")
        }
        .accessibilityIdentifier("vadThresholdPanel")
    }
}

private struct DiagnosticRow: View {
    let icon: String
    let value: String

    private var parts: [String] {
        value.components(separatedBy: " / ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.l) {
            Image(systemName: icon)
                .frame(width: AppSize.iconS)
                .foregroundStyle(AppColorPalette.textSecondary)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                ForEach(parts, id: \.self) { part in
                    Text(part)
                        .font(AppTypography.footnoteMono)
                        .foregroundStyle(AppColorPalette.textPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appDiagnosticsCardStyle()
    }
}

private struct LiveTransmitPipelineView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            Label("Live TX Pipeline", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(AppTypography.sectionTitle)

            HStack(alignment: .top, spacing: AppSpacing.xs) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    PipelineStepView(step: step)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("transmitPipelineStep\(index)")

                    if index < steps.count - 1 {
                        PipelineConnectorView(color: connectorColor(after: index))
                            .frame(width: AppSize.connector.width, height: AppSize.connector.height)
                            .accessibilityIdentifier("transmitPipelineConnector\(index)")
                    }
                }
            }
        }
        .appDiagnosticsCardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveTransmitPipelineView")
    }

    private var steps: [PipelineStep] {
        [
            micStep,
            muteIsolationStep,
            vadStep,
            encodeStep,
            sendStep
        ]
    }

    private var micStep: PipelineStep {
        if viewModel.audioErrorMessage != nil {
            return PipelineStep(title: "Mic", detail: "Error", icon: "mic.slash.fill", state: .blocked)
        }
        if viewModel.isAudioReady, !viewModel.isMicrophoneCaptureRunning {
            return PipelineStep(title: "Mic", detail: "Off", icon: "mic.slash.fill", state: .blocked)
        }
        if viewModel.isAudioReady {
            let detail = viewModel.diagnosticsInputLevel > 0 ? "Input" : "Ready"
            return PipelineStep(title: "Mic", detail: detail, icon: "mic.fill", state: .passing)
        }
        return PipelineStep(title: "Mic", detail: "Idle", icon: "mic", state: .idle)
    }

    private var muteIsolationStep: PipelineStep {
        if viewModel.isMuted {
            let detail = viewModel.isMicrophoneCaptureRunning ? "Muted" : "Muted + Mic Off"
            return PipelineStep(title: "Mute", detail: detail, icon: "mic.slash.fill", state: .blocked)
        }
        let detail = viewModel.isSoundIsolationEnabled ? "Iso On" : "Open"
        return PipelineStep(title: "Input FX", detail: detail, icon: "waveform", state: viewModel.isAudioReady ? .passing : .idle)
    }

    private var vadStep: PipelineStep {
        if viewModel.isMuted {
            return PipelineStep(title: "VAD", detail: "Muted", icon: "waveform.slash", state: .idle)
        }
        if viewModel.isVoiceActive {
            return PipelineStep(title: "VAD", detail: "Voice", icon: "waveform.badge.mic", state: .passing)
        }
        return PipelineStep(title: "VAD", detail: viewModel.isAudioReady ? "Silent" : "Waiting", icon: "waveform.slash", state: viewModel.isAudioReady ? .waiting : .idle)
    }

    private var encodeStep: PipelineStep {
        guard viewModel.isAudioReady else {
            return PipelineStep(title: "Encode", detail: "Idle", icon: "cpu", state: .idle)
        }
        guard viewModel.isVoiceActive else {
            return PipelineStep(title: "Encode", detail: codecLabel, icon: "cpu", state: .waiting)
        }
        return PipelineStep(title: "Encode", detail: codecLabel, icon: "cpu.fill", state: .passing)
    }

    private var sendStep: PipelineStep {
        guard viewModel.isAudioReady else {
            return PipelineStep(title: "Send", detail: "Idle", icon: "paperplane", state: .idle)
        }
        guard viewModel.connectionState == .localConnected || viewModel.connectionState == .internetConnected else {
            return PipelineStep(title: "Send", detail: "Waiting", icon: "paperplane", state: .waiting)
        }
        guard viewModel.sentVoicePacketCount > 0 else {
            return PipelineStep(title: "Send", detail: "Ready", icon: "paperplane", state: .waiting)
        }
        return PipelineStep(title: "Send", detail: "TX \(viewModel.sentVoicePacketCount)", icon: "paperplane.fill", state: .passing)
    }

    private var codecLabel: String {
        switch viewModel.preferredTransmitCodec {
        case .pcm16:
            "PCM"
        case .heAACv2:
            "AAC"
        case .opus:
            "Opus"
        }
    }

    private func connectorColor(after index: Int) -> Color {
        let left = steps[index].state
        let right = steps[index + 1].state
        if left == .blocked || right == .blocked {
            return AppColorPalette.danger
        }
        if left == .passing && right == .passing {
            return AppColorPalette.success
        }
        if left == .passing || right == .waiting {
            return AppColorPalette.warning
        }
        return AppColorPalette.connectorNeutral
    }
}

private struct PipelineStep: Equatable {
    let title: String
    let detail: String
    let icon: String
    let state: PipelineStepState
}

private enum PipelineStepState: Equatable {
    case passing
    case waiting
    case blocked
    case idle

    var color: Color {
        switch self {
        case .passing:
            AppColorPalette.success
        case .waiting:
            AppColorPalette.warning
        case .blocked:
            AppColorPalette.danger
        case .idle:
            AppColorPalette.neutral
        }
    }
}

private struct PipelineStepView: View {
    let step: PipelineStep

    var body: some View {
        VStack(spacing: AppSpacing.s) {
            Image(systemName: step.icon)
                .font(.title3)
                .frame(width: AppSize.iconL, height: AppSize.iconL)
                .foregroundStyle(step.state.color)
            Text(step.title)
                .font(AppTypography.captionStrong)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(step.detail)
                .font(AppTypography.caption2)
                .foregroundStyle(step.state.color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(minWidth: AppSize.iconL)
        .accessibilityElement(children: .contain)
    }
}

private struct PipelineConnectorView: View {
    let color: Color

    var body: some View {
        Text(">")
            .font(.system(size: 11, weight: .regular, design: .default))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct LocalMicrophoneHeaderControl: View {
    let member: GroupMember
    let isMuted: Bool
    let onToggleMute: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.xl) {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.m) {
                    Label {
                        Text("Input")
                            .font(AppTypography.subheadlineStrong)
                            .foregroundStyle(isMuted ? AppColorPalette.danger : AppColorPalette.textSecondary)
                    } icon: {
                        Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                            .foregroundStyle(isMuted ? AppColorPalette.danger : AppColorPalette.textSecondary)
                    }

                    Text(isMuted ? "Muted" : "Live")
                        .font(AppTypography.captionStrongMono)
                        .foregroundStyle(isMuted ? AppColorPalette.danger : AppColorPalette.success)
                        .accessibilityIdentifier("localMicrophoneStateLabel")
                }

                VoiceMeterView(
                    level: isMuted ? 0 : member.voiceLevel,
                    peakLevel: isMuted ? 0 : member.voicePeakLevel,
                    isMuted: isMuted,
                    showsValueText: false
                )
                .accessibilityIdentifier("localMicrophoneMeter")
            }

            Button(action: onToggleMute) {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: AppSize.tapPrimary.width, height: AppSize.tapPrimary.height)
            }
            .appSecondaryButtonStyle()
            .tint(isMuted ? AppColorPalette.danger : AppColorPalette.buttonProminentBackground)
            .accessibilityLabel(isMuted ? "Unmute" : "Mute")
            .accessibilityValue(isMuted ? "Muted" : "Live")
            .accessibilityIdentifier("localMicrophoneMuteButton")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your microphone")
        .accessibilityValue(isMuted ? "Muted" : "Live")
        .accessibilityIdentifier("localMicrophoneHeaderControl")
    }
}

private struct VoiceMeterView: View {
    let level: Float
    let peakLevel: Float
    let isMuted: Bool
    var showsValueText: Bool = true

    private var indicator: VoiceLevelIndicatorState {
        VoiceLevelIndicatorState(level: level, peakLevel: peakLevel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppColorPalette.meterTrack)
                    Capsule()
                        .fill(meterColor)
                        .frame(width: geometry.size.width * CGFloat(indicator.displayLevel))
                    Rectangle()
                        .fill(.primary)
                        .frame(width: AppSize.meterPeakWidth, height: AppSize.meterHeight)
                        .offset(x: max(0, geometry.size.width * CGFloat(indicator.displayPeakLevel) - 1))
                }
            }
            .frame(height: AppSize.meterHeight)

            if showsValueText {
                Text(isMuted ? "MUTED" : "LEVEL \(indicator.levelPercent)  PEAK \(indicator.peakPercent)")
                    .font(AppTypography.caption2Mono)
                    .foregroundStyle(isMuted ? AppColorPalette.danger : meterColor)
                    .accessibilityIdentifier("voiceMeterValueLabel")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio level")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if isMuted {
            return "Muted"
        }
        return "Level \(indicator.levelPercent), peak \(indicator.peakPercent)"
    }

    private var meterColor: Color {
        if isMuted {
            return AppColorPalette.danger
        }

        switch indicator.intensity {
        case .silent:
            return AppColorPalette.neutral
        case .low:
            return AppColorPalette.info
        case .medium:
            return AppColorPalette.success
        case .high:
            return AppColorPalette.warning
        }
    }
}

private struct RemoteParticipantRowView: View {
    let index: Int
    let member: GroupMember
    @Binding var outputVolume: Double

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.l) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xl) {
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(member.displayName)
                        .font(AppTypography.rowTitle)
                        .lineLimit(2)
                        .accessibilityIdentifier("participantName\(index)")

                    HStack(spacing: AppSpacing.m) {
                        Image(systemName: connectionIconName)
                            .foregroundStyle(connectionIconColor)
                        Image(systemName: authIconName)
                            .foregroundStyle(authIconColor)
                    }
                    .font(AppTypography.footnoteStrong)
                    .accessibilityIdentifier("participantStatusSummary\(index)")
                }

                Spacer()

                VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                    Label(codecLabel, systemImage: audioPipelineIconName)
                        .font(AppTypography.caption)
                        .foregroundStyle(audioPipelineColor)

                    Text(member.audioPipelineState.rawValue)
                        .font(AppTypography.captionStrongMono)
                        .foregroundStyle(audioPipelineColor)
                }
                .accessibilityIdentifier("participantAudioPipelineState\(index)")
            }

            VStack(alignment: .leading, spacing: AppSpacing.l) {
                participantMeter
                participantOutputControl
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCallCardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(member.displayName)
        .accessibilityValue("\(statusSummary), \(codecLabel), output \(outputPercentLabel)")
    }

    private var participantMeter: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Label("Input", systemImage: member.isMuted ? "mic.slash.fill" : "mic.fill")
                .font(AppTypography.captionStrong)
                .foregroundStyle(member.isMuted ? AppColorPalette.danger : AppColorPalette.textSecondary)

            VoiceMeterView(
                level: member.isMuted ? 0 : member.voiceLevel,
                peakLevel: member.isMuted ? 0 : member.voicePeakLevel,
                isMuted: member.isMuted,
                showsValueText: false
            )
        }
        .accessibilityIdentifier("participantVoiceLevel\(index)")
    }

    private var participantOutputControl: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.s) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(AppColorPalette.textSecondary)
                Text("Output")
                    .font(AppTypography.caption)
                Spacer()
                Text(outputPercentLabel)
                    .font(AppTypography.captionStrongMono)
                    .foregroundStyle(AppColorPalette.textSecondary)
            }
            Slider(value: $outputVolume, in: 0...1)
                .accessibilityLabel("\(member.displayName) Output")
                .accessibilityValue(outputPercentLabel)
                .accessibilityIdentifier("participantOutputVolumeSlider\(index)")
        }
    }

    private var outputPercentLabel: String {
        "\(Int((outputVolume * 100).rounded()))%"
    }

    private var statusSummary: String {
        "\(member.connectionState.rawValue) / \(authenticationLabel) / \(member.audioPipelineState.rawValue)"
    }

    private var connectionIconName: String {
        switch member.connectionState {
        case .connected:
            "wifi"
        case .connecting:
            "wifi.exclamationmark"
        case .offline:
            "wifi.slash"
        }
    }

    private var connectionIconColor: Color {
        switch member.connectionState {
        case .connected:
            AppColorPalette.success
        case .connecting:
            AppColorPalette.warning
        case .offline:
            AppColorPalette.neutral
        }
    }

    private var authIconName: String {
        switch member.authenticationState {
        case .open:
            "lock.open"
        case .pending:
            "clock.badge.questionmark"
        case .authenticated:
            "checkmark.seal.fill"
        case .offline:
            "xmark.seal"
        }
    }

    private var authIconColor: Color {
        switch member.authenticationState {
        case .open:
            AppColorPalette.neutral
        case .pending:
            AppColorPalette.warning
        case .authenticated:
            AppColorPalette.success
        case .offline:
            AppColorPalette.danger
        }
    }

    private var authenticationLabel: String {
        switch member.authenticationState {
        case .open:
            "Open"
        case .pending:
            "Auth Pending"
        case .authenticated:
            "Auth OK"
        case .offline:
            "Auth Off"
        }
    }

    private var codecLabel: String {
        switch member.activeCodec {
        case .pcm16:
            "PCM 16-bit"
        case .heAACv2:
            "HE-AAC v2"
        case .opus:
            "Opus"
        case nil:
            "--"
        }
    }

    private var audioPipelineIconName: String {
        "cpu"
    }

    private var audioPipelineColor: Color {
        switch member.audioPipelineState {
        case .receiving:
            AppColorPalette.info
        case .playing:
            AppColorPalette.success
        case .received:
            AppColorPalette.warning
        case .idle:
            AppColorPalette.neutral
        }
    }
}

#Preview {
    ContentView()
}
