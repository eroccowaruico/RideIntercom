import Foundation

extension IntercomViewModel {
    func beginContactInvitationPresentation() {
        contactInvitationMessage = nil
        guard let url = makeContactInviteURL(),
              let token = try? GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true),
              let id = token.directInvitation?.context.id else {
            contactInvitationMessage = "Could not save this invitation. Try again."
            return
        }
        contactInvitationPresentation = .sharing(id)
    }

    func showContactInvitation(_ id: UUID) {
        guard canEditSavedGroups, pendingContactInvitations.contains(where: { $0.id == id }) else { return }
        contactInvitationMessage = nil
        contactInvitationPresentation = .sharing(id)
    }

    /// Preview verifies the author without creating a local signing key, user,
    /// pending record or transport. Consent is a separate explicit operation.
    @discardableResult
    func previewContactInvitation(_ url: URL) -> Bool {
        guard canEditSavedGroups else { return false }
        do {
            let token = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
            let now = callAccessNow()
            guard !token.isExpired(now: now.timeIntervalSince1970),
                  token.inviterMemberID != localMemberIdentity.memberID,
                  token.recipientMemberID == nil || token.recipientMemberID == localMemberIdentity.memberID,
                  token.recipientAccount == nil || token.recipientAccount == localAccountPrincipal,
                  let context = token.directInvitation?.context, let proof = token.identityProof else { throw GroupInviteTokenError.wrongRecipient }
            _ = try proof.verify(Data(token.signature.utf8), purpose: .issueInvitation, memberID: token.inviterMemberID,
                                 trust: internetSettingsStore.identityTrust(), now: now)
            stopContactInvitationSession()
            contactInvitationMessage = nil
            contactInvitationPresentation = .accepting(.init(id: context.id,
                inviterName: token.inviterDisplayName ?? "Inviter", expiresAt: context.expiresAt,
                accountAccessID: accountAccessID, url: url))
            return true
        } catch {
            contactInvitationPresentation = nil
            contactInvitationMessage = "This invitation could not be verified. Ask the sender for a new invitation."
            return false
        }
    }

    @discardableResult
    func acceptPresentedContactInvitation(expectedInvitationID: UUID? = nil) -> Bool {
        guard case .some(.accepting(let preview)) = contactInvitationPresentation,
              expectedInvitationID == nil || preview.id == expectedInvitationID,
              preview.accountAccessID == accountAccessID, canEditSavedGroups else { return false }
        do {
            try acceptContactInviteURL(preview.url)
            contactInvitationPresentation = nil
            contactInvitationMessage = nil
            return true
        } catch {
            contactInvitationMessage = "This invitation could not be accepted. Ask the sender for a new invitation."
            return false
        }
    }

    func dismissContactInvitationPresentation(expectedPresentationID: String? = nil) {
        guard expectedPresentationID == nil || contactInvitationPresentation?.id == expectedPresentationID else { return }
        if case .some(.sharing(let id)) = contactInvitationPresentation, contactInvitationID == id {
            stopContactInvitationSession()
        }
        contactInvitationPresentation = nil
        contactInvitationMessage = nil
    }

    func contactInvitationURLForSharing(_ id: UUID, expectedAccountAccessID: UUID) throws -> URL {
        guard canEditSavedGroups, expectedAccountAccessID == accountAccessID,
              let record = pendingContactInvitations.first(where: { $0.id == id }),
              record.direction == .outgoing, record.state == .pending else { throw ContactInvitationError.unavailable }
        let payload = try groupRepository.contactInvitationPayload(id)
        // Validate a retained signing key without creating or replacing one.
        _ = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID,
                                                       expectedPublicKey: payload.token.identityProof?.publicKey)
        return try GroupInviteTokenCodec.joinURL(for: payload.token, contactBootstrap: true)
    }

    func retryPresentedContactInvitation(_ id: UUID) {
        guard case .some(.sharing(let presented)) = contactInvitationPresentation, presented == id else { return }
        contactInvitationMessage = nil
        _ = resumeContactInvitation(id)
    }

    @discardableResult
    func cancelPresentedContactInvitation(_ id: UUID) -> Bool {
        guard case .some(.sharing(let presented)) = contactInvitationPresentation, presented == id else { return false }
        do {
            try cancelContactInvitation(id)
            contactInvitationPresentation = nil
            contactInvitationMessage = nil
            return true
        } catch {
            contactInvitationMessage = "Could not cancel this pending invitation. Try again."
            return false
        }
    }

    func contactInvitationRecord(_ id: UUID) -> ContactInvitationRecord? {
        _ = contactInvitationRevision
        guard let record = groupRepository.contactInvitations.first(where: { $0.id == id }) else { return nil }
        if record.canResume && callAccessNow().timeIntervalSince1970 >= record.expiresAt { return nil }
        return record
    }

    func contactInvitationStatus(for record: ContactInvitationRecord) -> String {
        if record.direction == .incoming && record.state == .delivered {
            return "Contact saved. The acceptance notification was delivered."
        }
        if record.direction == .outgoing && record.state == .confirmed {
            return savedRemoteUsers.contains(where: { $0.memberIDs.contains(record.peerMemberID ?? "") })
                ? "Contact added. Confirmation can be resent."
                : "This invitation was already accepted. Confirmation can be resent."
        }
        if activeGroupID != nil || hasAnyActiveGroupConnection {
            return record.direction == .incoming
                ? "Contact saved. Waiting for the current call to end."
                : "Waiting for the current call to end."
        }
        if contactInvitationID == record.id {
            return record.direction == .incoming
                ? "Contact saved. Sending the acceptance notification."
                : "Waiting for an acceptance."
        }
        return record.direction == .incoming
            ? "Contact saved. Retry the acceptance notification when ready."
            : "Invitation saved. Retry when ready."
    }

}
