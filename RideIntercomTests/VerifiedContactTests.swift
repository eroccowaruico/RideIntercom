import CryptoKit
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct VerifiedContactTests {
    @Test func sameCertifiedPersonMergesDirectlyInvitedDevicesAndPreservesNickname() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let issuer = P256.Signing.PrivateKey()
        let trust = DeviceIdentityTrust(origin: URL(string: "https://account.test")!, issuerKey: IdentityEncoding.encode(issuer.publicKey.x963Representation))
        let first = try group("phone"), second = try group("tablet")
        let one = try accepted(first, member: "phone", issuer: issuer, userID: String(repeating: "a", count: 64), trust: trust)
        try f.repository.save([first], credential: .init(groupID: first.id, secret: "group-key"), acceptedInvitation: one)
        let userID = try #require(f.repository.users.first).id
        try f.repository.renameUser(userID, displayName: "My Friend")
        let two = try accepted(second, member: "tablet", issuer: issuer, userID: String(repeating: "a", count: 64), trust: trust)
        try f.repository.save([first, second], credential: .init(groupID: second.id, secret: "group-key"), acceptedInvitation: two)
        let user = try #require(f.repository.users.first)
        #expect(f.repository.users.count == 1 && user.id == userID)
        #expect(Set(user.memberIDs) == ["phone", "tablet"])
        #expect(user.localName == "My Friend")
        #expect(user.deviceKeys?.count == 2 && user.principal?.userID == String(repeating: "a", count: 64))
        let restarted = f.restart(); _ = try restarted.load(localMemberID: "local")
        #expect(restarted.users == [user])
        let snapshot = try #require(try f.file.read())
        #expect(snapshot.groups.allSatisfy { $0.members.last?.userID == userID })
    }

    @Test func copiedMemberIDAndDifferentAccountNeverOverwriteAnExistingContact() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let issuer = P256.Signing.PrivateKey()
        let trust = DeviceIdentityTrust(origin: URL(string: "https://account.test")!, issuerKey: IdentityEncoding.encode(issuer.publicKey.x963Representation))
        let group = try group("friend")
        let original = try accepted(group, member: "friend", issuer: issuer, userID: String(repeating: "a", count: 64), trust: trust)
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"), acceptedInvitation: original)
        let before = try f.file.read()
        for (key, userID) in [(P256.Signing.PrivateKey(), String(repeating: "a", count: 64)),
                              (TestDeviceIdentities.key("friend"), String(repeating: "b", count: 64))] {
            let changed = try accepted(group, member: "friend", key: key, issuer: issuer, userID: userID, trust: trust)
            #expect(throws: GroupStorageError.identityConflict) { try f.repository.acceptInvitation(changed, inviterName: "Same Name") }
            #expect(try f.file.read() == before)
        }
    }

    @Test func previousManifestRetiresUnsignedPendingReceiptWithoutLosingContactsOrGroups() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try group("friend")
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "group-key"),
                              acceptedInvitation: testAcceptedInvitation(groupID: group.id, inviter: group.members[1]))
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file.url)) as? [String: Any])
        object["version"] = 4
        var groups = try #require(object["groups"] as? [[String: Any]])
        var pending = try #require(groups[0]["pendingInvitation"] as? [String: Any])
        var invitation = try #require(pending["invitation"] as? [String: Any])
        invitation["inviterDeviceKey"] = nil; pending["invitation"] = invitation; pending["acceptanceProof"] = nil; pending["inviteeDeviceKey"] = nil
        groups[0]["pendingInvitation"] = pending; object["groups"] = groups
        var users = try #require(object["users"] as? [[String: Any]])
        users[0]["deviceKeys"] = nil; users[0]["principal"] = nil; object["users"] = users
        try JSONSerialization.data(withJSONObject: object).write(to: f.file.url)
        let restarted = f.restart()
        #expect(try restarted.load(localMemberID: "local").map(\.id) == [group.id])
        #expect(restarted.users.first?.memberIDs == ["friend"])
        #expect(restarted.users.first?.deviceKeys == nil)
        #expect(restarted.pendingInvitation(for: group.id) == nil)
        #expect(try restarted.credential(for: group.id)?.secret == "group-key")
        #expect(try f.file.read()?.version == 6)
    }

    private func group(_ member: String) throws -> IntercomGroup {
        try IntercomGroup(name: "Friends", members: [.init(id: "local", displayName: "You"), .init(id: member, displayName: "Shared Name")])
    }
    private func accepted(_ group: IntercomGroup, member: String, key: P256.Signing.PrivateKey? = nil,
                          issuer: P256.Signing.PrivateKey, userID: String, trust: DeviceIdentityTrust) throws -> AcceptedDirectInvitation {
        let key = key ?? TestDeviceIdentities.key(member)
        let envelope = try testIdentityCertificate(signer: issuer, userID: userID, deviceID: UUID().uuidString.lowercased(),
            memberID: member, deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation))
        let identity = try envelope.verify(origin: trust.origin, trustedIssuerKey: trust.issuerKey)
        let signer = try DeviceIdentitySigner(memberID: member, key: key, identity: identity)
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: signer, groupID: group.id,
            groupName: group.name, groupSecret: "group-key", inviterMemberID: member, inviterDisplayName: "Shared Name")
        return try token.accept(signer: testIdentitySigner("local"), displayName: "You", trust: trust)
    }
}
