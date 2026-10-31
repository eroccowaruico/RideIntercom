import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct AccountDirectCallTests {
    @Test func multipleDevicesResolveOneCallAndAccountAddressAcceptsAnotherDevice() throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let a = try fixture.peer("alice-phone", account: "a")
        let b = try fixture.peer("bob-phone", account: "b")
        let b2 = try fixture.peer("bob-tablet", account: "b")
        let c = try fixture.peer("charlie", account: "c")
        try fixture.introduce(b, to: a); try fixture.introduce(b2, to: a)
        try fixture.introduce(a, to: b2)
        let user = try #require(a.viewModel.savedRemoteUsers.first)
        #expect(user.memberIDs.count == 2)
        a.viewModel.disconnect()
        #expect(a.viewModel.selectUser(user.id))
        let direct = try #require(a.viewModel.selectedGroup)
        #expect(direct.kind == .direct)
        let url = try #require(a.viewModel.makeSelectedGroupInviteURL())
        try b2.viewModel.acceptInviteURL(url)
        #expect(b2.viewModel.selectedGroup?.kind == .direct)
        #expect(b2.viewModel.selectedGroup?.id == direct.id)
        #expect(try a.viewModel.groupRepository.credential(for: direct.id) == b2.viewModel.groupRepository.credential(for: direct.id))
        #expect(b2.viewModel.selectUser(try #require(b2.viewModel.savedRemoteUsers.first).id))
        #expect(b2.viewModel.selectedGroup?.id == direct.id)
        let snapshot = c.groupStore.snapshot
        #expect(throws: GroupInviteTokenError.wrongRecipient) { try c.viewModel.acceptInviteURL(url) }
        #expect(c.groupStore.snapshot == snapshot)
    }

    @Test func onlyTheOtherAccountCanEnrollADeviceAndRemovalPreservesOfflineProof() throws {
        let f = AccountCallFixture(); defer { f.disconnect() }
        let a = try f.peer("a", account: "a"), b = try f.peer("b", account: "b")
        let b2 = try f.peer("b2", account: "b"), c = try f.peer("c", account: "c")
        let a2 = try f.peer("a2", account: "a")
        try f.introduce(b, to: a)
        let user = try #require(a.viewModel.savedRemoteUsers.first)
        a.viewModel.disconnect()
        #expect(a.viewModel.selectUser(user.id))
        let groupID = try #require(a.viewModel.selectedGroup?.id)
        let key = try a.viewModel.groupRepository.credential(for: groupID)
        a.callSession.authenticate(["b2", "c", "a2", "unverified"])
        #expect(a.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        try f.deliverProfile(from: c, to: a); try f.deliverProfile(from: a2, to: a)
        try f.deliverProfile(from: b2, to: a)
        let unverified = try testPeerProfile(a.viewModel, peerID: "unverified", displayName: "Same name")
        a.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "unverified",
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(unverified))))
        #expect(Set(IntercomViewModel.admittedMemberships(in: a.viewModel.peerProfiles).keys.map(\.rawValue)) == ["b2"])
        #expect(Set(try #require(a.viewModel.selectedGroup).members.map(\.id)) == ["a", "b", "b2"])
        #expect(a.viewModel.savedUsers.first?.memberIDs == ["b"])
        #expect(a.viewModel.removeSavedUser(user.id))
        a.callSession.authenticate([]); a.callSession.authenticate(["b2"])
        // No current account certificate: the earlier verified key is sufficient offline.
        try f.deliverProfile(from: b2, to: a, certified: false)
        #expect(a.viewModel.peerProfiles["b2"]?.verified != nil)
        #expect(a.viewModel.savedUsers.isEmpty)
        #expect(try a.viewModel.groupRepository.credential(for: groupID) == key)
        #expect(a.viewModel.selectedGroup?.id == groupID)
        #expect(!a.viewModel.canShareSelectedGroup)
        a.callSession.authenticate([]); a.callSession.authenticate(["b2"])
        let forged = try testPeerProfile(a.viewModel, peerID: "b2", displayName: "Same name",
            signer: DeviceIdentitySigner(memberID: "b2", key: P256.Signing.PrivateKey()))
        a.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "b2",
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(forged))))
        #expect(a.viewModel.peerProfiles["b2"]?.verified == nil)
        // Same device key, but now certified as another account, must not inherit access.
        let b2key = try b2.viewModel.internetSettingsStore.deviceSigningKey()
        let changed = try testIdentityCertificate(signer: f.issuer, userID: String(repeating: "c", count: 64),
            memberID: "b2", deviceKey: IdentityEncoding.encode(b2key.publicKey.x963Representation))
        let changedProfile = try testPeerProfile(a.viewModel, peerID: "b2", displayName: "Same name",
            signer: DeviceIdentitySigner(memberID: "b2", key: b2key,
                identity: changed.verify(origin: URL(string: "https://account.test")!, trustedIssuerKey: changed.issuerKey)))
        a.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "b2",
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(changedProfile))))
        #expect(a.viewModel.peerProfiles["b2"]?.verified == nil)
        #expect(a.viewModel.groupStorageIssue == nil)
    }

    @Test func foreignCertificationAndFailedPersistenceNeverGrantAudio() throws {
        let f = AccountCallFixture(); defer { f.disconnect() }
        let a = try f.peer("a", account: "a"), b = try f.peer("b", account: "b")
        let b2 = try f.peer("b2", account: "b")
        try f.introduce(b, to: a)
        a.viewModel.disconnect()
        #expect(a.viewModel.selectUser(try #require(a.viewModel.savedRemoteUsers.first).id))
        let id = try #require(a.viewModel.selectedGroup?.id)
        let key = try a.viewModel.groupRepository.credential(for: id)
        let old = a.groupStore.snapshot
        a.callSession.authenticate(["b2"])
        let deviceKey = try b2.viewModel.internetSettingsStore.deviceSigningKey()
        let foreign = try testIdentityCertificate(signer: P256.Signing.PrivateKey(), userID: String(repeating: "b", count: 64),
            memberID: "b2", deviceKey: IdentityEncoding.encode(deviceKey.publicKey.x963Representation))
        let forged = try testPeerProfile(a.viewModel, peerID: "b2", displayName: "Friend",
            signer: DeviceIdentitySigner(memberID: "b2", key: deviceKey,
                identity: foreign.verify(origin: URL(string: "https://account.test")!, trustedIssuerKey: foreign.issuerKey)))
        a.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "b2",
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(forged))))
        #expect(a.viewModel.peerProfiles["b2"]?.verified == nil)
        #expect(a.groupStore.snapshot == old)
        a.groupStore.failSaving = true
        try f.deliverProfile(from: b2, to: a)
        #expect(a.groupStore.snapshot == old)
        #expect(a.viewModel.selectedGroup?.id == id)
        #expect(a.viewModel.peerProfiles["b2"]?.verified == nil)
        #expect(a.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        a.groupStore.failSaving = false
        // Reload reopens the repository after an uncertain commit failure.
        _ = try a.viewModel.groupRepository.load(localMemberID: "a")
        #expect(try a.viewModel.groupRepository.credential(for: id) == key)
    }

    @Test func simultaneousInvitationsConvergeByAccountInsteadOfDeviceOrdering() throws {
        let f = AccountCallFixture(); defer { f.disconnect() }
        let a = try f.peer("z-device", account: "a"), b = try f.peer("a-device", account: "b")
        try f.introduce(b, to: a); try f.introduce(a, to: b)
        #expect(a.viewModel.selectUser(try #require(a.viewModel.savedRemoteUsers.first).id))
        #expect(b.viewModel.selectUser(try #require(b.viewModel.savedRemoteUsers.first).id))
        let au = try #require(a.viewModel.makeSelectedGroupInviteURL()), bu = try #require(b.viewModel.makeSelectedGroupInviteURL())
        let id = try #require(a.viewModel.selectedGroup?.id)
        let winner = try a.viewModel.groupRepository.credential(for: id)
        a.viewModel.disconnect(); b.viewModel.disconnect()
        try a.viewModel.acceptInviteURL(bu); try b.viewModel.acceptInviteURL(au)
        #expect(try a.viewModel.groupRepository.credential(for: id) == winner)
        #expect(try b.viewModel.groupRepository.credential(for: id) == winner)
    }

    @Test func expiredLocalCertificateKeepsStableIdentityButCannotIssueNewAccountInvitation() throws {
        let f = AccountCallFixture(); defer { f.disconnect() }
        let a = try f.peer("a", account: "a", at: Date().addingTimeInterval(-3600))
        let b = try f.peer("b", account: "b")
        try f.introduce(b, to: a)
        #expect(a.viewModel.localAccountPrincipal?.userID == String(repeating: "a", count: 64))
        #expect(a.viewModel.selectUser(try #require(a.viewModel.savedRemoteUsers.first).id))
        #expect(a.viewModel.selectedGroup?.accountPair != nil)
        #expect(a.viewModel.makeSelectedGroupInviteURL() == nil)
        #expect(a.viewModel.groupStorageIssue == nil)
        #expect(throws: (any Error).self) { try a.viewModel.internetSettingsStore.loadIdentity(memberID: "a") }
        #expect(try a.viewModel.internetSettingsStore.loadPrincipal(memberID: "a") == a.viewModel.localAccountPrincipal)
        #expect(throws: (any Error).self) { try a.viewModel.internetSettingsStore.loadPrincipal(memberID: "different") }
        try a.viewModel.internetSettingsStore.save(url: "https://account.test", token: "replacement-without-identity")
        #expect(try a.viewModel.internetSettingsStore.loadPrincipal(memberID: "a") == nil)
    }

    @Test(arguments: [false, true]) func signedOutInternetRegistrationKeepsOfflineCallIdentityAfterNativeLogin(peerHasCertificate: Bool) throws {
        let f = AccountCallFixture(); defer { f.disconnect() }
        let a = try f.peer("a", account: "a"), b = try f.peer("b", account: "b"), a2 = try f.peer("a2", account: "a")
        try f.introduce(b, to: a); try f.introduce(a2, to: a)
        let user = try #require(a.viewModel.savedRemoteUsers.first)
        #expect(a.viewModel.selectUser(user.id))
        let group = try #require(a.viewModel.selectedGroup)
        let credential = try a.viewModel.groupRepository.credential(for: group.id)
        let count = a.viewModel.groups.count
        a.viewModel.disconnect()
        let store = a.viewModel.internetSettingsStore
        let retired = try #require(try store.retireAppleCredential())
        try store.finishRevocation(retired)
        let restarted = try f.restart(a)
        #expect(restarted.viewModel.localAccountPrincipal == a.viewModel.localAccountPrincipal)
        #expect(!restarted.viewModel.hasInternetCredentials)
        #expect(try store.load() == nil && store.loadIdentity(memberID: "a") == nil)
        #expect(restarted.viewModel.savedRemoteUsers.map(\.id) == [user.id])
        #expect(restarted.viewModel.selectUser(user.id))
        #expect(restarted.viewModel.selectedGroup?.id == group.id)
        #expect(restarted.viewModel.groups.count == count)
        #expect(try restarted.viewModel.groupRepository.credential(for: group.id) == credential)
        #expect(restarted.viewModel.makeSelectedGroupInviteURL() == nil)
        restarted.callSession.authenticate(["b"])
        try f.deliverProfile(from: b, to: restarted, certified: peerHasCertificate)
        #expect(restarted.viewModel.peerProfiles["b"]?.verified != nil)
        #expect(Set(IntercomViewModel.admittedMemberships(in: restarted.viewModel.peerProfiles).keys.map(\.rawValue)) == ["b"])
        // Offline trust still verifies a current peer certificate. A new account
        // reusing the old device key must not inherit the old account's call.
        restarted.callSession.authenticate([]); restarted.callSession.authenticate(["b"])
        let key = try b.viewModel.internetSettingsStore.deviceSigningKey()
        let changed = try testIdentityCertificate(signer: f.issuer, userID: String(repeating: "c", count: 64),
            memberID: "b", deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation))
        let identity = try changed.verify(origin: URL(string: "https://account.test")!, trustedIssuerKey: changed.issuerKey)
        let profile = try testPeerProfile(restarted.viewModel, peerID: "b", displayName: "Same device, different account",
            signer: DeviceIdentitySigner(memberID: "b", key: key, identity: identity))
        restarted.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "b",
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))))
        #expect(restarted.viewModel.peerProfiles["b"]?.verified == nil)
    }

    @Test func missingLocalAccountIdentityCannotDowngradeASavedAccountCallToDeviceIDs() throws {
        let f = AccountCallFixture(); defer { f.disconnect() }
        let a = try f.peer("a", account: "a"), b = try f.peer("b", account: "b")
        try f.introduce(b, to: a)
        let user = try #require(a.viewModel.savedRemoteUsers.first)
        #expect(a.viewModel.selectUser(user.id))
        let original = a.groupStore.snapshot
        try a.viewModel.saveInternetConnection(url: "https://account.test", token: "manual-without-account-identity")
        #expect(a.viewModel.localAccountPrincipal == nil)
        #expect(!a.viewModel.selectUser(user.id))
        #expect(a.groupStore.snapshot == original)
        #expect(a.viewModel.groupErrorMessage?.contains("Verify your account") == true)
    }

    @Test(arguments: ["current", "signed-out", "manual"]) func replacedPublicAccountStopsOldCallsAndKeepsDeletionTarget(source: String) throws {
        let f = AccountCallFixture(); defer { f.disconnect() }
        let a = try f.peer("a", account: "a"), b = try f.peer("b", account: "b")
        try f.introduce(b, to: a)
        let user = try #require(a.viewModel.savedRemoteUsers.first)
        #expect(a.viewModel.selectUser(user.id))
        a.viewModel.connectLocal()
        #expect(a.viewModel.activeGroupID != nil)
        let before = a.groupStore.snapshot
        let store = a.viewModel.internetSettingsStore
        if source == "signed-out" {
            let retired = try #require(try store.retireAppleCredential())
            try store.finishRevocation(retired)
        } else if source == "manual" {
            try a.viewModel.saveInternetConnection(url: "https://account.test", token: "manual-token")
        }
        let key = try store.deviceSigningKey()
        let certificate = try testIdentityCertificate(signer: f.issuer, userID: String(repeating: "c", count: 64),
            deviceID: store.accountDeviceID(), memberID: "a", deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation))
        let identity = try certificate.verify(origin: URL(string: "https://account.test")!, trustedIssuerKey: certificate.issuerKey)
        #expect(throws: (any Error).self) {
            try a.viewModel.saveInternetConnection(url: "https://account.test", token: "replacement-token", identity: identity)
        }
        #expect(!a.viewModel.canStartCalls)
        #expect(a.viewModel.activeGroupID == nil)
        #expect(a.viewModel.localAccountPrincipal == nil)
        #expect(!a.viewModel.hasInternetCredentials)
        #expect(try store.load() == nil)
        #expect(try store.deletionAccess()?.userID == String(repeating: "a", count: 64))
        #expect(try store.deletionAccess()?.requiresAppleVerification == true)
        #expect(a.groupStore.snapshot == before)
        #expect(!a.viewModel.selectUser(user.id))
        a.viewModel.connectLocal()
        #expect(a.viewModel.activeGroupID == nil)
        let restarted = try f.restart(a)
        #expect(!restarted.viewModel.canStartCalls)
        #expect(restarted.viewModel.accountSession.userID != nil)
        #expect(throws: (any Error).self) { try restarted.viewModel.makeInternetAccountAuthorization() }
        #expect(throws: (any Error).self) {
            try restarted.viewModel.saveInternetConnection(url: "https://another.test", token: "manual-token")
        }
    }

    @Test func schemaFiveUpgradePreservesSignedPendingReceiptAndCredential() throws {
        let f = AccountCallFixture(); defer { f.disconnect() }
        let a = try f.peer("a", account: "a"), b = try f.peer("b", account: "b")
        try f.introduce(b, to: a)
        var old = a.groupStore.snapshot
        old.version = 5
        let receipt = try #require(old.groups.first?.pendingInvitation)
        let upgraded = try GroupSnapshot.decode(old.encoded()).upgraded()
        #expect(upgraded.version == 7)
        #expect(upgraded.groups.first?.pendingInvitation == receipt)
        #expect(upgraded.groups.first?.credentialReference == old.groups.first?.credentialReference)
        #expect(upgraded.users == old.users)
        #expect(a.viewModel.selectUser(try #require(a.viewModel.savedRemoteUsers.first).id))
        var invalid = a.groupStore.snapshot; invalid.version = 5
        #expect(throws: (any Error).self) { try invalid.encoded() }
    }

    @Test func ownOtherDeviceCannotBecomeAnIndividualCallTarget() throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let a = try fixture.peer("alice-phone", account: "a")
        let a2 = try fixture.peer("alice-tablet", account: "a")
        try fixture.introduce(a2, to: a)
        let saved = try #require(a.viewModel.savedUsers.first)
        #expect(a.viewModel.savedRemoteUsers.isEmpty)
        #expect(!a.viewModel.selectUser(saved.id))
    }
}

