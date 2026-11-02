import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct ContactInvitationSessionTests {
    /// The first decisive experiment uses actual RTC adapters and Multipeer
    /// discovery/authentication/application data. No auth event is injected.
    @Test(.timeLimit(.minutes(1)))
    func nativeControlOnlyReceivesAcceptanceFromPreviouslyUnknownPeer() async throws {
        let suffix = UUID().uuidString.prefix(8)
        let authorID = "contact-author-\(suffix)"
        let friendID = "contact-friend-\(suffix)"
        let authorTransport = RideIntercomCallSessionAdapter(memberID: authorID)
        let friendTransport = RideIntercomCallSessionAdapter(memberID: friendID)
        var authorsContacts: [String] = []
        var friendsContacts: [String] = []
        let author = ContactInvitationSession(transport: authorTransport, authority: testInvitationAuthority(),
            signer: testIdentitySigner(authorID), displayName: "Author", routes: [.multipeer]) { identity, name in
                #expect(identity.memberID == friendID)
                #expect(name == "Friend")
                authorsContacts.append(identity.memberID)
            }
        let friend = ContactInvitationSession(transport: friendTransport, authority: testInvitationAuthority(),
            signer: testIdentitySigner(friendID), displayName: "Friend", routes: [.multipeer]) { identity, name in
                #expect(identity.memberID == authorID)
                #expect(name == "Author")
                friendsContacts.append(identity.memberID)
            }
        defer { author.stop(); friend.stop() }
        let url = try author.issue()
        #expect(authorsContacts.isEmpty)
        try friend.accept(url)
        #expect(friendsContacts == [authorID], "Explicit acceptance stores the signed inviter immediately")
        let deadline = ContinuousClock.now + .seconds(30)
        while (!author.isConfirmed || !friend.isAcknowledged), ContinuousClock.now < deadline {
            friend.retry()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(authorsContacts == [friendID])
        #expect(friendsContacts == [authorID])
        #expect(author.isConfirmed)
        #expect(friend.isAcknowledged)
        // These coordinators own only CallSession control; no App audio pipeline
        // or ordinary group repository is constructed by this experiment.
    }
}
