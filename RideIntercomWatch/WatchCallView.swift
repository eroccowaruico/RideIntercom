import SwiftUI

struct WatchCallView: View {
    let client: WatchControlClient
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
                            Button(state.isMuted ? LocalizedStringKey("Unmute iPhone microphone") : LocalizedStringKey("Mute iPhone microphone")) {
                                Task { await client.perform(.setMuted(!state.isMuted)) }
                            }.disabled(client.isWaiting)
                            if state.hasCall {
                                Button("End Call", role: .destructive) { Task { await client.perform(.end) } }
                                    .disabled(client.isWaiting)
                            }
                        }
                    }
                    if client.isWaiting { ProgressView("Updating…") }
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
                    Section("Call on iPhone") {
                        ForEach(state.targets) { target in
                            VStack(alignment: .leading) {
                                Button { Task { await client.perform(.start(target.id)) } } label: { Text(target.name) }
                                    .buttonStyle(.bordered)
                                if target.canNotify {
                                    Button("Send Call Request") { Task { await client.perform(.requestCall(target.id)) } }
                                        .buttonStyle(.bordered)
                                }
                            }.disabled(client.isWaiting)
                        }
                    }
                }
                Section { Text("Audio plays on iPhone or its headphones.").font(.footnote) }
            }
            .navigationTitle("RideIntercom")
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
        case .signedOut: "Open RideIntercom on iPhone and sign in."
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
        case .noAccount: "Open RideIntercom on iPhone and sign in."
        case .missingDestination: "This saved call destination is no longer available."
        case .denied: "Open RideIntercom on iPhone to continue."
        }
    }
}
