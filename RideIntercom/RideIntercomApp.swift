import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

@main
struct RideIntercomApp: App {
    #if canImport(AppKit)
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(RideIntercomApplicationDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        let _ = configureOpenWindowBridge()

        return WindowGroup(id: SingleWindowPolicy.mainWindowID) {
            ContentView()
                .onAppear {
                    SingleWindowPolicy.enforce()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                EmptyView()
            }
        }
    }

    private func configureOpenWindowBridge() {
        #if canImport(AppKit)
        appDelegate.openMainWindow = {
            openWindow(id: SingleWindowPolicy.mainWindowID)
        }
        #endif
    }
}
