import Foundation
import Testing
@testable import RideIntercom

/// Group Settings opens from the call's menu and from list rows; renaming keeps the call.
@MainActor
struct GroupSettingsTests {
    @Test func renamingAGroupSavesTheTrimmedName() throws {
        let h = try harness(); let vm = h.viewModel
        let group = vm.groups[0]
        #expect(vm.renameGroup(group.id, to: "  Weekend Ride  "))
        #expect(vm.groups.first { $0.id == group.id }?.name == "Weekend Ride")
        #expect(h.groupStore.snapshot.groups.first { $0.id == group.id }?.name == "Weekend Ride")
    }

    @Test func renamingTheShownCallUpdatesItWithoutReconnecting() throws {
        let h = try harness(); let vm = h.viewModel
        defer { vm.disconnect() }
        let group = vm.groups[0]
        #expect(vm.openDestination(.group(group.id)) == .opened)
        let reference = vm.currentCallReference
        #expect(vm.renameGroup(group.id, to: "Weekend Ride"))
        #expect(vm.selectedGroup?.name == "Weekend Ride")
        #expect(vm.currentCallReference == reference)
    }

    @Test func invalidNamesAreRejected() throws {
        let h = try harness(); let vm = h.viewModel
        let group = vm.groups[0]
        #expect(!vm.renameGroup(group.id, to: "   "))
        #expect(!vm.renameGroup(group.id, to: "A|B"))
        #expect(vm.groups[0].name == "First")
        #expect(vm.groupErrorMessage != nil)
    }

    private func harness() throws -> AppTestSupport.Harness {
        let first = try IntercomGroup(name: "First", members: [.init(id: "local", displayName: "You")], accessSecret: "group-key")
        return AppTestSupport.makeHarness(groups: [first])
    }
}
