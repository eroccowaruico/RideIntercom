import AppIntents
import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct WidgetDestinationTests {
    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WidgetDestinations-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "destinations.json")
    }

    @Test func snapshotQueryReadsOnlyValidCurrentProjectionAndRecoversAfterCorruption() async throws {
        let file = try temporaryFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WidgetDestinationStore(fileURL: file)
        let item = WidgetCallDestination(id: "scope|user|\(UUID())", name: "Friend", kind: .user)
        try store.write([item])
        let query = WidgetCallDestinationQuery(store: store)
        #expect(try await query.suggestedEntities() == [item])
        #expect(try await query.entities(for: ["old"]).isEmpty)
        #expect(try await query.entities(matching: "friend") == [item])
        let renamed = WidgetCallDestination(id: item.id, name: "New name", kind: .user)
        try store.write([renamed])
        #expect(store.current(item) == renamed)
        try store.write([])
        #expect(store.current(item) == nil)
        try Data("broken".utf8).write(to: file)
        #expect(store.current(item) == nil)
        #expect(try await query.suggestedEntities().isEmpty)
        try store.write([item])
        #expect(try await query.entities(for: [item.id]) == [item])
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(Set(json.keys) == ["version", "destinations"])
        let entries = try #require(json["destinations"] as? [[String: Any]])
        #expect(Set(entries[0].keys) == ["id", "name", "kind"])
    }

    @Test func ownerPublishesCurrentSavedTargetsAndClearsAfterSignOut() async throws {
        let file = try temporaryFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WidgetDestinationStore(fileURL: file), account = AccountFixture(); defer { account.remove() }; account.signIn()
        let h = AppTestSupport.makeHarness(accountSession: account.session), vm = h.viewModel
        defer { vm.disconnect() }
        let owner = AppCallOwner(account: account.session, viewModel: vm, widgetDestinationStore: store)
        #expect(store.read().count == vm.regularGroups.count)
        let first = try #require(store.read().first)
        vm.deleteGroup(vm.regularGroups[0].id)
        await AppTestSupport.waitUntil { !store.read().contains(where: { $0.id == first.id }) }
        account.session.signOut()
        await AppTestSupport.waitUntil { store.read().isEmpty }
        #expect(store.read().isEmpty)
        account.signIn()
        #expect(owner.callTargets.isEmpty)
        #expect(throws: CallIntentError.self) { try owner.startWidgetCall(id: first.id) }
    }

    @Test func selectedIntentRechecksOwnerRejectsOldOrDeletedTargetAndDoesNotSwitchCalls() async throws {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel; defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm)
        let ids = owner.callTargets.map(\.entity.id)
        let start = OpenCallControlIntent(destinationID: ids[0]); start.actions = owner
        _ = try await start.perform()
        let reference = vm.currentCallReference
        let other = OpenCallControlIntent(destinationID: ids[1]); other.actions = owner
        await #expect(throws: CallIntentError.self) { _ = try await other.perform() }
        #expect(vm.currentCallReference == reference)
        vm.disconnect(); vm.deleteGroup(vm.groups[0].id)
        await #expect(throws: CallIntentError.self) { _ = try await start.perform() }
        let foreign = AppTestSupport.makeHarness(localMemberID: "foreign"); defer { foreign.viewModel.disconnect() }
        start.actions = AppCallOwner(account: foreign.viewModel.accountSession, viewModel: foreign.viewModel)
        await #expect(throws: CallIntentError.self) { _ = try await start.perform() }
    }

    @Test func projectionIncludesOnlySavedUsersAndDeletionPreservesActiveCallEnd() async throws {
        let file = try temporaryFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let h = AppTestSupport.makeHarness(), vm = h.viewModel; defer { vm.disconnect() }
        let store = WidgetDestinationStore(fileURL: file)
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm, widgetDestinationStore: store)
        #expect(store.read().allSatisfy { $0.kind == .group })
        let group = vm.groups[0]
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            groupID: group.id, groupName: group.name, groupSecret: "group-key", inviterMemberID: "friend")
        try vm.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        let user = try #require(vm.savedRemoteUsers.first)
        await AppTestSupport.waitUntil { store.read().contains(where: { $0.kind == .user }) }
        let selected = try #require(store.read().first(where: { $0.kind == .user }))
        #expect(store.read().filter { $0.kind == .user }.count == 1)
        vm.disconnect()
        try owner.startWidgetCall(id: selected.id)
        let reference = try #require(owner.currentLivePresentation?.reference)
        #expect(vm.removeSavedUser(user.id))
        await AppTestSupport.waitUntil { !store.read().contains(where: { $0.id == selected.id }) }
        #expect(store.current(selected) == nil)
        #expect(throws: CallIntentError.self) { try owner.startWidgetCall(id: selected.id) }
        #expect(vm.activeGroupID != nil)
        try owner.performCallSurfaceAction(.end, reference: reference)
        #expect(vm.activeGroupID == nil)
    }

    @Test func failedPublicationCanRetryAndUnchangedSuccessDoesNotReload() throws {
        let file = try temporaryFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var reloads = 0
        let publisher = WidgetDestinationPublisher(store: .init(fileURL: file), reload: { reloads += 1 })
        let item = WidgetCallDestination(id: "scope|group|\(UUID())", name: "Ride", kind: .group)
        publisher.publish([item]); publisher.publish([item])
        #expect(reloads == 1)
        try Data("broken".utf8).write(to: file)
        publisher.publish([item])
        #expect(WidgetDestinationStore(fileURL: file).read() == [item])
        #expect(reloads == 2)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        publisher.publish([])
        try? FileManager.default.removeItem(at: file)
        publisher.publish([])
        #expect(WidgetDestinationStore(fileURL: file).read().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
