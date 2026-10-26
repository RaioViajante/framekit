import Foundation

/// An sRGB colour with components between 0 and 1.
public struct RGBColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum Easing: String, CaseIterable, Sendable {
    /// `1 - (1 - p)^3`
    case easeOutCubic = "ease-out-cubic"
    /// `p^2 (3 - 2p)`
    case smoothstep
}

/// The look of a caption, as data. A preset says nothing about what is said, when, or in which video:
/// that comes from the caption input. Every field is required, so a preset never depends on hidden
/// defaults. Contract: docs/caption-configuration.md#preset-contract
///
/// Values come only from `validate`, and outside this module they cannot be changed, so they always
/// keep its rules. Code inside the module may change one; the APIs that use a preset with an input
/// check it again.
public struct CaptionPreset: Equatable, Sendable {
    /// The `schema_version` this library reads.
    public static let schemaVersion = 1

    public internal(set) var presetID: String
    public internal(set) var presetVersion: String
    public internal(set) var description: String?
    public internal(set) var canvas: Canvas
    /// Every PostScript font name the preset uses, exactly. Fonts are a dependency, never substituted.
    public internal(set) var requiredFonts: [String]
    public internal(set) var text: Text
    public internal(set) var outline: Outline
    public internal(set) var shadow: Shadow
    public internal(set) var placement: Placement
    public internal(set) var timing: Timing
    public internal(set) var animation: Animation
    public internal(set) var emphasisStyles: [String: EmphasisStyle]

    public struct Canvas: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var fps: Double
    }

    public enum Alignment: String, CaseIterable, Sendable {
        case center
    }

    public struct Text: Equatable, Sendable {
        public var font: String
        public var size: Double
        public var color: RGBColor
        public var tracking: Double
        public var lineHeight: Double
        public var align: Alignment
        public var maxLines: Int
    }

    public struct Outline: Equatable, Sendable {
        public var width: Double
        public var color: RGBColor
        public var alpha: Double
    }

    /// A soft shadow cast by the outline. Offsets are in image coordinates: positive `dy` moves it down.
    public struct Shadow: Equatable, Sendable {
        public var color: RGBColor
        public var alpha: Double
        public var blur: Double
        public var dx: Double
        public var dy: Double
    }

    public enum PlacementMode: String, CaseIterable, Sendable {
        case fixed
    }

    /// Where a cue sits: lines centred on `x`, the first baseline at `baselineY` (pixels from the top).
    public struct Placement: Equatable, Sendable {
        public var mode: PlacementMode
        public var x: Double
        public var baselineY: Double
    }

    /// How long a cue stays on screen, derived from its words' timestamps (seconds).
    public struct Timing: Equatable, Sendable {
        /// Shown this long before its first word starts.
        public var leadIn: Double
        /// Kept this long after its last word ends.
        public var hold: Double
        public var minDuration: Double
        /// Gap kept between a cue and the next when they would overlap.
        public var minGap: Double
        public var overlap: Overlap
    }

    /// How a cue is cut short when the next one would start while it is still visible. The exact
    /// procedure: docs/caption-configuration.md#timing
    public struct Overlap: Equatable, Sendable {
        /// Fade-out used instead of the normal one when a cue is cut short.
        public var fadeOut: Double
        /// Margin kept from the word boundaries (next cue's first word, cut cue's last word) when
        /// placing the cut.
        public var wordMargin: Double
        /// Shortest time the cut cue stays visible before the cut, unless its words need longer.
        public var minVisible: Double
    }

    public struct Animation: Equatable, Sendable {
        public var fadeIn: FadeIn
        public var fadeOut: FadeOut
    }

    /// Fade-in; the cue also rises by `rise` pixels into place (it starts `rise` px lower).
    public struct FadeIn: Equatable, Sendable {
        public var duration: Double
        public var easing: Easing
        public var rise: Double
    }

    public struct FadeOut: Equatable, Sendable {
        public var duration: Double
        public var easing: Easing
    }

    /// When a style property switches from the base text to the emphasis value.
    public enum SwitchPoint: String, CaseIterable, Sendable {
        /// For as long as the cue is visible.
        case cueStart = "cue-start"
        /// Once the colour transition's progress exceeds `threshold`.
        case threshold
    }

    /// A named emphasis style that the caption input can apply to single words.
    public struct EmphasisStyle: Equatable, Sendable {
        public var font: String
        public var size: Double
        public var color: RGBColor
        public var transition: Transition
        public var fontFrom: SwitchPoint
        public var sizeFrom: SwitchPoint
    }

    /// The colour moves from the text colour to the emphasis colour, starting `lead` seconds before the
    /// word starts.
    public struct Transition: Equatable, Sendable {
        public var duration: Double
        public var lead: Double
        public var easing: Easing
        public var threshold: Double
    }

    /// The fonts the preset actually uses: the text font and each emphasis font, without repeats.
    public var usedFonts: [String] {
        var fonts = [text.font]
        for (_, style) in emphasisStyles.sorted(by: { $0.key < $1.key }) where !fonts.contains(style.font) {
            fonts.append(style.font)
        }
        return fonts
    }
}

