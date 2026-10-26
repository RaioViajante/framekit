import Foundation
import Testing
@testable import FrameKitCaptions

@Suite struct PresetContract {
    let base: JSONValue

    init() throws {
        base = try Repo.json("captions/presets/kinetic-minimal.json")
    }

    func issues(_ doc: JSONValue) -> [String] { summary(CaptionPreset.validate(doc).issues) }

    @Test func theShippedPresetIsValid() {
        let result = CaptionPreset.validate(base)
        #expect(result.issues.isEmpty)
        #expect(result.value?.presetID == "kinetic-minimal")
    }

    @Test func descriptionIsTheOnlyOptionalField() {
        #expect(issues(base.setting("description", nil)) == [])
        #expect(issues(base.setting("shadow.blur", nil)) == ["field.missing /shadow/blur"])
        #expect(issues(base.setting("emphasis_styles", nil)) == ["field.missing /emphasis_styles"])
        #expect(issues(base.setting("timing.overlap.min_visible", nil)) == ["field.missing /timing/overlap/min_visible"])
    }

    @Test func unknownFieldsAreRejectedAtEveryLevel() {
        #expect(issues(base.setting("colour", "#ffffff")) == ["field.unknown /colour"])
        #expect(issues(base.setting("text.weight", 500)) == ["field.unknown /text/weight"])
        #expect(issues(base.setting("emphasis_styles.soft.glow", 0.5)) == ["field.unknown /emphasis_styles/soft/glow"])
        #expect(issues(base.setting("text.color.alpha", 1)) == ["field.unknown /text/color/alpha"])
    }

    @Test func wrongTypes() {
        #expect(issues(base.setting("text.size", "54")) == ["type.mismatch /text/size"])
        #expect(issues(base.setting("canvas.width", 1080.5)) == ["type.mismatch /canvas/width"])
        #expect(issues(base.setting("outline.alpha", true)) == ["type.mismatch /outline/alpha"])
        #expect(issues(base.setting("required_fonts", "AvenirNext-Medium")) == ["type.mismatch /required_fonts"])
        #expect(issues(base.setting("shadow", [0, 0, 0])) == ["type.mismatch /shadow"])
        #expect(issues(base.setting("text.color", 7)) == ["type.mismatch /text/color"])
    }

    @Test func valuesOutOfRange() {
        #expect(issues(base.setting("outline.alpha", 1.2)) == ["value.out_of_range /outline/alpha"])
        #expect(issues(base.setting("text.size", 0)) == ["value.out_of_range /text/size"])
        #expect(issues(base.setting("canvas.fps", 0)) == ["value.out_of_range /canvas/fps"])
        #expect(issues(base.setting("text.max_lines", 0)) == ["value.out_of_range /text/max_lines"])
        #expect(issues(base.setting("placement.x", 1081)) == ["value.out_of_range /placement/x"])
        #expect(issues(base.setting("placement.baseline_y", -1)) == ["value.out_of_range /placement/baseline_y"])
        #expect(issues(base.setting("text.color.srgb.1", -0.1)) == ["value.out_of_range /text/color/srgb/1"])
        #expect(issues(base.setting("animation.fade_in.duration", -0.14)) == ["value.out_of_range /animation/fade_in/duration"])
    }

    @Test func placementIsAdjustableWithinTheCanvas() throws {
        let moved = base.setting("placement.x", 300).setting("placement.baseline_y", 1500)
        let preset = try #require(CaptionPreset.validate(moved).value)
        #expect(preset.placement == .init(mode: .fixed, x: 300, baselineY: 1500))
        // a larger canvas widens the allowed range
        #expect(issues(moved.setting("canvas.height", 1400)) == ["value.out_of_range /placement/baseline_y"])
    }

    @Test(arguments: [(1920, 1080, 30.0), (1080, 1920, 29.97), (720, 720, 25.0)])
    func canvasAndFrameRateAreNotFixed(width: Int, height: Int, fps: Double) throws {
        let doc = base.setting("canvas", ["width": .number(Double(width)), "height": .number(Double(height)), "fps": .number(fps)])
            .setting("placement.x", .number(Double(width) / 2))
        let preset = try #require(CaptionPreset.validate(doc).value)
        #expect(preset.canvas == .init(width: width, height: height, fps: fps))
    }

    /// Integers go up to 2^53 - 1, the largest integer every JSON implementation reads exactly (I-JSON);
    /// the schema states the same maximum. A whole number beyond it is out of range, not a wrong type.
    @Test func largeIntegers() {
        let largest = 9_007_199_254_740_991.0
        #expect(issues(base.setting("text.max_lines", .number(largest))) == [])
        #expect(issues(base.setting("text.max_lines", .number(largest + 1))) == ["value.out_of_range /text/max_lines"])
        #expect(issues(base.setting("text.max_lines", 1e15)) == [])
        #expect(issues(base.setting("text.max_lines", 1e20)) == ["value.out_of_range /text/max_lines"])
        #expect(issues(base.setting("text.max_lines", .number(.infinity))) == ["value.out_of_range /text/max_lines"])
        #expect(issues(base.setting("text.max_lines", 2.5)) == ["type.mismatch /text/max_lines"])
        #expect(issues(base.setting("canvas.width", 1e20)) == ["value.out_of_range /canvas/width"])
        #expect(issues(base.setting("schema_version", 1e20)) == ["value.out_of_range /schema_version"])
        #expect(issues(base.setting("schema_version", .number(-largest - 1))) == ["value.out_of_range /schema_version"])
    }

