import Foundation
import Observation

/// The app and system actions share the same account and call model.
@MainActor @Observable
final class AppCallOwner: CallSurfaceActions {
    let widgetDestinations: WidgetDestinationPublisher
    let liveActivities: CallLiveActivityPresenter
    var systemSurfaceIsForeground = false
    let account: AppleAccountSession
    let notificationBridge = AppNotificationBridge()
    var viewModel: IntercomViewModel?
    var callPresentationID: UUID?
    #if os(iOS)
    var watchBridge: WatchPhoneBridge?
    #endif

    init(account: AppleAccountSession, viewModel: IntercomViewModel?, liveActivityDriver: (any CallLiveActivityDriving)? = nil, widgetDestinationStore: WidgetDestinationStore = .system) {
        widgetDestinations = WidgetDestinationPublisher(store: widgetDestinationStore)
        liveActivities = CallLiveActivityPresenter(driver: liveActivityDriver ?? SystemCallLiveActivityDriver())
        self.account = account
        self.viewModel = viewModel
        observeSystemSurfaces()
        observeWidgetDestinations()
    }
}
