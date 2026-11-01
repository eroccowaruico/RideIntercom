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
        #expect(store.readSnapshot()?.destinations.first { $0.id == item.id } == renamed)
        try store.write([])
        #expect(store.readSnapshot()?.destinations.first { $0.id == item.id } == nil)
        try Data("broken".utf8).write(to: file)
        #expect(store.readSnapshot()?.destinations.first { $0.id == item.id } == nil)
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
        await AppTestSupport.waitUntil { store.readSnapshot()?.currentCall?.reference == reference }
        #expect(store.readSnapshot()?.currentDestinationID == selected.id)
        #expect(vm.removeSavedUser(user.id))
        await AppTestSupport.waitUntil { !store.read().contains(where: { $0.id == selected.id }) }
        #expect(store.readSnapshot()?.destinations.first { $0.id == selected.id } == nil)
        #expect(store.readSnapshot()?.currentDestinationID == nil)
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

    @Test func selectedWidgetShowsCurrentControlsOnlyForItsConfiguredDestination() throws {
        let file = try temporaryFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WidgetDestinationStore(fileURL: file)
        let configured = WidgetCallDestination(id: "scope|group|\(UUID())", name: "Ride", kind: .group)
        let other = WidgetCallDestination(id: "scope|group|\(UUID())", name: "Other", kind: .group)
        let call = CallLivePresentation(reference: .init(accountAccessID: UUID(), connectionGeneration: UUID(), groupID: UUID()), status: .inCall, isMuted: false)
        try store.write(.init(destinations: [configured, other], currentDestinationID: configured.id, currentCall: call))
        #expect(store.readSnapshot()?.currentCall(for: configured) == call)
        #expect(store.readSnapshot()?.currentCall(for: other) == nil)
        #expect(store.readSnapshot()?.currentCall(for: nil) == nil)
        try store.write(.init(destinations: [other], currentDestinationID: configured.id, currentCall: call))
        #expect(store.readSnapshot()?.currentCall(for: configured) == nil)
        let foreign = WidgetCallDestination(id: "other-account|group|\(UUID())", name: "Ride", kind: .group)
        try store.write(.init(destinations: [configured, foreign], currentDestinationID: configured.id, currentCall: call))
        #expect(store.readSnapshot()?.currentCall(for: foreign) == nil)

        let oldFileSnapshot = #"{"version":1,"destinations":[{"id":"scope|group|old","name":"Ride","kind":"group"}],"currentCall":{"reference":{"accountAccessID":"00000000-0000-0000-0000-000000000001","connectionGeneration":"00000000-0000-0000-0000-000000000002","groupID":"00000000-0000-0000-0000-000000000003"},"status":"inCall","isMuted":false}}"#
        try Data(oldFileSnapshot.utf8).write(to: file)
        let old = WidgetCallDestination(id: "scope|group|old", name: "Ride", kind: .group)
        #expect(store.readSnapshot()?.currentCall(for: old) == nil)
    }

    @Test func callProjectionCarriesCurrentReferenceAndExplicitMuteAndClearsAtSignOut() async throws {
        let file = try temporaryFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WidgetDestinationStore(fileURL: file), account = AccountFixture(); defer { account.remove() }; account.signIn()
        let h = AppTestSupport.makeHarness(accountSession: account.session), vm = h.viewModel; defer { vm.disconnect() }
        let owner = AppCallOwner(account: account.session, viewModel: vm, widgetDestinationStore: store)
        let selected = try #require(owner.callTargets.first)
        try owner.startWidgetCall(id: selected.entity.id)
        await AppTestSupport.waitUntil { store.readSnapshot()?.currentCall != nil }
        let call = try #require(store.readSnapshot()?.currentCall)
        #expect(call.reference == owner.currentLivePresentation?.reference)
        #expect(store.readSnapshot()?.currentDestinationID == selected.entity.id)
        #expect(call.status == vm.callStatus(for: vm.activeGroupID))
        #expect(owner.setCallSurfaceMuted(true, reference: call.reference))
        await AppTestSupport.waitUntil { store.readSnapshot()?.currentCall?.isMuted == true }
        #expect(store.readSnapshot()?.currentCall?.reference == call.reference)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let projected = try #require(json["currentCall"] as? [String: Any])
        #expect(Set(projected.keys) == ["reference", "status", "isMuted", "canControlMicrophone"])
        account.session.signOut()
        await AppTestSupport.waitUntil { store.readSnapshot()?.currentCall == nil && store.read().isEmpty }
        #expect(store.readSnapshot()?.currentCall == nil)
    }

    @Test func currentTargetProjectionUsesOnlyCurrentTargetsAndOldSnapshotRemainsReadable() async throws {
        let file = try temporaryFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WidgetDestinationStore(fileURL: file)
        let group = IntercomSeedData.recentGroups[0]
        let h = AppTestSupport.makeHarness()
        let vm = h.viewModel; defer { vm.disconnect() }
        let owner = AppCallOwner(account: vm.accountSession, viewModel: vm, widgetDestinationStore: store)
        #expect(store.readSnapshot()?.currentDestinationID == nil)
        vm.deleteGroup(group.id)
        await AppTestSupport.waitUntil { store.readSnapshot()?.destinations.count == owner.callTargets.count }
        let oldFormat = #"{"version":1,"destinations":[]}"#
        try Data(oldFormat.utf8).write(to: file)
        #expect(store.readSnapshot()?.destinations == [])
        #expect(store.readSnapshot()?.currentCall == nil)
        #expect(store.readSnapshot()?.currentDestinationID == nil)
    }
}
