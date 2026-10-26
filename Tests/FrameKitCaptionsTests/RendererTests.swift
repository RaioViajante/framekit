import Foundation
import Testing
@testable import FrameKitCaptions

/// kinetic-minimal with fields changed, validated like any preset.
func kineticMinimal(_ changes: [String: JSONValue] = [:]) throws -> CaptionPreset {
    var doc = try Repo.json("captions/presets/kinetic-minimal.json")
    for (path, value) in changes { doc = doc.setting(path, value) }
    let result = CaptionPreset.validate(doc)
    return try #require(result.value, "\(result.issues)")
}

func captionInput(_ doc: JSONValue) throws -> CaptionInput {
    let result = CaptionInput.validate(doc)
    return try #require(result.value, "\(result.issues)")
}

/// One cue of one word, "Edge", shown from `start` to `end` (overrides), spoken in between.
func edgeInput(start: Double, end: Double) throws -> CaptionInput {
    try captionInput(["schema_version": 1, "language": "en",
                      "words": [["id": "w1", "text": "Edge", "start": .number(start + 0.125), "end": .number(end - 0.5)]],
                      "cues": [["id": "c1", "lines": [["w1"]], "start": .number(start), "end": .number(end)]]])
}

extension Pixels {
    /// The smallest rectangle holding every pixel with any opacity, or nil for a transparent image.
    var inkBounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var b: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<height {
            for x in 0..<width where rgba[(y * width + x) * 4 + 3] > 0 {
                b = (min(b?.minX ?? x, x), min(b?.minY ?? y, y), max(b?.maxX ?? x, x), max(b?.maxY ?? y, y))
            }
        }
        return b
    }

    var maxAlpha: UInt8 { stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }.max() ?? 0 }
}

extension CaptionRenderer {
    func pixels(_ index: Int) throws -> Pixels { try Pixels(png: png(of: frame(index))) }
}

