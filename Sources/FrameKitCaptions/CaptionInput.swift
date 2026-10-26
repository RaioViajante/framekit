import Foundation

/// What a video's captions say and when: words with timestamps, grouped into cues with explicit line
/// breaks, and optional emphasis. It carries no styling; the look comes from a preset.
/// Contract: docs/caption-configuration.md#input-contract
public struct CaptionInput: Equatable, Sendable {
    /// The `schema_version` this library reads.
    public static let schemaVersion = 1

    /// BCP 47 tag, such as `en` or `pt-BR`.
    public var language: String
    public var timingSource: TimingSource?
    public var words: [Word]
    public var cues: [Cue]

    public enum TimingSource: String, CaseIterable, Sendable {
        /// Timestamps were estimated (for example spread over a phrase).
        case estimated
        /// Timestamps come from an alignment with the audio.
        case aligned
    }

    /// A word; `start` and `end` are seconds on the final video timeline.
    public struct Word: Equatable, Sendable {
        public var id: String
        public var text: String
        public var start: Double
        public var end: Double
    }

    /// Words shown together. `lines` are word ids, line by line; nothing is reflowed or truncated.
    public struct Cue: Equatable, Sendable {
        public var id: String
        public var lines: [[String]]
        /// Word id to emphasis style name.
        public var emphasis: [String: String]
        /// Overrides the visible start or end that the preset's timing would derive from the words.
        public var start: Double?
        public var end: Double?
    }
}

extension CaptionInput {
    /// Validates an input document on its own. Rules that depend on the preset (line count, emphasis
    /// style names) are checked by `validate(against:)`.
    public static func validate(_ data: Data) -> ValidationResult<CaptionInput> {
        guard let json = JSONValue.parse(data) else {
            return ValidationResult(value: nil, issues: [ValidationIssue(.jsonMalformed, at: "", "not valid JSON")])
        }
        return validate(json)
    }

    public static func validate(_ json: JSONValue) -> ValidationResult<CaptionInput> {
        let r = DocumentReader()
        let input = read(json, r)
        return ValidationResult(value: r.hasErrors ? nil : input, issues: r.issues)
    }

    /// Reads an input file and throws `CaptionDocumentError` when it has errors.
    public static func load(contentsOf url: URL) throws -> CaptionInput {
        let result = validate(try Data(contentsOf: url))
        guard let input = result.value else { throw CaptionDocumentError(file: url.path, issues: result.issues) }
        return input
    }

