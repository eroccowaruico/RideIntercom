import Foundation
import Testing
#if os(iOS)
import UIKit

@MainActor
struct DesignSystemContrastTests {
    private func luminance(_ name: String, style: UIUserInterfaceStyle = .light,
                           contrast: UIAccessibilityContrast = .normal) throws -> Double {
        let traits = UITraitCollection {
            $0.userInterfaceStyle = style
            $0.accessibilityContrast = contrast
        }
        let color = try #require(UIColor(named: name, in: .main, compatibleWith: traits))
            .resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    @Test func lightActionAndVoiceRemainReadableOnWhiteCards() throws {
        #expect(1.05 / (try luminance("AccentColor") + 0.05) >= 4.5)
        #expect(1.05 / (try luminance("VoiceAqua") + 0.05) >= 3)
    }

    @Test func cardsRemainDistinctFromBothBackgroundEndpoints() throws {
        for name in ["BackgroundTop", "BackgroundBase"] {
            #expect(1.05 / (try luminance(name) + 0.05) >= 1.12)
            // A standard dark grouped cell is #1C1C1E; the background must be darker.
            #expect(try luminance(name, style: .dark) < 0.012)
        }
    }

    @Test func increasedContrastStatusSymbolsReachNonTextContrast() throws {
        for name in ["RideGreen", "VoiceAqua", "Warning", "Danger"] {
            #expect(1.05 / (try luminance(name, contrast: .high) + 0.05) >= 3)
        }
    }
}
#endif
