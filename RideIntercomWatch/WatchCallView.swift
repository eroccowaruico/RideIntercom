import SwiftUI

struct WatchCallView: View {
    let client: WatchControlClient
    let audio: WatchAudioController
    @GestureState private var isHolding = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !client.isReachable {
                        Text("Connect to your iPhone to control a call.")
                    } else if let state = client.snapshot {
                        Text(stateTitle(state.state))
                        if let title = state.title { Text(title) }
                        if state.reference != nil {
                            Picker("Microphone Mode", selection: Binding(
                                get: { audio.microphoneIntent.mode }, set: audio.setMicrophoneMode)) {
                                Text("Hold to Talk").tag(WatchMicrophoneIntent.Mode.hold)
                                Text("Toggle Microphone").tag(WatchMicrophoneIntent.Mode.toggle)
                            }
                            if audio.microphoneIntent.mode == .hold {
                                Button { } label: {
                                    Text(audio.isTalking ? LocalizedStringKey("Talking…") : LocalizedStringKey("Hold to Talk"))
                                }
                                .buttonStyle(.borderedProminent)
                                .simultaneousGesture(DragGesture(minimumDistance: 0).updating($isHolding) { _, state, _ in state = true })
                                .onChange(of: isHolding) { _, held in audio.setPressed(held) }
                                .disabled(!audio.isReady || client.isWaiting)
                                .accessibilityIdentifier("watchHoldToTalk")
                                .accessibilityHint("Choose Toggle Microphone to use a single tap.")
                            } else {
                                Toggle("Microphone", isOn: Binding(get: { audio.isTalking }, set: audio.setPressed))
                                    .disabled(!audio.isReady || client.isWaiting)
                                    .accessibilityIdentifier("watchMicrophoneToggle")
                            }
                            if state.hasCall {
                                Button("End Call", role: .destructive) { audio.stop(); Task { await client.perform(.end) } }
                                    .disabled(client.isWaiting)
                            }
                        }
                    }
                    if client.isWaiting || audio.isPreparing { ProgressView("Updating…") }
                    if let problem = audio.problem { Text(problem).foregroundStyle(.secondary) }
                    if let problem = client.problem { Text(problemTitle(problem)).foregroundStyle(.secondary) }
                    Button("Refresh") { Task { await client.perform(.refresh) } }
                        .disabled(!client.isReachable || client.isWaiting)
                }
                if let notification = client.snapshot?.notification {
                    Section("Call Request") {
                        Text(notificationTitle(notification.status))
                        if notification.canCancel {
                            Button("Cancel Call Request") {
                                Task { await client.perform(.cancelCallRequest(notification.requestID)) }
                            }.disabled(!client.isReachable || client.isWaiting)
                        }
                    }
                }
                if client.isReachable, let state = client.snapshot, !state.targets.isEmpty {
                    Section("Call") {
                        ForEach(state.targets) { target in
                            VStack(alignment: .leading) {
                                Button { Task { await audio.startCall(to: target.id) } } label: { Text(target.name) }
                                    .buttonStyle(.bordered)
                                if target.canNotify {
                                    Button("Send Call Request") { Task { await client.perform(.requestCall(target.id)) } }
                                        .buttonStyle(.bordered)
                                }
                            }.disabled(client.isWaiting || audio.isPreparing)
                        }
                    }
                }
                Section { Text("Audio uses your Watch. Keep your iPhone nearby.").font(.footnote) }
            }
            .navigationTitle("RideCom")
            .onDisappear { audio.setPressed(false) }
        }
    }
    private func notificationTitle(_ status: CallNotificationStatus) -> LocalizedStringKey {
        switch status {
        case .accepted: "Notification accepted. Delivery is not confirmed."
        case .processing: "The call request is being processed."
        case .noDestinations: "This person has no notification destination available."
        case .retryLater: "The call request could not be sent. Please try again later."
        case .rejected: "The call request was not accepted."
        case .cancelled: "Call request cancelled."
        }
    }
    private func stateTitle(_ state: WatchCallState) -> LocalizedStringKey {
        switch state {
        case .signedOut: "Open RideCom on iPhone and sign in."
        case .idle: "Choose a call"
        case .connecting: "Connecting — waiting for others"
        case .inCall: "In a call"
        case .audioPaused: "Audio paused — check your audio device"
        case .audioUnavailable: "Audio unavailable — check your settings"
        }
    }
    private func problemTitle(_ problem: WatchControlProblem) -> LocalizedStringKey {
        switch problem {
        case .unavailable: "Could not reach iPhone. Try again."
        case .stale: "The call changed. Check the current call and try again."
        case .noAccount: "Open RideCom on iPhone and sign in."
        case .missingDestination: "This saved call destination is no longer available."
        case .denied: "Open RideCom on iPhone to continue."
        }
    }
}
