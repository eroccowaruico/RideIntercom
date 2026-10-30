import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct PeerProfileTests {
    @Test func audioAdmissionRequiresCurrentProofAndSurvivesCodecChanges() throws {
        let h = AppTestSupport.makeHarness()
        let vm = h.viewModel; defer { vm.disconnect() }
        #expect(h.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        vm.selectGroup(try #require(vm.groups.first)); h.callSession.authenticate(["member-108"])
        #expect(h.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        let proof = try testPeerProfile(vm, peerID: "member-108", displayName: "Friend")
        try deliver(proof, from: "member-108", to: vm)
        guard case .admittedMemberships(let admitted) = h.callSession.audioPolicies.last?.peerPolicy else {
            Issue.record("Verified participants must use explicit RTC admission"); return
        }
        #expect(Set(admitted.keys.map(\.rawValue)) == ["member-108"])
        vm.updateAudioPipelineCodecSettings(); vm.rebuildAudioPipelineIfRunning()
        #expect(h.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships(admitted))
        vm.handleTransportEvent(.connected(peerIDs: []))
        h.callSession.authenticate([])
        #expect(h.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        h.callSession.authenticate(["member-108"])
        try deliver(proof, from: "member-108", to: vm)
        #expect(h.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        try deliver(testPeerProfile(vm, peerID: "member-108", displayName: "Friend"), from: "member-108", to: vm)
        guard case .admittedMemberships(let fresh) = h.callSession.audioPolicies.last?.peerPolicy else {
            Issue.record("Rejoined participant was not admitted"); return
        }
        #expect(fresh.count == 1 && fresh != admitted)
        vm.disconnect()
        #expect(h.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
    }

    @Test func changedMembershipInvalidatesProofWithoutAnIntermediateEmptySnapshot() throws {
        let h = AppTestSupport.makeHarness(); let vm = h.viewModel
        defer { vm.disconnect() }
        vm.selectGroup(try #require(vm.groups.first)); h.callSession.authenticate(["member-108"])
        let old = try testPeerProfile(vm, peerID: "member-108", displayName: "Friend")
        try deliver(old, from: "member-108", to: vm)
        let fresh = UUID()
        vm.handleTransportEvent(.authenticated(members: [.init(peer: .init(id: .init(rawValue: "member-108"), displayName: "Friend"),
            route: .webRTC, isConnected: true, membershipID: fresh)]))
        #expect(h.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        #expect(vm.peerProfiles["member-108"]?.verified == nil)
        try deliver(old, from: "member-108", to: vm)
        #expect(h.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        try deliver(testPeerProfile(vm, peerID: "member-108", displayName: "Friend"), from: "member-108", to: vm)
        let allowed = RTC.RTCAudioPeerPolicy.admittedMemberships([.init(rawValue: "member-108"): fresh])
        #expect(h.callSession.audioPolicies.last?.peerPolicy == allowed)
        let challenge = vm.peerProfiles["member-108"]?.challenge
        vm.handleTransportEvent(.authenticated(members: [.init(peer: .init(id: .init(rawValue: "member-108"), displayName: "Friend"),
            route: .multipeer, isConnected: true, membershipID: fresh)]))
        #expect(vm.peerProfiles["member-108"]?.challenge == challenge)
        #expect(h.callSession.audioPolicies.last?.peerPolicy == allowed)
    }

    @Test func twoPeersProveNamesWithoutCreatingGroupOnlyContactsAndKeepLocalNickname() throws {
        let a = AppTestSupport.makeHarness(groups: [], localMemberID: "alice")
        let b = AppTestSupport.makeHarness(groups: [], localMemberID: "bob")
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        #expect(a.viewModel.createTalkGroup(name: "Friends"))
        try b.viewModel.acceptInviteURL(#require(a.viewModel.makeSelectedGroupInviteURL()))
        a.callSession.authenticate(["bob"]); b.callSession.authenticate(["alice"])
        var ai = 0, bi = 0
        func pump() {
            for _ in 0..<8 {
                let old = ai + bi
                while ai < a.callSession.sentApplicationDataMessages.count {
                    let message = a.callSession.sentApplicationDataMessages[ai]; ai += 1
                    b.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "alice", message: message))
                }
                while bi < b.callSession.sentApplicationDataMessages.count {
                    let message = b.callSession.sentApplicationDataMessages[bi]; bi += 1
                    a.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "bob", message: message))
                }
                if ai + bi == old { return }
            }
            Issue.record("Profile exchange did not settle")
        }
        pump()
        #expect(a.viewModel.peerProfiles["bob"]?.verified != nil)
        #expect(b.viewModel.peerProfiles["alice"]?.verified != nil)
        let user = try #require(a.viewModel.savedUsers.first)
        #expect(a.viewModel.renameSavedUser(user.id, displayName: "My Friend"))
        #expect(b.viewModel.setLocalDisplayName("Bob's new name"))
        pump()
        #expect(a.viewModel.savedUsers.first?.displayName == "Bob's new name")
        #expect(a.viewModel.savedUsers.first?.resolvedDisplayName == "My Friend")
        a.callSession.authenticate(["bob", "group-only"])
        let stranger = try testPeerProfile(a.viewModel, peerID: "group-only", displayName: "Today's Rider")
        try deliver(stranger, from: "group-only", to: a.viewModel)
        #expect(a.viewModel.savedUsers.count == 1)
        #expect(a.viewModel.peerProfiles["group-only"]?.verified != nil)
    }

    @Test func copiedMemberIDCannotReplaceSavedKeyAndOldConnectionCannotReplayAName() throws {
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "local")
        let vm = h.viewModel; defer { vm.disconnect() }
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            groupID: UUID(), groupName: "Friends", groupSecret: "group-key", inviterMemberID: "friend", inviterDisplayName: "Friend")
        try vm.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token)); h.callSession.authenticate(["friend"])
        let forged = try testPeerProfile(vm, peerID: "friend", displayName: "Impostor",
            signer: DeviceIdentitySigner(memberID: "friend", key: P256.Signing.PrivateKey()))
        try deliver(forged, from: "friend", to: vm)
        #expect(vm.savedUsers.first?.displayName == "Friend" && vm.peerProfiles["friend"]?.verified == nil)
        #expect(vm.groupStorageIssue == nil)
        let genuine = try testPeerProfile(vm, peerID: "friend", displayName: "Current", revision: 2)
        try deliver(genuine, from: "friend", to: vm)
        let stale = try testPeerProfile(vm, peerID: "friend", displayName: "Old name", revision: 1)
        let writes = h.groupStore.saveCount
        try deliver(stale, from: "friend", to: vm); try deliver(genuine, from: "friend", to: vm)
        #expect(vm.savedUsers.first?.displayName == "Current" && h.groupStore.saveCount == writes)
        vm.handleTransportEvent(.connected(peerIDs: [])); h.callSession.authenticate(["friend"])
        #expect(vm.peerProfiles["friend"]?.verified == nil)
        try deliver(genuine, from: "friend", to: vm)
        #expect(vm.peerProfiles["friend"]?.verified == nil)
        let current = try testPeerProfile(vm, peerID: "friend", displayName: "Reconnected", revision: 1)
        try deliver(current, from: "friend", to: vm)
        #expect(vm.savedUsers.first?.displayName == "Reconnected")
        vm.disconnect(); vm.connectLocal(); h.callSession.authenticate(["friend"])
        try deliver(current, from: "friend", to: vm)
        #expect(vm.peerProfiles["friend"]?.verified == nil)
    }

    @Test func challengeBackoffStopsAfterVerificationAndCachedRepliesDoNotReadKeys() throws {
        let keychain = DictionaryKeychain()
        let h = AppTestSupport.makeHarness(internetSettingsStore: InternetConnectionSettingsStore(keychain: keychain, namespace: "profile-cache"))
        let vm = h.viewModel; defer { vm.disconnect() }
        vm.selectGroup(try #require(vm.groups.first)); h.callSession.authenticate(["member-108"])
        let next = try #require(vm.peerProfiles["member-108"]).nextRequestAt
        let count = h.callSession.sentApplicationDataMessages.count
        for _ in 0..<30 { vm.sendPeerProfileChallenges(now: next - 0.1) }
        #expect(h.callSession.sentApplicationDataMessages.count == count)
        vm.sendPeerProfileChallenges(now: next)
        #expect(h.callSession.sentApplicationDataMessages.count == count + 1)
        #expect(vm.peerProfiles["member-108"]?.requestInterval == 4)
        let nonce = UUID()
        try receiveTestProfileChallenge(vm, peerID: "member-108", nonce: nonce, now: 100)
        let reads = keychain.readCount, replyCount = h.callSession.sentApplicationDataMessages.count
        let reply = try #require(h.callSession.sentApplicationDataMessages.last)
        for _ in 0..<30 { try receiveTestProfileChallenge(vm, peerID: "member-108", nonce: UUID(), now: 100.5) }
        #expect(keychain.readCount == reads && h.callSession.sentApplicationDataMessages.count == replyCount)
        try receiveTestProfileChallenge(vm, peerID: "member-108", nonce: nonce, now: 102)
        #expect(keychain.readCount == reads)
        #expect(h.callSession.sentApplicationDataMessages.last?.payload == reply.payload)
        try deliver(testPeerProfile(vm, peerID: "member-108", displayName: "Verified"), from: "member-108", to: vm)
        let verifiedCount = h.callSession.sentApplicationDataMessages.count
        vm.sendPeerProfileChallenges(now: next + 600)
        #expect(h.callSession.sentApplicationDataMessages.count == verifiedCount)
        vm.disconnect(); #expect(vm.peerProfiles.isEmpty)
    }

    @Test func changedPayloadAndWrongRecipientCannotPassVerification() throws {
        let nonce = UUID(), group = UUID()
        let original = try SharedDisplayName.make(groupID: group, recipientMemberID: "local", challenge: nonce,
            revision: 1, displayName: "Friend", signer: testIdentitySigner("friend"))
        let encoded = try JSONEncoder().encode(original)
        let values: [(String, Any)] = [("displayName", "Spoofed"), ("revision", 2), ("memberID", "other"),
            ("recipientMemberID", "other"), ("challenge", UUID().uuidString), ("groupID", UUID().uuidString)]
        for (field, value) in values {
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any]); object[field] = value
            let changed = try JSONDecoder().decode(SharedDisplayName.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: (any Error).self) { try changed.verified(peerID: "friend", recipient: "local", groupID: group, challenge: nonce) }
        }
        #expect(try original.verified(peerID: "friend", recipient: "local", groupID: group, challenge: nonce).displayName == "Friend")
    }

    @Test func certifiedAccountChangeCannotRenameThePreviousAccountEvenWithSameDeviceKey() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let issuer = P256.Signing.PrivateKey(), device = TestDeviceIdentities.key("friend")
        let trust = DeviceIdentityTrust(origin: URL(string: "https://account.test")!, issuerKey: IdentityEncoding.encode(issuer.publicKey.x963Representation))
        func signer(_ user: String) throws -> DeviceIdentitySigner {
            let certificate = try testIdentityCertificate(signer: issuer, userID: String(repeating: user, count: 64), memberID: "friend",
                deviceKey: IdentityEncoding.encode(device.publicKey.x963Representation))
            return try DeviceIdentitySigner(memberID: "friend", key: device,
                identity: certificate.verify(origin: trust.origin, trustedIssuerKey: trust.issuerKey))
        }
        let original = try signer("a")
        let group = try IntercomGroup(name: "Friends", members: [.init(id: "local", displayName: "You"), .init(id: "friend", displayName: "Friend")])
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: original, groupID: group.id,
            groupName: group.name, groupSecret: "key", inviterMemberID: "friend", inviterDisplayName: "Friend")
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"),
            acceptedInvitation: token.accept(signer: testIdentitySigner("local"), displayName: "You", trust: trust))
        let nonce = UUID()
        for user in ["a", "b"] {
            let value = try SharedDisplayName.make(groupID: group.id, recipientMemberID: "local", challenge: nonce,
                revision: 1, displayName: user, signer: signer(user))
            let verified = try value.verified(peerID: "friend", recipient: "local", groupID: group.id, challenge: nonce, trust: trust)
            #expect(verified.identity.principal?.userID == String(repeating: user, count: 64))
            #expect(try f.repository.receiveProfile(verified) == (user == "a"))
        }
        #expect(f.repository.users.first?.displayName == "a")
        #expect(f.repository.users.first?.principal?.userID == String(repeating: "a", count: 64))
        #expect(try !f.repository.receiveProfile(testVerifiedPeerProfile(groupID: group.id, memberID: "unknown", displayName: "Ignored")))
        #expect(try !f.repository.receiveProfile(testVerifiedPeerProfile(groupID: UUID(), memberID: "friend", displayName: "Ignored")))
    }

    @Test(arguments: ["link", "disconnect", "signout"])
    func losingTheConnectionDiscardsProfileProofs(reason: String) throws {
        let account = AccountFixture(); defer { account.remove() }; account.signIn()
        let h = AppTestSupport.makeHarness(accountSession: account.session)
        let vm = h.viewModel; defer { vm.disconnect() }
        vm.selectGroup(try #require(vm.groups.first)); h.callSession.authenticate(["member-108"])
        let value = try testPeerProfile(vm, peerID: "member-108", displayName: "Friend")
        try deliver(value, from: "member-108", to: vm)
        #expect(vm.peerProfiles["member-108"]?.verified != nil)
        switch reason {
        case "link": vm.handleTransportEvent(.linkFailed(willRetry: true))
        case "disconnect": vm.handleTransportEvent(.disconnected)
        default: account.session.signOut(); account.signIn()
        }
        #expect(vm.peerProfiles.isEmpty)
        try deliver(value, from: "member-108", to: vm)
        #expect(vm.peerProfiles.isEmpty)
    }

    private func deliver(_ profile: SharedDisplayName, from peerID: String, to vm: IntercomViewModel) throws {
        vm.handleTransportEvent(.receivedApplicationData(peerID: peerID,
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))))
    }
}
