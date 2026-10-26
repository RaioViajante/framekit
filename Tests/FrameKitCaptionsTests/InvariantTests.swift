import Foundation
import Testing
@testable import FrameKitCaptions

/// A `CaptionInput` is valid by construction outside this module (its properties cannot be set there).
/// Code inside the module can still change one, as these tests do; the preset-facing APIs must then
/// report the problem instead of trapping or accepting it.
@Suite struct ChangedInputInvariants {
    static func load() throws -> (CaptionInput, CaptionPreset) {
        let input = try CaptionInput.load(contentsOf: Repo.url("captions/examples/two-cues.input.json"))
        let preset = try CaptionPreset.load(contentsOf: Repo.url("captions/presets/kinetic-minimal.json"))
        return (input, preset)
    }

    /// Runs in a child process, so a trap fails this test instead of ending the test run.
    @Test func aChangedInputDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            let (valid, preset) = try ChangedInputInvariants.load()
            var input = valid
            input.cues[0].lines = []
            _ = input.validate(against: preset)
            _ = try? input.cueWindows(with: preset)
            input = valid
            input.cues[1].lines = [[]]
            _ = input.validate(against: preset)
            _ = try? input.cueWindows(with: preset)
            input = valid
            input.cues[0].lines = [["missing"]]
            _ = input.validate(against: preset)
            _ = try? input.cueWindows(with: preset)
            input = valid
            input.words.append(input.words[0])
            _ = input.validate(against: preset)
            _ = try? input.cueWindows(with: preset)
            input = valid
            input.cues = []
            _ = input.validate(against: preset)
            _ = try? input.cueWindows(with: preset)
        }
    }

    @Test func aChangedInputIsReportedWithTheValidatorsCodes() throws {
        let (valid, preset) = try Self.load()
        var input = valid
        input.cues[0].lines = []  // its emphasised word goes with it
        #expect(summary(input.validate(against: preset)) == ["array.empty /cues/0/lines", "emphasis.word_not_in_cue /cues/0/emphasis/w6"])
        input = valid
        input.cues[1].lines = [[]]
        #expect(summary(input.validate(against: preset)) == ["array.empty /cues/1/lines/0"])
        input = valid
        input.cues[0].lines = [["missing"]]
        #expect(summary(input.validate(against: preset)) == ["word.unknown /cues/0/lines/0/0", "emphasis.word_not_in_cue /cues/0/emphasis/w6"])
        input = valid
        input.words.append(input.words[0])
        #expect(summary(input.validate(against: preset)) == ["id.duplicate /words/11/id", "timing.out_of_order /words/11/start"])
        input = valid
        input.words[3].end = input.words[3].start  // a timing rule, not only structure
        #expect(summary(input.validate(against: preset)) == ["timing.invalid /words/3/end"])
        input = valid
        input.cues = []
        #expect(summary(input.validate(against: preset)) == ["array.empty /cues"])
        input = valid
        input.words[0].start = .nan  // JSON cannot carry NaN or infinity; changed values can
        #expect(summary(input.validate(against: preset)) == ["value.out_of_range /words/0/start"])
        input = valid
        input.cues[1].end = .infinity
        #expect(summary(input.validate(against: preset)) == ["value.out_of_range /cues/1/end"])
    }

    @Test func cueWindowsRefuseAChangedInput() throws {
        let (valid, preset) = try Self.load()
        var input = valid
        input.cues[1].lines = [["missing"]]
        #expect {
            try input.cueWindows(with: preset)
        } throws: { error in
            summary((error as? InvalidCaptionInput)?.issues ?? []) == ["word.unknown /cues/1/lines/0/0"]
        }
        #expect(try valid.cueWindows(with: preset).count == 2)
    }

    @Test func theValidatedValueRoundTrips() throws {
        let (valid, _) = try Self.load()
        // What the preset-facing APIs re-check is exactly the validated value.
        #expect(CaptionInput.validate(valid.jsonValue).value == valid)
    }
}

/// The same for a `CaptionPreset` changed inside the module: never a trap, never windows computed from
/// broken values, never a silent pass.
@Suite struct ChangedPresetInvariants {
    let input: CaptionInput
    let preset: CaptionPreset

    init() throws {
        (input, preset) = try ChangedInputInvariants.load()
    }

    @Test(arguments: [("description", nil), ("text.color", "#ece7e0"), ("emphasis_styles", [:] as JSONValue)] as [(String, JSONValue?)])
    func theValidatedValueRoundTrips(path: String, value: JSONValue?) throws {
        var doc = try Repo.json("captions/presets/kinetic-minimal.json").setting(path, value)
        if path == "emphasis_styles" { doc = doc.setting("required_fonts", ["AvenirNext-Medium"]) }
        let valid = try #require(CaptionPreset.validate(doc).value)
        #expect(CaptionPreset.validate(valid.jsonValue).value == valid)
        #expect(CaptionPreset.validate(preset.jsonValue).value == preset)
    }

