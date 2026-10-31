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
        return .init(reference: watchReference(vm), generatedAt: now, validUntil: now.addingTimeInterval(120),
                     targets: callTargets.map { .init(id: $0.entity.id, name: $0.entity.name) },
                     title: vm.groups.first { $0.id == vm.activeGroupID }.map(vm.callTitle),
                     hasCall: hasCall, isMuted: vm.isMuted, state: state)
    }

    func handleWatchRequest(_ request: WatchControlRequest, now: Date = Date()) -> WatchControlReply {
        func reply(_ problem: WatchControlProblem? = nil) -> WatchControlReply { .init(snapshot: watchSnapshot(now: now), problem: problem) }
        if request.action == .refresh { return reply() }
        guard let vm = try? callModel(), vm.hasCurrentAccountAccess else { return reply(.noAccount) }
        guard request.reference == watchReference(vm), request.validUntil > now,
              request.validUntil <= now.addingTimeInterval(120) else { return reply(.stale) }
        let succeeded: Bool
        switch request.action {
        case .refresh: return reply()
        case .start(let id):
            guard let target = callTargets.first(where: { $0.entity.id == id }) else { return reply(.missingDestination) }
            succeeded = vm.startCall(to: target.destination, accountAccessID: vm.accountAccessID, allowSwitchingCall: false)
        case .end: succeeded = vm.endCall(vm.currentCallReference)
        case .setMuted(let value): succeeded = vm.setCallMuted(value, for: vm.currentCallReference)
        }
        return reply(succeeded ? nil : .denied)
    }
}
