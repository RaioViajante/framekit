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
