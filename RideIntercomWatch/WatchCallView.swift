import SwiftUI

/// Saved people first; an active call takes over the screen until it ends.
struct WatchCallView: View {
    let client: WatchControlClient
    let audio: WatchAudioController

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(isPresented: Binding(get: { showsCall }, set: { _ in })) {
                    WatchActiveCallView(client: client, audio: audio)
                }
        }
        .onDisappear { audio.setPressed(false) }
    }

    private var showsCall: Bool { client.isReachable && client.snapshot?.hasCall == true }

    @ViewBuilder private var content: some View {
        if !client.isReachable {
            WatchMessageView(symbol: "iphone.slash", title: "Can't connect to iPhone",
                             detail: "Keep your iPhone nearby with RideCom open.") {
                Button("Try Again") { Task { await client.perform(.refresh) } }
                    .accessibilityIdentifier("watchRetryButton")
            }
        } else if client.snapshot?.state == .signedOut {
            WatchMessageView(symbol: "person.crop.circle.badge.exclamationmark", title: "Sign in to RideCom on iPhone",
                             detail: nil) { EmptyView() }
        } else {
            WatchDestinationList(client: client, audio: audio)
        }
    }
}

private struct WatchDestinationList: View {
    let client: WatchControlClient
    let audio: WatchAudioController

    var body: some View {
        List {
            Section {
                Label("Connected to iPhone", systemImage: "iphone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("watchConnectionStatus")
                if let targets = client.snapshot?.targets, !targets.isEmpty {
                    ForEach(targets) { target in
                        Button { Task { await audio.startCall(to: target.id) } } label: {
                            Label {
                                Text(verbatim: target.name).lineLimit(2)
                            } icon: {
                                Image(systemName: "person.fill").foregroundStyle(RideComColors.accent)
                            }
                        }
                        .disabled(client.isWaiting || audio.isPreparing)
                        .swipeActions(edge: .trailing) { requestActions(target) }
                        .accessibilityIdentifier("watchTarget-\(target.id)")
                    }
                } else if client.snapshot != nil {
                    Text("Add people on iPhone to call them here.")
                        .font(.footnote)
                        .accessibilityIdentifier("watchNoTargets")
                }
            } footer: {
                Text("Audio uses your Watch. Keep your iPhone nearby.")
            }
            if let notification = client.snapshot?.notification {
                Section("Call Request") {
                    Text(WatchText.notification(notification.status)).font(.footnote)
                }
            }
            if client.isWaiting || audio.isPreparing {
                ProgressView("Updating…")
            }
            if let problem = audio.problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
            if let problem = client.problem { Text(WatchText.problem(problem)).font(.footnote).foregroundStyle(.secondary) }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await client.perform(.refresh) } }
                .disabled(client.isWaiting)
        }
        .containerBackground(RideComColors.accent.gradient, for: .navigation)
        .navigationTitle("RideCom")
        .accessibilityIdentifier("watchDestinationList")
    }

    // watchOS has no long-press menu; call requests sit behind a row swipe instead.
    @ViewBuilder private func requestActions(_ target: WatchCallTarget) -> some View {
        if target.canNotify {
            Button("Send Call Request", systemImage: "bell") {
                Task { await client.perform(.requestCall(target.id)) }
            }
        }
        if let notification = client.snapshot?.notification, notification.canCancel {
            Button("Cancel Call Request", systemImage: "bell.slash", role: .destructive) {
                Task { await client.perform(.cancelCallRequest(notification.requestID)) }
            }
        }
    }
}

/// End sits top-leading, farthest from the talk panel, and always asks first.
private struct WatchActiveCallView: View {
    let client: WatchControlClient
    let audio: WatchAudioController
    @State private var confirmsEnd = false

