#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import RideIntercom

/// Draws the changed Mac screens in an offscreen window with the real AppKit controls.
/// The PNG attachments are the visual evidence for the Mac layout of each design change.
extension AppTests {
@MainActor
struct MacScreenRenderingTests {
    @Test(arguments: ["en", "ja"])
    func listsCallColumnAndSettingsDraw(language: String) async throws {
        let h = try AppTestSupport.makeHarnessWithSavedUser()
        let vm = h.viewModel
        defer { vm.disconnect() }
        var tab = AppTab.users
        let binding = Binding(get: { tab }, set: { tab = $0 })
        try await record(SignedInContentView(viewModel: vm, selectedTab: binding), size: .init(width: 1000, height: 680),
                         language: language, named: "users")
        tab = .groups
        try await record(SignedInContentView(viewModel: vm, selectedTab: binding), size: .init(width: 1000, height: 680),
                         language: language, named: "groups")
        let group = try #require(vm.regularGroups.first)
        #expect(vm.openDestination(.group(group.id)) == .opened)
        tab = .call
        try await record(SignedInContentView(viewModel: vm, selectedTab: binding), size: .init(width: 1100, height: 720),
                         language: language, named: "call-column")
        try await record(GroupSettingsView(viewModel: vm, groupID: group.id), size: .init(width: 480, height: 620),
                         language: language, named: "group-settings")
        let user = try #require(vm.savedRemoteUsers.first)
        try await record(SavedUserNameView(viewModel: vm, user: user), size: .init(width: 480, height: 560),
                         language: language, named: "user-settings")
    }

    private func record(_ view: some View, size: CGSize, language: String, named name: String) async throws {
        let host = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: language)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds), "\(name) has no bitmap")
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        Attachment.record(data, named: "mac-\(name)-\(language).png")
        window.close()
    }
}
}
#endif
