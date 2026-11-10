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

    private func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// Rows sit where the gradient has ended, on BackgroundBase; only the light top also holds cards.
    @Test func cardsRemainDistinctFromTheBackgroundUnderThem() throws {
        #expect(1.05 / (try luminance("BackgroundBase") + 0.05) >= 1.12)
        #expect(1.05 / (try luminance("BackgroundTop") + 0.05) >= 1.12)
        // A standard dark grouped cell is #1C1C1E; the background under rows must be darker.
        #expect(try luminance("BackgroundBase", style: .dark) < 0.012)
    }

    /// The top must differ visibly from the base, so glass controls stand out from the backdrop.
    /// The earlier pair differed by 1.01 (light) and 1.03 (dark) and read as one flat color.
    @Test func backgroundChangesVisiblyFromTopToBase() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            #expect(ratio(try luminance("BackgroundTop", style: style), try luminance("BackgroundBase", style: style)) >= 1.1)
        }
    }

    @Test func darkActionTextStaysReadableOnTheBackgroundTop() throws {
        #expect(ratio(try luminance("AccentColor", style: .dark), try luminance("BackgroundTop", style: .dark)) >= 4.5)
    }

    @Test func increasedContrastStatusSymbolsReachNonTextContrast() throws {
        for name in ["RideGreen", "VoiceAqua", "Warning", "Danger"] {
            #expect(1.05 / (try luminance(name, contrast: .high) + 0.05) >= 3)
        }
    }
}
#endif
