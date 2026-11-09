import SwiftUI

/// Both Users layouts project the same durable invitation records and operations.
struct PendingContactInvitationsSection: View {
    let viewModel: IntercomViewModel

    var body: some View {
        if !viewModel.pendingContactInvitations.isEmpty {
            Section("Invitations") {
                ForEach(viewModel.pendingContactInvitations) { record in
                    Button { viewModel.showContactInvitation(record.id) } label: {
                        if viewModel.interfaceMode == .advanced {
                            AdvancedInvitationRow(record: record)
                        } else {
                            StandardInvitationRow(name: viewModel.contactInvitationName(for: record),
                                                  state: viewModel.contactInvitationStateWord(for: record),
                                                  isSending: viewModel.contactInvitationIsSending(record))
                        }
                    }
                    .buttonStyle(.borderless)
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

/// Not-yet-joined people never look like saved users: a dashed avatar, the name, one state word.
/// Sending states show progress instead of a chevron; resending lives in the invitation's detail.
private struct StandardInvitationRow: View {
    let name: String
    let state: String
    let isSending: Bool

    var body: some View {
        HStack(spacing: AppSpacing.m) {
            PendingAvatar()
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).foregroundStyle(Color.primary).lineLimit(2)
                Text(LocalizedStringKey(state)).font(.subheadline).foregroundStyle(Color.secondary)
                    .accessibilityIdentifier("pendingContactInvitationState")
            }
            Spacer(minLength: 0)
            if isSending {
                ProgressView()
            } else {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Advanced shows the `ContactInvitationRecord` as stored.
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

struct ContactInvitationSheet: View {
    let viewModel: IntercomViewModel
    let invitationID: UUID
    @State private var confirmsCancellation = false
    @State private var name = ""
    /// Chosen once per opening so the placeholder does not change while the sheet is open.
    @State private var candidate = ""
    @FocusState private var nameFocused: Bool

    private var isUnsent: Bool { record.map { $0.direction == .outgoing && $0.state == .pending } ?? false }
    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? candidate : typed
    }

    private func saveName() { saveName(refresh: true) }

    private func saveName(refresh: Bool) {
        guard isUnsent, !candidate.isEmpty else { return }
        viewModel.setContactInvitationNickname(invitationID, effectiveName, refresh: refresh)
    }

    private var record: ContactInvitationRecord? {
        viewModel.contactInvitationRecord(invitationID)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let record {
                    if isUnsent {
                        // Name first: who the invitation is for, in the inviter's own words.
                        Section {
                            TextField("Their Name", text: $name, prompt: Text(verbatim: candidate))
                                .focused($nameFocused)
                                .submitLabel(.done)
                                .onSubmit(saveName)
                                // Leaving the field (for example, to send) saves the name.
                                // Without republishing, so the share sheet it may be opening is not redrawn.
                                .onChange(of: nameFocused) { _, focused in if !focused { saveName(refresh: false) } }
                                .accessibilityIdentifier("contactInvitationNameField")
                        } header: {
                            Text("Their Name")
                        } footer: {
                            Text("Only you see this name. If you leave it empty, it will be \(candidate). They see the name they chose for themselves.")
                        }
                        Section {
                            ShareLink(item: InvitationShare(viewModel: viewModel, contactInvitationID: invitationID),
                                subject: Text("RideCom Invite"), message: Text("RideCom invitation for \(effectiveName)"),
                                preview: SharePreview(Text("RideCom Invite"))) {
                                    Label("Send Invitation", systemImage: "square.and.arrow.up")
                                }
                                .accessibilityIdentifier("shareContactInvitationButton")
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
            .navigationTitle(isUnsent ? "Invite Someone New" : "Contact Invitation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isUnsent ? "Cancel" : "Close") {
                        saveName()
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
        .onAppear {
            guard candidate.isEmpty else { return }
            let used = Set(viewModel.savedRemoteUsers.map(\.resolvedDisplayName))
                .union(viewModel.pendingContactInvitations.compactMap(\.nickname))
            if let saved = record?.nickname { name = saved }
            candidate = ProvisionalName.candidate(avoiding: used.subtracting([record?.nickname].compactMap { $0 }))
            if isUnsent && record?.nickname == nil { nameFocused = true }
        }
        .onDisappear {
            saveName()
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
