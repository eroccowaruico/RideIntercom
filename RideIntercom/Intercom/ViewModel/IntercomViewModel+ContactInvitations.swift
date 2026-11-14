import Foundation

extension IntercomViewModel {
    var pendingContactInvitations: [ContactInvitationRecord] {
        _ = contactInvitationRevision
        let now = callAccessNow().timeIntervalSince1970
        // Expired sent invitations stay (as "Expired") until a new one is sent or they are cancelled.
        return groupRepository.contactInvitations.filter { ($0.canResume && now < $0.expiresAt) || contactInvitationIsExpired($0) }
            .sorted { $0.expiresAt > $1.expiresAt }
    }

    /// Direct contact consent is independent of the right to create a group.
    func makeContactInviteURL() -> URL? {
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return nil }
        do {
            let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
            let token = try ContactInvitationSession.makeToken(authority: invitationAuthority, signer: signer,
                displayName: localMemberIdentity.displayName, now: callAccessNow().timeIntervalSince1970)
            try groupRepository.stageContactInvitation(token, now: callAccessNow().timeIntervalSince1970)
            refreshGroupStorageStatus()
            let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
            _ = resumeContactInvitation(try contactID(token))
            return url
        } catch {
            contactInvitationMessage = "Could not save this invitation. Try again."
            return nil
        }
    }

    func acceptContactInviteURL(_ url: URL) throws {
        guard canEditSavedGroups else { throw ContactInvitationError.unavailable }
        let token = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
        let acceptance = try token.accept(signer: signer, displayName: localMemberIdentity.displayName,
            trust: internetSettingsStore.identityTrust(), now: callAccessNow().timeIntervalSince1970, contactBootstrap: true)
        try groupRepository.acceptContactInvitation(token, accepted: acceptance,
            localDisplayName: localMemberIdentity.displayName, now: callAccessNow().timeIntervalSince1970)
        adoptStoredDirectCall(with: acceptance.inviter.memberID)
        refreshGroupStorageStatus()
        _ = resumeContactInvitation(try contactID(token))
    }

    @discardableResult
    func resumeContactInvitation(_ id: UUID) -> Bool {
        guard canEditSavedGroups, activeGroupID == nil, !hasAnyActiveGroupConnection,
              let record = groupRepository.contactInvitations.first(where: { $0.id == id }),
              record.canResume, callAccessNow().timeIntervalSince1970 < record.expiresAt else { return false }
        if contactInvitationID == id, let session = contactInvitationSession, !session.isStopped {
            session.retry()
            return true
        }
        do {
            let payload = try groupRepository.contactInvitationPayload(id)
            let expectedKey = record.direction == .outgoing ? payload.token.identityProof?.publicKey : payload.receipt?.inviteeDeviceKey
            let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: expectedKey)
            let trust = try internetSettingsStore.identityTrust()
            stopContactInvitationSession()
            let transport: CallSession
            if let contactSessionFactory { transport = contactSessionFactory() }
            else {
                transport = RideIntercomCallSessionAdapter(memberID: localMemberIdentity.memberID,
                    internetConfiguration: try internetSettingsStore.load())
            }
            let access = accountAccessID
            let session = ContactInvitationSession(transport: transport, authority: invitationAuthority, signer: signer,
                displayName: localMemberIdentity.displayName, trust: trust, routes: enabledRTCTransportRoutes,
                now: { [weak self] in self?.callAccessNow().timeIntervalSince1970 ?? .infinity },
                confirmReceipt: { [weak self] verified in
                    guard let self, self.canEditSavedGroups, self.accountAccessID == access,
                          self.contactInvitationID == id, verified.receipt.invitation?.id == id else { throw ContactInvitationError.unavailable }
                    try self.groupRepository.confirmContactInvitation(verified, localDisplayName: self.localMemberIdentity.displayName,
                        now: self.callAccessNow().timeIntervalSince1970)
                    self.adoptStoredDirectCall(with: verified.identity.memberID)
                    self.refreshGroupStorageStatus()
                }, acknowledged: { [weak self] in
                    guard let self, self.canEditSavedGroups, self.accountAccessID == access,
                          self.contactInvitationID == id else { throw ContactInvitationError.unavailable }
                    try self.groupRepository.completeContactNotification(id)
                    self.refreshGroupStorageStatus()
                    self.stopContactInvitationSession()
                }, confirm: { _, _ in
                    // Explicit acceptance is committed atomically before restore.
                    throw ContactInvitationError.unavailable
                })
            contactInvitationID = id
            contactInvitationSession = session
            try session.restore(payload)
            // Each explicit retry has a finite radio lifetime. The durable
            // invitation keeps its independent seven-day validity after pausing.
            let remaining = Duration.seconds(max(0, record.expiresAt - callAccessNow().timeIntervalSince1970))
            let attempt = min(.seconds(60), max(.zero, contactNotificationAttemptDuration))
            let delay = min(remaining, attempt)
            contactInvitationExpiryTask = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, self.contactInvitationID == id else { return }
                self.stopContactInvitationSession()
                do {
                    try self.groupRepository.removeExpiredContactInvitations(now: self.callAccessNow().timeIntervalSince1970)
                    self.refreshGroupStorageStatus()
                } catch { self.contactInvitationMessage = "Could not update this invitation. Try again." }
            }
            return true
        } catch {
            stopContactInvitationSession()
            contactInvitationMessage = "This invitation could not be resumed. Try again."
            return false
        }
    }

    /// Saves the name the inviter gives the person before sending. Blank clears it.
    @discardableResult
    /// `refresh: false` saves without republishing state, for saves made while a share sheet opens.
    func setContactInvitationNickname(_ id: UUID, _ name: String, refresh: Bool = true) -> Bool {
        guard canEditSavedGroups else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || IntercomGroup.isValidName(trimmed) else { return false }
        do {
            try groupRepository.setContactInvitationNickname(id, nickname: trimmed.isEmpty ? nil : trimmed)
            if refresh { refreshGroupStorageStatus() }
            return true
        } catch {
            return false
        }
    }

    func cancelContactInvitation(_ id: UUID) throws {
        guard canEditSavedGroups else { throw ContactInvitationError.unavailable }
        // Commit the cancellation before stopping; a failed save remains retryable.
        try groupRepository.cancelContactInvitation(id)
        if contactInvitationID == id { stopContactInvitationSession() }
        refreshGroupStorageStatus()
    }

    func stopContactInvitationSession() {
        contactInvitationExpiryTask?.cancel()
        contactInvitationExpiryTask = nil
        contactInvitationSession?.stop()
        contactInvitationSession = nil
        contactInvitationID = nil
    }

    private func contactID(_ token: GroupInviteToken) throws -> UUID {
        guard let context = token.directInvitation?.context, context.contactBootstrap == true else { throw GroupInviteTokenError.invalidTokenEncoding }
        return context.id
    }
}

enum ContactInvitationError: Error {
    case unavailable
}
