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
    /// Opened right after "+": name the person, then send. Otherwise the invitation's detail.
    @State private var isCreating: Bool
    @State private var confirmsCancellation = false
    @State private var name = ""
    /// Chosen once per opening so the placeholder does not change while the sheet is open.
    @State private var candidate = ""
    @FocusState private var nameFocused: Bool

    init(viewModel: IntercomViewModel, invitationID: UUID) {
        self.viewModel = viewModel
        self.invitationID = invitationID
        let record = viewModel.contactInvitationRecord(invitationID)
        // Closing the creation sheet always saves a name, so an unnamed record has not been sent yet.
        _isCreating = State(initialValue: record.map { $0.direction == .outgoing && $0.state == .pending && $0.nickname == nil } ?? false)
    }

    private var isAdvanced: Bool { viewModel.interfaceMode == .advanced }
    private var isAwaitingAcceptance: Bool { record.map { $0.direction == .outgoing && $0.state == .pending } ?? false }
    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? candidate : typed
    }

    private func saveName() { saveName(refresh: true) }

    private func saveName(refresh: Bool) {
        guard isAwaitingAcceptance, !candidate.isEmpty, !(isAdvanced && !isCreating) else { return }
        viewModel.setContactInvitationNickname(invitationID, effectiveName, refresh: refresh)
    }

    private var record: ContactInvitationRecord? {
        viewModel.contactInvitationRecord(invitationID)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let record {
                    if isCreating {
                        creation
                    } else if isAdvanced {
                        AdvancedContactInvitationDetail(viewModel: viewModel, record: record,
                                                        confirmsCancellation: $confirmsCancellation)
                    } else {
                        standardDetail(record)
                    }
                } else {
                    Text("This invitation is no longer available.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isCreating ? "Invite Someone New" : isAdvanced ? "Contact Invitation" : "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isCreating ? "Cancel" : "Close") {
                        saveName()
                        viewModel.dismissContactInvitationPresentation(expectedPresentationID: "share-" + invitationID.uuidString)
                    }
                        .accessibilityIdentifier("closeContactInvitationButton")
                }
            }
            .accessibilityIdentifier("contactInvitationSheet")
            .alert(cancellationTitle, isPresented: $confirmsCancellation) {
                Button(cancellationButton, role: .destructive) { confirmCancellation() }
                    .accessibilityIdentifier("confirmCancelContactInvitationButton")
                if isAdvanced {
                    Button("Keep Pending Invitation", role: .cancel) {}
                } else if record?.direction == .outgoing {
                    Button("Keep Invitation", role: .cancel) {}
                } else {
                    Button("Cancel", role: .cancel) {}
                }
            } message: {
                if isAdvanced {
                    Text("Stops retries on this device. A link already shared may still be accepted until it expires.")
                } else if record?.direction == .outgoing {
                    Text("An invitation already sent may still be accepted until it expires.")
                }
            }
        }
        .onAppear {
            guard candidate.isEmpty else { return }
            let used = Set(viewModel.savedRemoteUsers.map(\.resolvedDisplayName))
                .union(viewModel.pendingContactInvitations.compactMap(\.nickname))
            if let saved = record?.nickname { name = saved }
            candidate = isCreating
                ? ProvisionalName.candidate(avoiding: used.subtracting([record?.nickname].compactMap { $0 }))
                : record?.nickname ?? ""
            if isCreating { nameFocused = true }
            // Standard keeps listening for, or delivering, the reply while the detail is open.
            if !isCreating && !isAdvanced { viewModel.retryPresentedContactInvitation(invitationID) }
        }
        .onDisappear {
            saveName()
            if viewModel.contactInvitationID == invitationID { viewModel.stopContactInvitationSession() }
        }
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 460, minHeight: 320)
        #endif
    }

    // MARK: Creation

    /// Name first: who the invitation is for, in the inviter's own words.
    @ViewBuilder private var creation: some View {
        Section {
            nameField
        } header: {
            Text("Their Name")
        } footer: {
            Text("Only you see this name. If you leave it empty, it will be \(candidate). They see the name they chose for themselves.")
        }
        Section {
            shareLink("Send Invitation")
        }
    }

    private var nameField: some View {
        TextField("Their Name", text: $name, prompt: Text(verbatim: candidate))
            .focused($nameFocused)
            .submitLabel(.done)
            .onSubmit(saveName)
            // Leaving the field (for example, to send) saves the name.
            // Without republishing, so the share sheet it may be opening is not redrawn.
            .onChange(of: nameFocused) { _, focused in if !focused { saveName(refresh: false) } }
            .accessibilityIdentifier("contactInvitationNameField")
    }

    private func shareLink(_ title: LocalizedStringKey) -> some View {
        ShareLink(item: InvitationShare(viewModel: viewModel, contactInvitationID: invitationID),
            subject: Text("RideCom Invite"), message: Text("RideCom invitation for \(effectiveName)"),
            preview: SharePreview(Text("RideCom Invite"))) {
                Label(title, systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("shareContactInvitationButton")
    }

    // MARK: Standard detail

    /// One state word, one sentence and at most one main action; what it sends is said below it.
    @ViewBuilder private func standardDetail(_ record: ContactInvitationRecord) -> some View {
        let person = viewModel.contactInvitationName(for: record)
        let outgoing = record.direction == .outgoing
        let inCall = viewModel.activeGroupID != nil || viewModel.hasAnyActiveGroupConnection
        let delivering = viewModel.contactInvitationID == record.id
        Section {
            VStack(spacing: AppSpacing.s) {
                PendingAvatar(diameter: 56)
                Text(outgoing ? "You sent this invitation" : "Invitation from \(person)")
                    .font(.subheadline).foregroundStyle(Color.secondary)
                Text(verbatim: person).font(.title2.bold()).multilineTextAlignment(.center)
                if isAwaitingAcceptance {
                    stateWord("Waiting to be accepted", busy: false)
                    sentence("\(person) joins your Users after opening and accepting this invitation.")
                    shareLink("Send Again").appProminentButtonStyle()
                    footnote("Sends the same invitation to \(person) again.")
                } else if delivering || inCall {
                    stateWord("Sending a reply", busy: true)
                    if inCall {
                        sentence("Waiting for the current call to end.")
                    } else if outgoing {
                        sentence("\(person) accepted the invitation. Once the reply arrives, you can call each other.")
                    } else {
                        sentence("You accepted \(person)'s invitation. Once the reply arrives, you can call each other.")
                    }
                } else {
                    stateWord("Reply not delivered", busy: false)
                    sentence("\(person) hasn't received your reply yet.")
                    Button("Send Again", systemImage: "arrow.clockwise") {
                        viewModel.retryPresentedContactInvitation(invitationID)
                    }
                    .appProminentButtonStyle()
                    .accessibilityIdentifier("retryContactInvitationButton")
                    footnote(outgoing ? "Sends your reply to \(person) again."
                                      : "Tells \(person) again that you accepted the invitation.")
                }
                if let message = viewModel.contactInvitationMessage { sentence(LocalizedStringKey(message)) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.s)
        }
        if isAwaitingAcceptance {
            Section("Name on this device") {
                TextField("Name on this device", text: $name, prompt: Text(verbatim: candidate))
                    .submitLabel(.done)
                    .onSubmit(saveName)
                    .accessibilityIdentifier("contactInvitationNameField")
            }
        }
        Section {
            Button(outgoing ? "Cancel Invitation" : "Delete This Person", role: .destructive) { confirmsCancellation = true }
                .accessibilityIdentifier("cancelPendingContactInvitationButton")
        }
    }

    private func stateWord(_ word: LocalizedStringKey, busy: Bool) -> some View {
        HStack(spacing: AppSpacing.xs) {
            if busy { ProgressView().controlSize(.small) }
            Text(word).font(.headline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("contactInvitationState")
    }

    private func sentence(_ text: LocalizedStringKey) -> some View {
        Text(text).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            .accessibilityIdentifier("contactInvitationStatus")
    }

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.footnote).foregroundStyle(Color.secondary).multilineTextAlignment(.center)
    }

    // MARK: Cancellation

    private var cancellationTitle: LocalizedStringKey {
        if isAdvanced { return record?.state == .confirmed ? "Stop Retrying Notification?" : "Cancel This Pending Invitation?" }
        guard let record else { return "Cancel This Invitation?" }
        return record.direction == .outgoing
            ? "Cancel This Invitation?" : "Delete \(viewModel.contactInvitationName(for: record))?"
    }

    private var cancellationButton: LocalizedStringKey {
        if isAdvanced { return record?.state == .confirmed ? "Stop Retrying Notification" : "Cancel Pending Invitation" }
        return record?.direction == .incoming ? "Delete" : "Cancel Invitation"
    }

    /// Standard removes the person behind a received invitation; Advanced only cancels the record.
    private func confirmCancellation() {
        let peer = record?.direction == .incoming ? record?.peerMemberID : nil
        let user = peer.flatMap { peer in viewModel.savedRemoteUsers.first { $0.memberIDs.contains(peer) } }
        guard viewModel.cancelPresentedContactInvitation(invitationID), !isAdvanced, let user else { return }
        _ = viewModel.removeSavedUser(user.id)
    }
}

/// Advanced shows the `ContactInvitationRecord` as stored and the implementation's operations.
private struct AdvancedContactInvitationDetail: View {
    let viewModel: IntercomViewModel
    let record: ContactInvitationRecord
    @Binding var confirmsCancellation: Bool

    var body: some View {
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
                Button(LocalizedStringKey(record.state == .confirmed ? "Stop Retrying Notification" : "Cancel Pending Invitation"),
                       role: .destructive) { confirmsCancellation = true }
                    .accessibilityIdentifier("cancelPendingContactInvitationButton")
            }
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
