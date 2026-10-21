import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct GroupPersistenceTests {
    @Test func persistenceStoresIdentityWithoutRuntimeStateOrSecret() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try IntercomGroup(name: "Saved", members: [.init(id: "local", displayName: "You", isMuted: true, isTalking: true, voiceLevel: 0.7, receivedAudioPacketCount: 4, authenticationState: .authenticated, connectionState: .connected)], accessSecret: "never-persist")
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "never-persist"))
        let text = String(decoding: try Data(contentsOf: f.file.url), as: UTF8.self)
        #expect(!text.contains("never-persist"))
        #expect(!text.contains("voiceLevel"))
        #expect(!text.contains("isMuted"))
        let restored = try #require(try f.restart().load(localMemberID: "local").first)
        #expect(restored.members[0].connectionState == .offline)
        #expect(!restored.members[0].isTalking)
        #expect(!restored.members[0].isMuted)
    }

    @Test func corruptStoreIsReportedAndPreserved() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let data = Data("{broken".utf8)
        try data.write(to: f.file.url)
        #expect(throws: (any Error).self) { try f.restart().load(localMemberID: "local") }
        #expect(try Data(contentsOf: f.file.url) == data)
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
        let f = try GroupStorageFixture(); defer { f.remove() }
        let corrupted = Data("invalid".utf8)
        try corrupted.write(to: f.file.url)
        let repository = f.restart()
        #expect(throws: (any Error).self) { try repository.load(localMemberID: "local") }
        let group = try f.group()
        #expect(throws: (any Error).self) { try repository.save([group], credential: .init(groupID: group.id, secret: "key")) }
        #expect(try Data(contentsOf: f.file.url) == corrupted)
        #expect(f.keys.references().isEmpty)
    }

    @Test func decodedStoredGroupsStillValidateIdentityAndRestoreLocalFirst() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try IntercomGroup(name: "Order", members: [.init(id: "remote", displayName: "Rider"), .init(id: "local", displayName: "You")])
        try f.repository.save([group])
        #expect(try f.restart().load(localMemberID: "local")[0].members[0].id == "local")
        var snapshot = try #require(try f.file.read())
        snapshot.groups[0].members = [.init(id: "local", displayName: "A"), .init(id: "local", displayName: "B")]
        try JSONEncoder().encode(snapshot).write(to: f.file.url)
        #expect(throws: (any Error).self) { try f.restart().load(localMemberID: "local") }
    }
}
