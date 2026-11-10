import SwiftUI

/// Opens one invitation: naming and sending a new one, or each mode's own detail.
/// The modes share only the data and operations; each detail lives in its mode's folder.
struct ContactInvitationSheet: View {
    let viewModel: IntercomViewModel
    let invitationID: UUID
    /// Opened right after "+": name the person, then send. Otherwise the invitation's detail.
    @State private var isCreating: Bool

    init(viewModel: IntercomViewModel, invitationID: UUID) {
        self.viewModel = viewModel
        self.invitationID = invitationID
        let record = viewModel.contactInvitationRecord(invitationID)
        // Closing the creation sheet always saves a name, so an unnamed record has not been sent yet.
        _isCreating = State(initialValue: record.map { $0.direction == .outgoing && $0.state == .pending && $0.nickname == nil } ?? false)
    }

    private var isAdvanced: Bool { viewModel.interfaceMode == .advanced }

    var body: some View {
        NavigationStack {
            Group {
                if let record = viewModel.contactInvitationRecord(invitationID) {
                    if isCreating {
                        ContactInvitationCreation(viewModel: viewModel, invitationID: invitationID)
                    } else if isAdvanced {
                        AdvancedContactInvitationDetail(viewModel: viewModel, record: record)
                    } else {
                        StandardContactInvitationDetail(viewModel: viewModel, record: record)
                    }
                } else {
                    Form { Text("This invitation is no longer available.") }.formStyle(.grouped)
                }
            }
            .screenBackground(AppColorPalette.listScreenBackground)
            // Standard's detail has no title: the name is its heading. A verbatim empty title adds no catalog key.
            .navigationTitle(isCreating ? Text("Invite Someone New") : isAdvanced ? Text("Contact Invitation") : Text(verbatim: ""))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isCreating ? "Cancel" : "Close") {
                        viewModel.dismissContactInvitationPresentation(expectedPresentationID: "share-" + invitationID.uuidString)
                    }
                    .accessibilityIdentifier("closeContactInvitationButton")
                }
            }
            .accessibilityIdentifier("contactInvitationSheet")
        }
        // While naming and sending, only Cancel closes the sheet. With the keyboard up, a swipe meant
        // to close the share sheet otherwise lands on this sheet and closes both.
        .interactiveDismissDisabled(isCreating)
        .onDisappear {
            if viewModel.contactInvitationID == invitationID { viewModel.stopContactInvitationSession() }
        }
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 460, minHeight: 320)
        #endif
    }
}

/// Naming the person first, then sending. Used by both modes until Advanced has its own design.
private struct ContactInvitationCreation: View {
    let viewModel: IntercomViewModel
    let invitationID: UUID
    @State private var name = ""
    /// Chosen once per opening so the placeholder does not change while the sheet is open.
    @State private var candidate = ""
    @FocusState private var nameFocused: Bool

    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? candidate : typed
    }

    var body: some View {
        Form {
            Section {
                TextField("Their Name", text: $name, prompt: Text(verbatim: candidate))
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { save(refresh: true) }
                    // Leaving the field (for example, to send) saves the name.
                    // Without republishing, so the share sheet it may be opening is not redrawn.
                    .onChange(of: nameFocused) { _, focused in if !focused { save(refresh: false) } }
                    .accessibilityIdentifier("contactInvitationNameField")
            } header: {
                Text("Their Name")
            } footer: {
                Text("Only you see this name. If you leave it empty, it will be \(candidate). They see the name they chose for themselves.")
            }
            Section {
                ContactInvitationShareLink(viewModel: viewModel, invitationID: invitationID,
                                           title: "Send Invitation", personName: effectiveName)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard candidate.isEmpty else { return }
            let used = Set(viewModel.savedRemoteUsers.map(\.resolvedDisplayName))
                .union(viewModel.pendingContactInvitations.compactMap(\.nickname))
            candidate = ProvisionalName.candidate(avoiding: used)
            nameFocused = true
        }
        .onDisappear { save(refresh: true) }
    }

    private func save(refresh: Bool) {
        guard !candidate.isEmpty else { return }
        viewModel.setContactInvitationNickname(invitationID, effectiveName, refresh: refresh)
    }
}

/// Shares the stored invitation; the message names who it is for.
struct ContactInvitationShareLink: View {
    let viewModel: IntercomViewModel
    let invitationID: UUID
    let title: LocalizedStringKey
    let personName: String

    var body: some View {
        ShareLink(item: InvitationShare(viewModel: viewModel, contactInvitationID: invitationID),
            subject: Text("RideCom Invite"), message: Text("RideCom invitation for \(personName)"),
            preview: SharePreview(Text("RideCom Invite"))) {
                Label(title, systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("shareContactInvitationButton")
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
            .screenBackground(AppColorPalette.listScreenBackground)
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
