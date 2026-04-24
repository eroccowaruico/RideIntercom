import SwiftUI

#if os(macOS)
import AppKit
#endif

@main
struct RideIntercomApp: App {
    private static let mainWindowID = "main"

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(RideIntercomApplicationDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        let _ = {
            appDelegate.openMainWindow = {
                openWindow(id: Self.mainWindowID)
            }
        }()
        #endif

        return WindowGroup(id: Self.mainWindowID) {
            ContentView()
                #if os(macOS)
                .onAppear {
                    SingleWindowPolicy.enforce()
                }
                #endif
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                EmptyView()
            }
        }
    }
}
