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
    @Test(arguments: ["en", "ja"]) func usersList(language: String) async throws {
        try await render(.users, language: language)
    }
    @Test(arguments: ["en", "ja"]) func groupsList(language: String) async throws {
        try await render(.groups, language: language)
    }
    @Test(arguments: ["en", "ja"]) func settingsList(language: String) async throws {
        let h = try AppTestSupport.makeHarnessWithSavedUser(), vm = h.viewModel
        defer { vm.disconnect() }
        try await record(NavigationStack { SettingsView(viewModel: vm) },
                         size: .init(width: 900, height: 680), language: language, named: "settings")
    }
    @Test(arguments: ["en", "ja"]) func callColumn(language: String) async throws {
        try await render(.call, language: language)
    }

    @Test func diagnosticsOverview() async throws {
        let h = try AppTestSupport.makeHarnessWithSavedUser(), vm = h.viewModel
        defer { vm.disconnect() }
        let group = try #require(vm.regularGroups.first)
        #expect(vm.openDestination(.group(group.id)) == .opened)
        try await record(NavigationStack { DiagnosticsView(viewModel: vm) },
                         size: .init(width: 520, height: 760), language: "en", named: "diagnostics-overview")
    }

    @Test(arguments: ["en", "ja"])
    func settingsSheets(language: String) async throws {
        let h = try AppTestSupport.makeHarnessWithSavedUser(), vm = h.viewModel
        defer { vm.disconnect() }
        let group = try #require(vm.regularGroups.first), user = try #require(vm.savedRemoteUsers.first)
        try await record(GroupSettingsView(viewModel: vm, groupID: group.id), size: .init(width: 480, height: 620),
                         language: language, named: "group-settings")
        try await record(SavedUserNameView(viewModel: vm, user: user), size: .init(width: 480, height: 560),
                         language: language, named: "user-settings")
        try await record(SavedUsersView(viewModel: vm), size: .init(width: 480, height: 560),
                         language: language, named: "new-group")
    }

    /// The lists and the call column as the window lays them out. The root `inspector` itself is
    /// not hosted here: outside a window scene it reports negative geometry even when empty.
    private func render(_ tab: AppTab, language: String) async throws {
        let h = try AppTestSupport.makeHarnessWithSavedUser(), vm = h.viewModel
        defer { vm.disconnect() }
        var selected = tab
        let binding = Binding(get: { selected }, set: { selected = $0 })
        switch tab {
        case .groups:
            try await record(NavigationStack { StandardGroupsView(viewModel: vm, selectedTab: binding) },
                             size: .init(width: 900, height: 680), language: language, named: "groups")
        case .call:
            let group = try #require(vm.regularGroups.first)
            #expect(vm.openDestination(.group(group.id)) == .opened)
            try await record(HStack(spacing: 0) {
                NavigationStack { StandardGroupsView(viewModel: vm, selectedTab: binding) }
                Divider()
                CallPanel(viewModel: vm, selectedTab: binding) { }.frame(width: 380)
            }, size: .init(width: 1100, height: 720), language: language, named: "call-column")
        default:
            try await record(NavigationStack { StandardUsersView(viewModel: vm, selectedTab: binding) },
                             size: .init(width: 900, height: 680), language: language, named: "users")
        }
    }

    private func record(_ view: some View, size: CGSize, language: String, named name: String) async throws {
        // Size the host before it joins the window, so the first layout is the window size
        // rather than zero (a zero-width pass reports negative geometry).
        // Like an app window: titled with a unified toolbar, which the inspector's split view expects.
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        let host = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: language)))
        host.frame = CGRect(origin: .zero, size: size)
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
