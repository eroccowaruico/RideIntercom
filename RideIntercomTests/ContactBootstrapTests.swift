import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct ContactBootstrapTests {
    // Ordinary group invitation acceptance remains a separate contract.
    @Test func unknownContactAcceptanceRegistersAuthorAndAuthenticatedDeliveryRegistersRecipient() throws {
        let author = AppTestSupport.makeHarness(groups: [], localMemberID: "contact-author")
        let friend = AppTestSupport.makeHarness(groups: [], localMemberID: "contact-friend")
        let a = author.viewModel
        let b = friend.viewModel
        let authorNotification = RecordingCallSession(), friendNotification = RecordingCallSession()
        a.contactSessionFactory = { authorNotification }
        b.contactSessionFactory = { friendNotification }
        defer { a.disconnect(); b.disconnect() }
        let url = try #require(a.makeContactInviteURL())
        #expect(a.savedRemoteUsers.isEmpty)
        #expect(a.groups.isEmpty)
        try b.acceptContactInviteURL(url)
        #expect(a.savedRemoteUsers.isEmpty)
        #expect(b.savedRemoteUsers.map(\.memberIDs) == [["contact-author"]])
        #expect(a.groups.isEmpty)
        #expect(b.regularGroups.isEmpty)
        #expect(friendNotification.sentApplicationDataMessages.isEmpty)

        friendNotification.authenticate(["contact-author"])
        let receipt = try #require(friendNotification.sentApplicationDataMessages.last {
            $0.namespace == DirectInvitationReceipt.namespace
        })
        #expect(b.savedRemoteUsers.map(\.memberIDs) == [["contact-author"]], "Explicit acceptance already saved the signed author")
        // A receipt from an unbound / unauthenticated sender cannot save anyone.
        authorNotification.onEvent?(.receivedApplicationData(peerID: "contact-friend", message: receipt))
        #expect(a.savedRemoteUsers.isEmpty)
        authorNotification.authenticate(["contact-friend"])
        authorNotification.onEvent?(.receivedApplicationData(peerID: "contact-friend", message: receipt))
        #expect(a.savedRemoteUsers.map(\.memberIDs) == [["contact-friend"]])
        let spentID = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        #expect(throws: (any Error).self) {
            _ = try a.contactInvitationURLForSharing(spentID, expectedAccountAccessID: a.accountAccessID)
        }
        #expect(b.savedRemoteUsers.map(\.memberIDs) == [["contact-author"]])
        let acknowledgement = try #require(authorNotification.sentApplicationDataMessages.last {
            $0.namespace == DirectInvitationReceipt.namespace
        })
        friendNotification.onEvent?(.receivedApplicationData(peerID: "contact-author", message: acknowledgement))
        #expect(b.savedRemoteUsers.map(\.memberIDs) == [["contact-author"]])
        #expect(a.regularGroups.isEmpty, "Contact bootstrap is never an ordinary group")
        #expect(b.regularGroups.isEmpty)
        let call = IntercomGroup.directCallID(memberIDs: ["contact-author", "contact-friend"])
        #expect(a.groups.map(\.id) == [call] && b.groups.map(\.id) == [call])
        let key = try #require(try a.groupRepository.credential(for: call))
        #expect(try b.groupRepository.credential(for: call) == key, "Both sides finish the invitation with one pair call key")
        #expect(author.callSession.startMediaCallCount == 0)
        #expect(friend.callSession.startMediaCallCount == 0)
    }

    @Test func provisionalNamesPairAColorWithACreatureAndAvoidNamesInUse() {
        var generator = SystemRandomNumberGenerator()
        #expect(ProvisionalName.all(japanese: true).count == 112)
        #expect(ProvisionalName.all(japanese: true).contains("青いキツネ"))
        #expect(ProvisionalName.all(japanese: false).contains("Blue Fox"))
        let used = Set(ProvisionalName.all(japanese: false).filter { $0 != "White Gull" })
        #expect(ProvisionalName.candidate(japanese: false, avoiding: used, using: &generator) == "White Gull")
        let everything = Set(ProvisionalName.all(japanese: false))
        #expect(ProvisionalName.candidate(japanese: false, avoiding: everything, using: &generator) == "Blue Fox 2")
    }

    @Test func theNameGivenBeforeSendingBecomesTheSavedUsersLocalName() throws {
        let author = AppTestSupport.makeHarness(groups: [], localMemberID: "contact-author")
        let friend = AppTestSupport.makeHarness(groups: [], localMemberID: "contact-friend")
        let a = author.viewModel, b = friend.viewModel
        let authorNotification = RecordingCallSession(), friendNotification = RecordingCallSession()
        a.contactSessionFactory = { authorNotification }
        b.contactSessionFactory = { friendNotification }
        defer { a.disconnect(); b.disconnect() }
        let url = try #require(a.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        #expect(a.setContactInvitationNickname(id, "  Riding Buddy  "))
        #expect(a.contactInvitationRecord(id)?.nickname == "Riding Buddy")

        try b.acceptContactInviteURL(url)
        friendNotification.authenticate(["contact-author"])
        let receipt = try #require(friendNotification.sentApplicationDataMessages.last {
            $0.namespace == DirectInvitationReceipt.namespace
        })
        authorNotification.authenticate(["contact-friend"])
        authorNotification.onEvent?(.receivedApplicationData(peerID: "contact-friend", message: receipt))
        let user = try #require(a.savedRemoteUsers.first)
        #expect(user.localName == "Riding Buddy", "The inviter's own word for the person names them on this device")
        #expect(user.displayName != "Riding Buddy", "The person's shared name is kept separately")
    }

    @Test func reInvitingAnExistingContactReplacesThePairCallKeyOnBothDevices() throws {
        let callID = IntercomGroup.directCallID(memberIDs: ["contact-author", "contact-friend"])
        let authorCall = try IntercomGroup(id: callID, name: "Direct Call", members: [
            .init(id: "contact-author", displayName: "Author"),
            .init(id: "contact-friend", displayName: "Friend")
        ], accessSecret: "author-legacy-key", kind: .direct)
        let friendCall = try IntercomGroup(id: callID, name: "Direct Call", members: [
            .init(id: "contact-friend", displayName: "Friend"),
            .init(id: "contact-author", displayName: "Author")
        ], accessSecret: "friend-legacy-key", kind: .direct)
        let author = AppTestSupport.makeHarness(groups: [authorCall], localMemberID: "contact-author")
        let friend = AppTestSupport.makeHarness(groups: [friendCall], localMemberID: "contact-friend")
        let a = author.viewModel
        let b = friend.viewModel
        let authorNotification = RecordingCallSession(), friendNotification = RecordingCallSession()
        a.contactSessionFactory = { authorNotification }
        b.contactSessionFactory = { friendNotification }
        defer { a.disconnect(); b.disconnect() }
        let authorLegacyKey = try #require(try a.groupRepository.credential(for: callID))
        let friendLegacyKey = try #require(try b.groupRepository.credential(for: callID))
        #expect(authorLegacyKey != friendLegacyKey)

        let firstURL = try #require(a.makeContactInviteURL())
        try b.acceptContactInviteURL(firstURL)
        friendNotification.authenticate(["contact-author"])
        let firstReceipt = try #require(friendNotification.sentApplicationDataMessages.last)
        authorNotification.authenticate(["contact-friend"])
        authorNotification.onEvent?(.receivedApplicationData(peerID: "contact-friend", message: firstReceipt))
        let firstAcknowledgement = try #require(authorNotification.sentApplicationDataMessages.last)
        friendNotification.onEvent?(.receivedApplicationData(peerID: "contact-author", message: firstAcknowledgement))

        let oldKey = try #require(try a.groupRepository.credential(for: callID))
        #expect(try b.groupRepository.credential(for: callID) == oldKey)
        #expect(oldKey != authorLegacyKey && oldKey != friendLegacyKey)

        #expect(a.setLocalDisplayName("Updated Author"))
        let secondURL = try #require(a.makeContactInviteURL())
        #expect(secondURL != firstURL)
        #expect(try GroupInviteTokenCodec.decodeJoinURL(secondURL, contactBootstrap: true).inviterDisplayName == "Updated Author")
        try b.acceptContactInviteURL(secondURL)
        friendNotification.authenticate(["contact-author"])
        let secondReceipt = try #require(friendNotification.sentApplicationDataMessages.last)
        authorNotification.authenticate(["contact-friend"])
        authorNotification.onEvent?(.receivedApplicationData(peerID: "contact-friend", message: secondReceipt))
        let secondAcknowledgement = try #require(authorNotification.sentApplicationDataMessages.last)
        friendNotification.onEvent?(.receivedApplicationData(peerID: "contact-author", message: secondAcknowledgement))

        #expect(b.savedRemoteUsers.first?.displayName == "Updated Author")
        let newKey = try #require(try a.groupRepository.credential(for: callID))
        #expect(newKey != oldKey)
        #expect(try b.groupRepository.credential(for: callID) == newKey)
        #expect(a.groups.map(\.id) == [callID] && b.groups.map(\.id) == [callID])
        #expect(a.groups.first?.kind == .direct && b.groups.first?.kind == .direct)
    }
}
