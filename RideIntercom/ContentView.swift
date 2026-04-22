import SwiftUI

struct ContentView: View {
    @State private var viewModel = IntercomViewModel.makeForCurrentProcess()
    @State private var selectedTab: AppTab = AppTab.initialForCurrentProcess

    var body: some View {
        let _ = viewModel.uiEventRevision

        TabView(selection: $selectedTab) {
            NavigationStack {
                GroupSelectionView(viewModel: viewModel) {
                    selectedTab = .call
                }
                .navigationTitle("Groups")
            }
            .tabItem {
                Label("Groups", systemImage: "person.3.fill")
                    .accessibilityIdentifier("groupsTab")
            }
            .tag(AppTab.groups)

            NavigationStack {
                CallView(viewModel: viewModel)
                    .navigationTitle(viewModel.selectedGroup?.name ?? "Call")
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                selectedTab = .groups
                            } label: {
                                Label("Groups", systemImage: "person.3.fill")
                            }
                            .accessibilityIdentifier("showGroupsButton")
                        }
                    }
            }
            .tabItem {
                Label("Call", systemImage: "waveform.circle.fill")
                    .accessibilityIdentifier("callTab")
            }
            .tag(AppTab.call)

            NavigationStack {
                DiagnosticsView(viewModel: viewModel)
                    .navigationTitle("Diagnostics")
            }
            .tabItem {
                Label("Diagnostics", systemImage: "gauge")
                    .accessibilityIdentifier("diagnosticsTab")
            }
            .tag(AppTab.diagnostics)
        }
        .onOpenURL { url in
            if (try? viewModel.acceptInviteURL(url)) != nil {
                selectedTab = .call
            }
        }
    }
}

private enum AppTab: Hashable {
    case groups
    case call
    case diagnostics

    static var initialForCurrentProcess: AppTab {
        if ProcessInfo.processInfo.arguments.contains("--start-on-diagnostics") {
            return .diagnostics
        }
        return .groups
    }
}

