import Foundation
import Testing
@testable import FrameKitCaptions

/// `kinetic-minimal` reproduces the effective values of the frozen reference: what the reference frames
/// and the frozen renderer actually use, as exact floats.
@Suite struct KineticMinimal {
    let preset: CaptionPreset
    /// Reference frame items by frame index.
    let frames: [Int: [[String: Any]]]

    init() throws {
        preset = try CaptionPreset.load(contentsOf: Repo.url("captions/presets/kinetic-minimal.json"))
        let data = try Data(contentsOf: Repo.url("captions/tests/fixtures/ep001/frames.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try #require(root["frames"] as? [[String: Any]])
        frames = Dictionary(uniqueKeysWithValues: list.map { ($0["index"] as! Int, $0["items"] as! [[String: Any]]) })
    }

    /// Frames that show the generic look. 474 and 512 use the reference production's own "calm" and
    /// "shake" styles and 430 its manual placement, which are not part of the preset.
    static let genericFrames = [34, 51, 75, 118, 123]

    func runs(_ frame: Int) -> [[String: Any]] {
        frames[frame]!.flatMap { ($0["lines"] as! [[[String: Any]]]).joined() }
    }

    func run(_ frame: Int, _ text: String) -> [String: Any] {
        runs(frame).first { $0["text"] as? String == text }!
    }

    func rgb(_ value: Any?) -> RGBColor {
        let c = value as! [Double]
        return RGBColor(red: c[0], green: c[1], blue: c[2])
    }

    @Test func exactValues() {
        let expected = CaptionPreset(
            presetID: "kinetic-minimal", presetVersion: "1.0.0", description: preset.description,
            canvas: .init(width: 1080, height: 1916, fps: 24),
            requiredFonts: ["AvenirNext-Medium", "Palatino-Italic"],
            text: .init(font: "AvenirNext-Medium", size: 54, color: RGBColor(red: 0.9255, green: 0.9059, blue: 0.8784),
                        tracking: 0, lineHeight: 66, align: .center, maxLines: 2),
            outline: .init(width: 3.6, color: RGBColor(red: 0.07, green: 0.035, blue: 0.12), alpha: 0.92),
            shadow: .init(color: RGBColor(red: 0, green: 0, blue: 0), alpha: 0.5, blur: 10, dx: 0, dy: -3),
            placement: .init(mode: .fixed, x: 540, baselineY: 330),
            timing: .init(leadIn: 0.06, hold: 0.22, minDuration: 0.9, minGap: 0.02,
                          overlap: .init(fadeOut: 0.08, wordMargin: 0.03, minVisible: 0.5)),
            animation: .init(fadeIn: .init(duration: 0.14, easing: .easeOutCubic, rise: 8),
                             fadeOut: .init(duration: 0.16, easing: .smoothstep)),
            emphasisStyles: ["soft": .init(font: "Palatino-Italic", size: 58, color: RGBColor(red: 0.7647, green: 0.702, blue: 0.8784),
                                           transition: .init(duration: 0.22, lead: 0.02, easing: .smoothstep, threshold: 0.02),
                                           fontFrom: .cueStart, sizeFrom: .threshold)])
        #expect(preset == expected)
        #expect(preset.description?.isEmpty == false)
    }

    @Test(arguments: genericFrames)
    func itemStyleMatchesTheReferenceFrames(frame: Int) {
        for item in frames[frame]! {
            #expect(item["font"] as? String == preset.text.font)
            #expect(item["size"] as? Double == preset.text.size)
            #expect(item["tracking"] as? Double == preset.text.tracking)
            #expect(item["line_height"] as? Double == preset.text.lineHeight)
            #expect(item["y_base"] as? Double == preset.placement.baselineY)
            #expect(item["cx"] == nil && Double(preset.canvas.width) / 2 == preset.placement.x)  // reference default: centre
            #expect(item["stroke"] as? Double == preset.outline.width)
            #expect(rgb(item["outline"]) == preset.outline.color)
            #expect(item["shadow_blur"] as? Double == preset.shadow.blur)
            #expect(item["shadow_alpha"] as? Double == preset.shadow.alpha)
            // The reference passes the offset to CoreGraphics, where positive is up; the preset uses
            // image coordinates, where positive is down.
            #expect(item["shadow_dy"] as? Double == -preset.shadow.dy)
            #expect((item["lines"] as! [Any]).count <= preset.text.maxLines)
        }
    }

    @Test func textColourIsTheReferenceFloat() {
        for frame in Self.genericFrames {
            for run in runs(frame) where run["font"] == nil {
                #expect(rgb(run["color"]) == preset.text.color)
            }
        }
    }

    @Test func softEmphasisAtFullStrength() throws {
        let soft = try #require(preset.emphasisStyles["soft"])
        let peak = run(118, "legal")  // transition complete
        #expect(peak["font"] as? String == soft.font)
        #expect(peak["size"] as? Double == soft.size)
        #expect(rgb(peak["color"]) == soft.color)
    }

    @Test func softEmphasisFontFromCueStartSizeFromThreshold() throws {
        let soft = try #require(preset.emphasisStyles["soft"])
        #expect(soft.fontFrom == .cueStart && soft.sizeFrom == .threshold)
        // Before the transition the word is already in the emphasis font, at the text size and colour.
        for (frame, word) in [(34, "problema."), (75, "legal")] {
            let before = run(frame, word)
            #expect(before["font"] as? String == soft.font)
            #expect(before["size"] == nil)  // inherits the text size
            #expect(rgb(before["color"]) == preset.text.color)
        }
        // Early in the transition (progress above the threshold) it has the emphasis size; the colour
        // lies between the text and the emphasis colour.
        let early = run(51, "problema.")
        #expect(early["size"] as? Double == soft.size)
        let c = rgb(early["color"])
        #expect(c.red < preset.text.color.red && c.red > soft.color.red)
    }

    @Test func fadeInRise() {
        // During the fade-in the item is lowered by rise × (1 − progress), and alpha is the progress.
        for frame in [34, 430] {
            let item = frames[frame]![0]
            let alpha = item["alpha"] as! Double, dy = item["dy"] as! Double
            #expect(alpha < 1)
            #expect(abs(dy - preset.animation.fadeIn.rise * (1 - alpha)) < 1e-12)
        }
        // The fade-out does not move the caption.
        #expect(frames[118]![0]["dy"] as? Double == 0)
    }

    @Test func outlineAlphaAndShadowColourComeFromTheFrozenRenderer() throws {
        let source = try String(contentsOf: Repo.url("captions/reference/render_caps.swift"), encoding: .utf8)
        #expect(source.contains("ctx.setStrokeColor(color(outline, 0.92 * alpha))"))
        #expect(preset.outline.alpha == 0.92)
        #expect(source.contains("color: color([0, 0, 0], ((it[\"shadow_alpha\"] as? Double) ?? 0.62) * alpha)"))
        #expect(preset.shadow.color == RGBColor(red: 0, green: 0, blue: 0))
    }

    @Test func fontsAreAvailableOnThisMachine() {
        // The reference fonts ship with macOS; the regression suite needs them too.
        #expect(FontAvailability.check(preset) == [])
    }
}
