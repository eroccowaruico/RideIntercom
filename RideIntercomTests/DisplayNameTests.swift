import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct DisplayNameTests {
    @Test func localNamePersistsAndIsSharedWithoutEndingTheCall() throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        vm.selectGroup(try #require(vm.groups.first)); h.callSession.authenticate(["member-108"])
        let stops = h.callSession.disconnectCallCount
        #expect(vm.setLocalDisplayName("  やまねこ ⛷  "))
        #expect(vm.localMemberIdentity.displayName == "やまねこ ⛷")
        #expect(vm.groups.allSatisfy { $0.members.first?.displayName == "やまねこ ⛷" })
        #expect(h.callSession.disconnectCallCount == stops)
        let sent = try #require(h.callSession.sentApplicationDataMessages.last { $0.namespace == SharedDisplayName.namespace })
        #expect(try JSONDecoder().decode(SharedDisplayName.self, from: sent.payload).displayName == "やまねこ ⛷")
        #expect(!vm.setLocalDisplayName("\n"))
        #expect(!vm.setLocalDisplayName(String(repeating: "あ", count: 110)))
        #expect(vm.localMemberIdentity.displayName == "やまねこ ⛷")
        let suite = "RideIntercom.Tests.Name." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsLocalMemberIdentityStore(defaults: defaults)
        let id = store.loadOrCreate().memberID
        store.saveDisplayName("山ねこ")
        let restored = UserDefaultsLocalMemberIdentityStore(defaults: defaults).loadOrCreate()
        #expect(restored.memberID == id && restored.displayName == "山ねこ")
    }

    @Test func personalNameAndLocalOverrideSurviveRestartAndResetFollowsLatestName() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try IntercomGroup(name: "Friends", members: [.init(id: "local", displayName: "You"), .init(id: "rider", displayName: "山田")])
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"), acceptedInvitationFrom: group.members[1])
        let id = try #require(f.repository.users.first).id
        try f.repository.renameUser(id, displayName: "スキー仲間")
        try f.repository.receiveDisplayName("やまだ", from: "rider", in: group.id)
        let restarted = f.restart(); _ = try restarted.load(localMemberID: "local")
        #expect(restarted.users.first?.displayName == "やまだ")
        #expect(restarted.users.first?.resolvedDisplayName == "スキー仲間")
        try restarted.resetUserName(id)
        #expect(restarted.users.first?.resolvedDisplayName == "やまだ")
        try restarted.receiveDisplayName("やまちゃん", from: "rider", in: group.id)
        #expect(restarted.users.first?.resolvedDisplayName == "やまちゃん")
        #expect(try f.restart().load(localMemberID: "local").first?.members.last?.resolvedDisplayName == "やまちゃん")
    }

    @Test func groupOnlyNamesStayInTheirGroupAndNeverBecomeContacts() throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let group = try #require(vm.groups.first); vm.selectGroup(group); h.callSession.authenticate(["stranger"])
        #expect(vm.renameGroupMember("stranger", in: group.id, displayName: "今日の仲間"))
        let profile = SharedDisplayName(groupID: group.id, displayName: "さくら", requestsReply: false)
        vm.receiveSharedDisplayName(peerID: "stranger", message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile)))
        let member = try #require(vm.groups.first { $0.id == group.id }?.members.first { $0.id == "stranger" })
        #expect(member.displayName == "さくら" && member.resolvedDisplayName == "今日の仲間")
        #expect(vm.savedUsers.isEmpty)
        #expect(vm.resetGroupMemberName("stranger", in: group.id))
        #expect(vm.groups.first { $0.id == group.id }?.members.first { $0.id == "stranger" }?.resolvedDisplayName == "さくら")
    }

    @Test func unauthenticatedWrongGroupAndInvalidNamesCannotChangeSavedNames() throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel; defer { vm.disconnect() }
        let group = try #require(vm.groups.first); vm.selectGroup(group)
        func deliver(groupID: UUID, name: String) throws {
            let profile = SharedDisplayName(groupID: groupID, displayName: name, requestsReply: false)
            vm.receiveSharedDisplayName(peerID: "member-108", message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile)))
        }
        try deliver(groupID: group.id, name: "unauthenticated")
        h.callSession.authenticate(["member-108"])
        let before = vm.groups
        try deliver(groupID: UUID(), name: "wrong-group")
        try deliver(groupID: group.id, name: "bad\u{0001}name")
        #expect(vm.groups == before)
        #expect(!vm.groups.flatMap(\.members).contains { $0.displayName == "unauthenticated" })
    }

    @Test func invitationCarriesOnlyTheAuthorsNameAndProtectsItAgainstEditing() throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel; defer { vm.disconnect() }
        vm.selectGroup(try #require(vm.groups.first))
        #expect(vm.setLocalDisplayName("雪 | ねこ"))
        let url = try #require(vm.selectedGroupInviteURL)
        let invite = try GroupInviteTokenCodec.decodeJoinURL(url)
        #expect(invite.inviterDisplayName == "雪 | ねこ")
        let receiver = AppTestSupport.makeHarness(groups: [])
        defer { receiver.viewModel.disconnect() }
        try receiver.viewModel.acceptInviteURL(url)
        #expect(receiver.viewModel.savedUsers.first?.displayName == "雪 | ねこ")
        let data = try JSONEncoder().encode(invite)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["inviterDisplayName"] = "spoofed"
        let changed = try JSONDecoder().decode(GroupInviteToken.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!changed.verifySignature())
    }

    @Test func nameWriteFailurePreservesBothNamesAndExistingGroup() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try IntercomGroup(name: "Friends", members: [.init(id: "local", displayName: "You"), .init(id: "rider", displayName: "Rider")])
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"), acceptedInvitationFrom: group.members[1])
        let before = try Data(contentsOf: f.file.url); let users = f.repository.users
        f.store.failCommit = true
        #expect(throws: (any Error).self) { try f.repository.renameUser(users[0].id, displayName: "Alias") }
        #expect(f.repository.users == users)
        #expect(try Data(contentsOf: f.file.url) == before)
    }
}
