import Foundation
import Observation

@MainActor
protocol StoreKitAccessSource: AnyObject {
    func read(catalog: StoreProductCatalog, onVerifiedTransactions: @MainActor (StoreEntitlementSnapshot) -> Void) async throws -> StoreEntitlementSnapshot
    func sync() async throws
    func updates(catalog: StoreProductCatalog) -> AsyncStream<Void>
}

/// The device's App Store purchases. No account ID or independent purchase ledger is stored.
@MainActor @Observable
final class StoreKitAccess {
    let catalog: StoreProductCatalog
    private(set) var snapshot: StoreEntitlementSnapshot?
    private(set) var isRefreshing = false
    private(set) var message: String?
    private(set) var lastRefreshFailed = false
    @ObservationIgnored private let isCurrentUser: @MainActor () -> Bool
    @ObservationIgnored private let source: any StoreKitAccessSource
    @ObservationIgnored private let readTimeout: Duration
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var cancelRead: (() -> Void)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingRefresh = false

    init(catalog: StoreProductCatalog? = nil, source: (any StoreKitAccessSource)? = nil,
         isCurrentUser: (@MainActor () -> Bool)? = nil, readTimeout: Duration = .seconds(15)) {
        self.catalog = catalog ?? .production
        self.source = source ?? SystemStoreKitAccessSource()
        self.isCurrentUser = isCurrentUser ?? { true }
        self.readTimeout = readTimeout
    }
    deinit { observationTask?.cancel() }

    func evaluation(at now: Date) -> StoreAccessEvaluation {
        guard catalog.isConfigured else { return .init(status: .unconfigured) }
        guard isCurrentUser() else { return .init(status: .unknown) }
        let evaluation = snapshot?.evaluate(at: now) ?? .init(status: .unknown)
        if lastRefreshFailed && evaluation.status != .active { return .init(status: .unknown) }
        return evaluation
    }

    func start() async {
        guard catalog.isConfigured, isCurrentUser(), observationTask == nil else { return }
        let changes = source.updates(catalog: catalog)
        observationTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
        await refresh()
    }

    func stop() {
        generation += 1
        observationTask?.cancel()
        observationTask = nil
        cancelRead?()
        cancelRead = nil
        isRefreshing = false
        snapshot = nil
        message = nil
        pendingRefresh = false
        lastRefreshFailed = false
    }

    func refresh() async { await load(restore: false) }
    /// AppStore.sync is used only by this explicit user action.
    func restore() async { await load(restore: true) }

    private func load(restore: Bool) async {
        guard catalog.isConfigured, isCurrentUser() else { return }
        if isRefreshing {
            if !restore { pendingRefresh = true }
            return
        }
        let expectedGeneration = generation
        isRefreshing = true
        defer {
            if generation == expectedGeneration { isRefreshing = false; cancelRead = nil }
        }
        do {
            if restore {
                // User authentication in the system sheet has no read deadline.
                let sync = StoreKitReadAttempt<Void>()
                cancelRead = sync.cancel
                try await sync.run(timeout: nil) { [source] in try await source.sync() }
                guard generation == expectedGeneration, isCurrentUser(), !Task.isCancelled else { return }
            }
            repeat {
                pendingRefresh = false
                let attempt = StoreKitReadAttempt<StoreEntitlementSnapshot>()
                cancelRead = attempt.cancel
                let value = try await attempt.run(timeout: readTimeout) { [source, catalog, weak self] in
                    return try await source.read(catalog: catalog) { [weak self] partial in
                        guard let self, self.generation == expectedGeneration, self.isCurrentUser(), !attempt.isCompleted else { return }
                        self.snapshot = partial.retainingKnownSubscriptionStatus(from: self.snapshot)
                    }
                }
                guard generation == expectedGeneration, isCurrentUser(), !Task.isCancelled else { return }
                snapshot = value.retainingKnownSubscriptionStatus(from: snapshot)
                lastRefreshFailed = false
                message = value.hasUnverifiedTransactions ? "Some purchases could not be verified. Try Restore Purchases." : nil
            } while pendingRefresh
        } catch {
            guard generation == expectedGeneration, isCurrentUser(), !Task.isCancelled else { return }
            lastRefreshFailed = true
            message = restore ? "Purchases could not be restored. Check your App Store account and try again." : "Purchase status could not be checked. Try Restore Purchases."
        }
    }
}

/// Resume the caller without awaiting a cancelled, non-cooperative system API.
/// Late results only complete this attempt once; they cannot replace a new read.
@MainActor
private final class StoreKitReadAttempt<Value: Sendable> {
    private enum Failure: Error { case timedOut }
    private var continuation: CheckedContinuation<Result<Value, any Error>, Never>?
    private var operation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private(set) var isCompleted = false

    func run(timeout: Duration?, body: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let result: Result<Value, any Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !isCompleted else { continuation.resume(returning: .failure(CancellationError())); return }
                self.continuation = continuation
                operation = Task {
                    do { complete(.success(try await body())) }
                    catch { complete(.failure(error)) }
                }
                if let timeout {
                    deadline = Task {
                        do { try await Task.sleep(for: timeout); complete(.failure(Failure.timedOut)) }
                        catch { /* Completion cancelled the deadline. */ }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
        return try result.get()
    }
    func cancel() { complete(.failure(CancellationError())) }
    private func complete(_ result: Result<Value, any Error>) {
        guard !isCompleted else { return }
        isCompleted = true
        let waiting = continuation
        continuation = nil
        operation?.cancel(); operation = nil
        deadline?.cancel(); deadline = nil
        waiting?.resume(returning: result)
    }
}
