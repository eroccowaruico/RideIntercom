import SwiftUI

/// Both Users layouts project the same durable invitation records and operations.
struct PendingContactInvitationsSection: View {
    let viewModel: IntercomViewModel

    var body: some View {
        if !viewModel.pendingContactInvitations.isEmpty {
            Section("Invitations") {
                ForEach(viewModel.pendingContactInvitations) { record in
                    Button { viewModel.showContactInvitation(record.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(LocalizedStringKey(record.direction == .incoming ? "Acceptance Notification" : "Invitation"),
                                  systemImage: "envelope")
                            Text(LocalizedStringKey(viewModel.contactInvitationStatus(for: record)))
                                .font(.subheadline).foregroundStyle(Color.secondary)
                        }
                    }
                    .accessibilityIdentifier("pendingContactInvitation-\(record.id)")
                }
            }
        }
        if let message = viewModel.contactInvitationMessage {
            Section {
                Text(LocalizedStringKey(message))
                    .accessibilityIdentifier("contactInvitationMessage")
            }
        }
    }
}

struct ContactInvitationSheet: View {
    let viewModel: IntercomViewModel
    let invitationID: UUID
    @State private var confirmsCancellation = false

    private var record: ContactInvitationRecord? {
        viewModel.contactInvitationRecord(invitationID)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let record {
                    if record.direction == .outgoing && record.state == .pending {
                        Section {
                            ShareLink(item: InvitationShare(viewModel: viewModel, contactInvitationID: invitationID),
                                subject: Text("RideCom Invite"), message: Text("Add me on RideCom."),
                                preview: SharePreview(Text("RideCom Invite"))) {
                                    Label("Share Invitation", systemImage: "square.and.arrow.up")
                                }
                                .accessibilityIdentifier("shareContactInvitationButton")
                        } footer: {
                            Text("Sharing does not register a person. Their acceptance will identify them.")
                        }
                    }
                    Section {
                        Text(LocalizedStringKey(viewModel.contactInvitationStatus(for: record)))
                            .accessibilityIdentifier("contactInvitationStatus")
                        Text("Expires \(Date(timeIntervalSince1970: record.expiresAt), style: .date)")
                        if let message = viewModel.contactInvitationMessage { Text(LocalizedStringKey(message)) }
                    }
                    if record.canResume {
                        Section {
                            Button("Retry Notification", systemImage: "arrow.clockwise") {
                                viewModel.retryPresentedContactInvitation(invitationID)
                            }.accessibilityIdentifier("retryContactInvitationButton")
                            Button(LocalizedStringKey(record.state == .confirmed ? "Stop Retrying Notification" : "Cancel Pending Invitation"), role: .destructive) { confirmsCancellation = true }
                                .accessibilityIdentifier("cancelPendingContactInvitationButton")
                        }
                    }
                } else {
                    Text("This invitation is no longer available.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Contact Invitation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        viewModel.dismissContactInvitationPresentation(expectedPresentationID: "share-" + invitationID.uuidString)
                    }
                        .accessibilityIdentifier("closeContactInvitationButton")
                }
            }
            .accessibilityIdentifier("contactInvitationSheet")
            .alert(LocalizedStringKey(record?.state == .confirmed ? "Stop Retrying Notification?" : "Cancel This Pending Invitation?"), isPresented: $confirmsCancellation) {
                Button(LocalizedStringKey(record?.state == .confirmed ? "Stop Retrying Notification" : "Cancel Pending Invitation"), role: .destructive) {
                    _ = viewModel.cancelPresentedContactInvitation(invitationID)
                }.accessibilityIdentifier("confirmCancelContactInvitationButton")
                Button("Keep Pending Invitation", role: .cancel) {}
            } message: {
                Text("Stops retries on this device. A link already shared may still be accepted until it expires.")
            }
        }
        .onDisappear {
            if viewModel.contactInvitationID == invitationID { viewModel.stopContactInvitationSession() }
        }
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 460, minHeight: 320)
        #endif
    }
}

struct ContactInvitationAcceptanceView: View {
    let viewModel: IntercomViewModel
    let preview: ContactInvitationPreview
    let onAccepted: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(preview.inviterName).font(.title2)
                    Text("Accepting saves this person to Users. Your current call stays connected.")
                    if let message = viewModel.contactInvitationMessage { Text(LocalizedStringKey(message)) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Contact Invitation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.dismissContactInvitationPresentation(expectedPresentationID: "accept-" + preview.id.uuidString)
                    }
                        .accessibilityIdentifier("cancelContactInvitationButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept Invitation") {
                        if viewModel.acceptPresentedContactInvitation(expectedInvitationID: preview.id) { onAccepted() }
                    }.accessibilityIdentifier("acceptContactInvitationButton")
                }
            }
            .accessibilityIdentifier("contactInvitationPreview")
        }
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 460, minHeight: 280)
        #endif
    }
}
