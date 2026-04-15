import AppKit
import MacParakeetCore
import SwiftUI

// MARK: - Color <-> CodableColor bridging
//
// `CodableColor` lives in `MacParakeetCore`, which deliberately has no
// SwiftUI dependency (per CLAUDE.md "Core library has no UI deps"). All
// `SwiftUI.Color` conversion is therefore confined to the app target via
// these extensions.

extension CodableColor {
    /// Materialize as a SwiftUI `Color` in the sRGB color space, preserving
    /// translucency.
    func toSwiftUIColor() -> Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

extension Color {
    /// Convert a SwiftUI `Color` to a `CodableColor` by bridging through
    /// `NSColor` in the sRGB color space. Falls back to the supplied
    /// default if conversion fails (e.g. an unrepresentable dynamic color).
    func toCodableColor(
        fallback: CodableColor = AIAssistantConfig.defaultBubbleBackgroundColor
    ) -> CodableColor {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else {
            return fallback
        }
        return CodableColor(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent),
            opacity: Double(srgb.alphaComponent)
        )
    }
}

// MARK: - WCAG-style contrast helper

enum BubbleContrast {
    /// Returns `.white` or `.black` depending on the picked color's relative
    /// luminance, using the WCAG formula:
    ///
    ///   L = 0.2126 * R + 0.7152 * G + 0.0722 * B  (linearized sRGB)
    ///
    /// We use a simple 0.5 threshold on the gamma-corrected (non-linearized)
    /// channels, which is good enough for picking light vs dark text on a
    /// solid background swatch and avoids the cost/complexity of full
    /// linearization. If callers later need true WCAG contrast ratios we
    /// can swap in the full sRGB-to-linear transform here.
    static func contrastingForeground(for color: Color) -> Color {
        let codable = color.toCodableColor()
        let luminance = 0.2126 * codable.red
            + 0.7152 * codable.green
            + 0.0722 * codable.blue
        return luminance < 0.5 ? .white : .black
    }
}
