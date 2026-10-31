import AuthenticationServices
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
    @ObservationIgnored private let makeViewModel: @MainActor (AppleAccountSession) -> IntercomViewModel?
    @ObservationIgnored private var credentialRevocationObserver: NSObjectProtocol?
    #if os(iOS)
    var watchBridge: WatchPhoneBridge?
    #endif

    init(account: AppleAccountSession, viewModel: IntercomViewModel?, liveActivityDriver: (any CallLiveActivityDriving)? = nil, widgetDestinationStore: WidgetDestinationStore = .system,
         makeViewModel: @escaping @MainActor (AppleAccountSession) -> IntercomViewModel? = IntercomViewModel.makeForCurrentProcess) {
        widgetDestinations = WidgetDestinationPublisher(store: widgetDestinationStore)
        liveActivities = CallLiveActivityPresenter(driver: liveActivityDriver ?? SystemCallLiveActivityDriver())
        self.makeViewModel = makeViewModel
        self.account = account
        self.viewModel = viewModel
        credentialRevocationObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.account.revoke() }
        }
        observeAccountAccess()
        observeSystemSurfaces()
        observeWidgetDestinations()
    }
    deinit {
        if let credentialRevocationObserver { NotificationCenter.default.removeObserver(credentialRevocationObserver) }
    }

    private func observeAccountAccess() {
        withObservationTracking {
            _ = account.accessID
            _ = account.userID
            _ = account.deletion.blocksSignIn
            _ = account.storageUnavailable
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.synchronizeAccountModel()
                self?.observeAccountAccess()
            }
        }
    }

    private func synchronizeAccountModel() {
        guard viewModel?.accountAccessID != account.accessID || viewModel?.accountUserID != account.userID
                || account.deletion.blocksSignIn else { return }
        viewModel?.notifications.stop()
        viewModel?.stopCallAccessObservation()
        viewModel?.storeAccess.stop()
        viewModel?.disconnect()
        viewModel = nil
        guard !account.storageUnavailable, !account.deletion.blocksSignIn, account.userID != nil else { return }
        viewModel = makeViewModel(account)
    }

    func refreshAccountForForeground() async {
        account.reloadSavedSignIn()
        await account.refresh()
        synchronizeAccountModel()
        guard let model = viewModel, model.hasCurrentAccountAccess else { return }
        async let purchases: Void = model.storeAccess.refresh()
        async let notifications: Void = model.notifications.refresh()
        _ = await (purchases, notifications)
    }

    func prepareForBackgroundCallAction() async throws {
        let previousUserID = account.userID
        let previousAccessID = account.accessID
        account.reloadSavedSignIn()
        if previousUserID != nil, (account.userID != previousUserID || account.accessID != previousAccessID) {
            throw CallIntentError.unavailable("This sign-in has ended. Open your current account to continue.")
        }
        guard !account.storageUnavailable, !account.deletion.blocksSignIn, !account.isSigningIn,
              let userID = account.userID else {
            throw CallIntentError.unavailable(account.message ?? "Sign in with Apple in RideIntercom first.")
        }
        let accessID = account.accessID
        synchronizeAccountModel()
        let model = try callModel()
        let reference = model.currentCallReference
        await account.refresh()
        guard !Task.isCancelled, account.userID == userID, account.accessID == accessID,
              !account.storageUnavailable, !account.deletion.blocksSignIn, !account.isSigningIn else {
            throw CallIntentError.unavailable("This sign-in has ended. Open your current account to continue.")
        }
        guard viewModel === model, model.currentCallReference == reference else {
            throw CallIntentError.unavailable("The displayed call has ended or changed. Open RideIntercom to check your current call.")
        }
        guard model.canStartCalls else {
            throw CallIntentError.unavailable(model.groupStorageNotice ?? "Sign in with Apple in RideIntercom first.")
        }
        if model.groupStorageIssue == .unavailable, model.activeGroupID == nil { model.reloadSavedGroups() }
    }
}
