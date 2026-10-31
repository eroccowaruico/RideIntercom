import Foundation
import Observation
import RTC

extension IntercomViewModel {
    static var groupAccessRequiredMessage: String { "An active pass is required to create a group or invite riders. Check Access in Settings." }
    static var callAccessRequiredMessage: String { "Waiting for a rider with an active pass. You can also check Access in Settings." }

    var commercialAccess: StoreAccessEvaluation {
        callAccessEvaluation?(callAccessNow()) ?? storeAccess.evaluation(at: callAccessNow())
    }
    func hasLocalCallRight(at now: TimeInterval) -> Bool {
        let value = callAccessEvaluation?(Date(timeIntervalSince1970: now)) ?? storeAccess.evaluation(at: Date(timeIntervalSince1970: now))
        return value.status == .active && (value.activeUntil.map { $0.timeIntervalSince1970.isFinite && now < $0.timeIntervalSince1970 } ?? true)
    }
    var canManageRegularGroups: Bool { canEditSavedGroups && (!enforceCallAccess || hasLocalCallRight(at: callAccessNow().timeIntervalSince1970)) }
    func requireGroupAccess() -> Bool {
        guard canManageRegularGroups else {
            groupErrorMessage = groupStorageNotice ?? Self.groupAccessRequiredMessage
            return false
        }
        return true
    }