    private var state: WatchCallState { client.snapshot?.state ?? .connecting }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 6) {
                VStack(spacing: 2) {
                    if let title = client.snapshot?.title {
                        Text(verbatim: title)
                            .font(.headline)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                    }
                    status
                    if let problem = audio.problem { Text(problem).font(.caption2).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                WatchTalkPanel(client: client, audio: audio, state: state)
                    .frame(height: proxy.size.height / 2)
            }
        }
        .containerBackground(isStopped ? Color.black.gradient : RideComColors.accent.gradient, for: .navigation)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("End", systemImage: "phone.down.fill", role: .destructive) { confirmsEnd = true }
                    .tint(RideComColors.danger)
                    .disabled(client.isWaiting)
                    .accessibilityLabel("End Call")
                    .accessibilityIdentifier("watchEndCallButton")
            }
        }
        .confirmationDialog("End this call?", isPresented: $confirmsEnd) {
            Button("End Call", role: .destructive) {
                audio.stop()
                Task { await client.perform(.end) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .accessibilityIdentifier("watchActiveCall")
    }

    private var isStopped: Bool { state == .audioPaused || state == .audioUnavailable }

    private var status: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                switch state {
                case .connecting, .idle, .signedOut:
                    ProgressView().tint(RideComColors.warning).frame(width: 16, height: 16)
                    Text("Connecting")
                case .inCall:
                    Image(systemName: "waveform").foregroundStyle(RideComColors.success)
                    Text("In a call")
                case .audioPaused:
                    Image(systemName: "headphones").foregroundStyle(RideComColors.warning)
                    Text("Audio paused")
                case .audioUnavailable:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(RideComColors.danger)
                    Text("Audio unavailable")
                }
            }
            .font(.footnote)
            // The reason sits on its own line rather than after a dash.
            if isStopped {
                Text("Check your iPhone").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watchCallStatus")
    }
}

/// Talk only while pressed. Releasing, cancelling or leaving the active scene closes it.
private struct WatchTalkPanel: View {
    let client: WatchControlClient
    let audio: WatchAudioController
    let state: WatchCallState
    @GestureState private var isHolding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPreparing: Bool { audio.isPreparing || client.isWaiting || !audio.isReady }
    private var isStopped: Bool { state == .audioPaused || state == .audioUnavailable }

    var body: some View {
        Button { } label: { panel }
            .buttonStyle(.plain)
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($isHolding) { _, held, _ in held = true })
            .onChange(of: isHolding) { _, held in audio.setPressed(held) }
            .sensoryFeedback(trigger: audio.isTalking) { _, talking in
                let feedback: SensoryFeedback = talking ? .start : .stop
                return feedback
            }
            .disabled(isPreparing || isStopped)
            .accessibilityLabel("Hold to Talk")
            .accessibilityValue(audio.isTalking ? Text("Talking") : Text("Not talking"))
            .accessibilityIdentifier("watchHoldToTalk")
    }

    private var fill: Color { audio.isTalking ? RideComColors.voiceLevel : RideComColors.accent.opacity(0.35) }

    private var panel: some View {
        caption
            .font(.headline)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(audio.isTalking ? Color.black : Color.white)
            .background(fill, in: ConcentricRectangle())
            .overlay(ConcentricRectangle().stroke(Color.white.opacity(audio.isTalking ? 0 : 0.5), lineWidth: 1))
            .contentShape(ConcentricRectangle())
    }

    @ViewBuilder private var caption: some View {
        VStack(spacing: 4) {
            if isStopped {
                Image(systemName: "pause.circle.fill")
                Text("Audio paused")
            } else if isPreparing {
                ProgressView()
                Text("Preparing")
            } else if audio.isTalking {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                Text("Talking")
            } else {
                Image(systemName: "mic")
                Text("Hold to Talk")
            }
        }
    }
}

private struct WatchMessageView<Action: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    @ViewBuilder let action: () -> Action

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.headline).multilineTextAlignment(.center)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                action()
            }
            .frame(maxWidth: .infinity)
        }
        .containerBackground(Color.black.gradient, for: .navigation)
        .navigationTitle("RideCom")
        .accessibilityIdentifier("watchMessage")
    }
}

private enum WatchText {
    static func notification(_ status: CallNotificationStatus) -> LocalizedStringKey {
        switch status {
        case .accepted: "Notification accepted. Delivery is not confirmed."
        case .processing: "The call request is being processed."
        case .noDestinations: "This person has no notification destination available."
        case .retryLater: "The call request could not be sent. Please try again later."
        case .rejected: "The call request was not accepted."
        case .cancelled: "Call request cancelled."
        }
    }
    static func problem(_ problem: WatchControlProblem) -> LocalizedStringKey {
        switch problem {
        case .unavailable: "Could not reach iPhone. Try again."
        case .stale: "The call changed. Check the current call and try again."
        case .noAccount: "Open RideCom on iPhone and sign in."
        case .missingDestination: "This saved call destination is no longer available."
        case .denied: "Open RideCom on iPhone to continue."
        }
    }
}
