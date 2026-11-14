import SwiftUI

/// Not-yet-joined people in Users: a dashed avatar, the name, one state word. Tapping opens the detail.
struct StandardPendingInvitationsSection: View {
    let viewModel: IntercomViewModel

    var body: some View {
        if !viewModel.pendingContactInvitations.isEmpty {
            Section("Invitations") {
                ForEach(viewModel.pendingContactInvitations) { record in
                    Button { viewModel.showContactInvitation(record.id) } label: {
                        StandardInvitationRow(name: viewModel.contactInvitationName(for: record),
                                              state: viewModel.contactInvitationStateWord(for: record),
                                              isSending: viewModel.contactInvitationIsSending(record))
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

/// One state word, one sentence and at most one main action; what it sends is said below it.
/// The name stays editable, and cancelling or deleting comes last with a confirmation.
struct StandardContactInvitationDetail: View {
    let viewModel: IntercomViewModel
    let record: ContactInvitationRecord
    @State private var name: String
    @State private var confirmsCancellation = false

    init(viewModel: IntercomViewModel, record: ContactInvitationRecord) {
        self.viewModel = viewModel
        self.record = record
        _name = State(initialValue: record.nickname ?? "")
    }

    private var person: String { viewModel.contactInvitationName(for: record) }
    private var outgoing: Bool { record.direction == .outgoing }
    private var isExpired: Bool { viewModel.contactInvitationIsExpired(record) }
    private var isAwaitingAcceptance: Bool { outgoing && record.state == .pending && !isExpired }

    var body: some View {
        Form {
            Section {
                VStack(spacing: AppSpacing.s) {
                    PendingAvatar(diameter: 56)
                    Text(outgoing ? "You sent this invitation" : "Invitation from \(person)")
                        .font(.subheadline).foregroundStyle(Color.secondary)
                    Text(verbatim: person).font(.title2.bold()).multilineTextAlignment(.center)
                    stateAndAction
                    if let message = viewModel.contactInvitationMessage { sentence(LocalizedStringKey(message)) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.s)
            }
            if isAwaitingAcceptance {
                Section("Name on this device") {
                    TextField("Name on this device", text: $name, prompt: Text(verbatim: record.nickname ?? ""))
                        .submitLabel(.done)
                        .onSubmit(saveName)
                        .accessibilityIdentifier("contactInvitationNameField")
                }
            }
            // A received invitation shows the name the inviter chose for themselves, read only.
            if let ownName = viewModel.contactInvitationOwnName(for: record) {
                Section("Their Own Name") {
                    Text(verbatim: ownName).foregroundStyle(Color.secondary)
                        .accessibilityIdentifier("contactInvitationOwnName")
                }
            }
            Section {
                Button(outgoing ? "Cancel Invitation" : "Delete This Person", role: .destructive) { confirmsCancellation = true }
                    .accessibilityIdentifier("cancelPendingContactInvitationButton")
            }
        }
        .formStyle(.grouped)
        .alert(outgoing ? "Cancel This Invitation?" : "Delete \(person)?", isPresented: $confirmsCancellation) {
            Button(outgoing ? "Cancel Invitation" : "Delete", role: .destructive, action: cancel)
                .accessibilityIdentifier("confirmCancelContactInvitationButton")
            Button(outgoing ? "Keep Invitation" : "Cancel", role: .cancel) {}
        } message: {
            if outgoing { Text("An invitation already sent may still be accepted until it expires.") }
        }
        // Keeps listening for, or delivering, the reply while the detail is open.
        .onAppear { if !isExpired { viewModel.retryPresentedContactInvitation(record.id) } }
        .onDisappear(perform: saveName)
    }

    @ViewBuilder private var stateAndAction: some View {
        let inCall = viewModel.activeGroupID != nil || viewModel.hasAnyActiveGroupConnection
        if isExpired {
            stateWord("Expired", busy: false)
            sentence("This invitation can no longer be used.")
            Button("Send a New Invitation", systemImage: "square.and.arrow.up") {
                viewModel.sendNewContactInvitation(replacing: record.id)
            }
            .appProminentButtonStyle()
            .accessibilityIdentifier("sendNewContactInvitationButton")
        } else if viewModel.contactInvitationIsUnsent(record) {
            stateWord("Not sent yet", busy: false)
            sentence("This invitation has not been sent to anyone yet.")
            ContactInvitationShareLink(viewModel: viewModel, invitationID: record.id, title: "Send Invitation", personName: person)
                .appProminentButtonStyle()
        } else if isAwaitingAcceptance {
            stateWord("Waiting to be accepted", busy: false)
            sentence("\(person) joins your Users after opening and accepting this invitation.")
            ContactInvitationShareLink(viewModel: viewModel, invitationID: record.id, title: "Send Again", personName: person)
                .appProminentButtonStyle()
            footnote("Sends the same invitation to \(person) again.")
        } else if viewModel.contactInvitationID == record.id || inCall {
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
            Button("Send Again", systemImage: "arrow.clockwise") { viewModel.retryPresentedContactInvitation(record.id) }
                .appProminentButtonStyle()
                .accessibilityIdentifier("retryContactInvitationButton")
            footnote(outgoing ? "Sends your reply to \(person) again."
                              : "Tells \(person) again that you accepted the invitation.")
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

    /// An empty field returns to the name already saved.
    private func saveName() {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAwaitingAcceptance, !typed.isEmpty, typed != record.nickname else { return }
        viewModel.setContactInvitationNickname(record.id, typed)
    }

    /// A sent invitation is cancelled; for a received one, the person it saved is deleted too.
    private func cancel() {
        let user = record.peerMemberID.flatMap { peer in
            outgoing ? nil : viewModel.savedRemoteUsers.first { $0.memberIDs.contains(peer) }
        }
        guard viewModel.cancelPresentedContactInvitation(record.id), let user else { return }
        _ = viewModel.removeSavedUser(user.id)
    }
}
