import CoreTransferable
import CryptoKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import RideIntercom

@MainActor
struct ContactInvitationPresentationTests {
    private func authorURL() throws -> (AppTestSupport.Harness, URL) {
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "presentation-author")
        h.viewModel.contactSessionFactory = { RecordingCallSession() }
        return (h, try #require(h.viewModel.makeContactInviteURL()))
    }

    @Test func previewAndCancelDoNotCreateAUserPendingRecordOrSigningKey() throws {
        let (author, url) = try authorURL(); defer { author.viewModel.disconnect() }
        let keychain = DictionaryKeychain(), namespace = "contact-preview-" + UUID().uuidString
        let settings = InternetConnectionSettingsStore(keychain: keychain, namespace: namespace)
        let friend = AppTestSupport.makeHarness(groups: [], internetSettingsStore: settings, localMemberID: "presentation-friend")
        let notification = RecordingCallSession()
        friend.viewModel.contactSessionFactory = { notification }
        defer { friend.viewModel.disconnect() }
        let snapshot = friend.groupStore.snapshot, saves = friend.groupStore.saveCount
        #expect(friend.viewModel.previewContactInvitation(url))
        #expect(friend.viewModel.contactInvitationPresentation?.id.hasPrefix("accept-") == true)
        #expect(friend.groupStore.snapshot == snapshot)
        #expect(friend.groupStore.saveCount == saves)
        #expect(keychain.accounts(service: namespace + ".InternetConnection").isEmpty)
        friend.viewModel.dismissContactInvitationPresentation()
        #expect(friend.viewModel.contactInvitationPresentation?.id == nil)
        #expect(friend.groupStore.snapshot == snapshot)
        #expect(friend.viewModel.savedRemoteUsers.isEmpty)
        #expect(friend.viewModel.pendingContactInvitations.isEmpty)
        #expect(friend.viewModel.previewContactInvitation(url))
        #expect(friend.viewModel.acceptPresentedContactInvitation())
        #expect(friend.viewModel.contactInvitationPresentation?.id == nil)
        #expect(friend.viewModel.contactInvitationID != nil)
        #expect(notification.connectedGroup != nil, "Closing the accepted preview keeps the bounded Users-owned notification alive")
    }

    @Test func contactShareReusesOneStoredTokenAndRevalidatesAtExport() async throws {
        var now = Date()
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "sharing-author", callAccessNow: { now })
        h.viewModel.contactSessionFactory = { RecordingCallSession() }
        defer { h.viewModel.disconnect() }
        let url = try #require(h.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        let before = h.groupStore.saveCount
        let share = InvitationShare(viewModel: h.viewModel, contactInvitationID: id)
        for _ in 0..<2 {
            let bytes = try await share.exported(as: .url)
            let exported = try await URL(importing: bytes, contentType: .url)
            let expectedDigest = SHA256.hash(data: Data(url.absoluteString.utf8))
            let actualDigest = SHA256.hash(data: Data(exported.absoluteString.utf8))
            #expect(actualDigest == expectedDigest)
        }
        #expect(h.groupStore.saveCount == before + 1, "Only the first export records that it was sent")
        #expect(h.viewModel.pendingContactInvitations.count == 1)
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        await #expect(throws: (any Error).self) { _ = try await share.exported(as: .url) }
        now = Date()
        try h.viewModel.cancelContactInvitation(id)
        await #expect(throws: (any Error).self) { _ = try await share.exported(as: .url) }
        let anotherURL = try #require(h.viewModel.makeContactInviteURL())
        let anotherID = try #require(GroupInviteTokenCodec.decodeJoinURL(anotherURL, contactBootstrap: true).directInvitation).context.id
        let currentShare = InvitationShare(viewModel: h.viewModel, contactInvitationID: anotherID)
        h.viewModel.accountSession.signOut()
        await #expect(throws: (any Error).self) { _ = try await currentShare.exported(as: .url) }
    }

    /// Not sent until a share destination takes the link; expired sent invitations stay, as Expired, until a new
    /// one with the same name replaces them.
    @Test func invitationIsNotSentUntilSharedAndExpiredOnesOfferANewOne() async throws {
        var now = Date()
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "state-author", callAccessNow: { now })
        h.viewModel.contactSessionFactory = { RecordingCallSession() }
        defer { h.viewModel.disconnect() }
        let url = try #require(h.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        #expect(h.viewModel.setContactInvitationNickname(id, "Haruka"))
        var record = try #require(h.viewModel.contactInvitationRecord(id))
        #expect(h.viewModel.contactInvitationStateWord(for: record) == "Not sent yet")
        _ = try await InvitationShare(viewModel: h.viewModel, contactInvitationID: id).exported(as: .url)
        record = try #require(h.viewModel.contactInvitationRecord(id))
        #expect(h.viewModel.contactInvitationStateWord(for: record) == "Waiting to be accepted")
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        record = try #require(h.viewModel.pendingContactInvitations.first { $0.id == id }, "An expired sent invitation stays listed")
        #expect(h.viewModel.contactInvitationStateWord(for: record) == "Expired")
        try h.viewModel.groupRepository.removeExpiredContactInvitations(now: now.timeIntervalSince1970)
        record = try #require(h.viewModel.contactInvitationRecord(id))
        #expect(record.state == .expired && record.credentialReference == nil, "The secret is gone; only the name is kept")
        h.viewModel.contactInvitationPresentation = .sharing(id)
        h.viewModel.sendNewContactInvitation(replacing: id)
        #expect(h.viewModel.contactInvitationRecord(id) == nil, "The new invitation replaces the expired one")
        let replacement = try #require(h.viewModel.pendingContactInvitations.first)
        #expect(replacement.id != id && replacement.nickname == "Haruka")
        #expect(h.viewModel.contactInvitationStateWord(for: replacement) == "Not sent yet")
        #expect(h.viewModel.contactInvitationPresentation?.id == "share-" + replacement.id.uuidString)
    }

    @Test func acceptingAPreviewRegistersTheInviterWithoutInterruptingAnExistingCall() throws {
        let (author, url) = try authorURL(); defer { author.viewModel.disconnect() }
        let group = try IntercomGroup(name: "Current call", members: [.init(id: "presentation-friend", displayName: "Friend")], accessSecret: "current-call-key")
        let friend = AppTestSupport.makeHarness(groups: [group], localMemberID: "presentation-friend")
        let notification = RecordingCallSession()
        friend.viewModel.contactSessionFactory = { notification }
        defer { friend.viewModel.disconnect() }
        friend.viewModel.selectGroup(group)
        friend.viewModel.applyLocalMute(true)
        let disconnects = friend.callSession.disconnectCallCount
        #expect(friend.viewModel.previewContactInvitation(url))
        #expect(friend.viewModel.acceptPresentedContactInvitation())
        #expect(friend.viewModel.savedRemoteUsers.map(\.memberIDs) == [["presentation-author"]])
        #expect(friend.viewModel.activeGroupID == group.id)
        #expect(friend.viewModel.isMuted)
        #expect(friend.callSession.disconnectCallCount == disconnects)
        #expect(friend.callSession.connectedGroup?.id == group.id)
        #expect(notification.connectedGroup == nil)
        #expect(friend.viewModel.regularGroups.map(\.id) == [group.id])
    }
}
