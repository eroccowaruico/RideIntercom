#if os(macOS)
import AppKit
#endif
import AppIntents
import Foundation
import Logging
import SwiftUI

@main
struct RideIntercomApp: App {
    @State private var callOwner: AppCallOwner
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(RideIntercomApplicationDelegate.self) private var appDelegate
    #endif

    init() {
        RideIntercomLogging.bootstrap()
        let account = AppleAccountSession.makeForCurrentProcess()
        let owner = AppCallOwner(account: account, viewModel: IntercomViewModel.makeForCurrentProcess(accountSession: account))
        _callOwner = State(initialValue: owner)
        AppDependencyManager.shared.add(dependency: owner)
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

        return WindowGroup(id: SingleWindowPolicy.mainWindowID) {
            ContentView(account: callOwner.account, viewModel: $callOwner.viewModel, callPresentationID: callOwner.callPresentationID)
                .onAppear {
                    SingleWindowPolicy.enforce()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                EmptyView()
            }
        }
        #else
        return WindowGroup {
            ContentView(account: callOwner.account, viewModel: $callOwner.viewModel, callPresentationID: callOwner.callPresentationID)
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
