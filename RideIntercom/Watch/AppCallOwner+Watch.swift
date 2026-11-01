import Foundation

extension AppCallOwner {
    /// An opaque reference to the existing account/call generation, not another call state.
    private func watchReference(_ vm: IntercomViewModel) -> String {
        let call = vm.currentCallReference
        return "\(call.accountAccessID)|\(call.connectionGeneration)|\(call.groupID?.uuidString ?? "idle")"
    }

    func watchSnapshot(now: Date = Date()) -> WatchCallSnapshot {
        guard let vm = try? callModel(), vm.hasCurrentAccountAccess else {
            return .init(reference: nil, generatedAt: now, validUntil: now.addingTimeInterval(120),
                         targets: [], title: nil, hasCall: false, isMuted: true, state: .signedOut)
        }
        let hasCall = vm.hasAnyActiveGroupConnection
        let state: WatchCallState = switch vm.callStatus(for: vm.activeGroupID) {
        case .chooseDestination, .ready: .idle
        case .connecting: .connecting
        case .inCall: .inCall
        case .audioPaused: .audioPaused
        case .audioUnavailable: .audioUnavailable
        }
        let notification = vm.notifications.outgoing.map { outgoing in
            WatchCallNotification(requestID: outgoing.reply.requestID, status: outgoing.reply.status,
                canCancel: outgoing.reply.isLive(at: now) && [.processing, .accepted].contains(outgoing.reply.status))
        }
        return .init(reference: watchReference(vm), generatedAt: now, validUntil: now.addingTimeInterval(120),
                     targets: callTargets.map { target in
                         let canNotify: Bool
                         if case .user(let id) = target.destination { canNotify = vm.notifications.canNotify(id) }
                         else { canNotify = false }
                         return .init(id: target.entity.id, name: target.entity.name, canNotify: canNotify)
                     },
                     title: vm.groups.first { $0.id == vm.activeGroupID }.map(vm.callTitle),
                     hasCall: hasCall, isMuted: vm.isMuted, state: state, notification: notification,
                     audioCheck: vm.audioCheckWatchSessionID.map { sessionID in
                         let phase = vm.audioCheckPhase
                         if phase == .recording {
                             return .init(sessionID: sessionID, phase: phase, recordedFrames: 0, nonzeroSamples: 0)
                         }
                         return .init(sessionID: sessionID, phase: phase,
                             recordedFrames: vm.audioCheckRecordedFrameCount, nonzeroSamples: vm.audioCheckRecordedNonzeroSamples)
                     })
    }

    func handleWatchRequest(_ request: WatchControlRequest, now: Date = Date()) async -> WatchControlReply {
        func reply(_ problem: WatchControlProblem? = nil) -> WatchControlReply { .init(snapshot: watchSnapshot(now: now), problem: problem) }
        if request.action == .refresh { return reply() }
        guard let vm = try? callModel(), vm.hasCurrentAccountAccess else { return reply(.noAccount) }
        guard request.reference == watchReference(vm), request.validUntil > now,
              request.validUntil <= now.addingTimeInterval(120) else { return reply(.stale) }
        let succeeded: Bool
        switch request.action {
        case .refresh: return reply()
        case .startAudio(let id, let offer):
            guard offer.key.count == 32,
                  let target = callTargets.first(where: { $0.entity.id == id }) else { return reply(.missingDestination) }
            guard vm.startCall(to: target.destination, accountAccessID: vm.accountAccessID,
                               allowSwitchingCall: false, usingWatch: true) else { return reply(.denied) }
            do {
                let endpoint = try await vm.attachWatchAudio(offer)
                guard let current = try? callModel(), current === vm, vm.hasCurrentAccountAccess else { return reply(.noAccount) }
                return .init(snapshot: watchSnapshot(), problem: nil, audioEndpoint: endpoint)
            } catch { return reply(.unavailable) }
        case .start(let id):
            guard let target = callTargets.first(where: { $0.entity.id == id }) else { return reply(.missingDestination) }
            succeeded = vm.startCall(to: target.destination, accountAccessID: vm.accountAccessID, allowSwitchingCall: false, usingWatch: true)
        #if DEBUG
        case .startAudioCheck(let offer):
            guard offer.key.count == 32, vm.canStartAudioCheck else { return reply(.denied) }
            do {
                let endpoint = try await vm.attachWatchAudio(offer, audioCheck: true)
                return .init(snapshot: watchSnapshot(), problem: nil, audioEndpoint: endpoint)
            } catch { return reply(.unavailable) }
        case .playAudioCheck(let id):
            return reply(vm.playWatchAudioCheck(sessionID: id) ? nil : .stale)
        case .stopAudioCheck(let id):
            guard vm.audioCheckWatchSessionID == id else { return reply(.stale) }
            vm.cancelAudioCheck()
            return reply()
        #endif
        case .end: succeeded = vm.endCall(vm.currentCallReference)
        case .setMuted(let value): succeeded = vm.setCallMuted(value, for: vm.currentCallReference)
        case .requestCall(let id):
            guard let target = callTargets.first(where: { $0.entity.id == id }) else { return reply(.missingDestination) }
            guard case .user(let userID) = target.destination, vm.notifications.canNotify(userID) else { return reply(.denied) }
            succeeded = await vm.notifications.send(to: userID) != nil
        case .cancelCallRequest(let id):
            guard let outgoing = vm.notifications.outgoing, outgoing.reply.requestID == id,
                  outgoing.reply.isLive(at: now) else { return reply(.stale) }
            await vm.notifications.cancelOutgoing()
            succeeded = vm.notifications.outgoing == nil
        }
        guard let current = try? callModel(), current === vm, vm.hasCurrentAccountAccess else { return reply(.noAccount) }
        return reply(succeeded ? nil : .denied)
    }
}
