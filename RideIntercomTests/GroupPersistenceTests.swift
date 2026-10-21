import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct GroupPersistenceTests {
    @Test func persistenceStoresIdentityWithoutRuntimeStateOrSecret() throws {
        let name = "RideIntercom.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsGroupStore(defaults: defaults)
        let group = try IntercomGroup(name: "Saved", members: [.init(id: "local", displayName: "You", isMuted: true, isTalking: true, voiceLevel: 0.7, receivedAudioPacketCount: 4, authenticationState: .authenticated, connectionState: .connected)], accessSecret: "never-persist")
        try store.saveGroups([group])
        let data = try #require(defaults.data(forKey: "RideIntercom.groups"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("never-persist"))
        #expect(!text.contains("voiceLevel"))
        #expect(!text.contains("isMuted"))
        let restored = try #require(store.loadGroups().first)
        #expect(restored.members[0].connectionState == .offline)
        #expect(!restored.members[0].isTalking)
        #expect(!restored.members[0].isMuted)
    }

    @Test func corruptStoreIsReportedAndPreserved() throws {
        let name = "RideIntercom.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let data = Data("{broken".utf8)
        defaults.set(data, forKey: "RideIntercom.groups")
        let store = UserDefaultsGroupStore(defaults: defaults)
        #expect(throws: (any Error).self) { try store.loadGroups() }
        #expect(defaults.data(forKey: "RideIntercom.groups") == data)
    }

    @Test func groupCapacityAndIdentityAreValidated() throws {
        let members = (0..<8).map { GroupMember(id: "member-\($0)", displayName: "Rider") }
        #expect(try IntercomGroup(name: "Eight", members: members).members.count == 8)
        #expect(throws: (any Error).self) { try IntercomGroup(name: "Nine", members: members + [.init(id: "ninth", displayName: "Rider")]) }
        #expect(throws: (any Error).self) { try IntercomGroup(name: "Duplicate", members: [members[0], members[0]]) }
        #expect(throws: (any Error).self) { try IntercomGroup(name: "Empty ID", members: [.init(id: "", displayName: "Rider")]) }
    }

    @Test func decodedInviteRejectsUnsupportedVersionAndOversizedURL() throws {
        let token = try GroupInviteToken.make(groupID: UUID(), groupName: "Group", groupSecret: "shared", inviterMemberID: "remote")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(token)) as? [String: Any])
        json["version"] = 2
        let data = try JSONSerialization.data(withJSONObject: json)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let url = try #require(URL(string: "rideintercom://join?token=\(encoded)"))
        #expect(throws: GroupInviteTokenError.unsupportedVersion) { try GroupInviteTokenCodec.decodeJoinURL(url) }
        let huge = try #require(URL(string: "rideintercom://join?token=" + String(repeating: "a", count: 20000)))
        #expect(throws: GroupInviteTokenError.invalidURL) { try GroupInviteTokenCodec.decodeJoinURL(huge) }
    }

    @Test func failedReadBlocksWritesAndDoesNotCreateKeys() throws {
        let name = "RideIntercom.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let corrupted = Data("invalid".utf8)
        defaults.set(corrupted, forKey: "RideIntercom.groups")
        let keys = InMemoryGroupCredentialStore()
        let repository = GroupRepository(store: UserDefaultsGroupStore(defaults: defaults), credentials: keys)
        #expect(throws: (any Error).self) { try repository.load(localMemberID: "local") }
        let group = try IntercomGroup(name: "New", members: [.init(id: "local", displayName: "You")])
        #expect(throws: (any Error).self) { try repository.save([group], credential: .init(groupID: group.id, secret: "key")) }
        #expect(defaults.data(forKey: "RideIntercom.groups") == corrupted)
        #expect(keys.credential(for: group.id) == nil)
    }

    @Test func decodedStoredGroupsStillValidateIdentityAndRestoreLocalFirst() throws {
        let name = "RideIntercom.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsGroupStore(defaults: defaults)
        let group = try IntercomGroup(name: "Order", members: [.init(id: "remote", displayName: "Rider"), .init(id: "local", displayName: "You")])
        try store.saveGroups([group])
        let repository = GroupRepository(store: store, credentials: InMemoryGroupCredentialStore())
        #expect(try repository.load(localMemberID: "local")[0].members[0].id == "local")
        var json = try #require(JSONSerialization.jsonObject(with: defaults.data(forKey: "RideIntercom.groups")!) as? [[String: Any]])
        json[0]["members"] = [["id": "local", "displayName": "A"], ["id": "local", "displayName": "B"]]
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "RideIntercom.groups")
        #expect(throws: (any Error).self) { try store.loadGroups() }
    }
}
