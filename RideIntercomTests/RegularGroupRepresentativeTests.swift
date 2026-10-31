import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct RegularGroupRepresentativeTests {
    @Test func sevenSavedPeopleWithTwoDevicesEachUseSevenGroupSlots() throws {
        let store = InMemoryGroupStore(groups: [])
        store.snapshot.users = (1...7).map { index in
            let ids = ["friend-\(index)-a", "friend-\(index)-b"]
            return SavedUser(displayName: "Friend \(index)", memberIDs: ids, deviceKeys: Dictionary(uniqueKeysWithValues: ids.map { ($0, testIdentitySigner($0).publicKey) }),
                             principal: .init(issuer: "https://account.test", userID: String(repeating: String(index), count: 64)))
        }
        let h = AppTestSupport.makeHarness(groups: [], groupStore: store, localMemberID: "local")
        defer { h.viewModel.disconnect() }
        #expect(h.viewModel.createTalkGroup(name: "Eight people", userIDs: Set(store.snapshot.users.map(\.id))))
        let group = try #require(h.viewModel.selectedGroup)
        #expect(group.members.count == 8)
        #expect(group.accountDevices.count == 7)
        #expect(h.viewModel.availableUsers(for: group.id).isEmpty)
        #expect(!h.viewModel.addSavedUsers([store.snapshot.users[0].id], to: group.id))
    }

    @Test func additionalDevicesCannotDisplaceSevenConnectedRepresentatives() throws {
        let f = try RegularRepresentativeFixture(); defer { f.stop() }
        let vm = f.h.viewModel, accounts = ["b", "c", "d", "e", "f", "1", "2"]
        let representatives = accounts.indices.map { "rider-\($0)-phone" }
        f.h.callSession.authenticate(representatives)
        for (id, account) in zip(representatives, accounts) { try f.deliver(f.signer(id, account: account)) }
        let roster = vm.groups[0].members.map(\.id)
        let admitted = vm.callAccessAdmittedMemberships
        let oldChallenge = try #require(vm.peerProfiles[representatives.last!]?.challenge)

        // This sorts before every representative, including the same person's
        // currently connected phone. It must not manufacture a departure.
        f.h.callSession.authenticate(representatives + ["00-tablet"])
        try f.deliver(f.signer("00-tablet", account: accounts.last!))
        #expect(vm.groups[0].members.map(\.id) == roster)
        #expect(vm.callAccessAdmittedMemberships == admitted)
        #expect(vm.peerProfiles[representatives.last!]?.challenge == oldChallenge)
        #expect(vm.peerProfiles["00-tablet"]?.verified == nil)

        // Even more candidates than the bounded temporary budget may not evict
        // an already verified, still-connected representative.
        let candidates = (0..<8).map { "00-candidate-\($0)" }
        f.h.callSession.authenticate(representatives + candidates)
        #expect(vm.peerProfiles.count == 14)
        #expect(vm.callAccessAdmittedMemberships == admitted)
        #expect(vm.groups[0].members.map(\.id) == roster)
    }

    @Test func sevenPeopleCanBeVerifiedWhenBothDevicesAppearTogether() throws {
        let f = try RegularRepresentativeFixture(); defer { f.stop() }
        let vm = f.h.viewModel, accounts = ["b", "c", "d", "e", "f", "1", "2"]
        let phones = accounts.indices.map { "rider-\($0)-a" }
        let tablets = accounts.indices.map { "rider-\($0)-b" }
        f.h.callSession.authenticate(phones + tablets)
        #expect(vm.peerProfiles.count == 14)
        for (id, account) in zip(phones, accounts) { try f.deliver(f.signer(id, account: account)) }
        for (id, account) in zip(tablets, accounts) { try f.deliver(f.signer(id, account: account)) }
        #expect(Set(vm.groups[0].members.map(\.id)) == Set(["local"] + phones))
        #expect(Set(vm.callAccessAdmittedMemberships.keys.map(\.rawValue)) == Set(phones))
        #expect(tablets.allSatisfy { vm.peerProfiles[$0]?.verified == nil })
        #expect(vm.savedUsers.isEmpty)
        #expect(try vm.internetSettingsStore.notificationPermissions().isEmpty)
    }

    @Test func changedMembershipStillRequiresFreshRepresentativeProof() throws {
        let f = try RegularRepresentativeFixture(); defer { f.stop() }
        let vm = f.h.viewModel, signer = try f.signer("phone")
        f.h.callSession.authenticate(["phone"])
        let previous = try f.profile(signer)
        try f.deliver(previous)
        let replacementMembership = UUID()
        vm.handleTransportEvent(.authenticated(members: [
            .init(peer: .init(id: .init(rawValue: "phone"), displayName: "Phone"), route: .multipeer,
                  isConnected: true, membershipID: replacementMembership)
        ]))
        #expect(vm.peerProfiles["phone"]?.challenge != previous.challenge)
        #expect(vm.callAccessAdmittedMemberships.isEmpty)
        try f.deliver(previous)
        #expect(vm.peerProfiles["phone"]?.verified == nil)
        try f.deliver(signer)
        #expect(vm.callAccessAdmittedMemberships[.init(rawValue: "phone")] == replacementMembership)
    }

    @Test func samePersonWaitsForActiveRepresentativeThenReplacesAfterFreshChallenge() throws {
        let f = try RegularRepresentativeFixture(); defer { f.stop() }
        let vm = f.h.viewModel, first = try f.signer("phone"), second = try f.signer("tablet")
        f.h.callSession.authenticate(["phone"]); try f.deliver(first, name: "本人")
        #expect(vm.renameGroupMember("phone", in: f.groupID, displayName: "呼び名"))
        try vm.groupRepository.recordSponsoredStart(100, for: f.groupID, now: 200)
        let reference = vm.currentCallReference, secret = try vm.groupRepository.credential(for: f.groupID)
        f.h.callSession.authenticate(["phone", "tablet"])
        let pending = try f.profile(second)
        try f.deliver(pending)
        #expect(vm.peerProfiles["tablet"]?.verified == nil)
        #expect(vm.groups[0].members.map(\.id) == ["local", "phone"])
        let count = f.h.callSession.sentApplicationDataMessages.count
        f.h.callSession.authenticate(["tablet"])
        #expect(f.h.callSession.sentApplicationDataMessages.dropFirst(count).contains { $0.namespace == PeerProfileChallenge.namespace })
        #expect(vm.peerProfiles["tablet"]?.challenge != pending.challenge)
        try f.deliver(pending)
        #expect(vm.peerProfiles["tablet"]?.verified == nil)
        try f.deliver(second, name: "新しい本人名")
        let group = try #require(vm.groupRepository.storedGroup(f.groupID))
        #expect(group.members.map(\.id) == ["local", "tablet"])
        #expect(group.members[1].localName == "呼び名")
        #expect(group.members[1].displayName == "新しい本人名")
        #expect(group.accountDevices["phone"] == nil)
        #expect(vm.currentCallReference == reference)
        #expect(try vm.groupRepository.credential(for: f.groupID) == secret)
        #expect(vm.groupRepository.lastSponsoredStart(for: f.groupID) == 100)
        #expect(Set(vm.callAccessAdmittedMemberships.keys.map(\.rawValue)) == ["tablet"])
        #expect(vm.savedUsers.isEmpty)
        #expect(try vm.internetSettingsStore.notificationPermissions().isEmpty)
    }

    @Test func explicitInvitationFromSecondDeviceKeepsActiveRepresentative() throws {
        let f = try RegularRepresentativeFixture(); defer { f.stop() }
        let vm = f.h.viewModel, first = try f.signer("phone"), second = try f.signer("tablet")
        f.h.callSession.authenticate(["phone"]); try f.deliver(first)
        let credential = try #require(try vm.groupRepository.credential(for: f.groupID))
        let reference = vm.currentCallReference
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: second,
            groupID: f.groupID, groupName: "Friends", groupSecret: credential.secret,
            inviterMemberID: "tablet", inviterDisplayName: "Person")
        try vm.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        #expect(vm.groups[0].members.map(\.id) == ["local", "phone"])
        #expect(vm.currentCallReference == reference)
        #expect(vm.savedRemoteUsers.first?.memberIDs == ["tablet"])
        f.h.callSession.authenticate(["phone", "tablet"]); try f.deliver(second)
        #expect(vm.peerProfiles["tablet"]?.verified == nil)
        f.h.callSession.authenticate(["tablet"]); try f.deliver(second)
        #expect(vm.groups[0].members.map(\.id) == ["local", "tablet"])
        #expect(vm.savedRemoteUsers.first?.memberIDs == ["tablet"])
        vm.removeMember("tablet", from: f.groupID)
        #expect(vm.groups[0].accountDevices["tablet"] == nil)
        #expect(vm.peerProfiles["tablet"] == nil)
        #expect(f.h.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        #expect(vm.standardCallStatus == .connecting)
    }

    @Test func replacementCannotUseCopiedKeyDifferentAccountOrOldConnectionProof() throws {
        let f = try RegularRepresentativeFixture(); defer { f.stop() }
        let vm = f.h.viewModel, first = try f.signer("phone")
        f.h.callSession.authenticate(["phone"]); let old = try f.profile(first); try f.deliver(old)
        f.h.callSession.authenticate([]); f.h.callSession.authenticate(["phone"])
        try f.deliver(old)
        #expect(vm.peerProfiles["phone"]?.verified == nil)
        let forged = try f.signer("phone", key: P256.Signing.PrivateKey())
        try f.deliver(forged)
        #expect(vm.peerProfiles["phone"]?.verified == nil)
        try f.deliver(f.signer("phone", account: "c"))
        #expect(vm.peerProfiles["phone"]?.verified == nil)
        try f.deliver(first)
        #expect(vm.peerProfiles["phone"]?.verified != nil)
        #expect(vm.groups[0].accountDevices["phone"]?.principal == first.principal)
    }

    @Test func localOnlyPeersRemainDistinctAndUnauthenticatedDiscoveryCannotEvictAnyone() throws {
        let members = [GroupMember(id: "local", displayName: "You")] + (1...7).map { GroupMember(id: "peer-\($0)", displayName: "Rider \($0)") }
        let group = try IntercomGroup(name: "Full", members: members, accessSecret: "key")
        let h = AppTestSupport.makeHarness(groups: [group]), vm = h.viewModel; defer { vm.disconnect() }
        vm.selectGroup(group); h.callSession.authenticate(["unknown"])
        #expect(vm.groups[0].members.map(\.id) == members.map(\.id))
        let f = try RegularRepresentativeFixture(); defer { f.stop() }
        f.h.callSession.authenticate(["local-one", "local-two"])
        try f.deliver(testIdentitySigner("local-one")); try f.deliver(testIdentitySigner("local-two"))
        #expect(f.h.viewModel.groups[0].members.count == 3)
        #expect(f.h.viewModel.groups[0].accountDevices.count == 1) // Only our own certified binding.
        #expect(f.h.viewModel.savedUsers.isEmpty)
    }

    @Test func deletingDirectContactPreservesGroupBindingNamesAndCallWithoutRestoringContact() throws {
        let f = try RegularRepresentativeFixture(); defer { f.stop() }
        let vm = f.h.viewModel, first = try f.signer("phone"), second = try f.signer("tablet")
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: first, groupID: f.groupID,
            groupName: "Friends", groupSecret: "replacement-key", inviterMemberID: "phone", inviterDisplayName: "Person")
        vm.disconnect(); try vm.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        let user = try #require(vm.savedRemoteUsers.first)
        #expect(vm.renameSavedUser(user.id, displayName: "Friend"))
        f.h.callSession.authenticate(["phone"]); try f.deliver(first)
        f.h.callSession.authenticate(["tablet"]); try f.deliver(second)
        #expect(vm.groups[0].members.first { $0.id == "tablet" }?.resolvedDisplayName == "Friend")
        #expect(vm.availableUsers(for: f.groupID).isEmpty)
        #expect(vm.renameSavedUser(user.id, displayName: "Nickname"))
        #expect(vm.groups[0].members.first { $0.id == "tablet" }?.resolvedDisplayName == "Nickname")
        let reference = vm.currentCallReference
        #expect(vm.removeSavedUser(user.id))
        #expect(vm.savedUsers.isEmpty)
        try f.deliver(second, name: "Updated", revision: 2)
        #expect(vm.savedUsers.isEmpty)
        #expect(vm.currentCallReference == reference)
        #expect(vm.groups[0].members.first { $0.id == "tablet" }?.localName == "Nickname")
        #expect(!vm.startCall(to: .user(user.id), accountAccessID: vm.accountAccessID))
        #expect(vm.endCall(reference))
    }

    @Test func failedReplacementSaveKeepsOldBindingAndDoesNotAdmitNewAudio() throws {
        let f = try RegularRepresentativeFixture(); defer { f.stop() }
        let vm = f.h.viewModel
        f.h.callSession.authenticate(["phone"]); try f.deliver(f.signer("phone"))
        let group = try #require(vm.groupRepository.storedGroup(f.groupID))
        f.h.callSession.authenticate(["tablet"])
        f.h.groupStore.failSaving = true
        try f.deliver(f.signer("tablet"))
        #expect(vm.groupRepository.storedGroup(f.groupID) == group)
        #expect(vm.peerProfiles["tablet"]?.verified == nil)
        #expect(vm.callAccessAdmittedMemberships.isEmpty)
        #expect(vm.hasAnyActiveGroupConnection)
        #expect(vm.groupStorageIssue != nil)
    }

    @Test func pendingSecondDeviceCannotSponsorOrKeepEstablishedConversationAlive() throws {
        let f = try RegularRepresentativeFixture(enforce: true); defer { f.stop() }
        let vm = f.h.viewModel
        f.h.callSession.authenticate(["phone"]); try f.deliver(f.signer("phone"))
        f.h.callSession.authenticate(["phone", "tablet"]); try f.deliver(f.signer("tablet"))
        #expect(vm.peerProfiles["tablet"]?.verified == nil)
        let status = SharedCallAccess(groupID: f.groupID, recipientMemberID: "local",
            challenge: try #require(vm.peerProfiles["tablet"]?.challenge), revision: 1, hasActiveRight: true,
            activeUntil: nil, mediaReady: true, isEstablished: true, lastSponsoredStart: nil)
        let signed = try status.signed(by: f.signer("tablet"))
        vm.receiveCallAccess(peerID: "tablet", message: .init(namespace: SharedCallAccess.namespace, payload: try JSONEncoder().encode(signed)))
        #expect(vm.peerProfiles["tablet"]?.callAccess == nil)
        #expect(!vm.canPrepareCallMedia)
        _ = vm.callAccessState.establish(now: 100, sponsored: true, remoteEstablished: false, mediaReady: true)
        #expect(vm.callAccessState.isEstablished)
        f.h.callSession.authenticate(["tablet"])
        #expect(!vm.callAccessState.isEstablished)
        #expect(vm.callAccessAdmittedMemberships.isEmpty)
    }

    @Test func ownOtherDeviceDoesNotReplaceLocalRoleAndNormalSnapshotReloads() throws {
        let f = try RegularRepresentativeFixture(); defer { f.stop() }
        let vm = f.h.viewModel
        f.h.callSession.authenticate(["own-tablet"]); try f.deliver(f.signer("own-tablet", account: "a"))
        #expect(vm.groups[0].members.map(\.id) == ["local"])
        #expect(vm.peerProfiles["own-tablet"]?.verified == nil)
        f.h.callSession.authenticate(["phone"]); try f.deliver(f.signer("phone"))
        let bytes = try f.h.groupStore.snapshot.encoded()
        let decoded = try GroupSnapshot.decode(bytes)
        #expect(decoded.groups[0].accountDevices.count == 2)
        #expect(try decoded.groups[0].group().members.first?.id == "local")
        #expect(decoded.users.isEmpty)
    }
}

