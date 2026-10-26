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

    @Test(arguments: ["captions/examples/one-cue.input.json", "captions/examples/two-cues.input.json"])
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

    @Test func validationIsDeterministic() {
        let broken = base.setting("words.0.zeta", 1).setting("words.0.alpha", 1).setting("words.1.end", 0)
            .setting("cues.0.emphasis", ["q": "soft", "p": "soft"])
        #expect(issues(broken) == ["field.unknown /words/0/alpha", "field.unknown /words/0/zeta", "timing.invalid /words/1/end"])
        let refs = base.setting("cues.0.emphasis", ["q": "soft", "p": "soft"])
        #expect(issues(refs) == ["emphasis.word_not_in_cue /cues/0/emphasis/p", "emphasis.word_not_in_cue /cues/0/emphasis/q"])
        #expect(CaptionInput.validate(refs).issues == CaptionInput.validate(refs).issues)
    }
}