    /// The rules that need the preset: a cue has at most `text.max_lines` lines and only uses emphasis
    /// styles the preset defines. Pointers refer to the input document.
    public func validate(against preset: CaptionPreset) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for (ci, cue) in cues.enumerated() {
            let p = JSONPointer.root.appending("cues").appending(ci)
            if cue.lines.count > preset.text.maxLines {
                issues.append(ValidationIssue(.cueTooManyLines, at: p.appending("lines").description,
                                              "cue \"\(cue.id)\" has \(cue.lines.count) lines; preset \"\(preset.presetID)\" allows \(preset.text.maxLines)"))
            }
            for wordID in cue.emphasis.keys.sorted() where preset.emphasisStyles[cue.emphasis[wordID]!] == nil {
                let known = preset.emphasisStyles.keys.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
                issues.append(ValidationIssue(.emphasisUnknownStyle, at: p.appending("emphasis").appending(wordID).description,
                                              "style \"\(cue.emphasis[wordID]!)\" is not defined by preset \"\(preset.presetID)\" (defined: \(known.isEmpty ? "none" : known))"))
            }
        }
        return issues
    }

    private static func read(_ json: JSONValue, _ r: DocumentReader) -> CaptionInput? {
        let root = JSONPointer.root
        guard case .object(let top) = json else {
            _ = r.object(json, root, allowed: [])
            return nil
        }
        if case .number(let v)? = top["schema_version"], v > Double(schemaVersion) {
            _ = r.schemaVersion(Fields(values: top, pointer: root), supported: schemaVersion)
            return nil
        }
        guard let f = r.object(json, root, allowed: ["schema_version", "language", "timing_source", "words", "cues"]) else { return nil }
        let version = r.schemaVersion(f, supported: schemaVersion)
        let language = r.string(f, "language", pattern: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", patternText: "a BCP 47 language tag")
        let timingSource = r.choice(f, "timing_source", TimingSource.self, required: false)
        let words = readWords(f, r)
        // Cues refer to words by id, so they are checked only once the words are valid.
        let cues = words.flatMap { readCues(f, r, words: $0) }
        guard version != nil, let language, let words, let cues else { return nil }
        if f.values["timing_source"] != nil && timingSource == nil { return nil }
        return CaptionInput(language: language, timingSource: timingSource, words: words, cues: cues)
    }

    private static func readWords(_ f: Fields, _ r: DocumentReader) -> [Word]? {
        guard let raw = r.field(f, "words") else { return nil }
        let p = f.pointer.appending("words")
        guard let items = r.array(raw, p, nonEmpty: true) else { return nil }
        var words: [Word] = []
        var seen: Set<String> = []
        var ok = true
        for (i, item) in items.enumerated() {
            let wp = p.appending(i)
            guard let w = r.object(item, wp, allowed: ["id", "text", "start", "end"]) else { ok = false; continue }
            let id = r.string(w, "id"), text = r.string(w, "text")
            let start = r.number(w, "start", .nonNegative), end = r.number(w, "end", .nonNegative)
            guard let id, let text, let start, let end else { ok = false; continue }
            if !seen.insert(id).inserted { r.error(.idDuplicate, wp.appending("id"), "word id \"\(id)\" is used twice"); ok = false }
            // Compare scalars: String equality treats canonically equivalent forms as equal.
            if !text.unicodeScalars.elementsEqual(text.precomposedStringWithCanonicalMapping.unicodeScalars) {
                r.error(.textNotNormalized, wp.appending("text"), "text must be Unicode NFC"); ok = false
            }
            if text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) {
                r.error(.textContainsWhitespace, wp.appending("text"), "a word must not contain whitespace; split it into words"); ok = false
            }
            if end <= start { r.error(.timingInvalid, wp.appending("end"), "end \(end) must be after start \(start)"); ok = false }
            if let previous = words.last, start < previous.start {
                r.error(.timingOutOfOrder, wp.appending("start"), "word \"\(id)\" starts at \(start), before the previous word \"\(previous.id)\" (\(previous.start))")
                ok = false
            }
            words.append(Word(id: id, text: text, start: start, end: end))
        }
        return ok ? words : nil
    }

    private static func readCues(_ f: Fields, _ r: DocumentReader, words: [Word]) -> [Cue]? {
        guard let raw = r.field(f, "cues") else { return nil }
        let p = f.pointer.appending("cues")
        guard let items = r.array(raw, p, nonEmpty: true) else { return nil }
        let index = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($0.element.id, $0.offset) })
        var owner: [String: String] = [:]  // word id -> cue id
        var cueIDs: Set<String> = []
        var cues: [Cue] = []
        var ok = true
        var previousFirstWord: Int?
        for (ci, item) in items.enumerated() {
            let cp = p.appending(ci)
            guard let c = r.object(item, cp, allowed: ["id", "lines", "emphasis", "start", "end"]) else { ok = false; continue }
            let id = r.string(c, "id")
            let start = r.number(c, "start", .nonNegative, required: false)
            let end = r.number(c, "end", .nonNegative, required: false)
            if c.values["start"] != nil && start == nil || c.values["end"] != nil && end == nil { ok = false }
            if let start, let end, end <= start { r.error(.timingInvalid, cp.appending("end"), "end \(end) must be after start \(start)"); ok = false }
            guard let id else { ok = false; continue }
            if !cueIDs.insert(id).inserted { r.error(.idDuplicate, cp.appending("id"), "cue id \"\(id)\" is used twice"); ok = false }

            // lines: arrays of word ids, in the order the words are spoken
            var lines: [[String]] = []
            var lastWord: Int?
            if let rawLines = r.field(c, "lines"), let lineItems = r.array(rawLines, cp.appending("lines"), nonEmpty: true) {
                for (li, rawLine) in lineItems.enumerated() {
                    let lp = cp.appending("lines").appending(li)
                    guard let ids = r.array(rawLine, lp, nonEmpty: true) else { ok = false; continue }
                    var line: [String] = []
                    for (wi, rawID) in ids.enumerated() {
                        let wp = lp.appending(wi)
                        guard let wordID = r.string(rawID, wp) else { ok = false; continue }
                        line.append(wordID)
                        guard let w = index[wordID] else { r.error(.wordUnknown, wp, "no word has id \"\(wordID)\""); ok = false; continue }
                        if let other = owner[wordID] {
                            r.error(.wordReused, wp, "word \"\(wordID)\" is already in cue \"\(other)\""); ok = false; continue
                        }
                        owner[wordID] = id
                        if let lastWord, w < lastWord {
                            r.error(.timingOutOfOrder, wp, "word \"\(wordID)\" comes before the previous word of the cue in time"); ok = false
                        }
                        lastWord = w
                    }
                    lines.append(line)
                }
            } else { ok = false }

            // cues in the order of their first words
            if let first = lines.first?.first.flatMap({ index[$0] }) {
                if let previousFirstWord, first < previousFirstWord {
                    r.error(.timingOutOfOrder, cp, "cue \"\(id)\" starts with an earlier word than the previous cue"); ok = false
                }
                previousFirstWord = first
            }

            var emphasis: [String: String] = [:]
            if let rawEmphasis = r.field(c, "emphasis", required: false), let entries = r.map(rawEmphasis, cp.appending("emphasis")) {
                let inCue = Set(lines.joined())
                for (wordID, value) in entries {
                    let ep = cp.appending("emphasis").appending(wordID)
                    guard let style = r.string(value, ep) else { ok = false; continue }
                    if !inCue.contains(wordID) { r.error(.emphasisWordNotInCue, ep, "word \"\(wordID)\" is not in cue \"\(id)\""); ok = false }
                    emphasis[wordID] = style
                }
            } else if c.values["emphasis"] != nil { ok = false }

            cues.append(Cue(id: id, lines: lines, emphasis: emphasis, start: start, end: end))
        }
        // Only meaningful once the cues themselves are right.
        for w in words where ok && owner[w.id] == nil {
            r.warning(.wordUnused, JSONPointer.root.appending("words").appending(index[w.id]!), "word \"\(w.id)\" is not in any cue and will not be shown")
        }
        return ok ? cues : nil
    }
}
