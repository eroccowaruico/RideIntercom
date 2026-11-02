import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct ContactInvitationSessionSafetyTests {
    private enum Failure: Error { case storage }
    @MainActor private final class ConfirmationProbe {
        var memberIDs: [String] = []
        var fails = false
        func save(_ proof: VerifiedDeviceProof, name: String) throws {
            if fails { throw Failure.storage }
            memberIDs.append(proof.memberID)
        }
    }
    @MainActor private struct Pair {
        let authorTransport: RecordingCallSession
        let friendTransport: RecordingCallSession
        let authorsContacts: ConfirmationProbe
        let friendsContacts: ConfirmationProbe
        let author: ContactInvitationSession
        let friend: ContactInvitationSession
        init() {
            let authorTransport = RecordingCallSession(), friendTransport = RecordingCallSession()
            let authorsContacts = ConfirmationProbe(), friendsContacts = ConfirmationProbe()
            self.authorTransport = authorTransport; self.friendTransport = friendTransport
            self.authorsContacts = authorsContacts; self.friendsContacts = friendsContacts
            author = ContactInvitationSession(transport: authorTransport, authority: testInvitationAuthority(),
                signer: testIdentitySigner("safety-author"), displayName: "Author", confirm: authorsContacts.save)
            friend = ContactInvitationSession(transport: friendTransport, authority: testInvitationAuthority(),
                signer: testIdentitySigner("safety-friend"), displayName: "Friend", confirm: friendsContacts.save)
        }
        func prepare() throws -> (URL, ApplicationDataMessage) {
            let url = try author.issue()
            try friend.accept(url)
            friendTransport.authenticate(["safety-author"])
            let message = try #require(friendTransport.sentApplicationDataMessages.last)
            return (url, message)
        }
        func deliver(_ message: ApplicationDataMessage, peer: String = "safety-friend") {
            authorTransport.onEvent?(.receivedApplicationData(peerID: peer, message: message))
        }
        func stop() { author.stop(); friend.stop() }
    }

    @Test func duplicateReceiptAndAcknowledgementDoNotRepeatRegistration() throws {
        let pair = Pair(); defer { pair.stop() }
        let (_, receipt) = try pair.prepare()
        #expect(pair.friendsContacts.memberIDs == ["safety-author"])
        pair.deliver(receipt)
        #expect(pair.authorsContacts.memberIDs.isEmpty)
        pair.authorTransport.authenticate(["safety-friend"])
        pair.deliver(receipt)
        pair.deliver(receipt)
        #expect(pair.authorsContacts.memberIDs == ["safety-friend"])
        let ack = try #require(pair.authorTransport.sentApplicationDataMessages.last)
        pair.friendTransport.onEvent?(.receivedApplicationData(peerID: "safety-author", message: ack))
        pair.friendTransport.onEvent?(.receivedApplicationData(peerID: "safety-author", message: ack))
        #expect(pair.friend.isAcknowledged)
        #expect(pair.friendsContacts.memberIDs == ["safety-author"])
    }

    @Test func firstVerifiedRecipientBindingRejectsAnotherAuthenticatedRecipient() throws {
        let pair = Pair(); defer { pair.stop() }
        let (url, receipt) = try pair.prepare()
        pair.authorTransport.authenticate(["safety-friend", "safety-stranger"])
        pair.deliver(receipt)
        let token = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        let second = try token.accept(signer: testIdentitySigner("safety-stranger"), displayName: "Stranger", contactBootstrap: true)
        let other = ApplicationDataMessage(namespace: DirectInvitationReceipt.namespace,
            payload: try JSONEncoder().encode(second.receipt))
        let sentCount = pair.authorTransport.sentApplicationDataMessages.count
        pair.deliver(other, peer: "safety-stranger")
        #expect(pair.authorsContacts.memberIDs == ["safety-friend"])
        #expect(pair.authorTransport.sentApplicationDataMessages.count == sentCount)
    }

    @Test func stopIsTerminalAndLateTransportEventsCannotRegisterARecipient() throws {
        let pair = Pair(); defer { pair.stop() }
        let (url, receipt) = try pair.prepare()
        let delayed = try #require(pair.authorTransport.onEvent)
        pair.author.stop()
        pair.author.stop()
        delayed(.authenticated(members: [.init(peer: .init(id: .init(rawValue: "safety-friend"), displayName: "Friend"),
            route: .multipeer, isConnected: true)]))
        delayed(.receivedApplicationData(peerID: "safety-friend", message: receipt))
        #expect(pair.authorsContacts.memberIDs.isEmpty)
        #expect(pair.authorTransport.disconnectCallCount == 1)
        #expect(throws: GroupInviteTokenError.incompatibleCall) { _ = try pair.author.issue() }
        #expect(throws: GroupInviteTokenError.incompatibleCall) { try pair.author.accept(url) }
    }

    @Test func storageFailureLeavesNotificationRetryableWithoutAcknowledgingSuccess() throws {
        let pair = Pair(); defer { pair.stop() }
        let (_, receipt) = try pair.prepare()
        pair.authorTransport.authenticate(["safety-friend"])
        pair.authorsContacts.fails = true
        pair.deliver(receipt)
        #expect(!pair.author.isConfirmed)
        #expect(pair.authorsContacts.memberIDs.isEmpty)
        #expect(pair.authorTransport.sentApplicationDataMessages.isEmpty)
        #expect(pair.author.failure is Failure)
        pair.authorsContacts.fails = false
        pair.deliver(receipt)
        #expect(pair.authorsContacts.memberIDs == ["safety-friend"])
        #expect(pair.author.isConfirmed)
        #expect(pair.author.failure == nil)
    }
}
