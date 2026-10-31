import Foundation
import Observation

/// Account-scoped notification consent and pending requests; never starts audio.
@MainActor @Observable
final class CallNotifications {
    private(set) var receivesNotifications = false
    private(set) var isBusy = false
    private(set) var message: String?
    private(set) var outgoing: Outgoing?
    struct Outgoing { let contactID: UUID; let recipientID: String; let reply: CallNotificationReply }
    private var permissions: [CallNotificationPermission] = []
    @ObservationIgnored private let store: InternetConnectionSettingsStore
    @ObservationIgnored private let memberID: String
    @ObservationIgnored private let client: InternetAccountClient
    @ObservationIgnored private let isCurrentUser: @MainActor () -> Bool
    @ObservationIgnored private let contacts: @MainActor () -> [SavedUser]
    @ObservationIgnored private let requestAuthorization: @MainActor () async throws -> Bool
    @ObservationIgnored private let authorizationGranted: @MainActor () async -> Bool
    @ObservationIgnored private let register: @MainActor () -> Void
    @ObservationIgnored private let unregister: @MainActor () -> Void
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tokenGeneration = 0
    @ObservationIgnored private var deviceOperation: Task<Void, Never>?
    @ObservationIgnored private var deviceOperationID: UUID?
    @ObservationIgnored private var storageAvailable = true

