import CoreText
import Foundation

/// Fonts are an explicit dependency: a preset names them exactly, and a missing font is an error,
/// never a silent substitution (no visual equivalence is assumed between different fonts).
public enum FontAvailability {
    /// Whether `postScriptName` resolves to exactly that font. CoreText substitutes unknown names
    /// silently, so availability is judged by the name that comes back.
    public static func isAvailable(_ postScriptName: String) -> Bool {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        return CTFontCopyPostScriptName(font) as String == postScriptName
    }

    /// One `font.unavailable` error per font of `required_fonts` that this machine cannot resolve.
    public static func check(_ preset: CaptionPreset) -> [ValidationIssue] {
        preset.requiredFonts.enumerated().compactMap { i, name in
            isAvailable(name) ? nil : ValidationIssue(.fontUnavailable, at: "/required_fonts/\(i)",
                                                      "font \"\(name)\" is not installed; install it or choose another font in the preset")
        }
    }
}
