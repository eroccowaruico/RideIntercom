import Foundation
import Testing
@testable import RideIntercom

/// Choosing someone from a list connects at once; a different live call is only
/// replaced after the person confirms the switch.
@MainActor
struct DestinationOpeningTests {
    @Test func choosingWhileIdleConnectsImmediately() throws {
        let h = try harness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let first = vm.groups[0]
        #expect(vm.openDestination(.group(first.id)) == .opened)
        #expect(vm.activeGroupID == first.id && vm.selectedGroup?.id == first.id)
        #expect(vm.hasAnyActiveGroupConnection)
    }

    @Test func choosingTheCurrentCallReopensItWithoutReconnecting() throws {
        let h = try harness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let first = vm.groups[0], second = vm.groups[1]
        #expect(vm.openDestination(.group(first.id)) == .opened)
        let reference = vm.currentCallReference
        vm.selectGroup(second, connectIfIdle: false)
        #expect(vm.openDestination(.group(first.id)) == .opened)
        #expect(vm.currentCallReference == reference)
        #expect(vm.selectedGroup?.id == first.id)
    }

    /// A connection is one place at a time: another choice shows the live call and never switches or asks.
    @Test func choosingAnotherDestinationDuringACallShowsTheLiveCall() throws {
        let h = try harness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let first = vm.groups[0], second = vm.groups[1]
        #expect(vm.openDestination(.group(first.id)) == .opened)
        let reference = vm.currentCallReference
        #expect(vm.openDestination(.group(second.id)) == .showsLiveCall)
        #expect(vm.activeGroupID == first.id && vm.currentCallReference == reference)
        #expect(vm.selectedGroup?.id == first.id)
        #expect(vm.groupErrorMessage == nil)
    }

    /// Leaving takes ending the call; then the next choice connects there.
    @Test func afterEndingTheCallTheNextChoiceConnects() throws {
        let h = try harness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let first = vm.groups[0], second = vm.groups[1]
        #expect(vm.openDestination(.group(first.id)) == .opened)
        #expect(vm.endCall(vm.currentCallReference))
        #expect(vm.openDestination(.group(second.id)) == .opened)
        #expect(vm.activeGroupID == second.id && vm.hasAnyActiveGroupConnection)
    }

    private func harness() throws -> AppTestSupport.Harness {
        let first = try IntercomGroup(name: "First", members: [.init(id: "local", displayName: "You")], accessSecret: "group-key")
        let second = try IntercomGroup(name: "Second", members: [.init(id: "local", displayName: "You")], accessSecret: "second-key")
        return AppTestSupport.makeHarness(groups: [first, second])
    }
}
