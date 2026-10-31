import Foundation
import Observation

@MainActor protocol CallLiveActivityDriving: AnyObject {
    var onDismissed: ((CallSurfaceReference) -> Void)? { get set }
    func start(_ value: CallLivePresentation) async throws
    func update(_ value: CallLivePresentation) async
    func end() async
}

/// Serializes only presentation updates. The app's existing VM owns the call.
@MainActor @Observable final class CallLiveActivityPresenter {
    private(set) var message: String?
    @ObservationIgnored private let driver: any CallLiveActivityDriving
    @ObservationIgnored private var desired: CallLivePresentation?
    @ObservationIgnored private var displayed: CallLivePresentation?
    @ObservationIgnored private var suppressed: CallSurfaceReference?
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var needsReconciliation = true
    @ObservationIgnored private var task: Task<Void, Never>?

    init(driver: any CallLiveActivityDriving) {
        self.driver = driver
        driver.onDismissed = { [weak self] reference in
            guard let self else { return }
            self.suppressed = reference
            if self.displayed?.reference == reference { self.displayed = nil }
        }
    }
    deinit { task?.cancel() }

    func setPresentation(_ value: CallLivePresentation?, enabled: Bool, isForeground: Bool) {
        desired = enabled ? value : nil
        self.isForeground = isForeground
        if !enabled { suppressed = nil; message = nil }
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }
    private func drain() async {
        defer { task = nil }
        // Remove a previous process's display; a Live Activity is not evidence
        // that this process has restored its media connection.
        if needsReconciliation { needsReconciliation = false; await driver.end() }
        while !Task.isCancelled {
            if let displayed, displayed.reference != desired?.reference {
                self.displayed = nil
                await driver.end()
                continue
            }
            guard let next = desired, next.reference != suppressed else { return }
            if displayed == nil {
                guard isForeground else { return }
                do { try await driver.start(next); displayed = next; message = nil }
                catch {
                    suppressed = next.reference
                    message = "Call status could not be displayed. Your call can continue. Turn the display off and on to retry."
                }
                continue
            }
            guard displayed != next else { return }
            await driver.update(next)
            // A user or the system may have removed the display during update.
            if suppressed != next.reference { displayed = next }
        }
    }
}