@MainActor private final class RegularRepresentativeFixture {
    let issuer = P256.Signing.PrivateKey()
    let h: AppTestSupport.Harness
    let groupID: UUID
    let namespace: String
    init(enforce: Bool = false) throws {
        namespace = "RideIntercom.RegularGroup.Tests.\(UUID())"
        let settings = InternetConnectionSettingsStore(keychain: DictionaryKeychain(), namespace: namespace)
        let key = try settings.deviceSigningKey()
        let certificate = try testIdentityCertificate(signer: issuer, deviceID: settings.accountDeviceID(), memberID: "local", deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation))
        let identity = try certificate.verify(origin: URL(string: "https://account.test")!, trustedIssuerKey: certificate.issuerKey)
        try settings.save(url: "https://account.test", token: "ri1.\(String(repeating: "d", count: 64)).\(identity.deviceID).\(String(repeating: "e", count: 64))", identity: identity)
        let access = RegularRepresentativeAccess()
        h = AppTestSupport.makeHarness(groups: [], internetSettingsStore: settings, localMemberID: "local",
            enforceCallAccess: enforce, callAccessEvaluation: { _ in access.value })
        #expect(h.viewModel.createTalkGroup(name: "Friends"))
        groupID = try #require(h.viewModel.selectedGroup?.id)
        access.value = .init(status: .notPurchased)
        h.viewModel.refreshCallAccess()
    }
    func signer(_ id: String, account: String = "b", key: P256.Signing.PrivateKey? = nil) throws -> DeviceIdentitySigner {
        let key = key ?? TestDeviceIdentities.key(id)
        let certificate = try testIdentityCertificate(signer: issuer, userID: String(repeating: account, count: 64), memberID: id,
            deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation))
        return try DeviceIdentitySigner(memberID: id, key: key,
            identity: certificate.verify(origin: URL(string: "https://account.test")!, trustedIssuerKey: certificate.issuerKey))
    }
    func profile(_ signer: DeviceIdentitySigner, name: String = "Person", revision: UInt64 = 1) throws -> SharedDisplayName {
        try testPeerProfile(h.viewModel, peerID: signer.memberID, displayName: name, revision: revision, signer: signer)
    }
    func deliver(_ signer: DeviceIdentitySigner, name: String = "Person", revision: UInt64 = 1) throws { try deliver(profile(signer, name: name, revision: revision)) }
    func deliver(_ value: SharedDisplayName) throws {
        h.viewModel.handleTransportEvent(.receivedApplicationData(peerID: value.memberID,
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(value))))
    }
    func stop() { h.viewModel.disconnect(); UserDefaults.standard.removePersistentDomain(forName: namespace) }
}

@MainActor private final class RegularRepresentativeAccess { var value = StoreAccessEvaluation(status: .active) }
