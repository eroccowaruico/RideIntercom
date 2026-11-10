#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AppIntents
import Foundation
import Logging
import SwiftUI

@main
struct RideIntercomApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var callOwner: AppCallOwner
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(RideIntercomApplicationDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(RideIntercomApplicationDelegate.self) private var appDelegate
    #endif

    init() {
        RideIntercomLogging.bootstrap()
        let account = AppleAccountSession.makeForCurrentProcess()
        let owner = AppCallOwner(account: account, viewModel: IntercomViewModel.makeForCurrentProcess(accountSession: account))
        _callOwner = State(initialValue: owner)
        owner.notificationBridge.bind(to: owner)
        appDelegate.notificationBridge = owner.notificationBridge
        #if os(iOS)
        owner.watchBridge = WatchPhoneBridge(owner: owner)
        owner.watchBridge?.activate()
        #endif
        AppDependencyManager.shared.add(dependency: owner)
        AppDependencyManager.shared.add(dependency: owner as any CallSurfaceActions)
        AppLoggers.app.info(
            "app.lifecycle.started",
            metadata: .event("app.lifecycle.started", [
                "operationID": "\(UUID().uuidString)"
            ])
        )
    }

    var body: some Scene {
        #if os(macOS)
        let _ = configureOpenWindowBridge()

        WindowGroup(id: SingleWindowPolicy.mainWindowID) {
            ContentView(owner: callOwner)
                .environment(\.callLiveActivityPresenter, callOwner.liveActivities)
                .onChange(of: scenePhase, initial: true) { _, phase in callOwner.systemSurfaceIsForeground = phase == .active }
                .onAppear {
                    SingleWindowPolicy.enforce()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                EmptyView()
            }
            CallCommands(owner: callOwner)
        }
        MenuBarExtra(isInserted: Binding(
            get: { callOwner.isMenuBarInserted }, set: { callOwner.viewModel?.setMenuBarEnabled($0) })) {
            MenuBarCallView(owner: callOwner)
        } label: {
            // The app glyph identifies RideCom next to other menu bar items; a muted call
            // shows the microphone state instead.
            if callOwner.currentLivePresentation?.isMuted == true {
                Image(systemName: "mic.slash").accessibilityLabel("RideCom")
            } else {
                // The bubble layer stays translucent so the road shows through, as in the app icon.
                Image("ridecom.glyph").symbolRenderingMode(.hierarchical).accessibilityLabel("RideCom")
            }
        }
        .menuBarExtraStyle(.menu)
        #else
        WindowGroup {
            ContentView(owner: callOwner)
                .environment(\.callLiveActivityPresenter, callOwner.liveActivities)
                .onChange(of: scenePhase, initial: true) { _, phase in callOwner.systemSurfaceIsForeground = phase == .active }
        }
        #endif
    }

    #if os(macOS)
    private func configureOpenWindowBridge() {
        appDelegate.openMainWindow = {
            openWindow(id: SingleWindowPolicy.mainWindowID)
        }
    }
    #endif
}