private struct GroupSelectionView: View {
    @Bindable var viewModel: IntercomViewModel
    let onGroupSelected: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                viewModel.createTrailGroup()
                onGroupSelected()
            } label: {
                Label("Create Trail Group", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("createGroupButton")

            Text("Recent Groups")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            List {
                ForEach(viewModel.groups) { group in
                    Button {
                        viewModel.selectGroup(group)
                        onGroupSelected()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.name)
                                    .font(.headline)
                                Text("\(group.members.count) members")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(group.name)
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
            .listStyle(.plain)
        }
        .accessibilityIdentifier("groupSelectionList")
    }
}

private struct CallView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Group {
            if viewModel.selectedGroup == nil {
                CallPlaceholderView(viewModel: viewModel)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusHeader
                        if let localMember {
                            LocalMicrophonePanel(
                                member: localMember,
                                isMuted: viewModel.isMuted,
                                onToggleMute: { viewModel.toggleMute() }
                            )
                        }
                        controls

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Participants")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(Array(viewModel.selectedGroupSlots.enumerated()), id: \.offset) { index, member in
                                ParticipantSlotView(
                                    index: index,
                                    member: member,
                                    canRemove: member.map { viewModel.canRemoveMember($0.id) } ?? false
                                ) {
                                    guard let selectedGroup = viewModel.selectedGroup,
                                          let member else { return }
                                    viewModel.removeMember(member.id, from: selectedGroup.id)
                                }
                                    .accessibilityIdentifier("participantSlot\(index)")
                            }
                        }

                        if let audioErrorMessage = viewModel.audioErrorMessage {
                            Text(audioErrorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("audioErrorLabel")
                        }
                    }
                    .padding()
                }
                .accessibilityIdentifier("callScrollView")
            }
        }
        .accessibilityIdentifier("callScreen")
    }

    private var statusHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: connectionIconName)
                    .imageScale(.large)
                    .accessibilityLabel(viewModel.callPresenceLabel)
                    .accessibilityIdentifier("connectionStatusIcon")

                Spacer()

                Text(viewModel.routeLabel)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityIdentifier("routeLabel")
            }
        }
    }

    private var localMember: GroupMember? {
        viewModel.selectedGroup?.members.first
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if viewModel.canDisconnectCall {
                Button {
                    viewModel.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("disconnectButton")
            } else {
                Button {
                    viewModel.connectLocal()
                } label: {
                    Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("connectButton")
            }

            if let inviteURL = viewModel.selectedGroupInviteURL {
                ShareLink(
                    item: inviteURL,
                    subject: Text("RideIntercom Invite"),
                    message: Text("Join \(viewModel.selectedGroup?.name ?? "RideIntercom")")
                ) {
                    Label("Invite", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .simultaneousGesture(TapGesture().onEnded {
                    viewModel.reserveInviteMemberSlot()
                })
                .accessibilityLabel("Invite Group")
                .accessibilityIdentifier("inviteButton")
            }
        }
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
}

private struct CallPlaceholderView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("No Group Selected")
                    .font(.title2.weight(.semibold))
                Text("Choose a group or create one to start a call.")
                    .foregroundStyle(.secondary)
                Button {
                    viewModel.createTrailGroup()
                } label: {
                    Label("Create Trail Group", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("createGroupButton")
            }
            .padding()
        }
        .accessibilityIdentifier("callScrollView")
    }
}

private struct DiagnosticsView: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let snapshot = viewModel.diagnosticsSnapshot
            let now = context.date.timeIntervalSince1970

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AudioIOPanel(viewModel: viewModel)
                    TransmitCodecPanel(viewModel: viewModel)
                    AudioCheckPanel(viewModel: viewModel)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live Status")
                            .font(.headline)
                        DiagnosticRow(
                            icon: "checklist",
                            value: snapshot.realDeviceCallSummary(
                                connectionLabel: viewModel.connectionLabel,
                                isAudioReady: viewModel.isAudioReady,
                                now: now
                            )
                        )
                            .accessibilityIdentifier("realDeviceCallDebugSummaryLabel")
                        DiagnosticRow(icon: "waveform.path.ecg", value: snapshot.audio.summary)
                            .accessibilityIdentifier("audioDebugSummaryLabel")
                        DiagnosticRow(icon: "person.2.fill", value: snapshot.connectionSummary)
                            .accessibilityIdentifier("connectionDebugSummaryLabel")
                        DiagnosticRow(icon: "checkmark.seal.fill", value: snapshot.authenticationSummary)
                            .accessibilityIdentifier("authenticationDebugSummaryLabel")
                        DiagnosticRow(icon: "clock.arrow.circlepath", value: snapshot.reception.summary(now: now))
                            .accessibilityIdentifier("receptionDebugSummaryLabel")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Identity & Route")
                            .font(.headline)
                        DiagnosticRow(icon: "network", value: snapshot.transportSummary)
                            .accessibilityIdentifier("transportDebugSummaryLabel")
                        DiagnosticRow(icon: "antenna.radiowaves.left.and.right", value: snapshot.localNetwork.summary(now: now))
                            .accessibilityIdentifier("localNetworkDebugSummaryLabel")
                        DiagnosticRow(icon: "person.text.rectangle.fill", value: snapshot.localMemberSummary)
                            .accessibilityIdentifier("localMemberDebugSummaryLabel")
                        DiagnosticRow(icon: "person.3.sequence.fill", value: snapshot.selectedGroupSummary)
                            .accessibilityIdentifier("selectedGroupDebugSummaryLabel")
                        DiagnosticRow(icon: "number", value: snapshot.groupHashSummary)
                            .accessibilityIdentifier("groupHashDebugSummaryLabel")
                        DiagnosticRow(icon: "square.and.arrow.up", value: snapshot.inviteSummary)
                            .accessibilityIdentifier("inviteDebugSummaryLabel")
                    }
                }
                .padding()
            }
            .accessibilityIdentifier("diagnosticsScrollView")
        }
    }
}

private struct AudioIOPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Audio I/O", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Text(viewModel.isAudioDeviceSelectionLive ? "Live" : "Next start")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.isAudioDeviceSelectionLive ? .green : .secondary)
                    .accessibilityIdentifier("audioIOApplyStateLabel")
            }

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

            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                Text(viewModel.audioInputProcessingSummary)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
                .accessibilityIdentifier("audioInputProcessingSummaryLabel")
        }
        .padding(12)
        .background(.background)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("audioIOPanel")
    }
}