/// The engine on inputs of its own: sampling, fades, emphasis, canvas, fonts, errors and output.
@Suite struct Renderer {
    @Test func framesAreSampledAtTheirMiddleAndCuesAreVisibleFromStartToEndInclusive() throws {
        // At 4 fps the frames' middles are 0.125, 0.375, …; the cue is shown from 0.375 to 1.875 exactly.
        let renderer = try CaptionRenderer(input: edgeInput(start: 0.375, end: 1.875), preset: kineticMinimal(["canvas.fps": 4]))
        #expect((0..<9).map(renderer.time(ofFrame:)) == [0.125, 0.375, 0.625, 0.875, 1.125, 1.375, 1.625, 1.875, 2.125])
        #expect(renderer.windows == [.init(start: 0.375, end: 1.875, fadeOut: 0.16)])
        #expect(renderer.frame(0).items.isEmpty)
        // At the very start: there, but fully transparent and the whole rise below its place.
        let first = try #require(renderer.frame(1).items.first)
        #expect(first.alpha == 0 && first.offsetY == 8)
        #expect(renderer.frame(2).items.first?.alpha == 1)
        #expect(renderer.frame(7).items.first?.alpha == 0)  // at the very end
        #expect(renderer.frame(8).items.isEmpty)
        #expect(renderer.frameCount == 8)
        for index in [0, 1, 7, 8] { #expect(try renderer.pixels(index).inkBounds == nil, "frame \(index) should be empty") }
    }

    @Test func fadeInRisesAndFadeOutFollowsTheEasings() throws {
        let renderer = try CaptionRenderer(input: edgeInput(start: 1, end: 2), preset: kineticMinimal(["canvas.fps": 100]))
        let window = renderer.windows[0]
        var previous = -1.0
        for index in 100...113 {
            let t = renderer.time(ofFrame: index)
            let item = try #require(renderer.frame(index).items.first)
            let p = min(1, (t - window.start) / 0.14)
            let fadeIn = 1 - pow(1 - p, 3)  // ease-out-cubic
            #expect(item.alpha == fadeIn)
            #expect(item.offsetY == (1 - fadeIn) * 8)
            #expect(item.alpha > previous)
            previous = item.alpha
        }
        #expect(renderer.frame(114).items.first?.offsetY == 0)  // in place once faded in
        for index in 184...199 {
            let t = renderer.time(ofFrame: index)
            let p = min(1, (window.end - t) / 0.16)
            #expect(renderer.frame(index).items.first?.alpha == p * p * (3 - 2 * p))  // smoothstep
            #expect(renderer.frame(index).items.first?.offsetY == 0)  // the fade-out does not move
        }
    }

    @Test func aCueCutShortUsesTheOverlapFadeOut() throws {
        let renderer = try CaptionRenderer(input: CaptionInput.load(contentsOf: Repo.url("captions/examples/overlapping-cues.input.json")),
                                           preset: kineticMinimal())
        #expect(renderer.windows.map(\.fadeOut) == [0.08, 0.16, 0.16])
        let cut = renderer.windows[0]
        let last = (0..<renderer.frameCount).last { renderer.time(ofFrame: $0) <= cut.end }!
        let p = (cut.end - renderer.time(ofFrame: last)) / 0.08
        #expect(renderer.frame(last).items.first { $0.cueID == "light" }?.alpha == min(1, p * p * (3 - 2 * p)))
        // Never two cues at once in this input: the next one starts after the cut.
        for index in 0..<renderer.frameCount { #expect(renderer.frame(index).items.count <= 1) }
    }

    @Test func softEmphasisTakesItsFontAtOnceAndItsSizeAndColourOverTheTransition() throws {
        let preset = try kineticMinimal()
        let renderer = try CaptionRenderer(input: CaptionInput.load(contentsOf: Repo.url("captions/examples/overlapping-cues.input.json")), preset: preset)
        func run(_ index: Int, _ text: String) throws -> CaptionFrame.Run {
            try #require(renderer.frame(index).items.first?.lines.joined().first { $0.text == text })
        }
        let text = preset.text, soft = try #require(preset.emphasisStyles["soft"])
        // "moves" starts at 0.64, so its transition starts at 0.62 and lasts 0.22 s.
        let before = try run(14, "moves")  // t = 0.604
        #expect(before == .init(text: "moves", font: soft.font, size: text.size, color: text.color))
        let during = try run(16, "moves")  // t = 0.6875
        let u = { (p: Double) in p * p * (3 - 2 * p) }((renderer.time(ofFrame: 16) - (0.64 - 0.02)) / 0.22)
        #expect(u > 0.02 && u < 1)
        #expect(during.font == soft.font && during.size == soft.size)
        #expect(during.color.red == text.color.red + (soft.color.red - text.color.red) * u)
        #expect(during.color.red < text.color.red && during.color.red > soft.color.red)
        let after = try run(25, "moves")  // t = 1.0625, transition over
        #expect(after.size == soft.size && after.color.blue == soft.color.blue)
        // Words without emphasis keep the text style throughout.
        #expect(try run(25, "Light") == .init(text: "Light", font: text.font, size: text.size, color: text.color))

        let late = try CaptionRenderer(input: renderer.input, preset: kineticMinimal(["emphasis_styles.soft.font_from": "threshold"]))
        #expect(late.frame(14).items.first?.lines.joined().first { $0.text == "moves" }?.font == text.font)
        #expect(late.frame(16).items.first?.lines.joined().first { $0.text == "moves" }?.font == soft.font)
    }

    @Test func aDurationOfZeroIsCompleteFromItsFirstInstant() throws {
        // At 4 fps, frame 1 is exactly the cue's start, 0.375 s.
        let renderer = try CaptionRenderer(input: edgeInput(start: 0.375, end: 1.875),
                                           preset: kineticMinimal(["canvas.fps": 4, "animation.fade_in.duration": 0]))
        let first = try #require(renderer.frame(1).items.first)
        #expect(first.alpha == 1 && first.offsetY == 0)
        // An emphasis transition of 0 s is complete exactly when it starts (word start − lead).
        let doc: JSONValue = ["schema_version": 1, "language": "en",
                              "words": [["id": "w1", "text": "Now", "start": 0.395, "end": 0.9]],
                              "cues": [["id": "c1", "lines": [["w1"]], "emphasis": ["w1": "soft"], "start": 0.125, "end": 1.875]]]
        let sudden = try CaptionRenderer(input: captionInput(doc), preset: kineticMinimal(["canvas.fps": 4, "emphasis_styles.soft.transition.duration": 0]))
        let soft = try #require(sudden.preset.emphasisStyles["soft"])
        #expect(sudden.time(ofFrame: 1) == 0.395 - 0.02)
        #expect(sudden.frame(0).items.first?.lines[0][0].color == sudden.preset.text.color)
        #expect(sudden.frame(1).items.first?.lines[0][0] == .init(text: "Now", font: soft.font, size: soft.size, color: soft.color))
    }

    @Test func aSwitchHappensOnlyAboveTheThreshold() throws {
        // With a threshold of 1 the progress never exceeds it: the size never switches, even at the end.
        let renderer = try CaptionRenderer(input: CaptionInput.load(contentsOf: Repo.url("captions/examples/overlapping-cues.input.json")),
                                           preset: kineticMinimal(["emphasis_styles.soft.transition.threshold": 1]))
        let moves = try #require(renderer.frame(25).items.first?.lines.joined().first { $0.text == "moves" })
        #expect(moves.color == renderer.preset.emphasisStyles["soft"]?.color)  // transition complete
        #expect(moves.size == renderer.preset.text.size)
    }

    @Test func alphaOfTheImageFollowsTheCue() throws {
        let renderer = try CaptionRenderer(input: edgeInput(start: 1, end: 2), preset: kineticMinimal(["canvas.fps": 100]))
        #expect(try renderer.pixels(150).maxAlpha == 255)  // fill fully opaque at rest
        let fading = try renderer.pixels(103)
        #expect(fading.maxAlpha > 0 && fading.maxAlpha < 255)
        // A cue at 0.002 or less is not drawn at all, as in the reference.
        var frame = renderer.frame(150)
        try #require(frame.items.count == 1)
        frame.items[0].alpha = 0.002
        #expect(try Pixels(png: renderer.png(of: frame)).inkBounds == nil)
        frame.items[0].alpha = 0.003
        #expect(try Pixels(png: renderer.png(of: frame)).inkBounds != nil)
    }

    @Test func placementAndShadowMoveTheInkInImageCoordinates() throws {
        let input = try edgeInput(start: 1, end: 2)
        func bounds(_ changes: [String: JSONValue]) throws -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
            let renderer = try CaptionRenderer(input: input, preset: kineticMinimal(changes))
            return try #require(renderer.pixels(36).inkBounds)
        }
        let base = try bounds([:])
        let moved = try bounds(["placement.x": 640, "placement.baseline_y": 1330])
        #expect(moved == (base.minX + 100, base.minY + 1000, base.maxX + 100, base.maxY + 1000))
        // A sharp, opaque shadow 20 px below (positive dy) or above (negative dy) the outline.
        let sharp: [String: JSONValue] = ["shadow.blur": 0, "shadow.alpha": 1]
        let below = try bounds(sharp.merging(["shadow.dy": 20]) { $1 })
        let above = try bounds(sharp.merging(["shadow.dy": -20]) { $1 })
        #expect(below.maxY - above.maxY == 20 && below.minY - above.minY == 20)
        let right = try bounds(sharp.merging(["shadow.dx": 15, "shadow.dy": 0]) { $1 })
        let none = try bounds(sharp.merging(["shadow.dy": 0]) { $1 })
        #expect(right.maxX - none.maxX == 15 && right.minX == none.minX)
    }

    @Test func canvasSizeAndFrameRateComeFromThePreset() throws {
        let preset = try kineticMinimal(["canvas.width": 640, "canvas.height": 360, "canvas.fps": 30,
                                         "placement.x": 320, "placement.baseline_y": 200])
        let renderer = try CaptionRenderer(input: CaptionInput.load(contentsOf: Repo.url("captions/examples/one-cue.input.json")), preset: preset)
        #expect(renderer.time(ofFrame: 3) == 3.5 / 30)
        #expect(renderer.frameCount == Int((renderer.windows[0].end * 30 - 0.5).rounded(.down)) + 1)
        let image = try renderer.pixels(20)
        #expect(image.width == 640 && image.height == 360)
        #expect(image.inkBounds != nil)
    }

    @Test func trackingSpacesGlyphsWithinAWord() throws {
        let font = try CaptionRasterizer.font("AvenirNext-Medium", 54)
        let plain = CaptionRasterizer.glyphs("Hello", font: font, tracking: 0)
        let spaced = CaptionRasterizer.glyphs("Hello", font: font, tracking: 2)
        #expect(plain.paths.count == 5)
        #expect(spaced.width == plain.width + 8)
        #expect(zip(spaced.paths, plain.paths).enumerated().allSatisfy { i, p in p.0.x == p.1.x + 2 * Double(i) })
    }

    @Test func missingFontsStopRenderingAndAreNeverSubstituted() throws {
        let missing = "FrameKitTestMissingFont-Regular"
        let preset = try kineticMinimal(["text.font": .string(missing), "required_fonts": [.string(missing), "Palatino-Italic"]])
        let input = try edgeInput(start: 1, end: 2)
        #expect {
            try CaptionRenderer(input: input, preset: preset)
        } throws: { error in
            guard case CaptionRenderError.fontsUnavailable(let issues) = error else { return false }
            return summary(issues) == ["font.unavailable /required_fonts/0"]
        }
        // The same check while drawing, for a font that went away after the renderer was made.
        let renderer = try CaptionRenderer(input: input, preset: kineticMinimal())
        var frame = renderer.frame(36)
        try #require(frame.items.count == 1)
        frame.items[0].lines[0][0].font = missing
        #expect(throws: CaptionRenderError.fontUnavailable(missing)) { try renderer.png(of: frame) }
    }

