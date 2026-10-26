import Foundation

/// The captions of one video frame in drawing terms: every value resolved from the input and the preset
/// at the frame's instant, so that drawing needs nothing else. Frames come only from
/// `CaptionRenderer.frame(_:)`. Contract: docs/caption-rendering.md#the-rendering-engine
public struct CaptionFrame: Equatable, Sendable {
    public internal(set) var index: Int
    /// Seconds on the video timeline: the middle of the frame, `(index + 0.5) / fps`.
    public internal(set) var time: Double
    /// The cues visible at `time`, in input order.
    public internal(set) var items: [Item]

    /// One cue at this instant.
    public struct Item: Equatable, Sendable {
        public var cueID: String
        /// The text font and size: the default of each run, and the font of the spaces between words.
        public var font: String
        public var size: Double
        public var tracking: Double
        public var lineHeight: Double
        /// Horizontal centre of the lines and baseline of the first line, px from the top left.
        public var centerX: Double
        public var baselineY: Double
        /// Opacity of the whole cue, 0 to 1 (the fades). A cue at 0.002 or less is not drawn.
        public var alpha: Double
        /// Px the cue is drawn below its place (the fade-in rise).
        public var offsetY: Double
        public var outlineWidth: Double
        public var outlineColor: RGBColor
        public var outlineAlpha: Double
        public var shadowColor: RGBColor
        public var shadowAlpha: Double
        public var shadowBlur: Double
        /// Shadow offset in image coordinates: positive `shadowDY` moves the shadow down.
        public var shadowDX: Double
        public var shadowDY: Double
        /// Words, line by line; one run per word.
        public var lines: [[Run]]
    }

    /// One word with its own font, size and colour (emphasis changes them).
    public struct Run: Equatable, Sendable {
        public var text: String
        public var font: String
        public var size: Double
        public var color: RGBColor
    }
}

extension Easing {
    func callAsFunction(_ p: Double) -> Double {
        switch self {
        case .easeOutCubic: 1 - pow(1 - p, 3)
        case .smoothstep: p * p * (3 - 2 * p)
        }
    }

    /// The eased progress `elapsed` seconds into a change that lasts `duration` seconds, with the raw
    /// progress clamped to 0...1. A change of duration 0 is complete from its first instant.
    func progress(_ elapsed: Double, over duration: Double) -> Double {
        guard duration > 0 else { return elapsed >= 0 ? 1 : 0 }
        return self(max(0, min(1, elapsed / duration)))
    }
}

extension CaptionFrame {
    /// The frame at `index` for cues already resolved into `windows` (docs/caption-configuration.md#timing).
    static func make(index: Int, input: CaptionInput, preset: CaptionPreset, windows: [CaptionInput.CueWindow],
                     words: [String: CaptionInput.Word]) -> CaptionFrame {
        let t = (Double(index) + 0.5) / preset.canvas.fps
        var items: [Item] = []
        for (cue, window) in zip(input.cues, windows) where window.start <= t && t <= window.end {
            let a = preset.animation
            let fadeIn = a.fadeIn.easing.progress(t - window.start, over: a.fadeIn.duration)
            let fadeOut = a.fadeOut.easing.progress(window.end - t, over: window.fadeOut)
            let lines = cue.lines.map { ids in
                ids.compactMap { words[$0] }.map { run(for: $0, style: cue.emphasis[$0.id].flatMap { preset.emphasisStyles[$0] }, at: t, preset) }
            }
            items.append(Item(cueID: cue.id, font: preset.text.font, size: preset.text.size, tracking: preset.text.tracking,
                              lineHeight: preset.text.lineHeight, centerX: preset.placement.x, baselineY: preset.placement.baselineY,
                              alpha: min(fadeIn, fadeOut), offsetY: (1 - fadeIn) * a.fadeIn.rise,
                              outlineWidth: preset.outline.width, outlineColor: preset.outline.color, outlineAlpha: preset.outline.alpha,
                              shadowColor: preset.shadow.color, shadowAlpha: preset.shadow.alpha, shadowBlur: preset.shadow.blur,
                              shadowDX: preset.shadow.dx, shadowDY: preset.shadow.dy, lines: lines))
        }
        return CaptionFrame(index: index, time: t, items: items)
    }

    /// A word at `t`: in the text style, or moving towards its emphasis style (docs/caption-configuration.md#emphasis).
    private static func run(for word: CaptionInput.Word, style: CaptionPreset.EmphasisStyle?, at t: Double, _ preset: CaptionPreset) -> Run {
        let text = preset.text
        guard let style else { return Run(text: word.text, font: text.font, size: text.size, color: text.color) }
        let tr = style.transition
        let u = tr.easing.progress(t - (word.start - tr.lead), over: tr.duration)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * u }
        let color = RGBColor(red: mix(text.color.red, style.color.red), green: mix(text.color.green, style.color.green),
                             blue: mix(text.color.blue, style.color.blue))
        func switched(_ from: CaptionPreset.SwitchPoint) -> Bool { from == .cueStart || u > tr.threshold }
        return Run(text: word.text, font: switched(style.fontFrom) ? style.font : text.font,
                   size: switched(style.sizeFrom) ? style.size : text.size, color: color)
    }
}
