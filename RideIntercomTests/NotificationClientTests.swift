import CryptoKit
import Foundation
import RTC
import Testing
import UserNotifications
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct NotificationClientTests {
    let origin = URL(string: "https://notify.test")!
    let token = "ri1." + String(repeating: "a", count: 64) + ".00000000-0000-0000-0000-000000000001." + String(repeating: "b", count: 64)
    let userID = String(repeating: "c", count: 64)

    @Test func deviceRegistrationAndRemovalUseOnlyNativeNotificationFields() async throws {
        let client = makeClient()
        NotificationHTTPStub.response = "{\"registered\":true}"
        try await client.registerNotificationDevice(origin: origin, token: token, deviceToken: Data([0, 255, 8]), environment: "sandbox", topic: "fixture.app")
        var request = try #require(NotificationHTTPStub.requests.last)
        #expect(request.httpMethod == "PUT" && request.url?.path == "/api/notifications/device")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
        let fields = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(fields == ["token": "00ff08", "environment": "sandbox", "topic": "fixture.app"])
        NotificationHTTPStub.response = "{}"
        try await client.removeNotificationDevice(origin: origin, token: token)
        request = try #require(NotificationHTTPStub.requests.last)
        #expect(request.httpMethod == "DELETE" && request.httpBody == nil)
    }

    @Test func capabilityAndCallRequestsNeverSendNamesOrGroupData() async throws {
        let client = makeClient(), grantID = UUID(), requestID = UUID()
        NotificationHTTPStub.response = "{\"grantID\":\"\(grantID)\",\"capability\":\"opaque.signed.capability\"}"
        let grant = try await client.issueNotificationGrant(origin: origin, token: token, senderUserID: userID)
        #expect(grant.grantID == grantID)
        let issue = try #require(NotificationHTTPStub.requests.last)
        #expect(try JSONSerialization.jsonObject(with: try #require(issue.httpBody)) as? [String: String] == ["senderUserID": userID])
        let expiresAt = Date().addingTimeInterval(120).timeIntervalSince1970 * 1000
        NotificationHTTPStub.response = "{\"requestID\":\"\(requestID)\",\"expiresAt\":\(expiresAt),\"status\":\"accepted\"}"
        let result = try await client.sendCallNotification(origin: origin, token: token, capability: grant.capability, requestID: requestID)
        #expect(result.status == .accepted)
        let sent = try #require(NotificationHTTPStub.requests.last)
        #expect(try JSONSerialization.jsonObject(with: try #require(sent.httpBody)) as? [String: String] == ["capability": grant.capability, "requestID": requestID.uuidString.lowercased()])
        #expect(result.status != .cancelled)
    }

    @Test func tapLookupAndCancellationUseRecipientAndRequestAndRejectExpiredServerResponses() async throws {
        let client = makeClient(), requestID = UUID()
        NotificationHTTPStub.response = "{\"requestID\":\"\(requestID)\",\"expiresAt\":\(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000),\"status\":\"accepted\",\"senderUserID\":\"\(userID)\"}"
        let result = try await client.readCallNotification(origin: origin, token: token, recipientUserID: userID, requestID: requestID)
        #expect(result.senderUserID == userID)
        #expect(NotificationHTTPStub.requests.last?.httpMethod == "GET")
        NotificationHTTPStub.response = "{}"
        try await client.cancelCallNotification(origin: origin, token: token, recipientUserID: userID, requestID: requestID)
        #expect(NotificationHTTPStub.requests.last?.httpMethod == "DELETE")
        NotificationHTTPStub.status = 410
        await #expect(throws: (any Error).self) { try await client.readCallNotification(origin: origin, token: token, recipientUserID: userID, requestID: requestID) }
    }

    @Test func malformedGrantAndUnexpectedCallStatusesAreRejected() async {
        let client = makeClient()
        NotificationHTTPStub.response = "{\"grantID\":\"\(UUID())\",\"capability\":\"\"}"
        await #expect(throws: (any Error).self) { try await client.issueNotificationGrant(origin: origin, token: token, senderUserID: userID) }
        NotificationHTTPStub.response = "{\"requestID\":\"\(UUID())\",\"expiresAt\":1,\"status\":\"delivered\"}"
        await #expect(throws: (any Error).self) { try await client.sendCallNotification(origin: origin, token: token, capability: "opaque", requestID: UUID()) }
    }

    @Test func deniedOrRetiredPermissionRequestsNeverRegisterAPNs() async throws {
        let fixture = try NotificationModelFixture(client: makeClient())
        fixture.permission = false
        await fixture.notifications.enable()
        #expect(fixture.registerCount == 0 && NotificationHTTPStub.requests.isEmpty)
        fixture.permission = true
        let gate = ManualAsyncGate(); fixture.authorizationGate = gate
        let enabling = Task { await fixture.notifications.enable() }
        await gate.waitForEntry()
        fixture.current = false; let cleanup = fixture.notifications.stop()
        await gate.release(); await enabling.value; await cleanup?.value
        #expect(fixture.registerCount == 0 && !fixture.notifications.receivesNotifications)
        fixture.remove()
    }

    @Test func explicitContactPermissionPersistsAndSignedRevocationCannotBeReplayed() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        #expect(fixture.notifications.allowsIncoming(from: fixture.user.id))
        #expect(try fixture.store.notificationPermissions().first?.receiving == grant)
        let sending = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local, revision: 1,
            grant: try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local), signer: fixture.peerSigner)
        try fixture.notifications.receivePermission(sending, peerID: "friend")
        #expect(fixture.notifications.canNotify(fixture.user.id))
        let revoked = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local, revision: 2,
            grant: nil, signer: fixture.peerSigner)
        try fixture.notifications.receivePermission(revoked, peerID: "friend")
        try fixture.notifications.receivePermission(sending, peerID: "friend")
        #expect(!fixture.notifications.canNotify(fixture.user.id))
        #expect(try fixture.store.notificationPermissions().first?.receivedRevision == 2)
    }

    @Test func unknownOrGroupOnlyContactsNeverIssueOrSendNotifications() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        #expect(!(await fixture.notifications.setIncomingAllowed(true, contactID: UUID())))
        fixture.users = [SavedUser(id: fixture.user.id, displayName: "Group only", memberIDs: ["friend"])]
        #expect(!(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id)))
        #expect(await fixture.notifications.send(to: fixture.user.id) == nil)
        #expect(NotificationHTTPStub.requests.isEmpty)
    }

    @Test func localRemovalBlocksTapBeforeServerRevocationCompletes() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        try fixture.notifications.suppressContact(fixture.user.id)
        #expect(!fixture.notifications.allowsIncoming(from: fixture.user.id))
        NotificationHTTPStub.status = 503
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().first?.receiving?.grantID == grant.grantID)
        NotificationHTTPStub.status = 200; NotificationHTTPStub.response = "{}"
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().first?.receiving == nil)
        #expect(NotificationHTTPStub.requests.last?.httpMethod == "DELETE")
    }

    @Test func tapResolvesOnlyCurrentSavedSenderAndRejectsOldAccountOrDelayedExpiry() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let requestID = UUID(), tap = CallNotificationTap(requestID: requestID, recipientID: fixture.local.userID)
        let reply = CallNotificationReply(requestID: requestID, expiresAt: fixture.now.addingTimeInterval(120).timeIntervalSince1970 * 1000,
            status: .accepted, senderUserID: fixture.peer.userID)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        #expect(await fixture.notifications.resolveTap(tap) == fixture.user.id)
        fixture.now = fixture.now.addingTimeInterval(120)
        #expect(await fixture.notifications.resolveTap(tap) == nil)
        fixture.current = false
        let previous = NotificationHTTPStub.requests.count
        #expect(await fixture.notifications.resolveTap(tap) == nil)
        #expect(NotificationHTTPStub.requests.count == previous)
    }

    @Test func delayedTapCannotAffectAStoppedLogin() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let id = UUID()
        let reply = CallNotificationReply(requestID: id, expiresAt: fixture.now.addingTimeInterval(120).timeIntervalSince1970 * 1000,
            status: .accepted, senderUserID: fixture.peer.userID)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        let resolving = Task { await fixture.notifications.resolveTap(.init(requestID: id, recipientID: fixture.local.userID)) }
        await gate.waitForEntry()
        fixture.current = false
        NotificationHTTPStub.delayGate = nil
        let cleanup = fixture.notifications.stop()
        await gate.release()
        #expect(await resolving.value == nil)
        await cleanup?.value
        #expect(!fixture.notifications.receivesNotifications)
    }

    @Test func lateDeviceRegistrationCannotMarkANewLoginReady() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        await fixture.notifications.enable()
        #expect(fixture.registerCount == 1)
        NotificationHTTPStub.response = "{\"registered\":true}"
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        let registering = Task { await fixture.notifications.receivedDeviceToken(Data([1, 2, 3]), environment: "sandbox", topic: "fixture.app") }
        await gate.waitForEntry()
        fixture.current = false; NotificationHTTPStub.delayGate = nil
        let cleanup = fixture.notifications.stop()
        await gate.release(); await registering.value; await cleanup?.value
        #expect(!fixture.notifications.receivesNotifications)
    }

    @Test func notificationTapUsesCommonCallActionButArrivalDoesNotStartAudio() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let h = notificationHarness(fixture); defer { h.viewModel.disconnect() }
        let owner = AppCallOwner(account: h.viewModel.accountSession, viewModel: h.viewModel)
        #expect(h.callSession.connectedGroup == nil)
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let id = UUID()
        let reply = CallNotificationReply(requestID: id, expiresAt: fixture.now.addingTimeInterval(120).timeIntervalSince1970 * 1000,
            status: .accepted, senderUserID: fixture.peer.userID)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        owner.notificationBridge.bind(to: owner)
        #expect(await owner.notificationBridge.respond(to: .init(requestID: id, recipientID: fixture.local.userID),
            actionIdentifier: UNNotificationDefaultActionIdentifier, categoryIdentifier: ""))
        #expect(h.callSession.connectedGroup?.kind == .direct && h.viewModel.activeGroupID != nil)
        #expect(owner.callPresentationID != nil)
    }

    @Test func delayedNotificationTapCannotStartAfterTheAppChangesItsModel() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let h = notificationHarness(fixture); defer { h.viewModel.disconnect() }
        let owner = AppCallOwner(account: h.viewModel.accountSession, viewModel: h.viewModel)
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let id = UUID()
        let reply = CallNotificationReply(requestID: id, expiresAt: fixture.now.addingTimeInterval(120).timeIntervalSince1970 * 1000,
            status: .accepted, senderUserID: fixture.peer.userID)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        owner.notificationBridge.bind(to: owner)
        let responding = Task { await owner.notificationBridge.respond(to: .init(requestID: id, recipientID: fixture.local.userID),
            actionIdentifier: "RIDEINTERCOM_RESPOND_ON_IPHONE", categoryIdentifier: "RIDEINTERCOM_CALL_REQUEST") }
        await gate.waitForEntry(); owner.viewModel = nil
        await gate.release()
        #expect(!(await responding.value))
        #expect(h.callSession.connectedGroup == nil)
    }

    @Test func verifiedContactMergeKeepsPermissionAndRemovalStillRevokesTheOriginalGrant() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let merged = SavedUser(displayName: "Same verified account", memberIDs: fixture.user.memberIDs,
            deviceKeys: fixture.user.deviceKeys, principal: fixture.peer)
        fixture.users = [merged]
        #expect(fixture.notifications.allowsIncoming(from: merged.id))
        NotificationHTTPStub.response = "{}"
        #expect(await fixture.notifications.setIncomingAllowed(false, contactID: merged.id))
        #expect(!fixture.notifications.allowsIncoming(from: merged.id))
        #expect(NotificationHTTPStub.requests.last?.url?.path == "/api/notifications/grants/" + grant.grantID.uuidString.lowercased())
    }

    @Test func unreadablePermissionsArePreservedAndCanBeCheckedAgain() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        try fixture.keychain.saveSecret("unreadable permissions", service: fixture.namespace + ".InternetConnection", account: "notification-permissions")
        #expect(!fixture.notifications.canUseNotifications)
        #expect(try fixture.keychain.secret(service: fixture.namespace + ".InternetConnection", account: "notification-permissions") == "unreadable permissions")
        try fixture.keychain.saveSecret("[]", service: fixture.namespace + ".InternetConnection", account: "notification-permissions")
        await fixture.notifications.refresh()
        #expect(fixture.notifications.canUseNotifications)
        #expect(NotificationHTTPStub.requests.isEmpty)
    }

    @Test func missingServiceCredentialsStillAllowLocalDisableAndUnregister() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        await fixture.notifications.enable()
        #expect(fixture.notifications.isEnabled && fixture.registerCount == 1)
        _ = try fixture.store.retireAppleCredential()
        #expect(!fixture.notifications.canRegisterNotifications)
        await fixture.notifications.disable()
        #expect(!fixture.notifications.isEnabled && !fixture.notifications.receivesNotifications)
        #expect(fixture.store.notificationRemovalPending && fixture.unregisterCount == 1)
        #expect(!fixture.notifications.canReceive(.init(requestID: UUID(), recipientID: fixture.local.userID)))
        #expect(NotificationHTTPStub.requests.isEmpty)
    }

    @Test func disabledDeviceRejectsTapsAndRetriesFailedServerRemoval() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        NotificationHTTPStub.status = 503
        await fixture.notifications.disable()
        #expect(!fixture.notifications.isEnabled && fixture.store.notificationRemovalPending)
        let previous = NotificationHTTPStub.requests.count
        #expect(await fixture.notifications.resolveTap(.init(requestID: UUID(), recipientID: fixture.local.userID)) == nil)
        #expect(NotificationHTTPStub.requests.count == previous)
        NotificationHTTPStub.status = 200; NotificationHTTPStub.response = "{}"
        await fixture.notifications.refresh()
        #expect(NotificationHTTPStub.requests.count == previous + 1)
        #expect(NotificationHTTPStub.requests.last?.httpMethod == "DELETE")
        #expect(!fixture.store.notificationRemovalPending && !fixture.notifications.receivesNotifications)
    }

    @Test func disablingDuringAPutRemovesTheDeviceAfterThatPutFinishes() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        await fixture.notifications.enable()
        NotificationHTTPStub.response = "{\"registered\":true}"
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        let registering = Task { await fixture.notifications.receivedDeviceToken(Data([1]), environment: "sandbox", topic: "fixture.app") }
        await gate.waitForEntry()
        let disabling = Task { await fixture.notifications.disable() }
        for _ in 0..<100 where fixture.notifications.isEnabled { await Task.yield() }
        #expect(!fixture.notifications.isEnabled)
        #expect(NotificationHTTPStub.requests.filter { $0.httpMethod == "DELETE" }.isEmpty)
        NotificationHTTPStub.delayGate = nil; NotificationHTTPStub.response = "{}"
        await gate.release(); await registering.value; await disabling.value
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["PUT", "DELETE"])
        #expect(!fixture.notifications.receivesNotifications && !fixture.store.notificationRemovalPending)
    }

    @Test func reenablingBeforeAnOldCleanupCannotDeleteTheNewRegistration() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        await fixture.notifications.enable()
        NotificationHTTPStub.response = "{\"registered\":true}"
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        let old = Task { await fixture.notifications.receivedDeviceToken(Data([1]), environment: "sandbox", topic: "fixture.app") }
        await gate.waitForEntry()
        let disabling = Task { await fixture.notifications.disable() }
        for _ in 0..<100 where fixture.notifications.isEnabled { await Task.yield() }
        await fixture.notifications.enable()
        NotificationHTTPStub.delayGate = nil
        let fresh = Task { await fixture.notifications.receivedDeviceToken(Data([2]), environment: "sandbox", topic: "fixture.app") }
        await gate.release(); await old.value; await disabling.value; await fresh.value
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["PUT", "PUT"])
        #expect(fixture.notifications.receivesNotifications && fixture.notifications.isEnabled)
        #expect(!fixture.store.notificationRemovalPending)
    }

    @Test func foregroundSuppressionSharesTheCurrentRecipientAndOnBoundaryWithTap() throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let tap = CallNotificationTap(requestID: UUID(), recipientID: fixture.local.userID)
        #expect(!fixture.notifications.canReceive(tap))
        fixture.store.notificationRegistrationEnabled = true
        #expect(fixture.notifications.canReceive(tap))
        #expect(!fixture.notifications.canReceive(.init(requestID: tap.requestID, recipientID: fixture.peer.userID)))
        fixture.current = false
        #expect(!fixture.notifications.canReceive(tap))
        #expect(NotificationHTTPStub.requests.isEmpty)
    }

    @Test func aDeleteAlreadyInFlightFinishesBeforeANewRegistration() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        await fixture.notifications.enable()
        NotificationHTTPStub.response = "{\"registered\":true}"
        await fixture.notifications.receivedDeviceToken(Data([1]), environment: "sandbox", topic: "fixture.app")
        NotificationHTTPStub.requests = []; NotificationHTTPStub.response = "{}"
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        let disabling = Task { await fixture.notifications.disable() }
        await gate.waitForEntry()
        await fixture.notifications.enable()
        NotificationHTTPStub.delayGate = nil; NotificationHTTPStub.response = "{\"registered\":true}"
        let registering = Task { await fixture.notifications.receivedDeviceToken(Data([2]), environment: "sandbox", topic: "fixture.app") }
        for _ in 0..<20 { await Task.yield() }
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["DELETE"])
        await gate.release(); await disabling.value; await registering.value
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["DELETE", "PUT"])
        #expect(fixture.notifications.receivesNotifications && !fixture.store.notificationRemovalPending)
    }

    @Test func regularGroupsNeverBroadcastOrAcceptPersonalNotificationGrants() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let h = notificationHarness(fixture); defer { h.viewModel.disconnect() }
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        #expect(h.viewModel.createTalkGroup(name: "Regular", userIDs: [fixture.user.id]))
        #expect(h.viewModel.startCall(to: .group(try #require(h.viewModel.selectedGroup).id), accountAccessID: h.viewModel.accountAccessID))
        try authenticateNotificationPeer(h, fixture: fixture)
        h.viewModel.sendNotificationPermissions()
        #expect(!h.callSession.sentApplicationDataMessages.contains { $0.namespace == CallNotificationPermissionMessage.namespace })
        let incoming = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 1, grant: try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local), signer: fixture.peerSigner)
        h.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "friend", message: .init(namespace: CallNotificationPermissionMessage.namespace,
            payload: try JSONEncoder().encode(incoming))))
        #expect(!fixture.notifications.canNotify(fixture.user.id))
    }

    @Test func onlyTheMatchingSinglePeerDirectCallExchangesNotificationPermission() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let h = notificationHarness(fixture); defer { h.viewModel.disconnect() }
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        #expect(h.viewModel.startCall(to: .user(fixture.user.id), accountAccessID: h.viewModel.accountAccessID))
        try authenticateNotificationPeer(h, fixture: fixture)
        h.viewModel.sendNotificationPermissions()
        #expect(h.callSession.sentApplicationDataMessages.contains { $0.namespace == CallNotificationPermissionMessage.namespace })
        let incoming = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 1, grant: try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local), signer: fixture.peerSigner)
        h.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "friend", message: .init(namespace: CallNotificationPermissionMessage.namespace,
            payload: try JSONEncoder().encode(incoming))))
        #expect(fixture.notifications.canNotify(fixture.user.id))
        let before = h.callSession.sentApplicationDataMessages.count
        h.viewModel.connectedPeerIDs.append("unrelated"); h.viewModel.authenticatedPeerIDs.append("unrelated")
        h.viewModel.sendNotificationPermissions()
        #expect(h.callSession.sentApplicationDataMessages.count == before)
    }

    @Test func aGrantWhoseLocalSaveFailsIsRevokedOnceInsteadOfLosingItsIdentifier() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        fixture.keychain.failWriteAccount = "notification-permissions"
        #expect(!(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id)))
        #expect(!fixture.notifications.allowsIncoming(from: fixture.user.id))
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(NotificationHTTPStub.requests.last?.url?.path == "/api/notifications/grants/" + grant.grantID.uuidString.lowercased())
    }

    @Test func aKnownSecondDeviceHasItsOwnRevisionAndCannotRevokeAnotherDevicesGrant() throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let second = try DeviceIdentitySigner(memberID: "friend-tablet", key: .init())
        fixture.users[0].memberIDs.append("friend-tablet")
        fixture.users[0].deviceKeys?["friend-tablet"] = second.publicKey
        let firstGrant = try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local)
        let secondGrant = try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local)
        let first = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 10, grant: firstGrant, signer: fixture.peerSigner)
        try fixture.notifications.receivePermission(first, peerID: "friend")
        let next = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 1, grant: secondGrant, signer: second)
        try fixture.notifications.receivePermission(next, peerID: "friend-tablet")
        #expect(try fixture.store.notificationPermissions().first?.sending == secondGrant)
        let otherDeviceRevocation = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 11, grant: nil, signer: fixture.peerSigner)
        try fixture.notifications.receivePermission(otherDeviceRevocation, peerID: "friend")
        #expect(try fixture.store.notificationPermissions().first?.sending == secondGrant)
        let revoked = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 2, grant: nil, signer: second)
        try fixture.notifications.receivePermission(revoked, peerID: "friend-tablet")
        try fixture.notifications.receivePermission(next, peerID: "friend-tablet")
        #expect(!fixture.notifications.canNotify(fixture.user.id))
    }

    @Test func aPeerCannotRedirectTheSelectedContactUsingAnotherRecipientsCapability() throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let unrelated = AccountPrincipal(issuer: fixture.peer.issuer, userID: String(repeating: "f", count: 64))
        let otherGrant = try testCallNotificationGrant(owner: unrelated, allowedSender: fixture.local)
        let wrapped = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 1, grant: otherGrant, signer: fixture.peerSigner)
        #expect(throws: (any Error).self) { try fixture.notifications.receivePermission(wrapped, peerID: "friend") }
        #expect(!fixture.notifications.canNotify(fixture.user.id) && NotificationHTTPStub.requests.isEmpty)
    }

    @Test func matchingUnverifiedClaimsStillRequireTheServersSignatureAndPermissionCheck() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let signed = try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local)
        let parts = signed.capability.split(separator: ".")
        let notServerVerified = CallNotificationGrant(grantID: signed.grantID, capability: parts[0] + "." + parts[1] + ".invalid-signature")
        let message = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 1, grant: notServerVerified, signer: fixture.peerSigner)
        try fixture.notifications.receivePermission(message, peerID: "friend")
        NotificationHTTPStub.status = 403
        #expect(await fixture.notifications.send(to: fixture.user.id) == nil)
        #expect(fixture.notifications.outgoing == nil)
        #expect(NotificationHTTPStub.requests.count == 1)
    }

    @Test func cancelledRemovedContactsReleaseAll256SlotsBeforeGrantingANewPerson() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let records = (1...256).map { number in
            CallNotificationPermission(contactID: UUID(), owner: fixture.local,
                peer: .init(issuer: fixture.local.issuer, userID: String(format: "%064x", number)), revision: UInt64(number))
        }
        try fixture.store.saveNotificationPermissions(records)
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().isEmpty)
        #expect(NotificationHTTPStub.requests.isEmpty)
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let saved = try #require(fixture.store.notificationPermissions().first)
        #expect(saved.receiving == grant && saved.revision > 256)
    }

    @Test func readdingTheSamePersonKeepsIssuedRevisionAboveThePrunedRecordAcrossReload() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let user = fixture.user
        try fixture.store.saveNotificationPermissions([.init(contactID: user.id, owner: fixture.local, peer: fixture.peer, revision: 40)])
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().count == 1) // Keep a saved contact's revocation.
        try fixture.notifications.suppressContact(user.id)
        let lastRevision = try #require(fixture.store.notificationPermissions().first?.revision)
        #expect(lastRevision > 40)
        fixture.users = []
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().isEmpty)
        fixture.users = [user]
        let restartedStore = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        let restarted = CallNotifications(store: restartedStore, memberID: "local", client: fixture.client,
            isCurrentUser: { fixture.current }, contacts: { fixture.users })
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(await restarted.setIncomingAllowed(true, contactID: user.id))
        #expect(try restartedStore.notificationPermissions().first?.revision ?? 0 > lastRevision)
    }

    @Test func failedRevocationKeepsItsGrantWhileAlreadyCancelledRemovedRowsAreReclaimed() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let pending = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        let other = AccountPrincipal(issuer: fixture.local.issuer, userID: String(repeating: "f", count: 64))
        try fixture.store.saveNotificationPermissions([
            .init(contactID: fixture.user.id, owner: fixture.local, peer: fixture.peer, receiving: pending, revision: 7),
            .init(contactID: UUID(), owner: fixture.local, peer: other, revision: 8)
        ])
        fixture.users = []; NotificationHTTPStub.status = 503
        await fixture.notifications.retryRevocations()
        let saved = try fixture.store.notificationPermissions()
        #expect(saved.count == 1 && saved.first?.receiving == pending)
        #expect(NotificationHTTPStub.requests.count == 1)
    }

    @Test(arguments: ["-1", "+1", "broken", String(UInt64.max), String(UInt64.max - 1)])
    func invalidOrExhaustedRevisionCounterDoesNotPublishOrLoseANewGrant(counter: String) async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        UserDefaults(suiteName: fixture.namespace)?.set(counter, forKey: "CallNotifications.issuedRevision")
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(!(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id)))
        #expect(try fixture.store.notificationPermissions().isEmpty)
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(NotificationHTTPStub.requests.last?.url?.lastPathComponent == grant.grantID.uuidString.lowercased())
    }

    @Test func failedCleanupSaveKeepsTheRecordInMemoryAndOnDiskForRetry() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let user = fixture.user
        try fixture.store.saveNotificationPermissions([.init(contactID: user.id, owner: fixture.local, peer: fixture.peer, revision: 400)])
        fixture.users = []; fixture.keychain.failWriteAccount = "notification-permissions"
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().first?.revision == 400)
        fixture.users = [user]
        let signer = try fixture.store.invitationSigner(memberID: "local")
        #expect(try fixture.notifications.permissionMessage(for: "friend", signer: signer)?.revision == 400)
        fixture.users = []; fixture.keychain.failWriteAccount = nil
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().isEmpty)
    }

    @Test func iphoneResponseCategoryHasOneBackgroundActionWithoutRequiringUnlock() throws {
        let category = NotificationSystem.callRequestCategory
        #expect(category.identifier == "RIDEINTERCOM_CALL_REQUEST")
        let action = try #require(category.actions.first)
        #expect(category.actions.count == 1 && action.identifier == "RIDEINTERCOM_RESPOND_ON_IPHONE")
        #expect(action.options.isEmpty)
        #expect(action.title == String(localized: "Respond on iPhone"))
    }

    @Test func backgroundResponseUsesTheCommonValidatedTapAndRejectsUnknownDismissAndWrongCategory() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let h = notificationHarness(fixture); defer { h.viewModel.disconnect() }
        let owner = AppCallOwner(account: h.viewModel.accountSession, viewModel: h.viewModel)
        owner.notificationBridge.bind(to: owner)
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let id = UUID(), tap = CallNotificationTap(requestID: id, recipientID: fixture.local.userID)
        let before = NotificationHTTPStub.requests.count
        for action in ["unrecognized", UNNotificationDismissActionIdentifier] {
            #expect(!(await owner.notificationBridge.respond(to: tap, actionIdentifier: action, categoryIdentifier: "RIDEINTERCOM_CALL_REQUEST")))
        }
        #expect(!(await owner.notificationBridge.respond(to: tap, actionIdentifier: "RIDEINTERCOM_RESPOND_ON_IPHONE", categoryIdentifier: "other")))
        #expect(NotificationHTTPStub.requests.count == before && h.callSession.connectedGroup == nil)
        let reply = CallNotificationReply(requestID: id, expiresAt: fixture.now.addingTimeInterval(120).timeIntervalSince1970 * 1000,
            status: .accepted, senderUserID: fixture.peer.userID)
        NotificationHTTPStub.response = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        #expect(await owner.notificationBridge.respond(to: tap, actionIdentifier: "RIDEINTERCOM_RESPOND_ON_IPHONE", categoryIdentifier: "RIDEINTERCOM_CALL_REQUEST"))
        #expect(h.callSession.connectedGroup?.kind == .direct)
        #expect(h.viewModel.createTalkGroup(name: "Another call"))
        let groupID = try #require(h.viewModel.regularGroups.first?.id)
        #expect(h.viewModel.startCall(to: .group(groupID), accountAccessID: h.viewModel.accountAccessID, allowSwitchingCall: true))
        let current = h.viewModel.currentCallReference
        #expect(!(await owner.notificationBridge.respond(to: tap, actionIdentifier: "RIDEINTERCOM_RESPOND_ON_IPHONE", categoryIdentifier: "RIDEINTERCOM_CALL_REQUEST")))
        #expect(h.viewModel.currentCallReference == current)
    }

    @Test func watchProjectsOnlySavedPeoplesPermissionAndRequestsWithoutStartingAudioThenCancelsOnlyCurrentRequest() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let h = notificationHarness(fixture); defer { h.viewModel.disconnect() }
        let owner = AppCallOwner(account: h.viewModel.accountSession, viewModel: h.viewModel)
        #expect(owner.watchSnapshot().targets.first?.canNotify == false)
        let grant = try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local)
        try fixture.notifications.receivePermission(.make(owner: fixture.peer, allowedSender: fixture.local, revision: 1,
            grant: grant, signer: fixture.peerSigner), peerID: "friend")
        let snapshot = owner.watchSnapshot(), target = try #require(snapshot.targets.first)
        #expect(target.canNotify)
        NotificationHTTPStub.echoCallStatus = .accepted
        let sent = await owner.handleWatchRequest(.init(.requestCall(target.id), snapshot: snapshot))
        let first = try #require(sent.snapshot.notification)
        #expect(sent.problem == nil && first.status == .accepted && first.canCancel)
        #expect(h.callSession.connectedGroup == nil && !sent.snapshot.hasCall)
        #expect(!String(decoding: try JSONEncoder().encode(sent), as: UTF8.self).contains(grant.capability))
        let second = await owner.handleWatchRequest(.init(.requestCall(target.id), snapshot: sent.snapshot))
        let current = try #require(second.snapshot.notification)
        #expect(first.requestID != current.requestID)
        let count = NotificationHTTPStub.requests.count
        #expect(await owner.handleWatchRequest(.init(.cancelCallRequest(first.requestID), snapshot: second.snapshot)).problem == .stale)
        #expect(NotificationHTTPStub.requests.count == count)
        let cancelled = await owner.handleWatchRequest(.init(.cancelCallRequest(current.requestID), snapshot: second.snapshot))
        #expect(cancelled.problem == nil && cancelled.snapshot.notification == nil)
        #expect(NotificationHTTPStub.requests.last?.httpMethod == "DELETE")
    }

    @Test func watchRejectsGroupsMissingRevokedAndExpiredNotificationTargetsBeforeSending() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let h = notificationHarness(fixture); defer { h.viewModel.disconnect() }
        let owner = AppCallOwner(account: h.viewModel.accountSession, viewModel: h.viewModel)
        #expect(h.viewModel.createTalkGroup(name: "Existing group"))
        let snapshot = owner.watchSnapshot(), person = try #require(snapshot.targets.first { $0.id.contains("|user|") })
        let group = try #require(snapshot.targets.first { $0.id.contains("|group|") })
        #expect(!group.canNotify)
        #expect(await owner.handleWatchRequest(.init(.requestCall(group.id), snapshot: snapshot)).problem == .denied)
        #expect(await owner.handleWatchRequest(.init(.requestCall(person.id), snapshot: snapshot)).problem == .denied)
        #expect(await owner.handleWatchRequest(.init(.requestCall("missing"), snapshot: snapshot)).problem == .missingDestination)
        #expect(await owner.handleWatchRequest(.init(.requestCall(person.id), snapshot: snapshot), now: snapshot.validUntil).problem == .stale)
        try fixture.notifications.receivePermission(.make(owner: fixture.peer, allowedSender: fixture.local, revision: 1,
            grant: try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local), signer: fixture.peerSigner), peerID: "friend")
        let permitted = owner.watchSnapshot()
        #expect(permitted.targets.first { $0.id == person.id }?.canNotify == true)
        try fixture.notifications.receivePermission(.make(owner: fixture.peer, allowedSender: fixture.local, revision: 2,
            grant: nil, signer: fixture.peerSigner), peerID: "friend")
        #expect(await owner.handleWatchRequest(.init(.requestCall(person.id), snapshot: permitted)).problem == .denied)
        // Remove the saved destination through storage without scheduling an unrelated
        // revocation Task beyond this fixture's lifetime.
        try h.viewModel.groupRepository.removeUser(fixture.user.id)
        h.viewModel.refreshGroupStorageStatus(); fixture.users = []
        #expect(await owner.handleWatchRequest(.init(.requestCall(person.id), snapshot: snapshot)).problem == .missingDestination)
        #expect(NotificationHTTPStub.requests.isEmpty)
    }

    @Test func delayedWatchNotificationReplyCannotRestoreAnOldAccount() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let h = notificationHarness(fixture); defer { h.viewModel.disconnect() }
        let owner = AppCallOwner(account: h.viewModel.accountSession, viewModel: h.viewModel)
        try fixture.notifications.receivePermission(.make(owner: fixture.peer, allowedSender: fixture.local, revision: 1,
            grant: try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local), signer: fixture.peerSigner), peerID: "friend")
        let snapshot = owner.watchSnapshot(), target = try #require(snapshot.targets.first)
        NotificationHTTPStub.echoCallStatus = .accepted
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        let task = Task { await owner.handleWatchRequest(.init(.requestCall(target.id), snapshot: snapshot)) }
        await gate.waitForEntry(); fixture.current = false; owner.viewModel = nil
        let cleanup = fixture.notifications.stop()
        NotificationHTTPStub.delayGate = nil; await gate.release()
        let reply = await task.value; await cleanup?.value
        #expect(reply.problem == .noAccount && reply.snapshot.reference == nil && reply.snapshot.notification == nil)
        #expect(fixture.notifications.outgoing == nil && h.callSession.connectedGroup == nil)
    }

    private func authenticateNotificationPeer(_ h: AppTestSupport.Harness, fixture: NotificationModelFixture) throws {
        h.callSession.authenticate(["friend"])
        let profile = try testPeerProfile(h.viewModel, peerID: "friend", displayName: "Friend", signer: fixture.peerSigner)
        h.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "friend", message: .init(namespace: SharedDisplayName.namespace,
            payload: try JSONEncoder().encode(profile))))
        #expect(h.viewModel.peerProfiles["friend"]?.verified != nil)
    }

    private func notificationHarness(_ fixture: NotificationModelFixture) -> AppTestSupport.Harness {
        let groups = InMemoryGroupStore(groups: [])
        groups.snapshot.users = fixture.users
        let h = AppTestSupport.makeHarness(groups: [], groupStore: groups, internetSettingsStore: fixture.store, localMemberID: "local")
        h.viewModel.notifications = fixture.notifications
        return h
    }

    private func makeClient() -> InternetAccountClient {
        NotificationHTTPStub.requests = []; NotificationHTTPStub.status = 200; NotificationHTTPStub.delayGate = nil; NotificationHTTPStub.echoCallStatus = nil
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [NotificationHTTPStub.self]
        return InternetAccountClient(session: URLSession(configuration: configuration))
    }
}