    /// In a fresh process, so the fonts are looked up for the first time: concurrent CoreText lookups from
    /// Swift concurrency could wait for the font server forever (see `FontLookup`).
    @Test func concurrentFontLookupsFinish() async {
        await #expect(processExitsWith: .success) {
            // A hang fails the test instead of stopping the run: a time limit does not end the child.
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 120)  // the first lookups alone took 23 s on a hosted runner
                exit(EXIT_FAILURE)
            }
            let names = ["AvenirNext-Medium", "Palatino-Italic", "FrameKitTestMissingFont-Regular"]
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<64 {
                    group.addTask {
                        _ = FontAvailability.isAvailable(names[i % 3])
                        if let font = try? CaptionRasterizer.font(names[i % 3], 54 + Double(i % 7)) {
                            _ = CaptionRasterizer.glyphs("Hello", font: font, tracking: 0)
                        }
                    }
                }
            }
        }
    }

    @Test func documentsWithErrorsNeverReachTheRenderer() throws {
        // Empty and invalid documents yield no value, so there is nothing to render.
        #expect(summary(CaptionInput.validate(Data()).issues) == ["json.malformed "])
        #expect(CaptionInput.validate(Data("{}".utf8)).value == nil)
        #expect(CaptionPreset.validate(Data("".utf8)).value == nil)
        // Valid alone, invalid with this preset: three lines where kinetic-minimal allows two.
        let threeLines = try captionInput(["schema_version": 1, "language": "en",
                                           "words": [["id": "a", "text": "One", "start": 1, "end": 1.2], ["id": "b", "text": "two", "start": 1.3, "end": 1.5],
                                                     ["id": "c", "text": "three", "start": 1.6, "end": 1.8]],
                                           "cues": [["id": "c1", "lines": [["a"], ["b"], ["c"]]]]])
        #expect {
            try CaptionRenderer(input: threeLines, preset: kineticMinimal())
        } throws: { error in
            summary((error as? InvalidCaptionInput)?.issues ?? []) == ["cue.too_many_lines /cues/0/lines"]
        }
        // A preset changed inside the module is checked again.
        var broken = try kineticMinimal()
        broken.canvas.fps = 0
        #expect(throws: InvalidCaptionPreset.self) { try CaptionRenderer(input: threeLines, preset: broken) }
    }

    @Test func aTimelineTooLongToNumberIsRefused() throws {
        let input = try captionInput(["schema_version": 1, "language": "en",
                                      "words": [["id": "a", "text": "Late", "start": 1e300, "end": 2e300]], "cues": [["id": "c1", "lines": [["a"]]]]])
        #expect(throws: CaptionRenderError.tooManyFrames(lastEnd: 2e300 + 0.22, fps: 24)) { try CaptionRenderer(input: input, preset: kineticMinimal()) }
    }

    @Test(arguments: ["captions/examples/one-cue.input.json", "captions/examples/two-cues.input.json",
                      "captions/examples/overlapping-cues.input.json"])
    func samplesRenderToTransparentFramesOfTheCanvasSize(path: String) throws {
        let renderer = try CaptionRenderer(input: CaptionInput.load(contentsOf: Repo.url(path)), preset: kineticMinimal())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("framekit-frames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try renderer.writeFrames(to: dir)
        #expect(files.map(\.lastPathComponent) == (0..<renderer.frameCount).map { String(format: "%04d.png", $0) })
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == renderer.frameCount)
        var shown: Set<String> = []
        for (index, file) in files.enumerated() {
            let data = try Data(contentsOf: file)
            #expect(data == (try renderer.png(of: renderer.frame(index))))  // deterministic
            let frame = renderer.frame(index)
            let visible = frame.items.contains { $0.alpha > 0.002 }
            if visible { shown.formUnion(frame.items.map(\.cueID)) }
            if index % 6 == 0 || !visible {
                let pixels = try Pixels(png: data)
                #expect(pixels.width == 1080 && pixels.height == 1916)
                #expect((pixels.inkBounds != nil) == visible, "frame \(index)")
            }
        }
        #expect(shown == Set(renderer.input.cues.map(\.id)))
        let some = try renderer.writeFrames(5..<7, to: dir)
        #expect(some.map(\.lastPathComponent) == ["0005.png", "0006.png"])
    }
}