@MainActor private final class AccountCallFixture {
    let issuer = P256.Signing.PrivateKey()
    var peers: [AppTestSupport.Harness] = []
    var namespaces: [String] = []
    var credentialStores: [String: InMemoryGroupCredentialStore] = [:]
    func peer(_ memberID: String, account: String, at date: Date = Date()) throws -> AppTestSupport.Harness {
        let namespace = "RideIntercom.AccountCallTests." + UUID().uuidString
        namespaces.append(namespace)
        let store = InternetConnectionSettingsStore(keychain: DictionaryKeychain(), namespace: namespace)
        let key = try store.deviceSigningKey()
        let certificate = try testIdentityCertificate(signer: issuer, userID: String(repeating: account, count: 64),
            deviceID: store.accountDeviceID(), memberID: memberID, deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation), now: date)
        let identity = try certificate.verify(origin: URL(string: "https://account.test")!, trustedIssuerKey: certificate.issuerKey, now: date)
        try store.save(url: "https://account.test", token: "ri1.\(String(repeating: "d", count: 64)).\(identity.deviceID).\(String(repeating: "e", count: 64))", identity: identity)
        let credentials = InMemoryGroupCredentialStore()
        credentialStores[memberID] = credentials
        let h = AppTestSupport.makeHarness(groups: [], credentialStore: credentials, internetSettingsStore: store, localMemberID: memberID)
        peers.append(h)
        return h
    }
    func restart(_ previous: AppTestSupport.Harness) throws -> AppTestSupport.Harness {
        let memberID = previous.viewModel.localMemberIdentity.memberID
        let credentials = try #require(credentialStores[memberID])
        let h = AppTestSupport.makeHarness(groups: [], groupStore: previous.groupStore, credentialStore: credentials,
            internetSettingsStore: previous.viewModel.internetSettingsStore, localMemberID: memberID)
        peers.append(h)
        return h
    }
    func introduce(_ sender: AppTestSupport.Harness, to receiver: AppTestSupport.Harness) throws {
        #expect(sender.viewModel.createTalkGroup(name: "Friends"))
        try receiver.viewModel.acceptInviteURL(#require(sender.viewModel.makeSelectedGroupInviteURL()))
    }
    func deliverProfile(from sender: AppTestSupport.Harness, to receiver: AppTestSupport.Harness, certified: Bool = true) throws {
        let memberID = sender.viewModel.localMemberIdentity.memberID
        let store = sender.viewModel.internetSettingsStore
        let signer = try certified ? store.invitationSigner(memberID: memberID)
            : DeviceIdentitySigner(memberID: memberID, key: store.deviceSigningKey())
        let profile = try testPeerProfile(receiver.viewModel, peerID: memberID, displayName: "Same name", signer: signer)
        receiver.viewModel.handleTransportEvent(.receivedApplicationData(peerID: memberID,
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))))
    }
    func disconnect() {
        peers.forEach { $0.viewModel.disconnect() }
        namespaces.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
    }
}
