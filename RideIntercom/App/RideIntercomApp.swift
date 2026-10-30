#if os(macOS)
import AppKit
#endif
import Foundation
import Logging
import SwiftUI

@main
struct RideIntercomApp: App {
    @State private var account = AppleAccountSession.makeForCurrentProcess()
    @State private var viewModel: IntercomViewModel?
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(RideIntercomApplicationDelegate.self) private var appDelegate
    #endif

    init() {
        RideIntercomLogging.bootstrap()
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
            ContentView(account: account, viewModel: $viewModel)
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
            ContentView(account: account, viewModel: $viewModel)
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