private struct TransmitCodecPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Transmit Codec", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)

            Picker("Codec", selection: Binding(
                get: { viewModel.preferredTransmitCodec },
                set: { viewModel.setPreferredTransmitCodec($0) }
            )) {
                Text("PCM 16-bit").tag(AudioCodecIdentifier.pcm16)
                Text("HE-AAC v2 VBR").tag(AudioCodecIdentifier.heAACv2)
            }
            .pickerStyle(.segmented)
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
        }
        .padding(12)
        .background(.background)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("transmitCodecPanel")
    }
}

private struct AudioCheckPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Audio Check", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(viewModel.isAudioReady ? "Call Live" : "Call Idle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(viewModel.isAudioReady ? .green : .secondary)
                        .accessibilityIdentifier("liveAudioStateLabel")
                    Text(viewModel.audioCheckPhase.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier("audioCheckPhaseLabel")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Microphone Input", systemImage: "mic.fill")
                    .font(.subheadline)
                VoiceMeterView(
                    level: viewModel.diagnosticsInputLevel,
                    peakLevel: viewModel.diagnosticsInputPeakLevel,
                    isMuted: viewModel.isMuted
                )
                .accessibilityIdentifier("audioCheckInputMeter")
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Speaker Output", systemImage: "speaker.wave.2.fill")
                    .font(.subheadline)
                VoiceMeterView(
                    level: viewModel.diagnosticsOutputLevel,
                    peakLevel: viewModel.diagnosticsOutputPeakLevel,
                    isMuted: false
                )
                .accessibilityIdentifier("audioCheckOutputMeter")
            }

            Text(viewModel.audioCheckStatusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("audioCheckStatusLabel")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Voice Activity Detection Threshold")
                    Spacer()
                    Text(String(format: "%.4f", viewModel.voiceActivityDetectionThreshold))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(viewModel.voiceActivityDetectionThreshold) },
                        set: { viewModel.setVoiceActivityDetectionThreshold(Float($0)) }
                    ),
                    in: Double(VoiceActivityDetector.minThreshold)...Double(VoiceActivityDetector.maxThreshold),
                    step: 0.00025
                )
                .accessibilityIdentifier("voiceActivityDetectionThresholdSlider")
            }

            if viewModel.supportsSoundIsolation {
                Toggle(
                    "Sound Isolation",
                    isOn: Binding(
                        get: { viewModel.isSoundIsolationEnabled },
                        set: { viewModel.setSoundIsolationEnabled($0) }
                    )
                )
                .accessibilityIdentifier("soundIsolationToggle")
            }

            Button {
                viewModel.startAudioCheck()
            } label: {
                Label("Record 5s and Play", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.audioCheckPhase == .recording || viewModel.audioCheckPhase == .playing)
            .accessibilityIdentifier("audioCheckButton")
        }
        .padding(12)
        .background(.background)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("audioCheckPanel")
    }

    private var statusColor: Color {
        switch viewModel.audioCheckPhase {
        case .idle:
            .secondary
        case .recording:
            .red
        case .playing:
            .green
        case .completed:
            .blue
        case .failed:
            .red
        }
    }
}

private struct DiagnosticRow: View {
    let icon: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct LocalMicrophonePanel: View {
    let member: GroupMember
    let isMuted: Bool
    let onToggleMute: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(isMuted ? .red : .green)
                Text("Your Microphone")
                    .font(.headline)
                Spacer()
                Text(isMuted ? "Muted" : "Live")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isMuted ? .red : .green)
                    .accessibilityIdentifier("localMicrophoneStateLabel")
            }

            HStack(alignment: .center, spacing: 12) {
                VoiceMeterView(
                    level: isMuted ? 0 : member.voiceLevel,
                    peakLevel: isMuted ? 0 : member.voicePeakLevel,
                    isMuted: isMuted
                )
                .accessibilityIdentifier("localMicrophoneMeter")

                Button(action: onToggleMute) {
                    Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .tint(isMuted ? .red : .accentColor)
                .accessibilityLabel(isMuted ? "Unmute" : "Mute")
                .accessibilityIdentifier("localMicrophoneMuteButton")
            }
        }
        .padding(12)
        .background(.background)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isMuted ? Color.red.opacity(0.6) : Color.green.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("localMicrophonePanel")
    }
}

private struct VoiceMeterView: View {
    let level: Float
    let peakLevel: Float
    let isMuted: Bool

