import Foundation
#if os(iOS)
import ActivityKit

@MainActor final class SystemCallLiveActivityDriver: CallLiveActivityDriving {
    var onDismissed: ((CallSurfaceReference) -> Void)?
    private var activity: Activity<RideCallActivityAttributes>?
    private var observation: Task<Void, Never>?
    enum Failure: Error { case unavailable }
    deinit { observation?.cancel() }

    func start(_ value: CallLivePresentation) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw Failure.unavailable }
        let activity = try Activity.request(attributes: RideCallActivityAttributes(reference: value.reference),
            content: content(value), pushType: nil)
        self.activity = activity
        observation?.cancel()
        observation = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .ended || state == .dismissed {
                    self?.onDismissed?(value.reference)
                    return
                }
            }
        }
    }
    func update(_ value: CallLivePresentation) async {
        guard let activity, activity.attributes.reference == value.reference else { return }
        guard activity.activityState == .active || activity.activityState == .stale else {
            onDismissed?(value.reference); return
        }
        await activity.update(content(value))
    }
    func end() async {
        observation?.cancel(); observation = nil
        activity = nil
        for previous in Activity<RideCallActivityAttributes>.activities {
            await previous.end(nil, dismissalPolicy: .immediate)
        }
    }
    private func content(_ value: CallLivePresentation) -> ActivityContent<RideCallActivityAttributes.ContentState> {
        .init(state: .init(status: value.status, isMuted: value.isMuted), staleDate: nil)
    }
}
#else
@MainActor final class SystemCallLiveActivityDriver: CallLiveActivityDriving {
    var onDismissed: ((CallSurfaceReference) -> Void)?
    func start(_ value: CallLivePresentation) async throws {}
    func update(_ value: CallLivePresentation) async {}
    func end() async {}
}
#endif