extension CaptionPreset {
    static let idPattern = "^[a-z0-9]+(-[a-z0-9]+)*$"

    /// Validates a preset document. `value` is set only when there are no errors.
    public static func validate(_ data: Data) -> ValidationResult<CaptionPreset> {
        do {
            return validate(try JSONParser.parse(data))
        } catch {
            return ValidationResult(value: nil, issues: [ValidationIssue(.jsonMalformed, at: "", "not valid JSON: \(error)")])
        }
    }

    public static func validate(_ json: JSONValue) -> ValidationResult<CaptionPreset> {
        let r = DocumentReader()
        let preset = read(json, r)
        return ValidationResult(value: r.hasErrors ? nil : preset, issues: r.issues)
    }

    /// Reads a preset file and throws `CaptionDocumentError` when it has errors.
    public static func load(contentsOf url: URL) throws -> CaptionPreset {
        let result = validate(try Data(contentsOf: url))
        guard let preset = result.value else { throw CaptionDocumentError(file: url.path, issues: result.issues) }
        return preset
    }

    private static func read(_ json: JSONValue, _ r: DocumentReader) -> CaptionPreset? {
        let root = JSONPointer.root
        guard case .object(let top) = json else {
            _ = r.object(json, root, allowed: [])
            return nil
        }
        // A newer schema is reported alone: its fields would only show up as noise.
        if case .number(let v)? = top["schema_version"], v > Double(schemaVersion) {
            _ = r.schemaVersion(Fields(values: top, pointer: root), supported: schemaVersion)
            return nil
        }
        guard let f = r.object(json, root, allowed: [
            "schema_version", "preset_id", "preset_version", "description", "canvas", "required_fonts", "text",
            "outline", "shadow", "placement", "timing", "animation", "emphasis_styles",
        ]) else { return nil }

        let version = r.schemaVersion(f, supported: schemaVersion)
        let id = r.string(f, "preset_id", pattern: idPattern, patternText: "lowercase words joined by hyphens")
        let presetVersion = r.string(f, "preset_version", pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+$", patternText: "a MAJOR.MINOR.PATCH version")
        let description = r.string(f, "description", required: false)
        let canvas = readCanvas(f, r)
        let fonts = readFonts(f, r)
        let text = readText(f, r)
        let outline = r.object(f, "outline", allowed: ["width", "color", "alpha"]).flatMap { o in
            zip3(r.number(o, "width", .nonNegative), r.color(o, "color"), r.number(o, "alpha", .unit))
                .map { Outline(width: $0, color: $1, alpha: $2) }
        }
        let shadow = r.object(f, "shadow", allowed: ["color", "alpha", "blur", "dx", "dy"]).flatMap { s -> Shadow? in
            let color = r.color(s, "color"), alpha = r.number(s, "alpha", .unit), blur = r.number(s, "blur", .nonNegative)
            let dx = r.number(s, "dx", .any), dy = r.number(s, "dy", .any)
            guard let color, let alpha, let blur, let dx, let dy else { return nil }
            return Shadow(color: color, alpha: alpha, blur: blur, dx: dx, dy: dy)
        }
        let placement = readPlacement(f, r, canvas: canvas)
        let timing = readTiming(f, r)
        let animation = readAnimation(f, r)
        let styles = readEmphasisStyles(f, r)

        guard version != nil, let id, let presetVersion, let canvas, let fonts, let text, let outline, let shadow,
              let placement, let timing, let animation, let styles else { return nil }
        let preset = CaptionPreset(presetID: id, presetVersion: presetVersion, description: description, canvas: canvas,
                                   requiredFonts: fonts, text: text, outline: outline, shadow: shadow, placement: placement,
                                   timing: timing, animation: animation, emphasisStyles: styles)
        checkDeclaredFonts(preset, r)
        return preset
    }

    private static func readCanvas(_ f: Fields, _ r: DocumentReader) -> Canvas? {
        guard let c = r.object(f, "canvas", allowed: ["width", "height", "fps"]) else { return nil }
        let w = r.integer(c, "width", 1...16384), h = r.integer(c, "height", 1...16384)
        let fps = r.number(c, "fps", NumberRange(min: 0, minExclusive: true, max: 240, text: "greater than 0, at most 240"))
        guard let w, let h, let fps else { return nil }
        return Canvas(width: w, height: h, fps: fps)
    }

    private static func readFonts(_ f: Fields, _ r: DocumentReader) -> [String]? {
        guard let raw = r.field(f, "required_fonts") else { return nil }
        let p = f.pointer.appending("required_fonts")
        guard let items = r.array(raw, p, nonEmpty: true) else { return nil }
        var fonts: [String] = []
        for (i, item) in items.enumerated() {
            guard let name = r.string(item, p.appending(i)) else { continue }
            if fonts.contains(name) { r.error(.idDuplicate, p.appending(i), "font \"\(name)\" is listed twice") }
            else { fonts.append(name) }
        }
        return fonts.count == items.count ? fonts : nil
    }

    private static func readText(_ f: Fields, _ r: DocumentReader) -> Text? {
        guard let t = r.object(f, "text", allowed: ["font", "size", "color", "tracking", "line_height", "align", "max_lines"]) else { return nil }
        let font = r.string(t, "font"), size = r.number(t, "size", .positive), color = r.color(t, "color")
        let tracking = r.number(t, "tracking", .any), lineHeight = r.number(t, "line_height", .positive)
        let align = r.choice(t, "align", Alignment.self, unsupported: ["left", "right"])
        let maxLines = r.integer(t, "max_lines", 1...DocumentReader.maxExactInteger)
        guard let font, let size, let color, let tracking, let lineHeight, let align, let maxLines else { return nil }
        return Text(font: font, size: size, color: color, tracking: tracking, lineHeight: lineHeight, align: align, maxLines: maxLines)
    }

    private static func readPlacement(_ f: Fields, _ r: DocumentReader, canvas: Canvas?) -> Placement? {
        guard let p = r.object(f, "placement", allowed: ["mode", "x", "baseline_y"]) else { return nil }
        let mode = r.choice(p, "mode", PlacementMode.self, unsupported: ["avoid-regions", "auto"])
        let x = r.number(p, "x", canvas.map { NumberRange(min: 0, max: Double($0.width), text: "0 to the canvas width \($0.width)") } ?? .nonNegative)
        let y = r.number(p, "baseline_y", canvas.map { NumberRange(min: 0, max: Double($0.height), text: "0 to the canvas height \($0.height)") } ?? .nonNegative)
        guard let mode, let x, let y else { return nil }
        return Placement(mode: mode, x: x, baselineY: y)
    }

    private static func readTiming(_ f: Fields, _ r: DocumentReader) -> Timing? {
        guard let t = r.object(f, "timing", allowed: ["lead_in", "hold", "min_duration", "min_gap", "overlap"]) else { return nil }
        let leadIn = r.number(t, "lead_in", .nonNegative), hold = r.number(t, "hold", .nonNegative)
        let minDuration = r.number(t, "min_duration", .nonNegative), minGap = r.number(t, "min_gap", .nonNegative)
        let overlap = r.object(t, "overlap", allowed: ["fade_out", "word_margin", "min_visible"]).flatMap { o in
            zip3(r.number(o, "fade_out", .nonNegative), r.number(o, "word_margin", .nonNegative), r.number(o, "min_visible", .nonNegative))
                .map { Overlap(fadeOut: $0, wordMargin: $1, minVisible: $2) }
        }
        guard let leadIn, let hold, let minDuration, let minGap, let overlap else { return nil }
        return Timing(leadIn: leadIn, hold: hold, minDuration: minDuration, minGap: minGap, overlap: overlap)
    }

    private static func readAnimation(_ f: Fields, _ r: DocumentReader) -> Animation? {
        guard let a = r.object(f, "animation", allowed: ["fade_in", "fade_out"]) else { return nil }
        let fadeIn = r.object(a, "fade_in", allowed: ["duration", "easing", "rise"]).flatMap { o in
            zip3(r.number(o, "duration", .nonNegative), r.choice(o, "easing", Easing.self), r.number(o, "rise", .any))
                .map { FadeIn(duration: $0, easing: $1, rise: $2) }
        }
        let fadeOut = r.object(a, "fade_out", allowed: ["duration", "easing"]).flatMap { o -> FadeOut? in
            let d = r.number(o, "duration", .nonNegative), e = r.choice(o, "easing", Easing.self)
            guard let d, let e else { return nil }
            return FadeOut(duration: d, easing: e)
        }
        guard let fadeIn, let fadeOut else { return nil }
        return Animation(fadeIn: fadeIn, fadeOut: fadeOut)
    }

    private static func readEmphasisStyles(_ f: Fields, _ r: DocumentReader) -> [String: EmphasisStyle]? {
        guard let raw = r.field(f, "emphasis_styles") else { return nil }
        let p = f.pointer.appending("emphasis_styles")
        guard let entries = r.map(raw, p) else { return nil }
        var styles: [String: EmphasisStyle] = [:]
        var ok = true
        for (name, value) in entries {
            let sp = p.appending(name)
            if name.range(of: idPattern, options: .regularExpression) == nil {
                r.error(.valueInvalid, sp, "style name \"\(name)\" is not lowercase words joined by hyphens")
                ok = false
                continue
            }
            if let style = readEmphasisStyle(value, sp, r) { styles[name] = style } else { ok = false }
        }
        return ok ? styles : nil
    }

    private static func readEmphasisStyle(_ value: JSONValue, _ p: JSONPointer, _ r: DocumentReader) -> EmphasisStyle? {
        guard let s = r.object(value, p, allowed: ["font", "size", "color", "transition", "font_from", "size_from"]) else { return nil }
        let font = r.string(s, "font"), size = r.number(s, "size", .positive), color = r.color(s, "color")
        let transition = r.object(s, "transition", allowed: ["duration", "lead", "easing", "threshold"]).flatMap { t -> Transition? in
            let d = r.number(t, "duration", .nonNegative), lead = r.number(t, "lead", .nonNegative)
            let e = r.choice(t, "easing", Easing.self)
            let threshold = r.number(t, "threshold", NumberRange(min: 0, max: 1, text: "between 0 and 1"))
            guard let d, let lead, let e, let threshold else { return nil }
            return Transition(duration: d, lead: lead, easing: e, threshold: threshold)
        }
        let fontFrom = r.choice(s, "font_from", SwitchPoint.self), sizeFrom = r.choice(s, "size_from", SwitchPoint.self)
        guard let font, let size, let color, let transition, let fontFrom, let sizeFrom else { return nil }
        return EmphasisStyle(font: font, size: size, color: color, transition: transition, fontFrom: fontFrom, sizeFrom: sizeFrom)
    }

    /// `required_fonts` must list exactly the fonts the preset uses, so the dependency is explicit.
    private static func checkDeclaredFonts(_ preset: CaptionPreset, _ r: DocumentReader) {
        let p = JSONPointer.root.appending("required_fonts")
        for font in preset.usedFonts where !preset.requiredFonts.contains(font) {
            r.error(.fontUndeclared, p, "font \"\(font)\" is used but not listed in required_fonts")
        }
        for (i, font) in preset.requiredFonts.enumerated() where !preset.usedFonts.contains(font) {
            r.error(.fontUnused, p.appending(i), "font \"\(font)\" is listed but not used")
        }
    }
}

extension CaptionPreset {
    /// The value as a document, so that a changed value can be validated again with the same rules.
    var jsonValue: JSONValue {
        func color(_ c: RGBColor) -> JSONValue { .object(["srgb": .array([.number(c.red), .number(c.green), .number(c.blue)])]) }
        var doc: [String: JSONValue] = [
            "schema_version": .number(Double(Self.schemaVersion)),
            "preset_id": .string(presetID),
            "preset_version": .string(presetVersion),
            "canvas": .object(["width": .number(Double(canvas.width)), "height": .number(Double(canvas.height)), "fps": .number(canvas.fps)]),
            "required_fonts": .array(requiredFonts.map(JSONValue.string)),
            "text": .object(["font": .string(text.font), "size": .number(text.size), "color": color(text.color),
                             "tracking": .number(text.tracking), "line_height": .number(text.lineHeight),
                             "align": .string(text.align.rawValue), "max_lines": .number(Double(text.maxLines))]),
            "outline": .object(["width": .number(outline.width), "color": color(outline.color), "alpha": .number(outline.alpha)]),
            "shadow": .object(["color": color(shadow.color), "alpha": .number(shadow.alpha), "blur": .number(shadow.blur),
                               "dx": .number(shadow.dx), "dy": .number(shadow.dy)]),
            "placement": .object(["mode": .string(placement.mode.rawValue), "x": .number(placement.x), "baseline_y": .number(placement.baselineY)]),
            "timing": .object(["lead_in": .number(timing.leadIn), "hold": .number(timing.hold), "min_duration": .number(timing.minDuration),
                               "min_gap": .number(timing.minGap),
                               "overlap": .object(["fade_out": .number(timing.overlap.fadeOut), "word_margin": .number(timing.overlap.wordMargin),
                                                   "min_visible": .number(timing.overlap.minVisible)])]),
            "animation": .object(["fade_in": .object(["duration": .number(animation.fadeIn.duration), "easing": .string(animation.fadeIn.easing.rawValue),
                                                      "rise": .number(animation.fadeIn.rise)]),
                                  "fade_out": .object(["duration": .number(animation.fadeOut.duration), "easing": .string(animation.fadeOut.easing.rawValue)])]),
            "emphasis_styles": .object(emphasisStyles.mapValues { s in
                .object(["font": .string(s.font), "size": .number(s.size), "color": color(s.color),
                         "transition": .object(["duration": .number(s.transition.duration), "lead": .number(s.transition.lead),
                                                "easing": .string(s.transition.easing.rawValue), "threshold": .number(s.transition.threshold)]),
                         "font_from": .string(s.fontFrom.rawValue), "size_from": .string(s.sizeFrom.rawValue)])
            }),
        ]
        if let description { doc["description"] = .string(description) }
        return .object(doc)
    }
}

/// A `CaptionPreset` that breaks the rules `validate` guarantees, which only a value changed inside this
/// module can do. `issues` are the validator's errors for it; their pointers refer to the preset.
public struct InvalidCaptionPreset: Error, CustomStringConvertible {
    public let issues: [ValidationIssue]

    public var description: String {
        (["invalid caption preset"] + issues.map { "  " + $0.description }).joined(separator: "\n")
    }
}

/// A document that failed validation.
public struct CaptionDocumentError: Error, CustomStringConvertible {
    public let file: String
    public let issues: [ValidationIssue]

    public var description: String {
        ([file + ": invalid"] + issues.map { "  " + $0.description }).joined(separator: "\n")
    }
}

func zip3<A, B, C>(_ a: A?, _ b: B?, _ c: C?) -> (A, B, C)? {
    guard let a, let b, let c else { return nil }
    return (a, b, c)
}
