import Foundation

/// Choosing a person starts the one-to-one connection and rings them at once; the call sheet's hero
/// shows how it went. Groups are never rung this way: a call request names no group.
struct DirectRing: Equatable {
    enum Phase: Equatable {
        /// Sent; waiting for them to join.
        case ringing
        /// No one joined before the request expired.
        case noAnswer
        /// The request could not be sent from here.
        case sendFailed
        /// They do not take call requests from this device, so nothing was sent.
        case undeliverable
    }
    let contactID: UUID
    let groupID: UUID
    var phase: Phase
}

extension IntercomViewModel {
    /// How long a request rings before it reads as unanswered (the design's 120 seconds).
    nonisolated static let directRingTimeout: Duration = .seconds(120)

    /// Rings the person a new one-to-one call was started with. Called when choosing them from a list.
    func beginDirectRing(to userID: UUID) {
        guard let groupID = activeGroupID, hasAnyActiveGroupConnection,
              let group = groups.first(where: { $0.id == groupID }), group.kind == .direct else { return }
        directRingTask?.cancel()
        guard notifications.canNotify(userID) else {
            directRing = DirectRing(contactID: userID, groupID: groupID, phase: .undeliverable)
            return
        }
        directRing = DirectRing(contactID: userID, groupID: groupID, phase: .ringing)
        directRingTask = Task { [weak self] in
            let reply = await self?.notifications.send(to: userID)
            self?.directRingSent(reply, contactID: userID)
            guard reply != nil else { return }
            try? await Task.sleep(for: Self.directRingTimeout)
            guard !Task.isCancelled else { return }
            self?.directRingExpired(contactID: userID)
        }
    }

    func directRingSent(_ reply: CallNotificationReply?, contactID: UUID) {
        guard directRing?.contactID == contactID, directRing?.phase == .ringing else { return }
        switch reply?.status {
        case .accepted, .processing: break
        case .noDestinations: directRing?.phase = .undeliverable
        case .retryLater, .rejected, .cancelled, nil: directRing?.phase = .sendFailed
        }
    }

    func directRingExpired(contactID: UUID) {
        guard directRing?.contactID == contactID, directRing?.phase == .ringing else { return }
        directRing?.phase = .noAnswer
    }

    /// The hero's ringing state for this call, or nil once they joined or the call ended.
    func directRingPhase(for group: IntercomGroup) -> DirectRing.Phase? {
        guard let ring = directRing, ring.groupID == group.id, activeGroupID == group.id,
              hasAnyActiveGroupConnection, callStatus(for: group.id) != .inCall else { return nil }
        return ring.phase
    }

    func cancelDirectRing() {
        directRingTask?.cancel()
        directRing = nil
        Task { [notifications] in await notifications.cancelOutgoing() }
    }

    func ringAgain() {
        guard let ring = directRing else { return }
        beginDirectRing(to: ring.contactID)
    }

    /// When they join, or the call ends, the ring stops; a ringing request is withdrawn so their phone
    /// does not keep showing it.
    func settleDirectRing() {
        guard let ring = directRing else { return }
        let joined = activeGroupID == ring.groupID && callStatus(for: ring.groupID) == .inCall
        let ended = activeGroupID != ring.groupID || !hasAnyActiveGroupConnection
        guard joined || ended else { return }
        directRingTask?.cancel()
        directRing = nil
        if ring.phase == .ringing { Task { [notifications] in await notifications.cancelOutgoing() } }
    }
}