private final class NotificationHTTPStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var response = "{}"
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var delayGate: ManualAsyncGate?
    nonisolated(unsafe) static var echoCallStatus: CallNotificationStatus?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "notify.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.requests.append(captured)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let data: Data
        if let status = Self.echoCallStatus, captured.httpMethod == "POST", captured.url?.path == "/api/notifications/calls",
           let body = captured.httpBody, let fields = try? JSONSerialization.jsonObject(with: body) as? [String: String],
           let id = fields["requestID"] {
            data = try! JSONSerialization.data(withJSONObject: ["requestID": id, "status": status.rawValue,
                "expiresAt": Date().addingTimeInterval(120).timeIntervalSince1970 * 1000])
        } else { data = Data(Self.response.utf8) }
        let gate = Self.delayGate
        Task { @MainActor [self] in
            if let gate { await gate.wait() }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor
private final class NotificationModelFixture {
    let namespace = "RideIntercom.NotificationTest." + UUID().uuidString
    let keychain = DictionaryKeychain()
    let store: InternetConnectionSettingsStore
    let local = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "a", count: 64))
    let peer = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "c", count: 64))
    let peerSigner = try! DeviceIdentitySigner(memberID: "friend", key: .init())
    let client: InternetAccountClient
    var current = true, permission = true, registerCount = 0, unregisterCount = 0
    var authorizationGate: ManualAsyncGate?
    var users: [SavedUser] = []
    var now = Date()
    var user: SavedUser { users[0] }
    lazy var notifications = CallNotifications(store: store, memberID: "local", client: client,
        isCurrentUser: { [unowned self] in current }, contacts: { [unowned self] in users },
        requestAuthorization: { [unowned self] in if let authorizationGate { await authorizationGate.wait() }; return permission },
        authorizationGranted: { [unowned self] in permission }, register: { [unowned self] in registerCount += 1 },
        unregister: { [unowned self] in unregisterCount += 1 }, now: { [unowned self] in now })
    init(client: InternetAccountClient) throws {
        self.client = client
        store = InternetConnectionSettingsStore(keychain: keychain, namespace: namespace)
        let deviceID = try store.accountDeviceID()
        let key = try store.deviceSigningKey()
        let envelope = try testIdentityCertificate(userID: local.userID, deviceID: deviceID, memberID: "local",
            deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation), origin: local.issuer)
        let identity = try envelope.verify(origin: URL(string: local.issuer)!, trustedIssuerKey: envelope.issuerKey)
        try store.save(url: local.issuer, token: "ri1." + String(repeating: "d", count: 64) + "." + deviceID + "." + String(repeating: "e", count: 64), identity: identity)
        users = [SavedUser(displayName: "Never send this name", memberIDs: ["friend"], deviceKeys: ["friend": peerSigner.publicKey], principal: peer)]
    }
    func remove() { UserDefaults(suiteName: namespace)?.removePersistentDomain(forName: namespace) }
}
