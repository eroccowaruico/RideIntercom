import SwiftUI
import RTC

enum AppTab: Hashable {
    case call
    case users
    case groups
    case diagnostics
    case settings

    func available(in mode: InterfaceMode) -> Self {
        switch (mode, self) {
        case (.standard, .diagnostics), (.advanced, .users), (.advanced, .groups): .call
        default: self
        }
    }
}
