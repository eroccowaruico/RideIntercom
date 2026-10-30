import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct DirectInvitationAuthorityTests {
    @Test func receiptCannotBeReassignedOrExtendedByAGroupObserver() throws {
        let authority = testInvitationAuthority()
        let grant = try authority.issue(.init(groupID: UUID(), inviterMemberID: "author", expiresAt: 200))
        let original = try DirectInvitationReceipt.make(grant: grant, inviteeMemberID: "friend", displayName: "Friend")
        #expect(try authority.verify(original, now: 199.99) != nil)
        #expect(try authority.verify(original, now: 200) == nil)
        #expect(try authority.verify(original, now: .nan) == nil)
        var mutations: [DirectInvitationReceipt] = []
        var changed = original; changed.id = UUID(); mutations.append(changed)
        changed = original; changed.inviteeMemberID = "stranger"; mutations.append(changed)
        changed = original; changed.invitation?.expiresAt = 300; mutations.append(changed)
        changed = original; changed.invitation?.id = UUID(); mutations.append(changed)
        changed = original; changed.groupID = UUID(); changed.invitation?.groupID = changed.groupID; mutations.append(changed)
        changed = original; changed.inviterMemberID = "other-author"; changed.invitation?.inviterMemberID = "other-author"; mutations.append(changed)
        changed = original; changed.proof = nil; mutations.append(changed)
        for receipt in mutations { #expect(try authority.verify(receipt, now: 100) == nil) }
        changed = original; changed.displayName = "New shared name"
        #expect(try authority.verify(changed, now: 100) != nil)
    }

    @Test func reopeningTheSameInvitationHasTheSameReceiptIdentity() throws {
        let authority = testInvitationAuthority()
        let grant = try authority.issue(.init(groupID: UUID(), inviterMemberID: "author", expiresAt: 200))
        let first = try DirectInvitationReceipt.make(grant: grant, inviteeMemberID: "friend", displayName: "Friend")
        let reopened = try DirectInvitationReceipt.make(grant: grant, inviteeMemberID: "friend", displayName: "Renamed")
        #expect(first.id == reopened.id)
        #expect(first.proof == reopened.proof)
        let other = try DirectInvitationReceipt.make(grant: grant, inviteeMemberID: "other", displayName: "Other")
        #expect(first.id != other.id)
        let freshGrant = try authority.issue(.init(groupID: grant.context.groupID, inviterMemberID: "author", expiresAt: 200))
        let fresh = try DirectInvitationReceipt.make(grant: freshGrant, inviteeMemberID: "friend", displayName: "Friend")
        #expect(first.id != fresh.id)
        var invented = first; invented.id = UUID()
        invented.proof = Data(HMAC<SHA256>.authenticationCode(for: try invented.proofMessage(),
            using: SymmetricKey(data: try #require(Data(base64Encoded: grant.secret))))).base64EncodedString()
        #expect(try authority.verify(invented, now: 100) == nil) // Even a link holder cannot choose a new replay identity.
    }

    @Test func privateAuthorKeySurvivesRestartAndIsNotReplacedWhenUnreadable() throws {
        let keychain = AccountTestKeychain()
        let authority = testInvitationAuthority(keychain: keychain)
        let grant = try authority.issue(.init(groupID: UUID(), inviterMemberID: "author", expiresAt: 200))
        let receipt = try DirectInvitationReceipt.make(grant: grant, inviteeMemberID: "friend", displayName: "Friend")
        let retained = try #require(keychain.value)
        let restarted = testInvitationAuthority(keychain: keychain)
        #expect(try restarted.verify(receipt, now: 100) != nil)
        #expect(try testInvitationAuthority().verify(receipt, now: 100) == nil)
        keychain.fails = true
        #expect(throws: (any Error).self) { try restarted.issue(grant.context) }
        #expect(throws: (any Error).self) { try restarted.verify(receipt, now: 100) }
        #expect(keychain.value == retained)
        keychain.fails = false; keychain.value = "invalid retained key"
        #expect(throws: (any Error).self) { try restarted.issue(grant.context) }
        #expect(keychain.value == "invalid retained key")
    }

    @Test func accountNamespacesAndKeyRemovalDoNotCarryOldInvitationsAcrossAccounts() throws {
        let keychain = DictionaryKeychain()
        let a = DirectInvitationAuthority(keychain: keychain, namespace: "account-a")
        let b = DirectInvitationAuthority(keychain: keychain, namespace: "account-b")
        let context = DirectInvitationContext(groupID: UUID(), inviterMemberID: "author", expiresAt: 200)
        let grant = try a.issue(context)
        let receipt = try DirectInvitationReceipt.make(grant: grant, inviteeMemberID: "friend", displayName: "Friend")
        _ = try b.issue(context)
        #expect(try b.verify(receipt, now: 100) == nil)
        #expect(try a.verify(receipt, now: 100) != nil)
        try keychain.deleteSecret(service: "account-a.DirectInvitations", account: "author")
        _ = try a.issue(context)
        #expect(try a.verify(receipt, now: 100) == nil)
        #expect(try keychain.secret(service: "account-b.DirectInvitations", account: "author") != nil)
    }

    @Test func concurrentFirstIssuanceAdoptsTheKeyInstalledByAnotherProcess() throws {
        let keychain = InvitationKeyRace()
        let authority = testInvitationAuthority(keychain: keychain)
        let grant = try authority.issue(.init(groupID: UUID(), inviterMemberID: "author", expiresAt: 200))
        let receipt = try DirectInvitationReceipt.make(grant: grant, inviteeMemberID: "friend", displayName: "Friend")
        #expect(try authority.verify(receipt, now: 100) != nil)
        #expect(!keychain.overwroteWinner)
    }

    @Test func verificationDoesNotCreateAuthorKeysAndDirectedGrantRejectsOtherRecipients() throws {
        let keychain = InternetTestKeychain()
        let unknownAuthor = testInvitationAuthority(keychain: keychain)
        let grant = try testInvitationAuthority().issue(.init(groupID: UUID(), inviterMemberID: "author",
                                                             recipientMemberID: "friend", expiresAt: 200))
        let receipt = try DirectInvitationReceipt.make(grant: grant, inviteeMemberID: "friend", displayName: "Friend")
        #expect(try unknownAuthor.verify(receipt, now: 100) == nil)
        #expect(keychain.value == nil)
        #expect(throws: GroupInviteTokenError.invalidTokenEncoding) {
            try DirectInvitationReceipt.make(grant: grant, inviteeMemberID: "stranger", displayName: "Stranger")
        }
    }

    @Test func invitationURLReceiptsSaveOnlyTheDirectPairAndNeverPublishTheCapability() throws {
        let group = try IntercomGroup(name: "Friends", members: [.init(id: "author", displayName: "Author")], accessSecret: "group-secret")
        let author = AppTestSupport.makeHarness(groups: [group])
        let friend = AppTestSupport.makeHarness(groups: [])
        let a = author.viewModel; let b = friend.viewModel
        defer { a.disconnect(); b.disconnect() }
        a.selectGroup(group)
        let url = try #require(a.selectedGroupInviteURL)
        let token = try GroupInviteTokenCodec.decodeJoinURL(url)
        let grant = try #require(token.directInvitation)
        try b.acceptInviteURL(url)
        #expect(b.savedUsers.map(\.memberIDs) == [["author"]])
        friend.callSession.authenticate(["author", "stranger"])
        let sent = try #require(friend.callSession.sentApplicationDataMessages.last { $0.namespace == DirectInvitationReceipt.namespace })
        let body = try #require(String(data: sent.payload, encoding: .utf8))
        #expect(!body.contains(grant.secret))
        let snapshot = try friend.groupStore.snapshot.encoded()
        #expect(!String(decoding: snapshot, as: UTF8.self).contains(grant.secret))
        author.callSession.authenticate([b.localMemberIdentity.memberID, "stranger"])
        a.handleTransportEvent(.receivedApplicationData(peerID: b.localMemberIdentity.memberID, message: sent))
        #expect(a.savedUsers.map(\.memberIDs) == [[b.localMemberIdentity.memberID]])
        let acknowledgement = try #require(author.callSession.sentApplicationDataMessages.last { $0.namespace == DirectInvitationReceipt.namespace })
        b.handleTransportEvent(.receivedApplicationData(peerID: "author", message: acknowledgement))
        #expect(b.groupRepository.pendingInvitation(for: group.id) == nil)
        #expect(!a.savedUsers.flatMap(\.memberIDs).contains("stranger"))
        #expect(!b.savedUsers.flatMap(\.memberIDs).contains("stranger"))
        #expect(a.removeSavedUser(try #require(a.savedUsers.first).id))
        a.handleTransportEvent(.receivedApplicationData(peerID: b.localMemberIdentity.memberID, message: sent))
        #expect(a.savedUsers.isEmpty)
        try b.acceptInviteURL(url) // Reopening an old link still cannot restore the deleted entry.
        b.sendPendingInvitationReceipt()
        let reopened = try #require(friend.callSession.sentApplicationDataMessages.last { $0.namespace == DirectInvitationReceipt.namespace })
        a.handleTransportEvent(.receivedApplicationData(peerID: b.localMemberIdentity.memberID, message: reopened))
        #expect(a.savedUsers.isEmpty)
        var forged = try JSONDecoder().decode(DirectInvitationReceipt.self, from: sent.payload)
        forged.inviteeMemberID = "stranger"; forged.id = UUID()
        let message = ApplicationDataMessage(namespace: DirectInvitationReceipt.namespace, payload: try JSONEncoder().encode(forged))
        a.handleTransportEvent(.receivedApplicationData(peerID: "stranger", message: message))
        #expect(a.savedUsers.isEmpty)
    }
}

@MainActor
private final class InvitationKeyRace: KeychainSecretStoring {
    private var firstRead = true
    private let winner = Data(repeating: 7, count: 32).base64EncodedString()
    private(set) var overwroteWinner = false
    func accounts(service: String) throws -> [String] { ["author"] }
    func secret(service: String, account: String) throws -> String? {
        if firstRead { firstRead = false; return nil }
        return winner
    }
    func createSecretIfAbsent(_ secret: String, service: String, account: String) throws -> String { winner }
    func saveSecret(_ secret: String, service: String, account: String) throws { overwroteWinner = true }
    func deleteSecret(service: String, account: String) throws { }
}
