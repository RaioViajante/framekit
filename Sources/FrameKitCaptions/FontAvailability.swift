import CoreText
import Foundation

/// Fonts are an explicit dependency: a preset names them exactly, and a missing font is an error,
/// never a silent substitution (no visual equivalence is assumed between different fonts).
public enum FontAvailability {
    /// Whether `postScriptName` resolves to exactly that font. CoreText substitutes unknown names
    /// silently, so availability is judged by the name that comes back.
    public static func isAvailable(_ postScriptName: String) -> Bool {
        let font = FontLookup.serialized { CTFontCreateWithName(postScriptName as CFString, 12, nil) }
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

/// CoreText asks the system font server for fonts over XPC. Lookups made at the same time from Swift
/// concurrency's threads can wait for a reply forever: measured on macOS 27, 64 tasks each creating a font
/// at the start of a process hung every time when the font does not exist, and in some runs (3 of 15 in
/// one measurement, none of 45 in another) when it does; one at a time, never. Every CoreText call of
/// this library that can look up a font goes through here.
enum FontLookup {
    private static let lock = NSLock()

    static func serialized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
