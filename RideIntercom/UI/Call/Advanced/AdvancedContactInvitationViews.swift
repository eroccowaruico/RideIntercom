import SwiftUI

/// `ContactInvitationRecord` as stored, one record per row, at the end of Users.
struct AdvancedInvitationsSection: View {
    let viewModel: IntercomViewModel

    var body: some View {
        let records = viewModel.pendingContactInvitations
        if !records.isEmpty {
            Section {
                ForEach(records) { record in
                    Button { viewModel.showContactInvitation(record.id) } label: { AdvancedInvitationRow(record: record) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("pendingContactInvitation-\(record.id)")
                }
            } header: {
                Text(verbatim: "Invitations \(records.count)")
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

private struct AdvancedInvitationRow: View {
    let record: ContactInvitationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: String(record.id.uuidString.prefix(8)).lowercased())
                .font(.headline.monospaced()).foregroundStyle(Color.primary)
            Text(verbatim: "\(record.direction.rawValue) · \(record.state.rawValue)\(record.canResume ? " · canResume" : "")")
                .font(.subheadline.monospaced()).foregroundStyle(Color.primary)
            Text(verbatim: "expiresAt \(Date(timeIntervalSince1970: record.expiresAt).formatted(.iso8601))")
                .font(.caption.monospaced()).foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// The stored record, the notification session and the implementation's operations under its conditions.
struct AdvancedContactInvitationDetail: View {
    let viewModel: IntercomViewModel
    let record: ContactInvitationRecord
    @State private var confirmsCancellation = false

    private var stopsRetrying: Bool { record.state == .confirmed }

    var body: some View {
        Form {
            Section {
                field("id", record.id.uuidString.lowercased())
                field("direction", record.direction.rawValue)
                field("state", record.state.rawValue)
                field("canResume", String(record.canResume))
                field("expiresAt", Date(timeIntervalSince1970: record.expiresAt).formatted(.iso8601))
                field("peerMemberID", record.peerMemberID ?? "nil")
                field("nickname", record.nickname ?? "nil")
                field("session", viewModel.contactInvitationID == record.id ? "running" : "stopped")
            } header: {
                Text(verbatim: "ContactInvitationRecord")
            }
            Section {
                Text(LocalizedStringKey(viewModel.contactInvitationStatus(for: record)))
                    .accessibilityIdentifier("contactInvitationStatus")
                if let message = viewModel.contactInvitationMessage { Text(LocalizedStringKey(message)) }
            }
            Section {
                if record.direction == .outgoing && record.state == .pending {
                    ShareLink(item: InvitationShare(viewModel: viewModel, contactInvitationID: record.id),
                              subject: Text("RideCom Invite"), preview: SharePreview(Text("RideCom Invite"))) {
                        Label("Share Again", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("shareContactInvitationButton")
                }
                if record.canResume {
                    Button("Retry Notification", systemImage: "arrow.clockwise") {
                        viewModel.retryPresentedContactInvitation(record.id)
                    }.accessibilityIdentifier("retryContactInvitationButton")
                    Button(stopsRetrying ? "Stop Retrying Notification" : "Cancel Pending Invitation", role: .destructive) {
                        confirmsCancellation = true
                    }
                    .accessibilityIdentifier("cancelPendingContactInvitationButton")
                }
            }
        }
        .formStyle(.grouped)
        .alert(stopsRetrying ? "Stop Retrying Notification?" : "Cancel This Pending Invitation?", isPresented: $confirmsCancellation) {
            Button(stopsRetrying ? "Stop Retrying Notification" : "Cancel Pending Invitation", role: .destructive) {
                _ = viewModel.cancelPresentedContactInvitation(record.id)
            }
            .accessibilityIdentifier("confirmCancelContactInvitationButton")
            Button("Keep Pending Invitation", role: .cancel) {}
        } message: {
            Text("Stops retries on this device. A link already shared may still be accepted until it expires.")
        }
    }

    private func field(_ name: String, _ value: String) -> some View {
        LabeledContent {
            Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled)
        } label: {
            Text(verbatim: name).font(.subheadline.monospaced())
        }
    }
}
