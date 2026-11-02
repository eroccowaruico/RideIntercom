import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct ContactInvitationPersistenceTests {
    @MainActor private final class DiskStore: GroupStoring {
        private let directory: URL
        private let file: FileGroupStore
        var failSaving = false
        init() {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("RideComContactTest-" + UUID().uuidString)
            file = FileGroupStore(directory: directory)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try! file.commit(GroupSnapshot())
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        var snapshot: GroupSnapshot {
            get { try! file.read()! }
            set { try! file.commit(newValue) }
        }
        func read() throws -> GroupSnapshot? { try file.read() }
        func commit(_ snapshot: GroupSnapshot) throws {
            if failSaving { throw IntercomGroupError.storageUnavailable }
            try file.commit(snapshot)
        }
        func lock() throws { try file.lock() }
        func unlock() { file.unlock() }
        func archive(legacyData: Data?) throws { try file.archive(legacyData: legacyData) }
    }

    @MainActor private final class Fixture {
        let memberID: String
        let store = DiskStore()
        let credentials = InMemoryGroupCredentialStore()
        let account = AppTestSupport.signedInAccount()
        let authority = testInvitationAuthority()
        init(_ memberID: String) { self.memberID = memberID }
        func make() -> (AppTestSupport.Harness, RecordingCallSession) {
            let harness = AppTestSupport.makeHarness(accountSession: account, groups: [],
                groupRepository: GroupRepository(store: store, credentials: credentials),
                credentialStore: credentials, invitationAuthority: authority, localMemberID: memberID)
            let contact = RecordingCallSession()
            harness.viewModel.contactSessionFactory = { contact }
            return (harness, contact)
        }
    }

    @Test func oneContactInvitationSurvivesRestartAndCommitsBothUsersWithoutOrdinaryGroups() throws {
        let author = Fixture("persist-author"), friend = Fixture("persist-friend")
        let (a0, _) = author.make()
        let url = try #require(a0.viewModel.makeContactInviteURL())
        let token = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        let id = try #require(token.directInvitation).context.id
        #expect(a0.viewModel.savedRemoteUsers.isEmpty)
        #expect(a0.viewModel.groups.isEmpty)
        #expect(a0.viewModel.pendingContactInvitations.map(\.id) == [id])
        let manifest = String(decoding: try author.store.snapshot.encoded(), as: UTF8.self)
        #expect(!manifest.contains(token.groupSecret))
        #expect(!manifest.contains(try #require(token.directInvitation).secret))
        #expect(!manifest.contains(url.absoluteString))
        a0.viewModel.stopContactInvitationSession()

        let (a, authorTransport) = author.make()
        #expect(a.viewModel.pendingContactInvitations.map(\.id) == [id])
        let (b0, _) = friend.make()
        try b0.viewModel.acceptContactInviteURL(url)
        #expect(b0.viewModel.savedRemoteUsers.map(\.memberIDs) == [["persist-author"]])
        #expect(b0.viewModel.groups.isEmpty)
        b0.viewModel.stopContactInvitationSession()
        let (b, friendTransport) = friend.make()
        #expect(b.viewModel.savedRemoteUsers.map(\.memberIDs) == [["persist-author"]])
        #expect(b.viewModel.pendingContactInvitations.map(\.id) == [id])
        #expect(a.viewModel.resumeContactInvitation(id))
        #expect(b.viewModel.resumeContactInvitation(id))
        defer { a.viewModel.stopContactInvitationSession(); b.viewModel.stopContactInvitationSession() }
        friendTransport.authenticate(["persist-author"])
        let receipt = try #require(friendTransport.sentApplicationDataMessages.last)
        authorTransport.authenticate(["persist-friend"])
        authorTransport.onEvent?(.receivedApplicationData(peerID: "persist-friend", message: receipt))
        #expect(a.viewModel.savedRemoteUsers.map(\.memberIDs) == [["persist-friend"]])
        let ack = try #require(authorTransport.sentApplicationDataMessages.last)
        friendTransport.onEvent?(.receivedApplicationData(peerID: "persist-author", message: ack))
        a.viewModel.stopContactInvitationSession(); b.viewModel.stopContactInvitationSession()
        let (reloadedA, _) = author.make(), (reloadedB, _) = friend.make()
        #expect(reloadedA.viewModel.savedRemoteUsers.map(\.memberIDs) == [["persist-friend"]])
        #expect(reloadedB.viewModel.savedRemoteUsers.map(\.memberIDs) == [["persist-author"]])
        #expect(reloadedB.viewModel.pendingContactInvitations.isEmpty)
        #expect(reloadedA.viewModel.groups.isEmpty && reloadedB.viewModel.groups.isEmpty)
        #expect(a.callSession.connectedGroup == nil && b.callSession.connectedGroup == nil)
        #expect(authorTransport.startMediaCallCount == 0 && friendTransport.startMediaCallCount == 0)
    }

    @Test func failedAcceptanceCannotCommitAUserWithoutItsPendingNotification() throws {
        let author = Fixture("atomic-author"), friend = Fixture("atomic-friend")
        let (a, _) = author.make(), (b, _) = friend.make()
        defer { a.viewModel.stopContactInvitationSession(); b.viewModel.stopContactInvitationSession() }
        let url = try #require(a.viewModel.makeContactInviteURL())
        friend.store.failSaving = true
        #expect(throws: (any Error).self) { try b.viewModel.acceptContactInviteURL(url) }
        #expect(friend.store.snapshot.users.isEmpty)
        friend.store.failSaving = false
        let (reloaded, _) = friend.make()
        #expect(reloaded.viewModel.savedRemoteUsers.isEmpty)
        #expect(reloaded.viewModel.pendingContactInvitations.isEmpty)
    }

    @Test func cancelledInvitationCannotRecreateAnExplicitlyRemovedUser() throws {
        let author = Fixture("cancel-author"), friend = Fixture("cancel-friend")
        let (a, _) = author.make(), (b, _) = friend.make()
        defer { a.viewModel.stopContactInvitationSession(); b.viewModel.stopContactInvitationSession() }
        let url = try #require(a.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        try b.viewModel.acceptContactInviteURL(url)
        let user = try #require(b.viewModel.savedRemoteUsers.first)
        #expect(b.viewModel.removeSavedUser(user.id))
        try b.viewModel.cancelContactInvitation(id)
        let (reloaded, _) = friend.make()
        #expect(!reloaded.viewModel.resumeContactInvitation(id))
        #expect(throws: (any Error).self) { try reloaded.viewModel.acceptContactInviteURL(url) }
        #expect(reloaded.viewModel.savedRemoteUsers.isEmpty)
        #expect(friend.credentials.values.isEmpty)
    }

    @Test func contactWaitingDoesNotTakeOverARegularCall() throws {
        let group = try IntercomGroup(name: "Current Group", members: [.init(id: "call-author", displayName: "Author")], accessSecret: "existing-call-key")
        let harness = AppTestSupport.makeHarness(groups: [group], localMemberID: "call-author")
        let vm = harness.viewModel
        let contact = RecordingCallSession()
        vm.contactSessionFactory = { contact }
        defer { vm.stopContactInvitationSession(); vm.disconnect() }
        vm.selectGroup(group)
        #expect(harness.callSession.connectedGroup?.id == group.id)
        let disconnects = harness.callSession.disconnectCallCount
        let url = try #require(vm.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        #expect(!vm.resumeContactInvitation(id))
        #expect(harness.callSession.connectedGroup?.id == group.id)
        #expect(harness.callSession.disconnectCallCount == disconnects)
        #expect(contact.connectedGroup == nil)
        #expect(vm.pendingContactInvitations.map(\.id) == [id])
    }

    @Test func schemaEightUpgradesAndOrdinarySnapshotUpdatesKeepPendingUntilReset() throws {
        let fixture = Fixture("schema-author")
        fixture.store.snapshot.version = 8
        let (h, _) = fixture.make()
        defer { h.viewModel.stopContactInvitationSession() }
        #expect(fixture.store.snapshot.version == 9)
        let url = try #require(h.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        try h.viewModel.groupRepository.save([])
        let (reloaded, _) = fixture.make()
        #expect(reloaded.viewModel.pendingContactInvitations.map(\.id) == [id])
        #expect(!fixture.credentials.values.isEmpty)
        try reloaded.viewModel.groupRepository.reset()
        #expect(reloaded.viewModel.pendingContactInvitations.isEmpty)
        #expect(fixture.credentials.values.isEmpty)
    }
    @Test func boundedNotificationAttemptStopsTransportAndKeepsDurableRetry() async throws {
        let fixture = Fixture("bounded-author")
        let (h, contact) = fixture.make()
        h.viewModel.contactNotificationAttemptDuration = .milliseconds(20)
        defer { h.viewModel.stopContactInvitationSession() }
        let url = try #require(h.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        #expect(contact.connectedGroup != nil)
        await AppTestSupport.waitUntil(timeout: .seconds(1)) { contact.connectedGroup == nil }
        #expect(contact.connectedGroup == nil)
        #expect(h.viewModel.pendingContactInvitations.map(\.id) == [id])
        #expect(h.viewModel.resumeContactInvitation(id))
        #expect(contact.connectedGroup != nil)
        #expect(h.callSession.connectedGroup == nil)
    }

    @Test func senderCancellationAndLateNotificationCannotRestoreARemovedUser() throws {
        let author = Fixture("sender-cancel-author"), friend = Fixture("sender-cancel-friend")
        let (a, transport) = author.make(), (b, friendTransport) = friend.make()
        defer { a.viewModel.stopContactInvitationSession(); b.viewModel.stopContactInvitationSession() }
        let url = try #require(a.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        try b.viewModel.acceptContactInviteURL(url)
        friendTransport.authenticate(["sender-cancel-author"])
        let receipt = try #require(friendTransport.sentApplicationDataMessages.last)
        transport.authenticate(["sender-cancel-friend"])
        let handler = try #require(transport.onEvent)
        handler(.receivedApplicationData(peerID: "sender-cancel-friend", message: receipt))
        let saved = try #require(a.viewModel.savedRemoteUsers.first)
        #expect(a.viewModel.removeSavedUser(saved.id))
        try a.viewModel.cancelContactInvitation(id)
        handler(.receivedApplicationData(peerID: "sender-cancel-friend", message: receipt))
        let (reloaded, _) = author.make()
        #expect(!reloaded.viewModel.resumeContactInvitation(id))
        #expect(reloaded.viewModel.savedRemoteUsers.isEmpty)
        #expect(author.credentials.values.isEmpty)
    }

    @Test func ordinaryCallStartAndSignOutStopContactTransportWithoutErasingPending() throws {
        let group = try IntercomGroup(name: "Current Group", members: [.init(id: "lifecycle-author", displayName: "Author")], accessSecret: "ordinary-key")
        let h = AppTestSupport.makeHarness(groups: [group], localMemberID: "lifecycle-author")
        let contact = RecordingCallSession()
        h.viewModel.contactSessionFactory = { contact }
        defer { h.viewModel.stopContactInvitationSession(); h.viewModel.disconnect() }
        let url = try #require(h.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        #expect(contact.connectedGroup != nil)
        h.viewModel.selectGroup(group)
        #expect(contact.connectedGroup == nil)
        #expect(h.callSession.connectedGroup?.id == group.id)
        #expect(h.viewModel.pendingContactInvitations.map(\.id) == [id])
        h.viewModel.disconnect()
        #expect(h.viewModel.resumeContactInvitation(id))
        #expect(contact.connectedGroup != nil)
        h.viewModel.accountSession.signOut()
        #expect(contact.connectedGroup == nil)
        #expect(!h.viewModel.resumeContactInvitation(id))
        #expect(h.groupStore.snapshot.users.isEmpty)
    }

    @Test func actualSchemaEightBytesDecodeWithoutContactFieldAndSchemaNineRequiresIt() throws {
        var old = GroupSnapshot()
        old.version = 8
        var json = try #require(JSONSerialization.jsonObject(with: old.encoded()) as? [String: Any])
        json.removeValue(forKey: "contactInvitations")
        let legacy = try GroupSnapshot.decode(JSONSerialization.data(withJSONObject: json))
        let upgraded = legacy.upgraded()
        #expect(upgraded.version == 9)
        #expect(upgraded.contactInvitations.isEmpty)
        json["version"] = 9
        #expect(throws: (any Error).self) { try GroupSnapshot.decode(JSONSerialization.data(withJSONObject: json)) }
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeVMNotificationCommitsBothUsersAndSurvivesDiskReload() async throws {
        let suffix = String(UUID().uuidString.prefix(8))
        let authorID = "native-vm-author-" + suffix, friendID = "native-vm-friend-" + suffix
        let author = Fixture(authorID), friend = Fixture(friendID)
        let (a, _) = author.make(), (b, _) = friend.make()
        a.viewModel.contactSessionFactory = { RideIntercomCallSessionAdapter(memberID: authorID) }
        b.viewModel.contactSessionFactory = { RideIntercomCallSessionAdapter(memberID: friendID) }
        a.viewModel.enabledRTCTransportRoutes = [.multipeer]
        b.viewModel.enabledRTCTransportRoutes = [.multipeer]
        defer { a.viewModel.stopContactInvitationSession(); b.viewModel.stopContactInvitationSession() }
        let url = try #require(a.viewModel.makeContactInviteURL())
        #expect(a.viewModel.savedRemoteUsers.isEmpty)
        #expect(b.viewModel.previewContactInvitation(url))
        #expect(b.viewModel.savedRemoteUsers.isEmpty)
        #expect(b.viewModel.acceptPresentedContactInvitation())
        #expect(b.viewModel.savedRemoteUsers.map(\.memberIDs) == [[authorID]])
        let deadline = ContinuousClock.now + .seconds(10)
        while (a.viewModel.savedRemoteUsers.isEmpty || !b.viewModel.pendingContactInvitations.isEmpty), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(a.viewModel.savedRemoteUsers.map(\.memberIDs) == [[friendID]], "Actual RTC acceptance notification reaches the author's atomic registration")
        #expect(b.viewModel.pendingContactInvitations.isEmpty, "Actual acknowledgement completes the recipient's durable notification")
        #expect(b.viewModel.contactInvitationID == nil)
        #expect(a.callSession.connectedGroup == nil && b.callSession.connectedGroup == nil)
        #expect(a.callSession.startMediaCallCount == 0 && b.callSession.startMediaCallCount == 0)
        a.viewModel.stopContactInvitationSession(); b.viewModel.stopContactInvitationSession()
        let (reloadedA, _) = author.make(), (reloadedB, _) = friend.make()
        #expect(reloadedA.viewModel.savedRemoteUsers.map(\.memberIDs) == [[friendID]])
        #expect(reloadedB.viewModel.savedRemoteUsers.map(\.memberIDs) == [[authorID]])
        #expect(reloadedA.viewModel.groups.isEmpty && reloadedB.viewModel.groups.isEmpty)
        #expect(reloadedB.viewModel.pendingContactInvitations.isEmpty)
    }

}