    private var indicator: VoiceLevelIndicatorState {
        VoiceLevelIndicatorState(level: level, peakLevel: peakLevel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.16))
                    Capsule()
                        .fill(meterColor)
                        .frame(width: geometry.size.width * CGFloat(indicator.displayLevel))
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: 16)
                        .offset(x: max(0, geometry.size.width * CGFloat(indicator.displayPeakLevel) - 1))
                }
            }
            .frame(height: 16)

            Text(isMuted ? "MUTED" : "LEVEL \(indicator.levelPercent)  PEAK \(indicator.peakPercent)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isMuted ? .red : meterColor)
                .accessibilityIdentifier("voiceMeterValueLabel")
        }
        .accessibilityElement(children: .contain)
    }

    private var meterColor: Color {
        if isMuted {
            return .red
        }

        switch indicator.intensity {
        case .silent:
            return .secondary
        case .low:
            return .blue
        case .medium:
            return .green
        case .high:
            return .orange
        }
    }
}

private struct ParticipantSlotView: View {
    @State private var showRemoveConfirmation = false

    let index: Int
    let member: GroupMember?
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(member?.displayName ?? "Empty")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityIdentifier("participantName\(index)")

                Spacer()

                if member != nil, canRemove {
                    Button {
                        showRemoveConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Remove \(member?.displayName ?? "Participant")")
                    .accessibilityIdentifier("removeParticipantButton\(index)")
                } else {
                    Image(systemName: member?.isMuted == true ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(member == nil ? .secondary : .primary)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: statusIconName)
                    .foregroundStyle(statusColor)
                    .accessibilityIdentifier("participantState\(index)")
                Image(systemName: authenticationIconName)
                    .foregroundStyle(authenticationColor)
                    .accessibilityIdentifier("participantAuthenticationState\(index)")
                Image(systemName: audioPipelineIconName)
                    .foregroundStyle(audioPipelineColor)
                    .accessibilityIdentifier("participantAudioPipelineState\(index)")
                Image(systemName: member?.isMuted == true ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(member?.isMuted == true ? .red : .secondary)
                    .accessibilityIdentifier("participantMuteState\(index)")
            }
            .font(.caption)

            VoiceMeterView(
                level: member?.isMuted == true ? 0 : indicator.level,
                peakLevel: member?.isMuted == true ? 0 : indicator.peakLevel,
                isMuted: member?.isMuted == true
            )
            .accessibilityIdentifier("participantVoiceLevel\(index)")

            if member != nil {
                Text("Codec: \(codecLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("participantCodec\(index)")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .padding(12)
        .background(.background)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(member == nil ? Color.secondary.opacity(0.25) : Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .confirmationDialog(
            "Remove Member",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                onRemove()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var indicator: VoiceLevelIndicatorState {
        VoiceLevelIndicatorState(level: member?.voiceLevel ?? 0, peakLevel: member?.voicePeakLevel ?? 0)
    }

    private var statusIconName: String {
        switch member?.connectionState {
        case .connected:
            "wifi"
        case .connecting:
            "wifi.exclamationmark"
        case .offline:
            "wifi.slash"
        case nil:
            "person.badge.plus"
        }
    }

    private var codecLabel: String {
        switch member?.activeCodec {
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
        switch member?.audioPipelineState {
        case .receiving:
            "arrow.down.circle.fill"
        case .playing:
            "speaker.wave.2.fill"
        case .received:
            "tray.and.arrow.down.fill"
        case .idle, nil:
            "speaker.slash.fill"
        }
    }

    private var audioPipelineColor: Color {
        switch member?.audioPipelineState {
        case .receiving:
            .blue
        case .playing:
            .green
        case .received:
            .orange
        case .idle, nil:
            .secondary
        }
    }

    private var statusColor: Color {
        switch member?.connectionState {
        case .connected:
            .green
        case .connecting:
            .orange
        case .offline, nil:
            .secondary
        }
    }

    private var authenticationIconName: String {
        switch member?.authenticationState {
        case .open:
            "lock.open.fill"
        case .pending:
            "hourglass"
        case .authenticated:
            "checkmark.seal.fill"
        case .offline:
            "lock.slash.fill"
        case nil:
            "person.crop.circle.badge.plus"
        }
    }

    private var authenticationColor: Color {
        switch member?.authenticationState {
        case .authenticated:
            .green
        case .pending:
            .orange
        case .open, .offline, nil:
            .secondary
        }
    }
}

#Preview {
    ContentView()
}