    @Test func reservedOptionsAreUnsupportedNotUnknown() {
        #expect(issues(base.setting("placement.mode", "auto")) == ["option.unsupported /placement/mode"])
        #expect(issues(base.setting("placement.mode", "avoid-regions")) == ["option.unsupported /placement/mode"])
        #expect(issues(base.setting("text.align", "left")) == ["option.unsupported /text/align"])
        #expect(issues(base.setting("placement.mode", "floating")) == ["value.invalid /placement/mode"])
        #expect(issues(base.setting("animation.fade_out.easing", "bounce")) == ["value.invalid /animation/fade_out/easing"])
        #expect(issues(base.setting("emphasis_styles.soft.font_from", "word-start")) == ["value.invalid /emphasis_styles/soft/font_from"])
    }

    @Test func schemaVersion() {
        // A newer version is reported alone, not as a list of unknown fields.
        #expect(issues(base.setting("schema_version", 2).setting("layers", [])) == ["schema.unsupported_version /schema_version"])
        #expect(issues(base.setting("schema_version", 0)) == ["value.out_of_range /schema_version"])
        #expect(issues(base.setting("schema_version", "1")) == ["type.mismatch /schema_version"])
        #expect(issues(base.setting("schema_version", nil)) == ["field.missing /schema_version"])
    }

    @Test func coloursKeepExactFloatsOrConvertHex() throws {
        let hex = try #require(CaptionPreset.validate(base.setting("text.color", "#ece7e0")).value)
        #expect(hex.text.color == RGBColor(red: 236.0 / 255, green: 231.0 / 255, blue: 224.0 / 255))
        let exact = try #require(CaptionPreset.validate(base).value)
        #expect(exact.text.color == RGBColor(red: 0.9255, green: 0.9059, blue: 0.8784))
        #expect(exact.text.color != hex.text.color)  // the floats are not a rounding of the hex value
        #expect(issues(base.setting("text.color", "#ece7e")) == ["value.invalid /text/color"])
        #expect(issues(base.setting("text.color", "ece7e0")) == ["value.invalid /text/color"])
        #expect(issues(base.setting("text.color.srgb", [1, 1])) == ["value.invalid /text/color/srgb"])
    }

    @Test func identifiers() {
        #expect(issues(base.setting("preset_id", "Kinetic Minimal")) == ["value.invalid /preset_id"])
        #expect(issues(base.setting("preset_version", "1.0")) == ["value.invalid /preset_version"])
        #expect(issues(base.setting("emphasis_styles.Soft", base.setting("emphasis_styles.soft", nil))) == ["value.invalid /emphasis_styles/Soft"])
        #expect(issues(base.setting("text.font", "")) == ["value.invalid /text/font"])
    }

    @Test func aPresetMayDefineNoEmphasisStyles() throws {
        let plain = base.setting("emphasis_styles", [:]).setting("required_fonts", ["AvenirNext-Medium"])
        let preset = try #require(CaptionPreset.validate(plain).value)
        #expect(preset.emphasisStyles.isEmpty)
    }

    @Test func malformedDocuments() {
        #expect(summary(CaptionPreset.validate(Data("{\"schema_version\": 1,".utf8)).issues) == ["json.malformed "])
        #expect(issues([base]) == ["type.mismatch "])
    }

    @Test func everyProblemIsReportedAtOnceInAStableOrder() {
        let broken = base
            .setting("zzz", 1).setting("aaa", 1)
            .setting("text.size", "big")
            .setting("shadow.dy", nil)
            .setting("placement.mode", "auto")
        let expected = [
            "field.unknown /aaa", "field.unknown /zzz",
            "type.mismatch /text/size",
            "field.missing /shadow/dy",
            "option.unsupported /placement/mode",
        ]
        #expect(issues(broken) == expected)
        #expect(CaptionPreset.validate(broken).issues == CaptionPreset.validate(broken).issues)
        #expect(CaptionPreset.validate(broken).value == nil)
    }

    @Test func loadThrowsWithEveryIssue() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("broken.json")
        try Data("{\"schema_version\": 1}".utf8).write(to: file)
        #expect {
            try CaptionPreset.load(contentsOf: file)
        } throws: { error in
            (error as? CaptionDocumentError)?.issues.count == 11  // every required field but schema_version
        }
        #expect(try CaptionPreset.load(contentsOf: Repo.url("captions/presets/kinetic-minimal.json")).presetID == "kinetic-minimal")
    }
}