    func observeCallAccess() {
        guard canStartCalls else { return }
        let generation = callAccessObservationGeneration
        withObservationTracking {
            _ = commercialAccess
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.canStartCalls, self.callAccessObservationGeneration == generation else { return }
                self.observeCallAccess()
                self.refreshCallAccess()
            }
        }
    }
    func stopCallAccessObservation() { callAccessObservationGeneration = UUID() }

    var canPrepareCallMedia: Bool {
        guard canStartCalls else { return false }
        guard enforceCallAccess else { return true }
        let peers = peerProfiles.values.filter { $0.verified != nil && $0.membershipID != nil }
        guard !peers.isEmpty else { return false }
        let now = callAccessNow().timeIntervalSince1970
        return callAccessState.isEstablished || hasLocalCallRight(at: now)
            || peers.contains { $0.callAccess?.hasRight(at: now) == true }
            || CallAccessState.permitsResume(since: callAccessState.lastSponsoredStart, now: now)
    }

    func callAccessPeersChanged() {
        if !peerProfiles.values.contains(where: { $0.verified != nil && $0.membershipID != nil }) {
            callAccessState.endConversation()
        }
    }

    func refreshCallAccess(now suppliedNow: TimeInterval? = nil, retryMedia: Bool = true) {
        let now = suppliedNow ?? callAccessNow().timeIntervalSince1970
        guard enforceCallAccess, canStartCalls, let groupID = activeGroupID, !isRefreshingCallAccess else { return }
        let previousAdmission = callAccessAdmittedMemberships
        isRefreshingCallAccess = true
        defer { isRefreshingCallAccess = false }
        callAccessPeersChanged()
        callAccessState.mergeStart(groupRepository.lastSponsoredStart(for: groupID), now: now)
        let peers = peerProfiles.values.filter { $0.verified != nil && $0.membershipID != nil }
        for peer in peers { callAccessState.mergeStart(peer.callAccess?.lastSponsoredStart, now: now) }
        if canPrepareCallMedia {
            if !isAudioPausedForDeviceChange, audioErrorMessage == nil || retryMedia { _ = startAudioPipelineIfNeeded() }
            let readyPeers = peers.compactMap(\.callAccess).filter { $0.mediaReady || $0.isEstablished }
            let sponsored = hasLocalCallRight(at: now) || readyPeers.contains { $0.hasRight(at: now) }
            let canEstablish = sponsored || CallAccessState.permitsResume(since: callAccessState.lastSponsoredStart, now: now)
            _ = callAccessState.establish(now: now, sponsored: sponsored,
                remoteEstablished: readyPeers.contains { $0.isEstablished },
                mediaReady: isAudioReady && !readyPeers.isEmpty && canEstablish)
            if groupErrorMessage == Self.callAccessRequiredMessage { groupErrorMessage = nil }
        } else {
            if isAudioReady { stopAudioPipeline() }
            if !peers.isEmpty { groupErrorMessage = Self.callAccessRequiredMessage }
        }
        let storedStart = groupRepository.lastSponsoredStart(for: groupID)
        if let start = callAccessState.lastSponsoredStart,
           storedStart.map({ !CallAccessState.validStart($0, now: now) || start > $0 }) ?? true,
           lastCallAccessSaveAttempt != start {
            lastCallAccessSaveAttempt = start
            do { try groupRepository.recordSponsoredStart(start, for: groupID, now: now) }
            catch { reportGroupStorageError(error) }
        }
        if previousAdmission != callAccessAdmittedMemberships { callSession.setAudioPolicy(currentCallAudioPolicy()) }
        sendCallAccess(now: now)
        if callAccessState.isEstablished { recordEstablishedCall() }
    }

    func sendCallAccess(to recipient: String? = nil, force: Bool = false, now suppliedNow: TimeInterval? = nil) {
        let now = suppliedNow ?? callAccessNow().timeIntervalSince1970
        guard enforceCallAccess, canStartCalls, let groupID = activeGroupID else { return }
        let evaluation = callAccessEvaluation?(Date(timeIntervalSince1970: now)) ?? storeAccess.evaluation(at: Date(timeIntervalSince1970: now))
        let until = hasLocalCallRight(at: now) ? evaluation.activeUntil?.timeIntervalSince1970 : nil
        for peerID in peerProfiles.keys.sorted() where recipient == nil || recipient == peerID {
            guard var state = peerProfiles[peerID], let challenge = state.remoteChallenge, state.verified != nil,
                  state.callAccessRevision < UInt64.max else { continue }
            var value = SharedCallAccess(groupID: groupID, recipientMemberID: peerID, challenge: challenge,
                revision: state.callAccessRevision, hasActiveRight: hasLocalCallRight(at: now), activeUntil: until, mediaReady: isAudioReady,
                isEstablished: callAccessState.isEstablished, lastSponsoredStart: callAccessState.lastSponsoredStart)
            guard force || value != state.sentCallAccess else { continue }
            value = SharedCallAccess(groupID: groupID, recipientMemberID: peerID, challenge: challenge,
                revision: state.callAccessRevision + 1, hasActiveRight: hasLocalCallRight(at: now), activeUntil: until, mediaReady: isAudioReady,
                isEstablished: callAccessState.isEstablished, lastSponsoredStart: callAccessState.lastSponsoredStart)
            guard let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID),
                  let signed = try? value.signed(by: signer), let payload = try? JSONEncoder().encode(signed) else { continue }
            state.callAccessRevision = value.revision
            state.sentCallAccess = value
            peerProfiles[peerID] = state
            callSession.sendApplicationData(.init(namespace: SharedCallAccess.namespace, payload: payload))
        }
    }

    func receiveCallAccess(peerID: String, message: ApplicationDataMessage, now suppliedNow: TimeInterval? = nil) {
        let now = suppliedNow ?? callAccessNow().timeIntervalSince1970
        guard enforceCallAccess, canStartCalls, message.namespace == SharedCallAccess.namespace, message.payload.count <= 8192,
              authenticatedPeerIDs.contains(peerID), var state = peerProfiles[peerID], state.membershipID != nil, let verified = state.verified,
              let value = try? JSONDecoder().decode(SharedCallAccess.self, from: message.payload),
              value.groupID == activeGroupID, value.recipientMemberID == localMemberIdentity.memberID,
              value.challenge == state.challenge, value.revision > (state.callAccess?.revision ?? 0),
              value.activeUntil.map({ $0.isFinite && $0 > 0 }) ?? true,
              value.lastSponsoredStart.map({ $0.isFinite && $0 > 0 }) ?? true,
              (try? value.verify(peerID: peerID, publicKey: verified.identity.publicKey)) != nil else { return }
        let first = state.callAccess == nil
        state.callAccess = value
        peerProfiles[peerID] = state
        refreshCallAccess(now: now)
        // A status sent before the other side's profile verification is discarded.
        // Reply once on first verified status, without a recurring acknowledgement protocol.
        if first { sendCallAccess(to: peerID, force: true, now: now) }
    }
}
