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
}
