import Foundation
import Testing
@testable import FrameKitCaptions

/// Fonts are an explicit dependency: listed exactly in the preset, checked on the machine, never
/// substituted.
@Suite struct FontDependency {
    let base: JSONValue

    init() throws {
        base = try Repo.json("captions/presets/kinetic-minimal.json")
    }

    @Test func everyUsedFontMustBeDeclared() {
        let doc = base.setting("required_fonts", ["AvenirNext-Medium"])
        #expect(summary(CaptionPreset.validate(doc).issues) == ["font.undeclared /required_fonts"])
        let changed = base.setting("emphasis_styles.soft.font", "Georgia-Italic")
        #expect(summary(CaptionPreset.validate(changed).issues) == ["font.undeclared /required_fonts", "font.unused /required_fonts/1"])
    }

    @Test func declaredFontsMustBeUsed() {
        let doc = base.setting("required_fonts", ["AvenirNext-Medium", "Palatino-Italic", "AvenirNext-DemiBold"])
        #expect(summary(CaptionPreset.validate(doc).issues) == ["font.unused /required_fonts/2"])
    }

    @Test func fontListShape() {
        #expect(summary(CaptionPreset.validate(base.setting("required_fonts", [])).issues) == ["array.empty /required_fonts"])
        let twice = base.setting("required_fonts", ["AvenirNext-Medium", "Palatino-Italic", "Palatino-Italic"])
        #expect(summary(CaptionPreset.validate(twice).issues) == ["id.duplicate /required_fonts/2"])
    }

    @Test func aMissingFontIsReportedNotSubstituted() throws {
        let missing = "FrameKitTestMissingFont-Regular"
        #expect(!FontAvailability.isAvailable(missing))
        let doc = base.setting("text.font", .string(missing)).setting("required_fonts", [.string(missing), "Palatino-Italic"])
        // The document itself is valid: availability depends on the machine, so it is a separate check.
        let preset = try #require(CaptionPreset.validate(doc).value)
        #expect(summary(FontAvailability.check(preset)) == ["font.unavailable /required_fonts/0"])
        #expect(FontAvailability.check(preset)[0].severity == .error)
    }

    @Test func availabilityComparesTheExactPostScriptName() {
        #expect(FontAvailability.isAvailable("Palatino-Italic"))
        #expect(!FontAvailability.isAvailable("palatino-italic"))  // CoreText would substitute; we refuse
    }
}