    init(store: InternetConnectionSettingsStore, memberID: String, client: InternetAccountClient = .init(),
         isCurrentUser: @escaping @MainActor () -> Bool, contacts: @escaping @MainActor () -> [SavedUser],
         requestAuthorization: @escaping @MainActor () async throws -> Bool = NotificationSystem.requestAuthorization,
         authorizationGranted: @escaping @MainActor () async -> Bool = NotificationSystem.authorizationGranted,
         register: @escaping @MainActor () -> Void = NotificationSystem.register,
         unregister: @escaping @MainActor () -> Void = NotificationSystem.unregister, now: @escaping @MainActor () -> Date = Date.init) {
        self.store = store; self.memberID = memberID; self.client = client; self.isCurrentUser = isCurrentUser; self.contacts = contacts
        self.requestAuthorization = requestAuthorization; self.authorizationGranted = authorizationGranted
        self.register = register; self.unregister = unregister; self.now = now
        do { permissions = try store.notificationPermissions() }
        catch { storageAvailable = false; message = "Notification permissions could not be read. Your saved data has been preserved." }
    }
    var canUseNotifications: Bool { access() != nil }
    var canRegisterNotifications: Bool { serviceAccess() != nil }
    var hasPermissionsToShare: Bool {
        guard !permissions.isEmpty, let context = access() else { return false }
        return permissions.contains { record in
            record.owner == context.principal && record.revision > 0 && contacts().contains { $0.principal == record.peer }
        }
    }
    var isEnabled: Bool { store.notificationRegistrationEnabled }
    private func serviceAccess() -> CallNotificationServiceAccess? {
        guard isCurrentUser() else { return nil }
        return try? store.notificationAccess(memberID: memberID)
    }
    private func access() -> CallNotificationServiceAccess? { storageAvailable ? serviceAccess() : nil }
    private func current(_ context: CallNotificationServiceAccess, generation expected: Int) -> Bool {
        generation == expected && !Task.isCancelled && serviceAccess() == context
    }
    private func contact(_ id: UUID, context: CallNotificationServiceAccess) -> SavedUser? {
        contacts().first { $0.id == id && $0.principal?.isValid == true && $0.principal?.issuer == context.principal.issuer
            && $0.principal != context.principal && $0.deviceKeys?.isEmpty == false }
    }
    private func permission(_ id: UUID, context: CallNotificationServiceAccess) -> CallNotificationPermission? {
        guard let user = contact(id, context: context) else { return nil }
        return permissions.first { $0.owner == context.principal && $0.peer == user.principal }
    }
    private func update(_ id: UUID, context: CallNotificationServiceAccess, _ change: (inout CallNotificationPermission) -> Void) throws {
        guard let user = contact(id, context: context), let peer = user.principal else { throw DeviceIdentityProof.Failure.invalid }
        var next = permissions
        if let index = next.firstIndex(where: { $0.owner == context.principal && $0.peer == peer }) {
            next[index].contactID = id
            change(&next[index])
        } else {
            var record = CallNotificationPermission(contactID: id, owner: context.principal, peer: peer)
            change(&record); next.append(record)
        }
        try store.saveNotificationPermissions(next); permissions = next
    }
    func allowsIncoming(from id: UUID) -> Bool {
        guard let context = access(), let record = permission(id, context: context) else { return false }
        return record.allowsIncoming && record.receiving != nil
    }
    func canNotify(_ id: UUID) -> Bool {
        guard let context = access(), let record = permission(id, context: context) else { return false }
        return record.sending?.isAddressed(to: record.peer, from: context.principal) == true
    }
    func enable() async {
        guard !isBusy, let context = serviceAccess() else { return }
        let expected = generation; isBusy = true
        defer { if generation == expected { isBusy = false } }
        do {
            let granted = try await requestAuthorization()
            guard current(context, generation: expected) else { return }
            guard granted else {
                receivesNotifications = false
                if isEnabled { await disable() }
                if current(context, generation: expected), !store.notificationRemovalPending { message = "Notifications are off in system settings." }
                return
            }
            store.notificationRegistrationEnabled = true
            register()
        } catch {
            guard current(context, generation: expected) else { return }
            message = "Notification permission could not be checked. Please try again."
        }
    }
    func refresh() async {
        guard isCurrentUser() else { return }
        if !storageAvailable {
            do { permissions = try store.notificationPermissions(); storageAvailable = true; message = nil }
            catch { /* Device removal must still work with unreadable contact permissions. */ }
        }
        guard let context = serviceAccess() else { return }
        let expected = generation
        if isEnabled {
            let granted = await authorizationGranted()
            guard current(context, generation: expected) else { return }
            if granted { register() }
            else {
                await disable()
                if current(context, generation: expected), !store.notificationRemovalPending { message = "Notifications are off in system settings." }
            }
        } else if store.notificationRemovalPending {
            await removePendingDevice(context, generation: expected)
        }
        await retryRevocations()
    }
    func disable() async {
        guard isCurrentUser() else { return }
        store.notificationRegistrationEnabled = false
        store.notificationRemovalPending = true
        receivesNotifications = false; tokenGeneration += 1; unregister()
        guard let context = serviceAccess() else {
            message = "Notifications are disabled here. Server removal is pending; retry when online."
            return
        }
        await removePendingDevice(context, generation: generation)
    }
    /// Serialize only device PUT/DELETE. The latest local desire is checked at
    /// execution time, so delayed cleanup cannot overtake a new registration.
    private func performDeviceOperation(_ context: CallNotificationServiceAccess, generation expected: Int,
                                        body: @escaping @MainActor () async -> Void) async {
        let previous = deviceOperation, id = UUID()
        let task = Task {
            await previous?.value
            guard current(context, generation: expected) else { return }
            await body()
        }
        deviceOperation = task; deviceOperationID = id
        await task.value
        if deviceOperationID == id { deviceOperation = nil; deviceOperationID = nil }
    }
    private func removePendingDevice(_ context: CallNotificationServiceAccess, generation expected: Int) async {
        await performDeviceOperation(context, generation: expected) {
            guard !self.isEnabled, self.store.notificationRemovalPending else { return }
            do {
                try await self.client.removeNotificationDevice(origin: context.origin, token: context.accessToken)
                guard self.current(context, generation: expected), !self.isEnabled else { return }
                self.store.notificationRemovalPending = false; self.message = nil
            } catch {
                guard self.current(context, generation: expected), !self.isEnabled else { return }
                self.message = "Notifications are disabled here. Server removal is pending; retry when online."
            }
        }
    }
    func receivedDeviceToken(_ token: Data, environment: String, topic: String) async {
        guard isEnabled, let context = serviceAccess() else { return }
        tokenGeneration += 1
        let expectedToken = tokenGeneration, expected = generation
        await performDeviceOperation(context, generation: expected) {
            guard self.isEnabled, expectedToken == self.tokenGeneration else { return }
            do {
                try await self.client.registerNotificationDevice(origin: context.origin, token: context.accessToken, deviceToken: token, environment: environment, topic: topic)
                guard self.current(context, generation: expected), expectedToken == self.tokenGeneration, self.isEnabled else { return }
                self.store.notificationRemovalPending = false
                self.receivesNotifications = true; self.message = "Notifications are enabled on this device."
            } catch {
                guard self.current(context, generation: expected), expectedToken == self.tokenGeneration else { return }
                self.receivesNotifications = false; self.message = "Notifications could not be registered. Please try again."
            }
        }
    }
    func registrationFailed() { if isCurrentUser(), isEnabled { receivesNotifications = false; message = "Notifications could not be registered. Please try again." } }
    @discardableResult
    func stop() -> Task<Void, Never>? {
        let previous = isEnabled || store.notificationRemovalPending ? try? store.notificationAccess(memberID: memberID) : nil
        let operation = deviceOperation
        generation += 1; tokenGeneration += 1; isBusy = false; receivesNotifications = false; outgoing = nil
        deviceOperation = nil; deviceOperationID = nil
        if let previous {
            store.notificationRemovalPending = true
            return Task {
                await operation?.value
                try? await client.removeNotificationDevice(origin: previous.origin, token: previous.accessToken)
            }
        }
        return nil
    }
    @discardableResult
    func setIncomingAllowed(_ allowed: Bool, contactID: UUID) async -> Bool {
        guard !isBusy, let context = access(), contact(contactID, context: context) != nil else { return false }
        let expected = generation; isBusy = true
        defer { if generation == expected { isBusy = false } }
        do {
            if !allowed {
                let revision = try store.nextNotificationRevision(after: permission(contactID, context: context)?.revision ?? 0)
                try update(contactID, context: context) { $0.allowsIncoming = false; $0.revision = revision }
                await retryRevocations()
                return current(context, generation: expected)
            }
            if let existing = permission(contactID, context: context), !existing.allowsIncoming, let grant = existing.receiving {
                try await client.revokeNotificationGrant(origin: context.origin, token: context.accessToken, grantID: grant.grantID)
                guard current(context, generation: expected), contact(contactID, context: context) != nil else { return false }
                try update(contactID, context: context) { if $0.receiving == grant { $0.receiving = nil } }
            }
            if permission(contactID, context: context)?.receiving == nil {
                guard let peer = contact(contactID, context: context)?.principal else { return false }
                let grant = try await client.issueNotificationGrant(origin: context.origin, token: context.accessToken, senderUserID: peer.userID)
                guard current(context, generation: expected), contact(contactID, context: context) != nil else {
                    try? await client.revokeNotificationGrant(origin: context.origin, token: context.accessToken, grantID: grant.grantID)
                    return false
                }
                do {
                    let revision = try store.nextNotificationRevision(after: permission(contactID, context: context)?.revision ?? 0)
                    try update(contactID, context: context) { $0.receiving = grant; $0.allowsIncoming = true; $0.revision = revision }
                }
                catch {
                    // Never knowingly lose a newly issued, unpersisted grant.
                    try? await client.revokeNotificationGrant(origin: context.origin, token: context.accessToken, grantID: grant.grantID)
                    throw error
                }
            }
            message = "Call notification permission saved. It is shared when you connect one to one with this person."
            return true
        } catch {
            guard current(context, generation: expected) else { return false }
            message = "Notification permission could not be updated. Please try again when online."
            return false
        }
    }
    func suppressContact(_ id: UUID) throws {
        guard let context = access(), permission(id, context: context) != nil else { return }
        let revision = try store.nextNotificationRevision(after: permission(id, context: context)?.revision ?? 0)
        try update(id, context: context) { $0.allowsIncoming = false; $0.sending = nil; $0.revision = revision }
    }
    func retryRevocations() async {
        guard let context = access() else { return }
        let expected = generation
        for record in permissions where record.owner == context.principal && !record.allowsIncoming {
            guard let grant = record.receiving else { continue }
            do {
                try await client.revokeNotificationGrant(origin: context.origin, token: context.accessToken, grantID: grant.grantID)
                guard current(context, generation: expected) else { return }
                var next = permissions
                if let index = next.firstIndex(where: { $0.contactID == record.contactID && !$0.allowsIncoming && $0.receiving == grant }) {
                    next[index].receiving = nil
                    try store.saveNotificationPermissions(next); permissions = next
                }
            } catch { break } // Keep this grant and still reclaim already cancelled rows.
        }
        guard current(context, generation: expected) else { return }
        let next = permissions.filter { record in
            !(record.owner == context.principal && record.receiving == nil && !record.allowsIncoming
              && !contacts().contains(where: { $0.principal == record.peer }))
        }
        guard next.count != permissions.count else { return }
        do {
            // Keep issued revisions monotonic even after the last contact row is removed.
            try store.retainNotificationRevision(atLeast: permissions.map(\.revision).max() ?? 0)
            try store.saveNotificationPermissions(next); permissions = next
        } catch {
            // A failed write must leave the persisted records and in-memory retry state intact.
        }
    }
    func permissionMessage(for peerID: String, signer: DeviceIdentitySigner) throws -> CallNotificationPermissionMessage? {
        guard let context = access(), let user = contacts().first(where: { $0.memberIDs.contains(peerID) }),
              let record = permission(user.id, context: context), record.revision > 0 else { return nil }
        return try .make(owner: context.principal, allowedSender: record.peer, revision: record.revision,
                         grant: record.allowsIncoming ? record.receiving : nil, signer: signer)
    }
    func receivePermission(_ value: CallNotificationPermissionMessage, peerID: String) throws {
        guard let context = access(), let user = contacts().first(where: { $0.memberIDs.contains(peerID) }),
              contact(user.id, context: context) != nil else { throw DeviceIdentityProof.Failure.invalid }
        let grant = try value.verifiedGrant(peerID: peerID, savedUser: user, local: context.principal)
        guard let source = value.proof?.publicKey else { throw DeviceIdentityProof.Failure.invalid }
        let previous = permission(user.id, context: context)
        if previous?.receivedRevisionSource == source, value.revision <= (previous?.receivedRevision ?? 0) { return }
        // Each known device has its own counter. A different device's revocation
        // must not erase the currently selected device's independently issued grant.
        if grant == nil, previous?.sending != nil, let previousSource = previous?.receivedRevisionSource, previousSource != source { return }
        try update(user.id, context: context) {
            $0.sending = grant; $0.receivedRevision = value.revision; $0.receivedRevisionSource = source
        }
    }
    func send(to contactID: UUID) async -> CallNotificationReply? {
        guard !isBusy, let context = access(), let record = permission(contactID, context: context),
              let grant = record.sending, grant.isAddressed(to: record.peer, from: context.principal) else { return nil }
        let capability = grant.capability
        let expected = generation; isBusy = true
        defer { if generation == expected { isBusy = false } }
        do {
            let reply = try await client.sendCallNotification(origin: context.origin, token: context.accessToken, capability: capability, requestID: UUID())
            guard current(context, generation: expected), permission(contactID, context: context)?.sending?.capability == capability else { return nil }
            outgoing = .init(contactID: contactID, recipientID: record.peer.userID, reply: reply)
            switch reply.status {
            case .accepted: message = "Notification accepted. Delivery is not confirmed."
            case .processing: message = "The call request is being processed."
            case .noDestinations: message = "This person has no notification destination available."
            case .retryLater: message = "The call request could not be sent. Please try again later."
            case .rejected: message = "The call request was not accepted."
            case .cancelled: message = "Call request cancelled."
            }
            return reply
        } catch { if current(context, generation: expected) { message = "The call request could not be sent. Please try again later." }; return nil }
    }
    func cancelOutgoing() async {
        guard let context = access(), let outgoing else { return }
        let expected = generation
        do {
            try await client.cancelCallNotification(origin: context.origin, token: context.accessToken, recipientUserID: outgoing.recipientID, requestID: outgoing.reply.requestID)
            guard current(context, generation: expected), self.outgoing?.reply.requestID == outgoing.reply.requestID else { return }
            self.outgoing = nil; message = "Call request cancelled."
        } catch { if current(context, generation: expected) { message = "The call request could not be cancelled. Please try again." } }
    }
    func canReceive(_ tap: CallNotificationTap) -> Bool { receivingAccess(for: tap) != nil }
    private func receivingAccess(for tap: CallNotificationTap) -> CallNotificationServiceAccess? {
        guard isEnabled, let context = access(), context.principal.userID == tap.recipientID else { return nil }
        return context
    }
    func resolveTap(_ tap: CallNotificationTap) async -> UUID? {
        guard let context = receivingAccess(for: tap) else { return nil }
        let expected = generation
        do {
            let reply = try await client.readCallNotification(origin: context.origin, token: context.accessToken, recipientUserID: tap.recipientID, requestID: tap.requestID)
            guard isEnabled, current(context, generation: expected), reply.isLive(at: now()),
                  let user = contacts().first(where: { $0.principal?.userID == reply.senderUserID && $0.principal?.issuer == context.principal.issuer }),
                  allowsIncoming(from: user.id) else { return nil }
            return user.id
        } catch { if current(context, generation: expected) { message = "This call request is no longer available." }; return nil }
    }
}
