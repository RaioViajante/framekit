import Foundation
import Testing
@testable import FrameKitCaptions

@Suite struct InputContract {
    let preset: CaptionPreset
    let base: JSONValue

    init() throws {
        preset = try CaptionPreset.load(contentsOf: Repo.url("captions/presets/kinetic-minimal.json"))
        base = [
            "schema_version": 1,
            "language": "en",
            "words": [
                ["id": "a", "text": "One", "start": 0.5, "end": 0.8],
                ["id": "b", "text": "two", "start": 0.9, "end": 1.2],
                ["id": "c", "text": "three.", "start": 1.3, "end": 1.9],
            ],
            "cues": [["id": "c1", "lines": [["a", "b", "c"]]]],
        ]
    }

    func issues(_ doc: JSONValue) -> [String] { summary(CaptionInput.validate(doc).issues) }

    /// Standalone issues followed by those that need the preset.
    func allIssues(_ doc: JSONValue) -> [String] {
        let result = CaptionInput.validate(doc)
        return summary(result.issues + (result.value?.validate(against: preset) ?? []))
    }

    @Test(arguments: ["captions/examples/one-cue.input.json", "captions/examples/two-cues.input.json",
                      "captions/examples/overlapping-cues.input.json"])
    func examplesAreValidForKineticMinimal(path: String) throws {
        #expect(try allIssues(Repo.json(path)) == [])
    }

    @Test func oneCueWithoutEmphasis() throws {
        let input = try #require(CaptionInput.validate(base).value)
        #expect(input.cues == [.init(id: "c1", lines: [["a", "b", "c"]], emphasis: [:], start: nil, end: nil)])
        #expect(input.timingSource == nil)
    }

    @Test func multipleCuesWithTwoLinesEmphasisAndOverrides() throws {
        let input = try CaptionInput.load(contentsOf: Repo.url("captions/examples/two-cues.input.json"))
        #expect(input.cues.map(\.id) == ["c1", "c2"])
        #expect(input.cues[0].lines == [["w1", "w2"], ["w3", "w4", "w5", "w6"]])
        #expect(input.cues[0].emphasis == ["w6": "soft"])
        #expect(input.cues[1].emphasis.isEmpty)
        #expect(input.cues[1].start == 3.0 && input.cues[1].end == 5.0)
        #expect(input.timingSource == .aligned)
        #expect(input.words.last?.text == "time…")  // the ellipsis stays one character
    }

    @Test func cuesMayOverlapInTime() {
        let doc = base.setting("cues", [
            ["id": "c1", "lines": [["a", "b"]], "end": 2.0],
            ["id": "c2", "lines": [["c"]], "start": 1.0],
        ])
        #expect(allIssues(doc) == [])
    }

    @Test func incorrectTimestamps() {
        #expect(issues(base.setting("words.1.end", 0.9)) == ["timing.invalid /words/1/end"])
        #expect(issues(base.setting("words.1.end", 0.1)) == ["timing.invalid /words/1/end"])
        #expect(issues(base.setting("words.0.start", -0.5)) == ["value.out_of_range /words/0/start"])
        #expect(issues(base.setting("words.0.start", "0:00.5")) == ["type.mismatch /words/0/start"])
        #expect(issues(base.setting("words.0.end", nil)) == ["field.missing /words/0/end"])
        #expect(issues(base.setting("words.2.start", 0.6).setting("words.2.end", 0.7)) == ["timing.out_of_order /words/2/start"])
        #expect(issues(base.setting("cues.0.start", 2.0).setting("cues.0.end", 1.0)) == ["timing.invalid /cues/0/end"])
        #expect(issues(base.setting("cues.0.end", -1)) == ["value.out_of_range /cues/0/end"])
    }

    @Test func unknownFields() {
        #expect(issues(base.setting("speaker", "x")) == ["field.unknown /speaker"])
        #expect(issues(base.setting("words.0.confidence", 0.9)) == ["field.unknown /words/0/confidence"])
        #expect(issues(base.setting("cues.0.style", "soft")) == ["field.unknown /cues/0/style"])
    }

