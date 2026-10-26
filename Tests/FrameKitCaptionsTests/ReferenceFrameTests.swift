import Foundation
import Testing
@testable import FrameKitCaptions

/// The engine against the frozen reference: the same frame items must give the same PNG bytes as the
/// frozen renderer built and run on this machine (any environment), and the same bytes as the goldens
/// where the environment is the goldens' one (docs/regression-testing.md).
@Suite struct ReferenceFrames {
    /// Frames whose every feature the engine has. 430's offset is a placement (`placement.x` 250).
    static let supported = [34, 51, 75, 118, 123, 430, 9999]

    let items: [Int: [[String: Any]]]

    init() throws {
        items = try Fixture.items()
    }

    func reference() throws -> ReferenceRun.Output {
        try ReferenceRun.output.get()
    }

    func enginePNG(_ index: Int) throws -> Data {
        let converted = try #require(items[index]).map { Fixture.engineItem($0) }
        let engineItems = try converted.map { try #require($0.item, "unsupported: \($0.unsupported)") }
        let frame = CaptionFrame(index: index, time: 0, items: engineItems)
        return try CaptionRasterizer.png(CaptionRasterizer(width: 1080, height: 1916).draw(frame))
    }

    @Test(arguments: supported)
    func sameBytesAsTheFrozenRendererOnThisMachine(frame: Int) throws {
        let reference = try #require(try reference().pngs[frame])
        let png = try enginePNG(frame)
        let differing = try Pixels(png: png).differingPixels(Pixels(png: reference))
        #expect(png == reference, "frame \(frame): \(differing) pixels differ from the frozen renderer")
    }

    @Test(arguments: supported)
    func sameBytesAsTheGoldensOnTheGoldensEnvironment(frame: Int) throws {
        let png = try enginePNG(frame)
        let golden = try Fixture.golden(frame)
        if try reference().environmentMatches {
            #expect(png == golden, "frame \(frame) differs from its golden on the goldens' environment")
        } else {
            // Not an equivalence claim: the goldens only bind their own environment.
            let differing = try Pixels(png: png).differingPixels(Pixels(png: golden))
            print("NOT VERIFIED: frame \(frame) vs golden on a different environment: \(png == golden ? "identical" : "\(differing) pixels differ")")
        }
    }

    @Test func framesWithFeaturesTheEngineLacksAreNamed() throws {
        // The reference production's own "calm" and "shake" emphasis, outside kinetic-minimal: measured
        // and documented in docs/caption-rendering.md, not drawn.
        let calm = Fixture.engineItem(try #require(items[474]?.first))
        #expect(calm.item == nil && calm.unsupported == ["\"funciona.\": vertical offset"])
        let shake = Fixture.engineItem(try #require(items[512]?.first))
        #expect(shake.item == nil && shake.unsupported == [
            "per-word horizontal offset", "\"quebro\": vertical offset", "\"quebro\": font AvenirNext-DemiBold, outside kinetic-minimal",
            "\"tudo,\": font AvenirNext-DemiBold, outside kinetic-minimal",
        ])
        #expect(Set(items.keys) == Set(Self.supported + [474, 512]))
    }

    /// Frames 75 and 123 show a whole cue at rest, which any timing that keeps the cue fully visible
    /// produces. Built from their words with made-up times, the input and kinetic-minimal give the
    /// fixture's items, field by field, and the same bytes as the frozen renderer.
    @Test(arguments: [75, 123])
    func inputAndPresetReproduceACueAtRest(frame: Int) throws {
        let preset = try CaptionPreset.load(contentsOf: Repo.url("captions/presets/kinetic-minimal.json"))
        let item = try #require(items[frame]?.first)
        let expected = try #require(Fixture.engineItem(item).item)
        let renderer = try CaptionRenderer(input: Self.input(restingAt: frame, item: item, fps: preset.canvas.fps), preset: preset)
        let produced = renderer.frame(frame)
        #expect(produced.items.count == 1)
        var actual = try #require(produced.items.first)
        actual.cueID = ""
        #expect(actual == expected)
        #expect(try renderer.png(of: produced) == reference().pngs[frame])
    }

    /// One cue with the item's words, line by line, fully visible at the frame. Every word but the last
    /// is spoken a second before; the last starts just after the frame, so its emphasis has not begun.
    static func input(restingAt frame: Int, item: [String: Any], fps: Double) throws -> CaptionInput {
        let t = (Double(frame) + 0.5) / fps
        let lines = (item["lines"] as! [[[String: Any]]]).map { $0.map { $0["text"] as! String } }
        let texts = lines.flatMap { $0 }
        var words: [JSONValue] = [], ids: [[JSONValue]] = [], emphasis: [String: JSONValue] = [:]
        var n = 0
        for line in (item["lines"] as! [[[String: Any]]]) {
            ids.append([])
            for run in line {
                let id = "w\(n)", isLast = n == texts.count - 1
                let start = isLast ? t + 0.1 : t - 1 + 0.1 * Double(n)
                words.append(["id": .string(id), "text": .string(run["text"] as! String), "start": .number(start), "end": .number(start + 0.08)])
                ids[ids.count - 1].append(.string(id))
                if run["font"] != nil { emphasis[id] = "soft" }
                n += 1
            }
        }
        var cue: [String: JSONValue] = ["id": "c1", "lines": .array(ids.map(JSONValue.array))]
        if !emphasis.isEmpty { cue["emphasis"] = .object(emphasis) }
        let doc: JSONValue = ["schema_version": 1, "language": "pt-BR", "words": .array(words), "cues": [.object(cue)]]
        let result = CaptionInput.validate(doc)
        return try #require(result.value, "\(result.issues)")
    }
}
