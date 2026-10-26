import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders a caption input with a preset into transparent RGBA frames: one `CaptionFrame` per video
/// frame, drawn with CoreText exactly as the frozen reference renderer draws (docs/caption-rendering.md).
/// Nothing in it is specific to a video: the words, cues and times come from the input, the look from the
/// preset, and which frames to render from the caller.
public struct CaptionRenderer: Sendable {
    public let input: CaptionInput
    public let preset: CaptionPreset
    /// Each cue's visible window (`CaptionInput.cueWindows(with:)`).
    public let windows: [CaptionInput.CueWindow]
    /// Frames from this index on show no caption: one past the last frame whose middle falls inside a
    /// cue's window. Frames before it may be empty too (between cues).
    public let frameCount: Int
    private let words: [String: CaptionInput.Word]

    /// Checks everything rendering depends on before any frame is drawn: the input against the preset
    /// (throws `InvalidCaptionInput` or `InvalidCaptionPreset`, as `cueWindows(with:)` does), and that
    /// every font of the preset is installed (throws `CaptionRenderError.fontsUnavailable`; a font is
    /// never substituted).
    public init(input: CaptionInput, preset: CaptionPreset) throws {
        windows = try input.cueWindows(with: preset)
        let missing = FontAvailability.check(preset)
        guard missing.isEmpty else { throw CaptionRenderError.fontsUnavailable(missing) }
        let lastEnd = windows.map(\.end).max() ?? 0
        // The middle of frame i is (i + 0.5) / fps; find the first one after the last cue, exactly.
        let fps = preset.canvas.fps
        let estimate = (lastEnd * fps).rounded(.down)
        guard estimate.magnitude < Double(1 << 53) else { throw CaptionRenderError.tooManyFrames(lastEnd: lastEnd, fps: fps) }
        var count = max(0, Int(estimate))
        while count > 0 && (Double(count - 1) + 0.5) / fps > lastEnd { count -= 1 }
        while (Double(count) + 0.5) / fps <= lastEnd { count += 1 }
        self.input = input
        self.preset = preset
        self.frameCount = count
        self.words = Dictionary(input.words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Seconds on the video timeline at the middle of frame `index`.
    public func time(ofFrame index: Int) -> Double {
        (Double(index) + 0.5) / preset.canvas.fps
    }

    /// What frame `index` shows. Any index is allowed; one outside every cue's window is empty.
    public func frame(_ index: Int) -> CaptionFrame {
        CaptionFrame.make(index: index, input: input, preset: preset, windows: windows, words: words)
    }

    /// The frame drawn on a transparent canvas of the preset's size: 8-bit RGBA, premultiplied, sRGB.
    public func image(of frame: CaptionFrame) throws -> CGImage {
        try CaptionRasterizer(width: preset.canvas.width, height: preset.canvas.height).draw(frame)
    }

    /// The frame as PNG: 8-bit RGBA, not interlaced, sRGB. The same frame on the same machine always
    /// gives the same bytes.
    public func png(of frame: CaptionFrame) throws -> Data {
        try CaptionRasterizer.png(image(of: frame))
    }

    /// Writes frames `indices` (all frames up to `frameCount` by default) as `NNNN.png` (the index, at
    /// least four digits) into `directory`, which is created if needed. Existing files with those names
    /// are replaced. Every frame of the range is written, empty or not. Returns the files in order.
    @discardableResult
    public func writeFrames(_ indices: Range<Int>? = nil, to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try (indices ?? 0..<frameCount).map { index in
            let url = directory.appendingPathComponent(String(format: "%04d.png", index))
            try png(of: frame(index)).write(to: url, options: .atomic)
            return url
        }
    }
}

public enum CaptionRenderError: Error, Equatable, CustomStringConvertible {
    /// Fonts of the preset that this machine cannot resolve exactly (`font.unavailable` issues).
    case fontsUnavailable([ValidationIssue])
    /// A font that did not resolve exactly while drawing.
    case fontUnavailable(String)
    /// The frame index of the last cue would not be an exact integer.
    case tooManyFrames(lastEnd: Double, fps: Double)
    /// CoreGraphics or ImageIO could not create the image (for example, out of memory).
    case imageFailed(String)

    public var description: String {
        switch self {
        case .fontsUnavailable(let issues): (["fonts unavailable"] + issues.map { "  " + $0.description }).joined(separator: "\n")
        case .fontUnavailable(let name): "font \"\(name)\" is not installed; it is never substituted"
        case .tooManyFrames(let end, let fps): "the last cue ends at \(end) s, too late to number its frames at \(fps) fps"
        case .imageFailed(let what): "could not \(what)"
        }
    }
}

/// Draws frames as the frozen reference renderer (`captions/reference/render_caps.swift`) does, call for
/// call, so that the same frame gives the same pixels. Where its behaviour is kept on purpose or differs,
/// docs/caption-rendering.md says so.
struct CaptionRasterizer {
    let width: Int
    let height: Int

    func draw(_ frame: CaptionFrame) throws -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CaptionRenderError.imageFailed("create a \(width)×\(height) bitmap") }
        func color(_ c: RGBColor, _ a: Double) -> CGColor { CGColor(colorSpace: cs, components: [c.red, c.green, c.blue, a])! }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)  // origin at the top left, y down
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        for item in frame.items {
            // Too faint to show, and skipped by the reference.
            guard item.alpha > 0.002 else { continue }
            let base = try Self.font(item.font, item.size)
            let space = FontLookup.serialized {
                CTFontGetAdvancesForGlyphs(base, .horizontal, [CTFontGetGlyphWithName(base, "space" as CFString)], nil, 1)
            }
            let top = item.baselineY + item.offsetY
            for (li, runs) in item.lines.enumerated() {
                let words = try runs.map { try (run: $0, glyphs: Self.glyphs($0.text, font: Self.font($0.font, $0.size), tracking: item.tracking)) }
                // Centred on centerX, words separated by one space of the text font. Summed word by word,
                // in the reference's order, so the result is the same to the last bit.
                var total = 0.0
                for (ri, w) in words.enumerated() {
                    total += w.glyphs.width
                    if ri < words.count - 1 { total += space }
                }
                var x = item.centerX - total / 2
                let baseline = top + Double(li) * item.lineHeight
                for (ri, w) in words.enumerated() {
                    let cx = x + w.glyphs.width / 2
                    var t = CGAffineTransform(translationX: cx, y: baseline).scaledBy(x: 1, y: -1).translatedBy(x: -w.glyphs.width / 2, y: 0)
                    let path = CGMutablePath()
                    for g in w.glyphs.paths { path.addPath(g.path, transform: CGAffineTransform(translationX: g.x, y: 0)) }
                    guard let placed = path.copy(using: &t) else { throw CaptionRenderError.imageFailed("place the glyphs of \"\(w.run.text)\"") }
                    // 1. the outline, casting the shadow (offsets go to CoreGraphics, where y points up)
                    ctx.saveGState()
                    ctx.setShadow(offset: CGSize(width: item.shadowDX, height: -item.shadowDY), blur: item.shadowBlur,
                                  color: color(item.shadowColor, item.shadowAlpha * item.alpha))
                    ctx.setLineWidth(item.outlineWidth)
                    ctx.setStrokeColor(color(item.outlineColor, item.outlineAlpha * item.alpha))
                    ctx.addPath(placed)
                    ctx.strokePath()
                    ctx.restoreGState()
                    // 2. the fill, on top, without a shadow
                    ctx.setFillColor(color(w.run.color, item.alpha))
                    ctx.addPath(placed)
                    ctx.fillPath()
                    x += w.glyphs.width
                    if ri < words.count - 1 { x += space }
                }
            }
        }
        guard let image = ctx.makeImage() else { throw CaptionRenderError.imageFailed("finish the frame image") }
        return image
    }

    /// The font with exactly this PostScript name; CoreText would silently substitute another.
    static func font(_ name: String, _ size: Double) throws -> CTFont {
        let font = FontLookup.serialized { CTFontCreateWithName(name as CFString, size, nil) }
        guard CTFontCopyPostScriptName(font) as String == name else { throw CaptionRenderError.fontUnavailable(name) }
        return font
    }

    struct Glyph {
        let path: CGPath
        let x: Double
    }

    /// The glyph outlines of `text` laid out by CoreText on one line, each `tracking` px further right than
    /// the one before, and the width they take.
    static func glyphs(_ text: String, font: CTFont, tracking: Double) -> (paths: [Glyph], width: Double) {
        FontLookup.serialized { layOut(text, font: font, tracking: tracking) }
    }

    private static func layOut(_ text: String, font: CTFont, tracking: Double) -> (paths: [Glyph], width: Double) {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        var out: [Glyph] = []
        var count = 0
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            for i in 0..<n {
                if let path = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
                    out.append(Glyph(path: path, x: positions[i].x + Double(count) * tracking))
                }
                count += 1
            }
        }
        return (out, CTLineGetTypographicBounds(line, nil, nil, nil) + Double(max(0, count - 1)) * tracking)
    }

    /// PNG with ImageIO's default settings, which write the same bytes as the reference's AppKit encoder.
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptionRenderError.imageFailed("start a PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptionRenderError.imageFailed("encode the PNG") }
        return data as Data
    }
}