    @Test func requiredFieldsAndTypes() {
        #expect(issues(base.setting("language", nil)) == ["field.missing /language"])
        #expect(issues(base.setting("language", "english!")) == ["value.invalid /language"])
        #expect(issues(base.setting("language", "pt-BR")) == [])
        #expect(issues(base.setting("timing_source", "guessed")) == ["value.invalid /timing_source"])
        #expect(issues(base.setting("words", [])) == ["array.empty /words"])
        #expect(issues(base.setting("cues", [])) == ["array.empty /cues"])
        #expect(issues(base.setting("cues.0.lines", [])) == ["array.empty /cues/0/lines"])
        #expect(issues(base.setting("cues.0.lines", [["a", "b", "c"], []])) == ["array.empty /cues/0/lines/1"])
        #expect(issues(base.setting("cues.0.lines", ["a", "b", "c"])) == [
            "type.mismatch /cues/0/lines/0", "type.mismatch /cues/0/lines/1", "type.mismatch /cues/0/lines/2",
        ])
        #expect(issues(base.setting("schema_version", 2)) == ["schema.unsupported_version /schema_version"])
    }

    @Test func wordText() {
        #expect(issues(base.setting("words.0.text", "Cafe\u{301}")) == ["text.not_normalized /words/0/text"])
        #expect(issues(base.setting("words.0.text", "Caf\u{e9}")) == [])
        #expect(issues(base.setting("words.0.text", "two words")) == ["text.contains_whitespace /words/0/text"])
        #expect(issues(base.setting("words.0.text", "")) == ["value.invalid /words/0/text"])
    }

    @Test func references() {
        #expect(issues(base.setting("words.1.id", "a")) == ["id.duplicate /words/1/id"])
        #expect(issues(base.setting("cues.0.lines", [["a", "x", "c"]])) == ["word.unknown /cues/0/lines/0/1"])
        #expect(issues(base.setting("cues.0.lines", [["a", "c", "b"]])) == ["timing.out_of_order /cues/0/lines/0/2"])
        let twoCues = base.setting("cues", [["id": "c1", "lines": [["a", "b"]]], ["id": "c2", "lines": [["b", "c"]]]])
        #expect(issues(twoCues) == ["word.reused /cues/1/lines/0/0"])
        let swapped = base.setting("cues", [["id": "c1", "lines": [["c"]]], ["id": "c2", "lines": [["a", "b"]]]])
        #expect(issues(swapped) == ["timing.out_of_order /cues/1"])
        let sameID = base.setting("cues", [["id": "c1", "lines": [["a", "b"]]], ["id": "c1", "lines": [["c"]]]])
        #expect(issues(sameID) == ["id.duplicate /cues/1/id"])
    }

    @Test func unusedWordsAreOnlyAWarning() throws {
        let result = CaptionInput.validate(base.setting("cues.0.lines", [["a", "b"]]))
        #expect(summary(result.issues) == ["word.unused /words/2"])
        #expect(result.warnings.count == 1 && result.errors.isEmpty)
        #expect(result.value != nil)
    }

    @Test func optionalEmphasis() {
        #expect(allIssues(base.setting("cues.0.emphasis", ["c": "soft"])) == [])
        #expect(allIssues(base.setting("cues.0.emphasis", [:])) == [])
        #expect(issues(base.setting("cues.0.emphasis", ["z": "soft"])) == ["emphasis.word_not_in_cue /cues/0/emphasis/z"])
        #expect(issues(base.setting("cues.0.emphasis", ["c": 1])) == ["type.mismatch /cues/0/emphasis/c"])
        #expect(issues(base.setting("cues.0.emphasis", ["c"])) == ["type.mismatch /cues/0/emphasis"])
        // Style names are the preset's business: the input alone accepts any name...
        #expect(issues(base.setting("cues.0.emphasis", ["c": "shake"])) == [])
        // ...and the preset refuses one it does not define.
        #expect(allIssues(base.setting("cues.0.emphasis", ["c": "shake"])) == ["emphasis.unknown_style /cues/0/emphasis/c"])
    }

    @Test func lineCountIsLimitedByThePreset() {
        let threeLines = base.setting("cues.0.lines", [["a"], ["b"], ["c"]])
        #expect(issues(threeLines) == [])
        #expect(allIssues(threeLines) == ["cue.too_many_lines /cues/0/lines"])
        #expect(allIssues(base.setting("cues.0.lines", [["a"], ["b", "c"]])) == [])
    }

    @Test func cuesDoNotInterleave() {
        // Every word of a cue comes after every word of the previous cue; a word left out is fine.
        let interleaved = base.setting("cues", [["id": "c1", "lines": [["a", "c"]]], ["id": "c2", "lines": [["b"]]]])
        #expect(issues(interleaved) == ["timing.out_of_order /cues/1"])
        let gap = base.setting("cues", [["id": "c1", "lines": [["a"]]], ["id": "c2", "lines": [["c"]]]])
        #expect(issues(gap) == ["word.unused /words/1"])
    }

    @Test func controlCharacters() {
        #expect(issues(base.setting("words.0.text", "One\u{7}")) == ["text.contains_control /words/0/text"])
        #expect(issues(base.setting("words.0.text", "One\u{0}")) == ["text.contains_control /words/0/text"])
        // Format characters that text needs, such as the zero-width joiner of emoji sequences, are kept.
        #expect(issues(base.setting("words.0.text", "\u{1F469}\u{200D}\u{1F4BB}")) == [])
    }

    @Test func timestampsKeepFullPrecision() throws {
        // Times are compared as written (IEEE 754 doubles); nothing is rounded to frames or milliseconds.
        let doc = base.setting("words.0.start", 0.1).setting("words.0.end", 0.30000000000000004)
        let input = try #require(CaptionInput.validate(doc).value)
        #expect(input.words[0].end == 0.30000000000000004 && input.words[0].end != 0.3)
        #expect(issues(base.setting("words.0.end", 0.5)) == ["timing.invalid /words/0/end"])  // equal to start
        // 1e400 is valid JSON syntax but no Double: it is refused as out of range, not as malformed.
        #expect(summary(CaptionInput.validate(Data(#"{"schema_version": 1e400}"#.utf8)).issues) == ["value.out_of_range /schema_version"])
        #expect(issues(base.setting("words.0.end", .number(.infinity))) == ["value.out_of_range /words/0/end"])
    }

    @Test func windowsAreDerivedFromTheWords() throws {
        let input = try #require(CaptionInput.validate(base).value)
        let t = preset.timing
        // first word 0.5, last word ends 1.9
        #expect(try input.cueWindows(with: preset) == [.init(start: 0.5 - t.leadIn, end: max(1.9 + t.hold, 0.5 - t.leadIn + t.minDuration),
                                                          fadeOut: preset.animation.fadeOut.duration)])
    }

    @Test func cueStartAndEndTakePrecedenceOverTheWords() throws {
        let input = try #require(CaptionInput.validate(base.setting("cues.0.start", 0.2).setting("cues.0.end", 4.0)).value)
        #expect(try input.cueWindows(with: preset) == [.init(start: 0.2, end: 4.0, fadeOut: 0.16)])
        // Only one side given: the other stays derived from the words.
        let onlyEnd = try #require(CaptionInput.validate(base.setting("cues.0.end", 4.0)).value)
        #expect(try onlyEnd.cueWindows(with: preset)[0].start == 0.5 - preset.timing.leadIn)
    }

    @Test func overlapsAreCutAfterTheOverrides() throws {
        // c1 asks to stay until 5 s, but c2 appears earlier: c1 is cut and ends with the short fade-out.
        let doc = base.setting("cues", [["id": "c1", "lines": [["a", "b"]], "end": 5.0], ["id": "c2", "lines": [["c"]]]])
        let windows = try #require(CaptionInput.validate(doc).value).cueWindows(with: preset)
        let t = preset.timing
        let cut = max(1.3 + t.overlap.wordMargin, (0.5 - t.leadIn) + t.overlap.minVisible)  // c2's first word starts at 1.3
        #expect(windows[0] == .init(start: 0.5 - t.leadIn, end: cut - t.minGap, fadeOut: t.overlap.fadeOut))
        #expect(windows[1].start == cut)
        #expect(allIssues(doc) == [])
    }

    @Test func resolvedWindowsMustNotBeEmpty() {
        // A start after the derived end (no end given) leaves nothing to show.
        #expect(allIssues(base.setting("cues.0.start", 9.0)) == ["timing.invalid /cues/0"])
        // An end before the derived start.
        #expect(allIssues(base.setting("cues.0.end", 0.1)) == ["timing.invalid /cues/0"])
        // No overrides at all: a long first word pushes the next cue past its own end.
        let pushed: JSONValue = [
            "schema_version": 1, "language": "en",
            "words": [["id": "a", "text": "Long", "start": 0.5, "end": 3.0], ["id": "b", "text": "short", "start": 0.6, "end": 0.7]],
            "cues": [["id": "c1", "lines": [["a"]]], ["id": "c2", "lines": [["b"]]]],
        ]
        #expect(issues(pushed) == [])
        #expect(allIssues(pushed) == ["timing.invalid /cues/1"])
    }

    @Test func idsCompareByCanonicalEquivalence() {
        let composed = "\u{E9}", decomposed = "e\u{301}"  // é as one code point, and as e + combining accent
        // Two spellings of one id are a duplicate...
        #expect(issues(base.setting("words.0.id", .string(composed)).setting("words.1.id", .string(decomposed))
            .setting("cues.0.lines", [[.string(composed), .string(decomposed), "c"]])) == ["id.duplicate /words/1/id"])
        // ...and either spelling refers to the same word.
        #expect(issues(base.setting("words.0.id", .string(composed)).setting("cues.0.lines", [[.string(decomposed), "b", "c"]])) == [])
    }

    @Test func validationIsDeterministic() {
        let broken = base.setting("words.0.zeta", 1).setting("words.0.alpha", 1).setting("words.1.end", 0)
            .setting("cues.0.emphasis", ["q": "soft", "p": "soft"])
        #expect(issues(broken) == ["field.unknown /words/0/alpha", "field.unknown /words/0/zeta", "timing.invalid /words/1/end"])
        let refs = base.setting("cues.0.emphasis", ["q": "soft", "p": "soft"])
        #expect(issues(refs) == ["emphasis.word_not_in_cue /cues/0/emphasis/p", "emphasis.word_not_in_cue /cues/0/emphasis/q"])
        #expect(CaptionInput.validate(refs).issues == CaptionInput.validate(refs).issues)
    }
}