    /// Each change, and the preset's own errors it must produce.
    static let changes: [(String, @Sendable (inout CaptionPreset) -> Void, [String])] = [
        ("NaN lead-in", { $0.timing.leadIn = .nan }, ["value.out_of_range /timing/lead_in"]),
        ("infinite gap", { $0.timing.minGap = .infinity }, ["value.out_of_range /timing/min_gap"]),
        ("negative fade-out", { $0.animation.fadeOut.duration = -1 }, ["value.out_of_range /animation/fade_out/duration"]),
        ("negative cut fade-out", { $0.timing.overlap.fadeOut = -0.08 }, ["value.out_of_range /timing/overlap/fade_out"]),
        ("NaN emphasis transition", { $0.emphasisStyles["soft"]!.transition.duration = .nan },
         ["value.out_of_range /emphasis_styles/soft/transition/duration"]),
        ("NaN colour", { $0.text.color.red = .nan }, ["value.out_of_range /text/color/srgb/0"]),
        ("zero text size", { $0.text.size = 0 }, ["value.out_of_range /text/size"]),
        ("no lines", { $0.text.maxLines = 0 }, ["value.out_of_range /text/max_lines"]),
        ("zero-width canvas", { $0.canvas.width = 0 }, ["value.out_of_range /canvas/width"]),
        ("placement outside the canvas", { $0.placement.x = 5000 }, ["value.out_of_range /placement/x"]),
        ("opacity above 1", { $0.shadow.alpha = 2 }, ["value.out_of_range /shadow/alpha"]),
        ("undeclared font", { $0.emphasisStyles["soft"]!.font = "Georgia-Italic" }, ["font.undeclared /required_fonts", "font.unused /required_fonts/1"]),
        ("no fonts", { $0.requiredFonts = [] }, ["array.empty /required_fonts"]),
        ("invalid id", { $0.presetID = "Not An Id" }, ["value.invalid /preset_id"]),
        ("empty font name", { $0.text.font = "" }, ["value.invalid /text/font"]),
    ]

    @Test func aChangedPresetIsReportedNotUsed() {
        for (name, change, expected) in Self.changes {
            var changed = preset
            change(&changed)
            // validate(against:): one issue, at the input's root, naming each of the preset's errors.
            let found = input.validate(against: changed)
            #expect(summary(found) == ["preset.invalid "], "\(name)")
            for e in expected {
                let parts = e.split(separator: " ")
                #expect(found.first?.message.contains("\(parts[0]) at \(parts[1])") == true, "\(name): \(e)")
            }
            // cueWindows: throws with the preset's errors, pointers into the preset.
            #expect("\(name)", performing: { try input.cueWindows(with: changed) }, throws: { error in
                summary((error as? InvalidCaptionPreset)?.issues ?? []) == expected
            })
        }
    }

    @Test func presetInvalidNamesEachErrorWithItsMessage() {
        var changed = preset
        changed.timing.leadIn = .nan
        // The example in docs/caption-configuration.md.
        #expect(input.validate(against: changed).first?.message.hasSuffix("value.out_of_range at /timing/lead_in (nan is not a finite number)") == true)
    }

        @Test func bothInvalidReportsBoth() {
        var changedInput = input
        changedInput.cues[1].lines = [["missing"]]
        var changedPreset = preset
        changedPreset.timing.leadIn = .nan
        #expect(summary(changedInput.validate(against: changedPreset)) == ["word.unknown /cues/1/lines/0/0", "preset.invalid "])
    }

    @Test func cueWindowsNeverReturnsAnEmptyWindow() throws {
        let doc = try Repo.json("captions/examples/two-cues.input.json").setting("cues.1.start", 9.0).setting("cues.1.end", nil)
        let late = try #require(CaptionInput.validate(doc).value)  // valid on its own; empty only with the preset
        #expect(performing: { try late.cueWindows(with: preset) }, throws: { error in
            summary((error as? InvalidCaptionInput)?.issues ?? []) == ["timing.invalid /cues/1"]
        })
    }

    /// Runs in a child process, so a trap fails this test instead of ending the test run.
    @Test func aChangedPresetDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            let (input, valid) = try ChangedInputInvariants.load()
            for (_, change, _) in ChangedPresetInvariants.changes {
                var preset = valid
                change(&preset)
                _ = input.validate(against: preset)
                _ = try? input.cueWindows(with: preset)
            }
        }
    }
}
