import Foundation
import Testing
@testable import RideIntercom

/// The destination Control follows the app's published destinations and live call.
struct CallControlStateTests {
    private let user = WidgetCallDestination(id: "user", name: "Haruka", kind: .user)
    private let group = WidgetCallDestination(id: "group", name: "Touring", kind: .group)
    private let call = CallLivePresentation(
        reference: CallSurfaceReference(accountAccessID: UUID(), connectionGeneration: UUID(), groupID: UUID()),
        status: .inCall, isMuted: false, canControlMicrophone: true)

    @Test func unconfiguredUntilADestinationIsChosen() {
        #expect(CallControlState(configured: nil, snapshot: .init(destinations: [user])) == .unconfigured)
    }

    @Test func readyWhenTheDestinationIsSavedAndNotInACall() {
        let snapshot = WidgetDestinationSnapshot(destinations: [user, group], currentDestinationID: group.id, currentCall: call)
        #expect(CallControlState(configured: user, snapshot: snapshot) == .ready(user))
    }

    @Test func inCallOnlyForTheDestinationOfTheLiveCall() {
        let snapshot = WidgetDestinationSnapshot(destinations: [user, group], currentDestinationID: user.id, currentCall: call)
        #expect(CallControlState(configured: user, snapshot: snapshot) == .inCall(user))
        #expect(CallControlState(configured: group, snapshot: snapshot) == .ready(group))
    }

    @Test func unavailableWhenTheDestinationWasRemoved() {
        #expect(CallControlState(configured: user, snapshot: .init(destinations: [group])) == .unavailable)
        #expect(CallControlState(configured: user, snapshot: nil) == .unavailable)
    }

    @Test func showsTheCurrentNameFromTheSnapshot() {
        let renamed = WidgetCallDestination(id: user.id, name: "Haruka Y", kind: .user)
        #expect(CallControlState(configured: user, snapshot: .init(destinations: [renamed])) == .ready(renamed))
    }
}
