import Foundation
import RTC

extension IntercomViewModel {
    @discardableResult
    func setLocalDisplayName(_ value: String) -> Bool {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canStartCalls, IntercomGroup.isValidName(name) else {
            groupErrorMessage = "Enter a valid display name."; return false
        }
        localMemberIdentityStore.saveDisplayName(name)
        localMemberIdentity.displayName = name
        applySavedUserNames()
        sendSharedDisplayName()
        groupErrorMessage = nil
        return true
    }

    func synchronizePeerProfiles(members: [RTC.CallMemberState]) {
        let peers = Set(authenticatedPeerIDs.sorted().prefix(IntercomGroup.maximumMemberCount - 1))
        var next: [String: PeerProfileState] = [:]
        for member in members where peers.contains(member.peer.id.rawValue) {
            let id = member.peer.id.rawValue
            if let retained = peerProfiles[id], retained.membershipID == member.membershipID {
                next[id] = retained
            } else {
                next[id] = PeerProfileState(membershipID: member.membershipID)
            }
        }
        peerProfiles = next
    }

    static func admittedMemberships(in profiles: [String: PeerProfileState]) -> [RTC.PeerID: UUID] {
        profiles.reduce(into: [:]) { admitted, entry in
            if entry.value.verified != nil, let membership = entry.value.membershipID {
                admitted[.init(rawValue: entry.key)] = membership
            }
        }
    }

    func currentCallAudioPolicy() -> RTC.RTCAudioPolicy {
        var policy = currentAudioPipelineConfiguration().audioPolicy
        policy.peerPolicy = .admittedMemberships(canStartCalls ? Self.admittedMemberships(in: peerProfiles) : [:])
        return policy
    }

    func sendPeerProfileChallenges(now: TimeInterval = Date().timeIntervalSince1970) {
        guard canStartCalls, let groupID = activeGroupID else { return }
        for peerID in peerProfiles.keys.sorted() {
            guard var state = peerProfiles[peerID], state.verified == nil, now >= state.nextRequestAt else { continue }
            let challenge = PeerProfileChallenge(groupID: groupID, recipientMemberID: peerID, nonce: state.challenge)
            guard let payload = try? JSONEncoder().encode(challenge) else { continue }
            state.nextRequestAt = now + state.requestInterval
            state.requestInterval = min(60, state.requestInterval * 2)
            peerProfiles[peerID] = state
            callSession.sendApplicationData(.init(namespace: PeerProfileChallenge.namespace, payload: payload))
        }
    }

    func receivePeerProfileChallenge(peerID: String, message: ApplicationDataMessage, now: TimeInterval = Date().timeIntervalSince1970) {
        guard canStartCalls, message.namespace == PeerProfileChallenge.namespace, message.payload.count <= 1024,
              authenticatedPeerIDs.contains(peerID), var state = peerProfiles[peerID],
              let challenge = try? JSONDecoder().decode(PeerProfileChallenge.self, from: message.payload),
              challenge.groupID == activeGroupID, challenge.recipientMemberID == localMemberIdentity.memberID,
              now - state.lastResponseAt >= 1 else { return }
        state.remoteChallenge = challenge.nonce
        peerProfiles[peerID] = state
        sendSharedDisplayName(to: peerID, now: now)
    }

    func sendSharedDisplayName() {
        for peerID in peerProfiles.keys.sorted() { sendSharedDisplayName(to: peerID) }
    }

    private func sendSharedDisplayName(to peerID: String, now: TimeInterval = Date().timeIntervalSince1970) {
        guard canStartCalls, let groupID = activeGroupID, authenticatedPeerIDs.contains(peerID),
              var state = peerProfiles[peerID], let challenge = state.remoteChallenge else { return }
        // Cache duplicate challenge replies; peer retransmission must not cause
        // repeated Keychain reads, signatures or a reply loop.
        let cached = state.response.flatMap { try? JSONDecoder().decode(SharedDisplayName.self, from: $0) }
        let payload: Data
        if let response = state.response, cached?.challenge == challenge, state.responseName == localMemberIdentity.displayName {
            payload = response
        } else {
            guard state.responseRevision < UInt64.max,
                  let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID),
                  let value = try? SharedDisplayName.make(groupID: groupID, recipientMemberID: peerID, challenge: challenge,
                      revision: state.responseRevision + 1, displayName: localMemberIdentity.displayName, signer: signer),
                  let data = try? JSONEncoder().encode(value) else { return }
            payload = data
            state.response = data; state.responseName = localMemberIdentity.displayName; state.responseRevision += 1
        }
        state.lastResponseAt = now
        peerProfiles[peerID] = state
        callSession.sendApplicationData(.init(namespace: SharedDisplayName.namespace, payload: payload))
    }

    func receiveSharedDisplayName(peerID: String, message: ApplicationDataMessage) {
        guard message.namespace == SharedDisplayName.namespace, message.payload.count <= 8192,
              authenticatedPeerIDs.contains(peerID), canEditSavedGroups, let groupID = activeGroupID,
              var state = peerProfiles[peerID],
              let value = try? JSONDecoder().decode(SharedDisplayName.self, from: message.payload),
              value.revision > (state.verified?.revision ?? 0),
              let verified = try? value.verified(peerID: peerID, recipient: localMemberIdentity.memberID,
                  groupID: groupID, challenge: state.challenge, trust: try? internetSettingsStore.identityTrust()) else { return }
        if let previous = state.verified {
            guard previous.identity.publicKey == verified.identity.publicKey,
                  previous.identity.principal == nil || verified.identity.principal == nil
                    || previous.identity.principal == verified.identity.principal else { return }
        }
        do {
            guard verified.identity.principal == nil || verified.identity.principal != localAccountPrincipal else { return }
            guard try groupRepository.receiveProfile(verified, connectedMemberIDs: Set(authenticatedPeerIDs)) else { return }
            refreshStoredAccountCall(groupID)
            state.verified = verified
            peerProfiles[peerID] = state
            refreshGroupStorageStatus()
            recordEstablishedCall()
        } catch { reportGroupStorageError(error) }
    }

    @discardableResult
    func resetSavedUserName(_ id: UUID) -> Bool {
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        do { try groupRepository.resetUserName(id) }
        catch { reportGroupStorageError(error); return false }
        refreshGroupStorageStatus(); groupErrorMessage = nil
        return true
    }

    @discardableResult
    func renameGroupMember(_ memberID: String, in groupID: UUID, displayName: String) -> Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IntercomGroup.isValidName(name) else { groupErrorMessage = "Enter a valid display name."; return false }
        return setGroupMemberName(memberID, in: groupID, localName: name)
    }

    @discardableResult
    func resetGroupMemberName(_ memberID: String, in groupID: UUID) -> Bool {
        setGroupMemberName(memberID, in: groupID, localName: nil)
    }

    private func setGroupMemberName(_ memberID: String, in groupID: UUID, localName: String?) -> Bool {
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        do { try groupRepository.setMemberName(memberID, in: groupID, localName: localName) }
        catch { reportGroupStorageError(error); return false }
        refreshGroupStorageStatus(); groupErrorMessage = nil
        return true
    }
}
